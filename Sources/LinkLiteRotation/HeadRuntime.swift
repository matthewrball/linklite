// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore

/// What the platform made of a display request.
public enum DisplayCreation<Display> {
    /// The display, and the identity it was created with.
    case created(Display, DisplayIdentity)
    /// The identity is still held by a display being released. The controller asks again later.
    case identityHeld
    case failed(String)
}

/// The platform operations of a HeadRuntime. DisplayHost supplies the real ones (VirtualDisplay, DisplayCapture,
/// display modes, UserDefaults); tests supply fakes. Each closure notes where it is called from.
public struct HeadPlatform<Display: AnyObject & Sendable, Stream: Sendable> {
    /// Creates the display for `monitor`, claiming its identity against `attached` (the other monitors on the bus).
    /// `onTerminated` runs on the main actor if the window server removes the display later.
    public var createDisplay: @MainActor (_ monitor: HeadMonitor, _ orientation: DisplayOrientation,
                                          _ attached: [AttachedMonitor],
                                          _ onTerminated: @escaping @MainActor () -> Void) -> DisplayCreation<Display>

    /// Starts one stream of `display`. The stream must deliver frames only through `gate.whileOpen`, and open the
    /// gate only when it is about to start. `onUsableFrame` is called once, at its first usable frame. `onStop` is
    /// called if the stream stops or fails on its own. Neither stops the stream: the runtime does, through
    /// `stopStream`, when the controller asks.
    public var startStream: @Sendable (_ display: Display, _ monitor: HeadMonitor, _ orientation: DisplayOrientation,
                                       _ gate: FrameGate, _ onUsableFrame: @escaping @Sendable () -> Void,
                                       _ onStop: @escaping @Sendable (Error) -> Void) async throws -> Stream

    /// Stops one stream. Throws if the stream cannot be confirmed stopped; it is then kept and retried.
    public var stopStream: @Sendable (Stream) async throws -> Void

    /// Maps a start or stop error to the reason the controller shows.
    public var failure: @Sendable (Error) -> CaptureFailure

    /// Sets the display's default mode. Never touches a capture.
    public var configureMode: @MainActor (_ display: Display, _ monitor: HeadMonitor,
                                          _ orientation: DisplayOrientation) async -> ModeOutcome

    /// The cursor targets to point at, each with the display it is on.
    public var publishCursorTargets: @MainActor ([(spec: CursorTargetSpec, display: Display)]) -> Void

    public var savePreferences: @MainActor ([String: Int]) -> Void

    public var saveConfiguredModes: @MainActor ([String]) -> Void

    /// Waits for a timer. Tests replace it with a gate that they open.
    public var sleep: @Sendable (Duration) async -> Void

    public init(createDisplay: @escaping @MainActor (HeadMonitor, DisplayOrientation, [AttachedMonitor],
                                                     @escaping @MainActor () -> Void) -> DisplayCreation<Display>,
                startStream: @escaping @Sendable (Display, HeadMonitor, DisplayOrientation, FrameGate,
                                                  @escaping @Sendable () -> Void,
                                                  @escaping @Sendable (Error) -> Void) async throws -> Stream,
                stopStream: @escaping @Sendable (Stream) async throws -> Void,
                failure: @escaping @Sendable (Error) -> CaptureFailure,
                configureMode: @escaping @MainActor (Display, HeadMonitor, DisplayOrientation) async -> ModeOutcome,
                publishCursorTargets: @escaping @MainActor ([(spec: CursorTargetSpec, display: Display)]) -> Void,
                savePreferences: @escaping @MainActor ([String: Int]) -> Void = { _ in },
                saveConfiguredModes: @escaping @MainActor ([String]) -> Void = { _ in },
                sleep: @escaping @Sendable (Duration) async -> Void = { duration in
                    try? await Task.sleep(for: duration)
                }) {
        self.createDisplay = createDisplay
        self.startStream = startStream
        self.stopStream = stopStream
        self.failure = failure
        self.configureMode = configureMode
        self.publishCursorTargets = publishCursorTargets
        self.savePreferences = savePreferences
        self.saveConfiguredModes = saveConfiguredModes
        self.sleep = sleep
    }
}

/// The app's HeadEffects: performs every HeadCommand, and feeds results back to its HeadDriver.
///
/// One owner for capture lifetime. Every capture of a head is started, cancelled and stopped through the head's
/// StreamLifecycle, keyed by head, so a head never has two streams running and a stop is never raced by a second
/// stop. A cancelled attempt's frame gate is closed at once, before its stop is queued: a stream that is still
/// starting, or whose stop stalls, cannot submit a frame to its head. A display is dropped only after the head's
/// captures are confirmed stopped, so its identity is free only once no stream can use it.
@MainActor
public final class HeadRuntime<Display: AnyObject & Sendable, Stream: Sendable>: HeadEffects {
    /// A display the runtime holds, with the identity it was created with. A class, so the ledger can hold it.
    private final class LiveDisplay {
        let display: Display
        let identity: DisplayIdentity

