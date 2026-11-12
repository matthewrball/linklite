// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import CDLLite
import CoreGraphics
import Foundation
import LinkLiteCore
import LinkLiteRotation
import os
import ScreenCaptureKit

private let log = Logger(subsystem: "com.ball.linklite", category: "host")
private let perfLog = Logger(subsystem: "com.ball.linklite", category: "perf")

extension HeadMonitor {
    init(_ info: MonitorInfo) {
        self.init(head: info.head, vendorID: info.vendorID, productCode: info.productCode, serial: info.serial,
                  width: info.width, height: info.height, refreshHz: info.refreshHz,
                  widthMillimeters: info.widthMillimeters, heightMillimeters: info.heightMillimeters,
                  name: info.name, hardwareCursor: info.hardwareCursor)
    }
}

/// Ties the engine to macOS. The rules live in HeadController (LinkLiteRotation). HeadRuntime performs its commands
/// with the real engine, virtual display, ScreenCaptureKit and user defaults, through one StreamLifecycle per head.
/// This class supplies the platform operations and the identity claims, and feeds results back as events.
@MainActor
final class DisplayHost {
    private(set) var engineState: DLLState?
    private(set) var engineMessage = "Starting…"
    /// Called after any change the menu shows. Never called from inside a change: see `changes`.
    var onChange: (() -> Void)?

    private nonisolated static let configuredMonitorsKey = "ConfiguredMonitors"
    private nonisolated static let identityRecordsKey = "DisplayIdentityRecords"
    /// `defaults write com.ball.linklite PerformanceLogging -bool true` logs engine counters once a
    /// second (category "perf"); read at start.
    private nonisolated static let performanceLoggingKey = "PerformanceLogging"

    private let engine = EngineHandle()
    private lazy var cursor = CursorTracker(engine: engine)
    /// Decides the identity each virtual display is created with, and holds each identity until its display is
    /// deallocated. Its records persist, so each socket keeps its identity across launches.
    private let identities: DisplayIdentityAllocator
    private lazy var runtime: HeadRuntime<VirtualDisplay, DisplayCapture> = makeRuntime()
    /// Screen Recording access: the launch request and the activation recheck. Its grants go to the runtime.
    private lazy var screenRecording = ScreenRecordingAccess(
        platform: ScreenRecordingAccess.Platform(
            isGranted: { CGPreflightScreenCaptureAccess() },
            requestAccess: { CGRequestScreenCaptureAccess() }
        )
    ) { [weak self] granted in
        self?.runtime.send(.permissionChanged(granted: granted))
    }
    /// Delivers `onChange` once per run of changes, on a later main-actor turn, so a retry or a notification that
    /// changes state cannot call back into the observer during the change.
    private lazy var changes = CoalescedNotifier(
        schedule: { work in Task { @MainActor in work() } },
        deliver: { [weak self] in self?.onChange?() }
    )
    private var displayReconfigured: NSObjectProtocol?
    private var identityReleased: NSObjectProtocol?
    private var perfTimer: Timer?
    private var gammaTimer: Timer?
    private var perfIntervalStart = ContinuousClock.now
    /// The cursor targets last given to CursorTracker, so screen changes can refresh them.
    private var lastCursorTargets: [CursorTracker.Target] = []
    /// The gamma table last sent to the engine per head (R, G, B, 256 bytes each); nil sends again.
    private var sentGamma: [UInt8: [UInt8]] = [:]
    /// The capture attempt the gamma table was last sent for, per head. A new stream may follow a new engine mailbox,
    /// so the table is sent again when the attempt changes.
    private var gammaAttempts: [UInt8: CaptureAttempt] = [:]

    init() {
        identities = DisplayIdentityAllocator(
            records: DisplayIdentityRecords(propertyList: UserDefaults.standard.dictionary(forKey: Self.identityRecordsKey)),
            persist: { records in
                UserDefaults.standard.set(records.propertyList, forKey: Self.identityRecordsKey)
            }
        )
    }

