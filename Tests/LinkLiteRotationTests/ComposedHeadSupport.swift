// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore
import Testing
@testable import LinkLiteRotation

// Fakes for the composed orchestration: the real HeadController, HeadDriver, HeadRuntime, StreamLifecycle and
// DisplayIdentityAllocator run here, with only the platform replaced. Nothing sleeps: every timer, start, stop and
// mode setup waits on a ManualGate that the test releases, and state is awaited with `eventually`, which yields
// rather than waiting on a clock.

/// Holds callers until a test releases them. Each waiting caller carries a token the test matches on. A caller that
/// is cancelled is released at once, as a cancelled Task.sleep would be.
final class ManualGate<Token: Equatable & Sendable>: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let token: Token
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var cancelledBeforeWaiting: Set<UUID> = []

    /// Returns once a test releases a waiter with this token, or the caller is cancelled.
    func wait(_ token: Token) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if cancelledBeforeWaiting.remove(id) != nil { return true }
                    waiters.append(Waiter(id: id, token: token, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let waiter = lock.withLock { () -> Waiter? in
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                return waiters.remove(at: index)
            }
            cancelledBeforeWaiting.insert(id)
            return nil
        }
        waiter?.continuation.resume()
    }

    /// Releases the oldest waiter whose token matches. Returns whether one was released.
    @discardableResult
    func release(where matches: (Token) -> Bool) -> Bool {
        let waiter = lock.withLock { () -> Waiter? in
            guard let index = waiters.firstIndex(where: { matches($0.token) }) else { return nil }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume()
        return waiter != nil
    }

    /// The tokens of the callers still waiting, oldest first.
    var pending: [Token] {
        lock.withLock { waiters.map(\.token) }
    }
}

/// A failure the fake platform reports for a start.
struct FakeError: Error, CustomStringConvertible, Sendable {
    /// The message that the fake platform maps to `.permissionDenied` (as SCStreamError.userDeclined is in the app).
    static let screenRecordingDenied = "Screen Recording denied"

    let message: String
    var description: String { message }
}

/// The fake stream. Frames are counted only while its gate is open, as DisplayCapture submits them. Its stops follow a
/// script: each stop takes the next step, and once the script is empty a stop succeeds.
final class FakeStream: @unchecked Sendable {
    enum StopStep: Sendable, Equatable {
        case succeed
        case fail
        /// Waits until the test releases it, then succeeds.
        case stall
    }

    let id: Int
    let head: UInt8
    let gate: FrameGate
    private let stops: ManualGate<Int>
    private let onUsable: @Sendable () -> Void
    private let lock = NSLock()
    private var script: [StopStep] = []
    private var announced = false
    private var frames = 0
    private var attempts = 0
    private var confirmed = false

    init(id: Int, head: UInt8, gate: FrameGate, stops: ManualGate<Int>, onUsable: @escaping @Sendable () -> Void) {
        self.id = id
        self.head = head
        self.gate = gate
        self.stops = stops
        self.onUsable = onUsable
    }

    /// Frames that reached the engine, which happens only while the gate is open.
    var submittedFrames: Int { lock.withLock { frames } }
    var stopAttempts: Int { lock.withLock { attempts } }
    var isConfirmedStopped: Bool { lock.withLock { confirmed } }

    func scriptStops(_ steps: [StopStep]) {
        lock.withLock { script = steps }
    }

    /// One complete frame from the stream. Returns whether it was submitted.
    @discardableResult
    func deliverFrame() -> Bool {
        guard gate.whileOpen({ lock.withLock { frames += 1 } }) != nil else { return false }
        let first = lock.withLock { () -> Bool in
            if announced { return false }
            announced = true
            return true
        }
        if first { onUsable() }
        return true
    }

    /// Stops the stream, as the runtime asks. Closes the gate first, as DisplayCapture.stop does.
    func stop() async throws {
        gate.close()
        let step = lock.withLock { () -> StopStep in
            attempts += 1
            return script.isEmpty ? .succeed : script.removeFirst()
        }
        switch step {
        case .succeed:
            lock.withLock { confirmed = true }
        case .fail:
            throw FakeError(message: "stop not confirmed")
        case .stall:
            await stops.wait(id)
            lock.withLock { confirmed = true }
        }
    }
}

/// The fake capture backend: starts (which may be held), streams, and the stops that may stall.
final class FakeBackend: @unchecked Sendable {
    /// Held starts, by head, when `holdStarts` is set.
    let starts = ManualGate<UInt8>()
    /// Starts that have opened their gate and stream but have not returned yet, by head. Frames already flow here.
    let openedHolds = ManualGate<UInt8>()
    /// Stalled stops, by stream ID.
    let stops = ManualGate<Int>()
    /// Timers and retry delays, by duration.
    let sleeps = ManualGate<Duration>()

    private let lock = NSLock()
    private var holdStarts = false
    private var holdAfterOpen = false
    private var startFailures: [String] = []
    private var nextID = 0
    private var requested: [UInt8] = []
    private var made: [FakeStream] = []