        init(display: Display, identity: DisplayIdentity) {
            self.display = display
            self.identity = identity
        }
    }

    /// The controller driven by this runtime. Its events arrive through `send`, or from the results of commands.
    public let driver: HeadDriver
    private let platform: HeadPlatform<Display, Stream>
    /// The displays the controller has not released, by generation, and the default-mode operations running on them.
    /// A display is dropped only after its head's streams are confirmed stopped and its outstanding mode operation has
    /// been cancelled and has returned; its identity goes with it. See DisplayLedger.
    private let displays = DisplayLedger<LiveDisplay>()
    /// The frame gate of each attempt that has not been retired.
    private var gates: [CaptureAttempt: FrameGate] = [:]
    /// The lifecycle attempt behind each controller attempt that has not been retired.
    private var lifecycleAttempts: [CaptureAttempt: StreamLifecycle<UInt8, Stream>.Attempt] = [:]
    private var timers: [HeadTimer: Task<Void, Never>] = [:]
    private var unconfirmedHeads = Set<UInt8>()

    /// Called on the main actor when a head's unconfirmed stop begins or is confirmed.
    public var onStopStateChanged: (() -> Void)?

    private lazy var lifecycle = StreamLifecycle<UInt8, Stream>(
        stopStream: platform.stopStream,
        retryDelay: { [sleep = platform.sleep] failures in
            await sleep(StreamRetry.interval(afterFailures: failures))
        },
        unconfirmedChanged: { [weak self] head in
            Task { @MainActor in self?.stopStateChanged(head) }
        }
    )

    public init(controller: HeadController, platform: HeadPlatform<Display, Stream>) {
        self.platform = platform
        driver = HeadDriver(controller: controller)
        driver.effects = self
    }

    public var controller: HeadController { driver.controller }

    public func send(_ event: HeadEvent) {
        driver.send(event)
    }

    /// The display of a generation, while the runtime holds it.
    public func display(_ generation: UInt64) -> Display? {
        displays[generation]?.display
    }

    /// True while some head has a stream whose stop is not confirmed.
    public var hasUnconfirmedStops: Bool { !unconfirmedHeads.isEmpty }

    /// Returns once every operation queued so far for `head` has finished and its streams are confirmed stopped.
    /// Waits as long as a stop keeps failing. Used by tests.
    public func quiesce(_ head: UInt8) async {
        await lifecycle.confirmedStopped(head).value
    }

    // MARK: - HeadEffects