    /// What the menu shows for each attached head.
    var heads: [UInt8: HeadStatus] {
        Dictionary(uniqueKeysWithValues: runtime.controller.statuses.map { ($0.monitor.head, $0) })
    }

    var screenRecordingDenied: Bool { runtime.controller.permissionDenied }

    /// What the panel shows while a capture's stop is not confirmed, or nil.
    var stopProblem: String? {
        runtime.hasUnconfirmedStops ? StreamStopNotConfirmed(reason: "").errorDescription : nil
    }

    private func makeRuntime() -> HeadRuntime<VirtualDisplay, DisplayCapture> {
        let defaults = UserDefaults.standard
        let engine = self.engine
        let runtime = HeadRuntime(
            controller: HeadController(
                preferences: OrientationPreferences(
                    propertyList: defaults.dictionary(forKey: OrientationPreferences.defaultsKey)),
                configuredModes: defaults.stringArray(forKey: Self.configuredMonitorsKey) ?? []),
            platform: HeadPlatform(
                createDisplay: { [weak self] monitor, orientation, attached, onTerminated in
                    guard let self else { return .failed("LinkLite is quitting") }
                    return self.createDisplay(monitor: monitor, orientation: orientation, attached: attached,
                                              onTerminated: onTerminated)
                },
                startStream: { display, monitor, orientation, gate, onUsableFrame, onStop in
                    try await DisplayCapture.start(displayID: display.displayID, monitor: monitor,
                                                   orientation: orientation, engine: engine, gate: gate,
                                                   onUsableFrame: onUsableFrame, onStop: onStop)
                },
                stopStream: { try await $0.stop() },
                failure: { Self.failure(for: $0) },
                configureMode: { display, monitor, orientation in
                    await Self.configureMode(of: display, for: monitor, orientation: orientation)
                },
                publishCursorTargets: { [weak self] targets in
                    self?.publishCursorTargets(targets)
                },
                savePreferences: { propertyList in
                    if propertyList.isEmpty {
                        UserDefaults.standard.removeObject(forKey: OrientationPreferences.defaultsKey)
                    } else {
                        UserDefaults.standard.set(propertyList, forKey: OrientationPreferences.defaultsKey)
                    }
                },
                saveConfiguredModes: { entries in
                    UserDefaults.standard.set(entries, forKey: Self.configuredMonitorsKey)
                }
            )
        )
        runtime.driver.onChange = { [weak self] in
            self?.pollGamma()
            self?.changes.request()
        }
        runtime.onStopStateChanged = { [weak self] in
            self?.changes.request()
        }
        return runtime
    }