    func setHoldStarts(_ hold: Bool) {
        lock.withLock { holdStarts = hold }
    }

    /// Holds each start after its stream has opened and started delivering frames, before the start returns.
    func setHoldAfterOpen(_ hold: Bool) {
        lock.withLock { holdAfterOpen = hold }
    }

    /// The next start fails with `message`.
    func failNextStart(_ message: String) {
        lock.withLock { startFailures.append(message) }
    }

    /// Heads a stream was requested for, in order.
    var startRequests: [UInt8] { lock.withLock { requested } }
    var streams: [FakeStream] { lock.withLock { made } }

    func stream(onHead head: UInt8) -> FakeStream? {
        lock.withLock { made.last { $0.head == head } }
    }

    func start(head: UInt8, gate: FrameGate, onUsable: @escaping @Sendable () -> Void) async throws -> FakeStream {
        let (hold, failure, id) = lock.withLock { () -> (Bool, String?, Int) in
            requested.append(head)
            nextID += 1
            let failure = startFailures.isEmpty ? nil : startFailures.removeFirst()
            return (holdStarts, failure, nextID)
        }
        if hold { await starts.wait(head) }
        if let failure { throw FakeError(message: failure) }
        // As DisplayCapture.begin: the gate opens just before the stream starts, unless it was closed meanwhile.
        gate.open()
        let stream = FakeStream(id: id, head: head, gate: gate, stops: stops, onUsable: onUsable)
        lock.withLock { made.append(stream) }
        let holdOpened = lock.withLock { holdAfterOpen }
        if holdOpened { await openedHolds.wait(head) }
        return stream
    }
}

/// A virtual display in the tests. The lease of its identity is attached, as VirtualDisplay does.
@MainActor
final class FakeDisplay {
    let identity: DisplayIdentity
    /// 1 for the first display the recorder made, and so on: tells apart displays that share an identity.
    let number: Int

    init(identity: DisplayIdentity, number: Int) {
        self.identity = identity
        self.number = number
    }
}

/// A weak reference, so the tests can see when a display is really deallocated and its identity freed.
struct WeakDisplay {
    weak var display: FakeDisplay?
}

/// The main-actor side of the fake platform: display creation with the real identity allocator, default modes,
/// and what was published or saved.
@MainActor
final class FakeRecorder {
    let identities = DisplayIdentityAllocator()
    var holdModes = false
    private var heldModes: [CheckedContinuation<ModeOutcome, Never>] = []
    private var scriptedModes: [ModeOutcome] = []
    private(set) var displays: [WeakDisplay] = []
    private(set) var creations: [(head: UInt8, orientation: DisplayOrientation, identity: DisplayIdentity)] = []
    /// Every creation the platform was asked for, including refused ones.
    private(set) var creationAttempts = 0
    private var scriptedCreations: [String] = []
    private(set) var modeCalls = 0
    private(set) var modeDisplays: [UInt64] = []
    /// The numbers of the displays whose default mode was actually set, in order. A setup that was cancelled before
    /// it set the mode adds nothing: the platform checks cancellation before the call, as DisplayHost does.
    private(set) var modeSetDisplays: [Int] = []
    private(set) var published: [[CursorTargetSpec]] = []
    private(set) var savedPreferences: [[String: Int]] = []
    private(set) var savedModes: [[String]] = []

    func scriptModes(_ outcomes: [ModeOutcome]) {
        scriptedModes = outcomes
    }

    /// Answers the oldest mode setup that is held.
    func answerHeldMode(_ outcome: ModeOutcome) -> Bool {
        guard !heldModes.isEmpty else { return false }
        heldModes.removeFirst().resume(returning: outcome)
        return true
    }

    var heldModeCount: Int { heldModes.count }

    /// The next creations are refused with these messages, in order. Later ones succeed.
    func scriptCreations(_ failures: [String]) {
        scriptedCreations = failures
    }

    func createDisplay(_ monitor: HeadMonitor, _ orientation: DisplayOrientation,
                       _ attached: [AttachedMonitor]) -> DisplayCreation<FakeDisplay> {
        creationAttempts += 1
        if !scriptedCreations.isEmpty {
            return .failed(scriptedCreations.removeFirst())
        }
        guard let claim = identities.claim(reported: monitor.reportedIdentity, head: monitor.head,
                                           attached: attached) else {
            return .identityHeld
        }
        let display = FakeDisplay(identity: claim.identity, number: displays.count + 1)
        DisplayLease.attach(claim.lease, to: display)
        displays.append(WeakDisplay(display: display))
        creations.append((monitor.head, orientation, claim.identity))
        return .created(display, claim.identity)
    }