    public func perform(_ command: HeadCommand) -> HeadEvent? {
        switch command {
        case .createDisplay(let head, let generation, let monitor, let orientation):
            return createDisplay(head: head, generation: generation, monitor: monitor, orientation: orientation)

        case .releaseDisplay(let head, let generation, let afterStopping):
            // Cancellations are queued before the confirmed-stop wait is taken: that wait covers only the streams
            // already unconfirmed, so the stops queued here must come first.
            for attempt in afterStopping { retire(attempt) }
            // The default-mode operation is cancelled now, not once the stop is confirmed: from the request on, nothing
            // new starts on the display and nothing it reports is accepted. The display itself is still held below.
            displays.beginRelease(generation)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.lifecycle.confirmedStopped(head).value
                // Only now: no stream on the head can use the display. The release also waits for the cancelled
                // operation to return, so the display, and with it its identity, outlives neither. A cancelled
                // operation reports nothing.
                await self.displays.release(generation) {
                    self.driver.send(.displayReleased(display: generation))
                }
            }
            return nil

        case .startCapture(let attempt, let generation, let monitor, let orientation):
            return startCapture(attempt, generation: generation, monitor: monitor, orientation: orientation)

        case .stopCapture(let attempt):
            retire(attempt)
            return nil

        case .configureMode(let head, let generation, let monitor, let orientation):
            // The operation is tracked by the display's ledger entry: its report reaches the controller only if it was
            // not cancelled, and a release waits for it to return.
            let configure = platform.configureMode
            switch displays.start(generation, operation: { live in
                await configure(live.display, monitor, orientation)
            }, report: { [weak self] outcome in
                self?.driver.send(.modeSetupFinished(head: head, display: generation, outcome: outcome))
            }) {
            case .started, .alreadyRunning:
                return nil
            case .unknownDisplay:
                return .modeSetupFinished(head: head, display: generation, outcome: .failed("The virtual display is gone"))
            }

        case .scheduleTimer(let timer, let delay):
            timers[timer]?.cancel()
            let sleep = platform.sleep
            timers[timer] = Task { @MainActor [weak self] in
                await sleep(delay)
                guard !Task.isCancelled, let self else { return }
                self.timers[timer] = nil
                self.driver.send(.timerFired(timer))
            }
            return nil

        case .cancelTimer(let timer):
            timers.removeValue(forKey: timer)?.cancel()
            return nil

        case .publishCursorTargets(let specs):
            platform.publishCursorTargets(specs.compactMap { spec in
                displays[spec.display].map { (spec: spec, display: $0.display) }
            })
            return nil

        case .savePreferences(let propertyList):
            platform.savePreferences(propertyList)
            return nil

        case .saveConfiguredModes(let entries):
            platform.saveConfiguredModes(entries)
            return nil
        }
    }

    // MARK: - Displays

    private func createDisplay(head: UInt8, generation: UInt64, monitor: HeadMonitor,
                               orientation: DisplayOrientation) -> HeadEvent {
        let result = platform.createDisplay(monitor, orientation, attachedMonitors(except: head)) { [weak self] in
            self?.driver.send(.displayTerminated(display: generation))
        }
        switch result {
        case .created(let display, let identity):
            displays.register(LiveDisplay(display: display, identity: identity), generation: generation)
            return .displayCreated(head: head, display: generation, identity: identity)
        case .identityHeld:
            return .displayCreationWaiting(head: head, display: generation)
        case .failed(let message):
            return .displayCreationFailed(head: head, display: generation, message: message)
        }
    }

    /// The monitors on the other heads, with the identities their displays hold, as the identity claim needs them.
    private func attachedMonitors(except head: UInt8) -> [AttachedMonitor] {
        driver.controller.attachedMonitors.compactMap { entry in
            guard entry.head != head else { return nil }
            return AttachedMonitor(reported: entry.monitor.reportedIdentity,
                                   identity: entry.display.flatMap { displays[$0]?.identity },
                                   head: entry.head)
        }
    }

    // MARK: - Captures

    /// Queues a start behind every earlier operation on the head. Its answer comes back as an event: .captureStarted
    /// only once the lifecycle has kept the stream, or .captureStartFailed. A cancelled start sends nothing.
    private func startCapture(_ attempt: CaptureAttempt, generation: UInt64, monitor: HeadMonitor,
                              orientation: DisplayOrientation) -> HeadEvent? {
        guard let live = displays[generation] else {
            return .captureStartFailed(attempt, .failed("The virtual display is gone"))
        }
        let gate = FrameGate()
        gates[attempt] = gate
        let display = live.display
        let startStream = platform.startStream
        let failure = platform.failure
        let (lifecycleAttempt, outcome) = lifecycle.start(attempt.head) {
            try await startStream(
                display, monitor, orientation, gate,
                { Task { @MainActor [weak self] in self?.driver.send(.captureUsableFrame(attempt)) } },
                { error in Task { @MainActor [weak self] in self?.driver.send(.captureStopped(attempt, failure(error))) } }
            )
        }
        lifecycleAttempts[attempt] = lifecycleAttempt
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if case .started = try await outcome.value {
                    self.driver.send(.captureStarted(attempt))
                } else {
                    self.forget(attempt)
                }
            } catch {
                self.forget(attempt)
                self.driver.send(.captureStartFailed(attempt, self.failureOf(error)))
            }
        }
        return nil
    }

    /// Retires a capture attempt. Its gate closes now, so no frame or cursor report from it can reach the engine, and
    /// its stream, if it has one, is stopped by an operation queued behind everything already queued on the head.
    /// Idempotent: a second retire of the same attempt does nothing.
    private func retire(_ attempt: CaptureAttempt) {
        gates.removeValue(forKey: attempt)?.close()
        guard let lifecycleAttempt = lifecycleAttempts.removeValue(forKey: attempt) else { return }
        lifecycle.cancel(lifecycleAttempt, on: attempt.head)
    }

    /// Drops the bookkeeping of an attempt that ended without a stream, or whose stream was taken by its stop.
    private func forget(_ attempt: CaptureAttempt) {
        gates.removeValue(forKey: attempt)?.close()
        lifecycleAttempts.removeValue(forKey: attempt)
    }

    private func failureOf(_ error: Error) -> CaptureFailure {
        if let notConfirmed = error as? StreamStopNotConfirmed {
            return .failed(notConfirmed.errorDescription ?? "Previous capture did not confirm it stopped")
        }
        return platform.failure(error)
    }

    private func stopStateChanged(_ head: UInt8) {
        let unconfirmed = lifecycle.unconfirmedCount(head) > 0
        if unconfirmed {
            unconfirmedHeads.insert(head)
        } else {
            unconfirmedHeads.remove(head)
        }
        // The controller shows it on the head, which may have no display (or be waiting for one) by now.
        driver.send(.stopConfirmationChanged(head: head, unconfirmed: unconfirmed))
        onStopStateChanged?()
    }
}