    func start() {
        // Denied until a check confirms access. The one explicit request may show the prompt once.
        screenRecording.checkAtLaunch()
        if !engine.start(onEvent: { [weak self] event in self?.handle(event) }) {
            engineMessage = "The dock engine could not start"
            log.error("dll_engine_start returned NULL")
        }
        // Display arrangement changes move the virtual displays' bounds.
        displayReconfigured = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCursorTargets()
                self?.pollGamma()
            }
        }
        // A display was deallocated, so an identity may be free for a head waiting on it.
        identityReleased = NotificationCenter.default.addObserver(
            forName: DisplayIdentityAllocator.identityReleasedNotification, object: identities, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runtime.send(.identityMayBeFree) }
        }
        if UserDefaults.standard.bool(forKey: Self.performanceLoggingKey) {
            startPerformanceLogging()
        }
        changes.request()
    }

    /// Blanks the monitors and releases the dock. Blocks until the engine thread has exited.
    func stop() {
        perfTimer?.invalidate()
        perfTimer = nil
        gammaTimer?.invalidate()
        gammaTimer = nil
        engine.stop()
    }

    private func startPerformanceLogging() {
        // Discard anything counted before the first interval starts.
        _ = engine.stats()
        perfIntervalStart = .now
        perfTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.logPerformance() }
        }
    }

    /// One line per attached head: rates over the interval since the last line, and the average
    /// milliseconds each presentation spent per stage (submit: per captured frame).
    private func logPerformance() {
        let now = ContinuousClock.now
        let seconds = (now - perfIntervalStart) / .seconds(1)
        perfIntervalStart = now
        guard seconds > 0, let stats = engine.stats() else { return }
        let passesPerSecond = Double(stats.engine.loop_passes) / seconds
        let budgetWaitPerSecond = Double(stats.engine.budget_wait_us) / 1000 / seconds
        for head in stats.heads {
            let fps = Double(head.frames_submitted) / seconds
            let presents = Double(head.presents) / seconds
            let calls = Double(head.present_calls) / seconds
            let skipped = Double(head.skipped) / seconds
            let coarse = Double(head.coarse_fallbacks) / seconds
            let megabytes = Double(head.bytes_sent) / 1_000_000 / seconds
            let perPresent = { (us: UInt64) in Double(us) / 1000 / Double(max(head.present_calls, 1)) }
            let take = perPresent(head.take_us)
            let plan = perPresent(head.plan_us)
            let encode = perPresent(head.encode_us)
            let pack = perPresent(head.pack_us)
            let usb = perPresent(head.usb_us)
            let poll = perPresent(head.poll_us)
            let submit = Double(head.submit_us) / 1000 / Double(max(head.frames_submitted, 1))
            perfLog.info("""
                head \(head.head, privacy: .public): \
                \(fps, format: .fixed(precision: 1), privacy: .public) fps in, \
                \(presents, format: .fixed(precision: 1), privacy: .public) presents/s \
                (\(calls, format: .fixed(precision: 1), privacy: .public) calls/s), \
                \(skipped, format: .fixed(precision: 1), privacy: .public) skipped/s, \
                \(coarse, format: .fixed(precision: 1), privacy: .public) coarse/s, \
                \(megabytes, format: .fixed(precision: 2), privacy: .public) MB/s; \
                ms/present take \(take, format: .fixed(precision: 2), privacy: .public) \
                plan \(plan, format: .fixed(precision: 2), privacy: .public) \
                encode \(encode, format: .fixed(precision: 2), privacy: .public) \
                pack \(pack, format: .fixed(precision: 2), privacy: .public) \
                usb \(usb, format: .fixed(precision: 2), privacy: .public) \
                poll \(poll, format: .fixed(precision: 2), privacy: .public); \
                ms/frame submit \(submit, format: .fixed(precision: 2), privacy: .public); \
                engine \(passesPerSecond, format: .fixed(precision: 0), privacy: .public) passes/s, \
                budget wait \(budgetWaitPerSecond, format: .fixed(precision: 1), privacy: .public) ms/s
                """)
        }
    }

    func setDisplayPower(on: Bool) {
        for head in heads.keys.sorted() {
            engine.setDisplayPower(head: head, on: on)
        }
    }

    /// Re-checks Screen Recording access. A confirmed grant is reported to the runtime, which restarts capture for heads
    /// that were waiting on it and counts the grant, even when no denial is known. Called when the app becomes active
    /// (the user returns from System Settings) and when the panel opens. Never prompts.
    func refreshScreenRecordingAccess() {
        screenRecording.recheck()
    }

    /// Restarts capture now for every head whose stream is down, e.g. after the Mac wakes or
    /// unlocks. ScreenCaptureKit stops all streams when the screen locks or the displays sleep
    /// (SCStreamError -3815); until a new stream starts, the dock keeps showing the last frame.
    func resumeCapture() {
        runtime.send(.resumeCapture)
    }

    /// The rotation of an attached head, or nil if no monitor is attached on it.
    func orientation(forHead head: UInt8) -> DisplayOrientation? {
        runtime.controller.status(forHead: head)?.orientation
    }

    /// Whether `head`'s rotation follows the monitor or is kept per port (identical or serial-less panels);
    /// see OrientationPreferences. Nil if no monitor is attached on `head`.
    func rotationScope(forHead head: UInt8) -> MonitorKey.RotationScope? {
        runtime.controller.rotationScope(forHead: head)
    }

    /// Sets the rotation of an attached head and applies it now. The controller stores it under the identity rules
    /// (OrientationPreferences) and decides how the display and capture follow.
    func setOrientation(_ requested: DisplayOrientation, forHead head: UInt8) {
        runtime.send(.setOrientation(head: head, orientation: requested))
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .attached(let info):
            log.info("Head \(info.head) attached: \(info.name, privacy: .public) \(info.width)x\(info.height)@\(info.refreshHz)")
            runtime.send(.monitorAttached(HeadMonitor(info)))
        case .detached(let head):
            log.info("Head \(head) detached")
            runtime.send(.monitorDetached(head: head))
        case .stateChanged(let state, let message):
            if state != engineState || message != engineMessage {
                log.info("Engine state \(state.rawValue): \(message, privacy: .public)")
            }
            engineState = state
            engineMessage = message
        }
        pollGamma()
        changes.request()
    }

    // MARK: - Displays

    /// Makes the virtual display for `monitor`, claiming its identity against the monitors on the other heads.
    /// A claim that is refused means the identity is still held by a display being released: the head waits.
    private func createDisplay(monitor: HeadMonitor, orientation: DisplayOrientation, attached: [AttachedMonitor],
                               onTerminated: @escaping @MainActor () -> Void) -> DisplayCreation<VirtualDisplay> {
        guard let claim = identities.claim(reported: monitor.reportedIdentity, head: monitor.head,
                                           attached: attached, configured: configuredIdentities) else {
            log.info("Head \(monitor.head): its identity is still held by a display being removed; waiting")
            return .identityHeld
        }
        if claim.identity != monitor.reportedIdentity {
            log.info("Head \(monitor.head) reports the same identity as another display; giving it a distinct serial")
        }
        do {
            let display = try VirtualDisplay(monitor: monitor, orientation: orientation, claim: claim,
                                             onTerminated: onTerminated)
            return .created(display, claim.identity)
        } catch {
            log.error("\(String(describing: error), privacy: .public)")
            return .failed("\(error)")
        }
    }

    /// The identities macOS already keeps per-display settings for (ConfiguredMonitors). A generated serial avoids
    /// them, so it never inherits another monitor's settings. Portrait entries name the same identity.
    private var configuredIdentities: Set<DisplayIdentity> {
        Set((UserDefaults.standard.stringArray(forKey: Self.configuredMonitorsKey) ?? []).compactMap { entry in
            let suffix = MonitorKey.portraitRecordSuffix
            let identityKey = entry.hasSuffix(suffix) ? String(entry.dropLast(suffix.count)) : entry
            return DisplayIdentity(configurationKey: identityKey)
        })
    }

    // MARK: - Cursor, gamma

    /// Points the hardware cursor at the heads whose dock draws the pointer. An empty list hides the dock's cursor.
    private func publishCursorTargets(_ targets: [(spec: CursorTargetSpec, display: VirtualDisplay)]) {
        lastCursorTargets = targets.map { target in
            CursorTracker.Target(head: target.spec.head, displayID: target.display.displayID,
                                 width: target.spec.width, height: target.spec.height)
        }
        cursor.setTargets(lastCursorTargets)
    }

    /// Re-applies the cursor targets so CursorTracker reads the displays' current bounds.
    private func refreshCursorTargets() {
        guard !lastCursorTargets.isEmpty else { return }
        cursor.setTargets(lastCursorTargets)
    }

    /// Hands each virtual display's gamma transfer table to the engine. ScreenCaptureKit returns
    /// pre-gamma pixels, so tint apps that set the table (CGSetDisplayTransferByTable) would
    /// otherwise not reach the dock. Polls every 0.5 s while any head has a virtual display.
    private func pollGamma() {
        let statuses = runtime.controller.statuses
        let active = statuses.contains { $0.display != nil }
        if active, gammaTimer == nil {
            gammaTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollGamma() }
            }
        } else if !active {
            gammaTimer?.invalidate()
            gammaTimer = nil
            return
        }
        for status in statuses {
            let head = status.monitor.head
            if status.captureAttempt != gammaAttempts[head] {
                gammaAttempts[head] = status.captureAttempt
                sentGamma[head] = nil
            }
            guard let generation = status.display, let display = runtime.display(generation),
                  let lut = Self.gammaTable(of: display.displayID), lut != sentGamma[head] else { continue }
            sentGamma[head] = lut
            engine.setGamma(head: head, lut: lut)
        }
    }

    /// The display's transfer table as 3 x 256 bytes (R, G, B), or nil if it cannot be read.
    private static func gammaTable(of displayID: CGDirectDisplayID) -> [UInt8]? {
        let capacity: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let n = Int(min(count, capacity))
        var lut = [UInt8](repeating: 0, count: 768)
        for (channel, table) in [red, green, blue].enumerated() {
            for i in 0..<256 {
                // Resample to 256 entries by linear interpolation when the table has another size.
                let value: Float
                if n == 256 {
                    value = table[i]
                } else {
                    let position = Float(i) * Float(n - 1) / 255
                    let lower = Int(position)
                    let upper = min(lower + 1, n - 1)
                    let fraction = position - Float(lower)
                    value = table[lower] + (table[upper] - table[lower]) * fraction
                }
                lut[channel * 256 + i] = UInt8(max(0, min(255, (value * 255).rounded())))
            }
        }
        return lut
    }

    // MARK: - Capture results

    /// Maps a capture error to the controller's failure kinds.
    nonisolated private static func failure(for error: Error) -> CaptureFailure {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        if case .unusableFrames(_, let reason) = error as? DisplayCapture.CaptureError {
            return .unusableFrames(reason: reason)
        }
        return .failed((error as? DisplayCapture.CaptureError)?.description ?? error.localizedDescription)
    }

    /// Waits for the new display's mode list, logs it, and sets the default HiDPI mode: "looks like" half of native.
    /// macOS would otherwise pick the largest HiDPI mode ("looks like" 2560x1440 on a 4K panel). Whether the
    /// mode has been recorded already is decided by the controller, not here.
    /// Runs as the display's ledger operation (HeadRuntime). Cancellation (the display is being released) ends the wait
    /// at once, and nothing is changed after it: the mode is set only if the setup has not been cancelled.
    @MainActor
    private static func configureMode(of display: VirtualDisplay, for monitor: HeadMonitor,
                                      orientation: DisplayOrientation) async -> ModeOutcome {
        // A portrait head's default is looked up at its logical (portrait) size.
        let logical = RotationGeometry(physical: monitor.physical, orientation: orientation).logical
        let native = (width: UInt32(logical.width), height: UInt32(logical.height))
        let defaultMode = await PollWait.firstValue(retries: 50, interval: .milliseconds(100)) {
            display.defaultMode(nativeWidth: native.width, nativeHeight: native.height)
        }
        guard !Task.isCancelled else { return .failed("the display was released") }

        let modes = display.availableModes()
            .filter { $0.isUsableForDesktopGUI() }
            .map { mode in
                mode.pixelWidth == mode.width
                    ? "\(mode.width)x\(mode.height)"
                    : "\(mode.width)x\(mode.height)@\(mode.pixelWidth)x\(mode.pixelHeight)"
            }
        log.info("Display \(display.displayID) modes: \(modes.joined(separator: ", "), privacy: .public)")

        guard let defaultMode else {
            log.error("No HiDPI mode backed by \(native.width)x\(native.height) on display \(display.displayID)")
            return .failed("no HiDPI mode backed by \(native.width)×\(native.height)")
        }
        // The last check before the mode changes: a setup cancelled while it was listing modes changes nothing.
        guard !Task.isCancelled else { return .failed("the display was released") }
        guard display.setMode(defaultMode) else {
            return .failed("macOS refused the \(defaultMode.width)×\(defaultMode.height) mode")
        }
        log.info("Display \(display.displayID) set to looks-like \(defaultMode.width)x\(defaultMode.height)")
        return .applied
    }
}