    /// Like a system call: a held call returns only when the test answers it, whether or not it was cancelled. Then, as
    /// DisplayHost does, a cancelled setup sets nothing.
    func configureMode(_ display: FakeDisplay) async -> ModeOutcome {
        modeCalls += 1
        modeDisplays.append(UInt64(display.number))
        let outcome: ModeOutcome = holdModes
            ? await withCheckedContinuation { heldModes.append($0) }
            : (scriptedModes.isEmpty ? .applied : scriptedModes.removeFirst())
        guard !Task.isCancelled else { return .failed("the display was released") }
        if outcome == .applied { modeSetDisplays.append(display.number) }
        return outcome
    }

    func recordPublished(_ specs: [CursorTargetSpec]) {
        published.append(specs)
    }

    func recordPreferences(_ list: [String: Int]) {
        savedPreferences.append(list)
    }

    func recordModes(_ list: [String]) {
        savedModes.append(list)
    }

    /// True while the display made for the nth creation has not been deallocated.
    func isAlive(creation index: Int) -> Bool {
        displays.indices.contains(index) && displays[index].display != nil
    }
}

/// The composed app-side orchestration over the fakes: a HeadRuntime with a real HeadController.
@MainActor
final class ComposedHeads {
    let backend = FakeBackend()
    let recorder = FakeRecorder()
    let runtime: HeadRuntime<FakeDisplay, FakeStream>
    /// Kept only so the observer lives as long as the harness. Its block holds the harness weakly, so an observer
    /// left behind by a finished test does nothing.
    private var identityObserver: NSObjectProtocol?

    init(preferences: OrientationPreferences = OrientationPreferences(), configured: [String] = []) {
        let backend = self.backend
        let recorder = self.recorder
        runtime = HeadRuntime(
            controller: HeadController(preferences: preferences, configuredModes: configured),
            platform: HeadPlatform(
                createDisplay: { monitor, orientation, attached, _ in
                    recorder.createDisplay(monitor, orientation, attached)
                },
                startStream: { _, monitor, _, gate, onUsable, _ in
                    try await backend.start(head: monitor.head, gate: gate, onUsable: onUsable)
                },
                stopStream: { try await $0.stop() },
                failure: { error in
                    let message = (error as? FakeError)?.message ?? String(describing: error)
                    return message == FakeError.screenRecordingDenied ? .permissionDenied : .failed(message)
                },
                configureMode: { display, _, _ in
                    await recorder.configureMode(display)
                },
                publishCursorTargets: { targets in
                    recorder.recordPublished(targets.map(\.spec))
                },
                savePreferences: { recorder.recordPreferences($0) },
                saveConfiguredModes: { recorder.recordModes($0) },
                sleep: { duration in await backend.sleeps.wait(duration) }
            )
        )
        // As DisplayHost: a released identity wakes the heads that wait for one.
        identityObserver = NotificationCenter.default.addObserver(
            forName: DisplayIdentityAllocator.identityReleasedNotification, object: recorder.identities, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runtime.send(.identityMayBeFree) }
        }
    }

    // MARK: Driving the app

    func attach(_ head: UInt8, serial: UInt32 = 0x1234_5678, cursor: Bool = true) {
        runtime.send(.monitorAttached(runtimeMonitor(head, serial: serial, cursor: cursor)))
    }

    func detach(_ head: UInt8) {
        runtime.send(.monitorDetached(head: head))
    }

    func rotate(_ head: UInt8, _ orientation: DisplayOrientation) {
        runtime.send(.setOrientation(head: head, orientation: orientation))
    }

    func status(_ head: UInt8) -> HeadStatus? {
        runtime.controller.status(forHead: head)
    }

    /// Yields until `condition` holds. Fails the test if it never does, after a bounded number of turns.
    func eventually(_ message: String = "", _ condition: () -> Bool) async {
        for _ in 0..<5_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("never reached: \(message)")
    }

    /// The nth display the platform made. Fails the test, rather than crashing it, if there is none.
    func madeDisplay(_ index: Int) throws -> (head: UInt8, orientation: DisplayOrientation, identity: DisplayIdentity) {
        try #require(recorder.creations.indices.contains(index), "display \(index) was never made")
        return recorder.creations[index]
    }

    /// The nth stream the backend made, in order. Fails the test, rather than crashing it, if there is none.
    func stream(_ index: Int) throws -> FakeStream {
        let streams = backend.streams
        try #require(streams.indices.contains(index), "stream \(index) was never made")
        return streams[index]
    }

    /// Yields a fixed number of times, so work that should not happen has had every chance to.
    func settle() async {
        for _ in 0..<500 { await Task.yield() }
    }
}

/// A monitor on a head. Its EDID identity is the same for every serial the tests pass.
func runtimeMonitor(_ head: UInt8, serial: UInt32 = 0x1234_5678, cursor: Bool = true) -> HeadMonitor {
    HeadMonitor(head: head, vendorID: 0x22f0, productCode: 0x3a4b, serial: serial, width: 3840, height: 2160,
                refreshHz: 60, widthMillimeters: 597, heightMillimeters: 336, name: "Dock \(head)",
                hardwareCursor: cursor)
}
