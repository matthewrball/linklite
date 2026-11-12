// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore

// The rotation state machine for dock heads. Pure: no AppKit, CoreGraphics, ScreenCaptureKit or engine types.
//
// HeadController owns every per-head decision: which monitor is on which head, its virtual display, its capture,
// the default-mode setup, retries, the first-usable-frame deadline, reconnect grace, the stored rotations, and the
// dock cursor targets. It performs no work. apply(_:) takes one event and returns the commands the platform must
// carry out. HeadDriver runs that loop against a HeadEffects. HeadRuntime is the app's HeadEffects: it performs
// every capture command through StreamLifecycle, which owns each head's capture lifetime.
//
// Contract with StreamLifecycle (the runtime maps each CaptureAttempt to one lifecycle attempt):
// - A capture is named by CaptureAttempt. Every capture result carries its attempt. A result for an attempt the
//   controller no longer holds changes nothing. A late successful start is answered with .stopCapture, so its
//   stream is stopped and never installed. A new attempt is never stopped by an older attempt's events.
// - Start: .startCapture(attempt) is answered by .captureStarted(attempt) or .captureStartFailed(attempt, failure).
//   The runtime answers .captureStarted only once the lifecycle has kept the stream, so a cancelled start sends nothing.
// - .captureUsableFrame(attempt) is sent once per stream, at its first usable frame. It may arrive before
//   .captureStarted (the stream's frames can start during its start), and is kept for that start. Idle and unusable
//   frames are not reported, so they cannot reset or extend the deadline.
// - The first-usable-frame deadline is the timer .firstFrame(attempt). It is armed on captureStarted and cancelled
//   by the first usable frame, by a failure, by a stop, or by a detach. It fires only while armed.
// - .captureStopped(attempt, failure): the stream stopped or failed after it started.
// - .stopCapture(attempt) is requested by the controller and is idempotent.
// - A display is released (.releaseDisplay) only after its captures are stopped and confirmed. Its identity is then
//   free to be claimed again. A display whose identity is still held is answered with .displayCreationWaiting and
//   tried again on .identityMayBeFree or its timer; the controller never creates a second display for the same head.
// - Gating: the first default-mode attempt of a display must resolve before its first capture starts. Later mode
//   retries never stop a running capture.
// - Permission: no capture starts while permissionDenied, whether for an attach, a rotation, a retry or a resume. A
//   grant restarts the waiting heads. Each capture keeps the permission grant count it was issued under, from its
//   start until it stops. A denial from a stream issued before the latest grant describes permission that has since
//   been restored, so it neither sets permissionDenied nor shows as a problem. Other failures never change it.
// - Display creation: a refused creation keeps its request and its error, and is asked again on .creationRetry
//   (HeadTiming.creationRetryDelay) or at once on a wake. Screen Recording does not hold it back.
// - Replacement: a head whose display is being released is listed as waiting, with its latest rotation, until its
//   replacement is made. A release, once requested, admits no new default-mode operation, and the results of the
//   cancelled ones are not accepted.
// - Timers are HeadTimer keys. A fired key that is not armed is ignored.

/// One capture of one head. `id` is unique within a controller.
public struct CaptureAttempt: Hashable, Sendable {
    public var head: UInt8
    public var id: UInt64

    public init(head: UInt8, id: UInt64) {
        self.head = head
        self.id = id
    }
}

/// A timer the controller may hold armed. Firing is accepted only while armed.
public enum HeadTimer: Hashable, Sendable {
    case firstFrame(CaptureAttempt)
    case captureRetry(head: UInt8)
    case modeRetry(head: UInt8, display: UInt64)
    case reconnectGrace(head: UInt8, display: UInt64)
    /// A display whose identity is still held by a display being released: tried again.
    case identityRetry(head: UInt8, display: UInt64)
    /// A display creation that was refused: tried again.
    case creationRetry(head: UInt8, display: UInt64)
}

/// The timing rules. Fixed values, so tests and the app agree.
public enum HeadTiming {
    /// A capture that has not delivered a usable frame this long after it started is failed and retried.
    public static let firstUsableFrameDeadline: Duration = .seconds(10)
    /// A detached head's virtual display is kept this long so a quick reconnect can reuse it.
    public static let reconnectGrace: Duration = .seconds(20)
    /// Mode setup attempts per display before the mode is reported as unavailable.
    public static let maxModeAttempts = 6

    /// Capture restart delays after failures: 1, 2, 4, 8, 16, then 30 s. Reset only by a usable frame.
    public static func captureRetryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(max(failures, 0), 5)))
    }

    /// Mode setup retry delays after the nth failure (n >= 1): 1, 2, 4, 8, 16 s.
    public static func modeRetryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(max(failures - 1, 0), 5)))
    }

    /// Retries for a display whose identity is still held, after the nth wait (n >= 1): 1, 2, 4, 8, 16, then 30 s.
    public static func identityRetryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(max(failures - 1, 0), 5)))
    }

    /// Retries for a display creation the platform refused, after the nth refusal (n >= 1): 1, 2, 4, 8, 16, then 30 s.
    /// The retries never stop while the head is attached, and never come faster than once per delay.
    public static func creationRetryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(max(failures - 1, 0), 5)))
    }
}

extension HeadMonitor {
    /// The vendor, product and serial the monitor's EDID reports.
    public var reportedIdentity: DisplayIdentity {
        DisplayIdentity(vendorID: vendorID, productCode: productCode, serial: serial)
    }
}

/// What the controller knows about a dock monitor. Mirrors the engine's report without importing it.
public struct HeadMonitor: Equatable, Sendable {
    public var head: UInt8
    public var vendorID: UInt16
    public var productCode: UInt16
    public var serial: UInt32
    /// The dock's programmed mode; every submitted frame must be exactly this size.
    public var width: UInt32
    public var height: UInt32
    public var refreshHz: UInt32
    public var widthMillimeters: UInt32
    public var heightMillimeters: UInt32
    public var name: String
    /// The dock draws the pointer itself.
    public var hardwareCursor: Bool

    public init(head: UInt8, vendorID: UInt16, productCode: UInt16, serial: UInt32, width: UInt32, height: UInt32,
                refreshHz: UInt32, widthMillimeters: UInt32, heightMillimeters: UInt32, name: String,
                hardwareCursor: Bool) {
        self.head = head
        self.vendorID = vendorID
        self.productCode = productCode
        self.serial = serial
        self.width = width
        self.height = height
        self.refreshHz = refreshHz
        self.widthMillimeters = widthMillimeters
        self.heightMillimeters = heightMillimeters
        self.name = name
        self.hardwareCursor = hardwareCursor
    }

    public var key: MonitorKey { MonitorKey(vendorID: vendorID, productCode: productCode, serial: serial, head: head) }
    public var physical: PixelSize { PixelSize(width: Int(width), height: Int(height)) }
    /// Refresh rate to offer macOS and to pace capture at; 60 Hz if the engine reports none.
    public var effectiveRefreshHz: UInt32 { refreshHz > 0 ? refreshHz : 60 }

    /// Whether `other` is the same physical monitor in the same mode, so its virtual display can be reused.
    public func sameDisplay(as other: HeadMonitor) -> Bool {
        head == other.head && vendorID == other.vendorID && productCode == other.productCode
            && serial == other.serial && width == other.width && height == other.height
            && refreshHz == other.refreshHz
    }
}

/// Why a capture stopped or did not start.
public enum CaptureFailure: Equatable, Sendable {
    /// Screen Recording is not granted. Retries stop until it is.
    case permissionDenied
    /// The stream delivered no usable frame before the deadline.
    case noUsableFrame
    /// Unusable complete frames reached the limit in a row.
    case unusableFrames(reason: String)
    /// The stream stopped on its own, or the start failed for another reason.
    case failed(String)
}

/// The result of one default-mode setup attempt.
public enum ModeOutcome: Equatable, Sendable {
    case applied
    case failed(String)
}

/// A dock cursor target the platform must point at a display: a head that draws the pointer itself.
public struct CursorTargetSpec: Equatable, Sendable {
    public var head: UInt8
    public var display: UInt64
    public var width: UInt32
    public var height: UInt32

    public init(head: UInt8, display: UInt64, width: UInt32, height: UInt32) {
        self.head = head
        self.display = display
        self.width = width
        self.height = height
    }
}

/// Input to the controller. `display` values are generations chosen by the controller and echoed by the platform.
public enum HeadEvent: Equatable, Sendable {
    case monitorAttached(HeadMonitor)
    case monitorDetached(head: UInt8)
    case setOrientation(head: UInt8, orientation: DisplayOrientation)
    /// Restart captures that are stopped (wake, unlock, display power). Does nothing while permission is denied.
    case resumeCapture
    case permissionChanged(granted: Bool)
    /// `identity` is the identity the display was created with, when it differs from the monitor's own. It keys the
    /// default-mode record, so identical monitors that were given different identities are configured separately.
    case displayCreated(head: UInt8, display: UInt64, identity: DisplayIdentity? = nil)
    /// The display's identity is still held by a display being released. The head waits; see HeadTimer.identityRetry.
    case displayCreationWaiting(head: UInt8, display: UInt64)
    /// A display identity was released. Heads waiting for one try again now.
    case identityMayBeFree
    case displayCreationFailed(head: UInt8, display: UInt64, message: String)
    /// The window server removed a virtual display.
    case displayTerminated(display: UInt64)
    /// A display released after the platform stopped its captures.
    case displayReleased(display: UInt64)
    case captureStarted(CaptureAttempt)
    case captureStartFailed(CaptureAttempt, CaptureFailure)
    case captureUsableFrame(CaptureAttempt)
    case captureStopped(CaptureAttempt, CaptureFailure)
    case modeSetupFinished(head: UInt8, display: UInt64, outcome: ModeOutcome)
    /// Whether a stop of the head's streams is unconfirmed. Sent by the runtime when that changes.
    case stopConfirmationChanged(head: UInt8, unconfirmed: Bool)
    case timerFired(HeadTimer)
}

/// Work the platform must do. Results that come later are sent back as HeadEvents.
public enum HeadCommand: Equatable, Sendable {
    case createDisplay(head: UInt8, display: UInt64, monitor: HeadMonitor, orientation: DisplayOrientation)
    /// Stops the listed captures, then releases the display. Answered later by .displayReleased.
    case releaseDisplay(head: UInt8, display: UInt64, afterStopping: [CaptureAttempt])
    case startCapture(CaptureAttempt, display: UInt64, monitor: HeadMonitor, orientation: DisplayOrientation)
    case stopCapture(CaptureAttempt)
    /// Sets the display's default mode. Answered later by .modeSetupFinished.
    case configureMode(head: UInt8, display: UInt64, monitor: HeadMonitor, orientation: DisplayOrientation)
    case scheduleTimer(HeadTimer, after: Duration)
    case cancelTimer(HeadTimer)
    case publishCursorTargets([CursorTargetSpec])
    /// The complete stored rotation list. Empty means the key should be removed.
    case savePreferences([String: Int])
    case saveConfiguredModes([String])
}

/// One head as the menu shows it.
public struct HeadStatus: Equatable, Sendable {
    public var monitor: HeadMonitor
    public var orientation: DisplayOrientation
    /// The display generation, or nil while the head has no display.
    public var display: UInt64?
    /// The capture being started or running, if any.
    public var captureAttempt: CaptureAttempt?
    /// True once the running capture has delivered a usable frame.
    public var hasUsableFrame: Bool
    public var problem: String?
    public var rotationScope: MonitorKey.RotationScope
    /// The head has no display yet because macOS has not released the monitor's identity.
    public var waitingForIdentity: Bool = false
    /// A stream has started on the head. False while it is starting, or waiting to retry.
    public var captureRunning: Bool = false
    /// A stop of one of the head's streams has failed and is not yet confirmed. The head waits until it is.
    public var stopUnconfirmed: Bool = false
}

/// Per-head state. Private to the controller.
public struct HeadController: Sendable {
    private enum Capture: Equatable, Sendable {
        case idle
        /// `grant`: the permission grant count when the start was issued (see HeadController.permissionGrants). It
        /// stays with the stream when the stream starts running, so a denial reported later is judged by the grant the
        /// stream was issued under, not by its state.
        case starting(CaptureAttempt, grant: UInt64)
        case running(CaptureAttempt, usable: Bool, grant: UInt64)

        var attempt: CaptureAttempt? {
            switch self {
            case .idle: nil
            case .starting(let attempt, _), .running(let attempt, _, _): attempt
            }
        }

        /// The grant count the capture was issued under, or nil when idle.
        var grant: UInt64? {
            switch self {
            case .idle: nil
            case .starting(_, let grant), .running(_, _, let grant): grant
            }
        }

        var hasUsableFrame: Bool {
            if case .running(_, usable: true, _) = self { return true }
            return false
        }

        /// A stream has started (it may not yet have delivered a usable frame).
        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        /// The stream of `attempt` is running, with the given usable-frame state.
        func isRunning(_ attempt: CaptureAttempt, usable: Bool) -> Bool {
            if case .running(let running, let isUsable, _) = self { return running == attempt && isUsable == usable }
            return false
        }
    }

    private struct Head: Sendable {
        var monitor: HeadMonitor
        var orientation: DisplayOrientation
        var display: UInt64?
        /// The display being created (creation is answered at once, so this is short-lived).
        var creating: UInt64?
        var capture = Capture.idle
        var problem: String?
        /// Failed starts since the last usable frame. Sets the next retry delay.
        var retryFailures = 0
        var rebuiltAfterTermination: Bool
        /// The display's identity is held elsewhere: the head waits, and retries on its timer or a release.
        var waitingForIdentity = false
        var identityRetries = 0
        /// The capture whose first usable frame arrived before its start was reported. Kept for that start.
        var usableBeforeStart: CaptureAttempt?
        /// The platform refused the creation of `creating`. It is retried on its timer, or at once on wake.
        var creationRefused = false
        /// Refused creations since the last display. Sets the next retry delay.
        var creationFailures = 0
    }

    private struct Retained: Sendable {
        var monitor: HeadMonitor
        var orientation: DisplayOrientation
        var display: UInt64
        var rebuiltAfterTermination: Bool
    }

    /// A head waiting for the old display's release, then a display of its own.
    private struct Replacement: Sendable {
        var monitor: HeadMonitor
        var rebuiltAfterTermination: Bool
        var waitingFor: UInt64
    }

    /// The default-mode setup of one display, kept until it is applied or the display is released.
    private struct ModeSetup: Sendable {
        var recordKey: String
        var inFlight = false
        /// Set after the first attempt's result, success or failure. Gates the first capture start.
        var resolvedOnce = false
        var failures = 0
        var lastFailure: String?
        var unavailable = false
    }

    private var heads: [UInt8: Head] = [:]
    private var retained: [UInt8: Retained] = [:]
    private var replacements: [UInt8: Replacement] = [:]
    /// Displays whose release has been commanded and not yet acknowledged, by head.
    private var releasing: [UInt64: UInt8] = [:]
    /// Heads on which a stop of a stream has failed and is not yet confirmed. Reported by statuses.
    private var unconfirmedStops = Set<UInt8>()
    private var modes: [UInt64: ModeSetup] = [:]
    private var armed: Set<HeadTimer> = []
    private var lastCursorTargets: [CursorTargetSpec] = []
    private var lastID: UInt64 = 0
    private var commands: [HeadCommand] = []

    public private(set) var preferences: OrientationPreferences
    /// The ConfiguredMonitors entries: display shapes whose default mode is recorded as set.
    public private(set) var configuredModes: [String]
    /// True while Screen Recording is not granted. Retries stop, and resume does nothing.
    public private(set) var permissionDenied: Bool
    /// Counts the permission grants seen. A start records the count it was issued under. A denial that comes back
    /// from a start issued under an earlier grant describes permission that has since been restored, so it does not
    /// block. Only a grant advances the count: no other event can make a start look newer than the permission.
    private var permissionGrants: UInt64 = 0

    public init(preferences: OrientationPreferences = OrientationPreferences(), configuredModes: [String] = [],
                permissionDenied: Bool = false) {
        self.preferences = preferences
        self.configuredModes = configuredModes
        self.permissionDenied = permissionDenied
    }

    /// Every head that has a monitor, in head order, once each. A head whose display is being rebuilt is listed too,
    /// as waiting for its replacement: its latest rotation is selectable, and it is applied when the replacement is made.
    public var statuses: [HeadStatus] {
        let attached = attachedKeys()
        return Set(heads.keys).union(replacements.keys).sorted().compactMap { head -> HeadStatus? in
            if let state = heads[head] {
                return HeadStatus(monitor: state.monitor, orientation: state.orientation, display: state.display,
                                  captureAttempt: state.capture.attempt,
                                  hasUsableFrame: state.capture.hasUsableFrame,
                                  problem: problem(of: state),
                                  rotationScope: state.monitor.key.rotationScope(among: attached),
                                  waitingForIdentity: state.waitingForIdentity,
                                  captureRunning: state.capture.isRunning,
                                  stopUnconfirmed: unconfirmedStops.contains(head))
            }
            guard let waiting = replacements[head] else { return nil }
            return HeadStatus(monitor: waiting.monitor, orientation: preferences.orientation(for: waiting.monitor.key),
                              display: nil, captureAttempt: nil, hasUsableFrame: false, problem: nil,
                              rotationScope: waiting.monitor.key.rotationScope(among: attached),
                              waitingForIdentity: true, captureRunning: false,
                              stopUnconfirmed: unconfirmedStops.contains(head))
        }
    }

    public func status(forHead head: UInt8) -> HeadStatus? {
        statuses.first { $0.monitor.head == head }
    }

    /// Every monitor the controller holds on a head, with the display generation it is using (nil while it has
    /// none). A monitor waiting for its old display to be released is included with nil. The runtime uses this to
    /// see which identities are in use before it claims one.
    public var attachedMonitors: [(head: UInt8, monitor: HeadMonitor, display: UInt64?)] {
        let live = heads.keys.sorted().compactMap { head -> (head: UInt8, monitor: HeadMonitor, display: UInt64?)? in
            guard let state = heads[head] else { return nil }
            return (head, state.monitor, state.display)
        }
        let waiting = replacements.keys.sorted().compactMap { head -> (head: UInt8, monitor: HeadMonitor, display: UInt64?)? in
            guard let waiting = replacements[head] else { return nil }
            return (head, waiting.monitor, nil)
        }
        return live + waiting
    }

    /// Whether a head's rotation follows its monitor or is kept per port. Nil if no monitor is on the head.
    public func rotationScope(forHead head: UInt8) -> MonitorKey.RotationScope? {
        (heads[head]?.monitor ?? replacements[head]?.monitor).map { $0.key.rotationScope(among: attachedKeys()) }
    }

    /// The timers currently armed. Firing any other key is ignored.
    public var armedTimers: Set<HeadTimer> { armed }

    /// Applies one event and returns the commands it requires, in order.
    public mutating func apply(_ event: HeadEvent) -> [HeadCommand] {
        handle(event)
        publishCursorTargetsIfChanged()
        let out = commands
        commands.removeAll()
        return out
    }

    // MARK: - Events

    private mutating func handle(_ event: HeadEvent) {
        switch event {
        case .monitorAttached(let monitor):
            attachMonitor(monitor)
        case .monitorDetached(let head):
            detachHead(head, keepDisplay: true)
        case .setOrientation(let head, let orientation):
            setOrientation(head: head, requested: orientation)
        case .resumeCapture:
            retryRefusedCreations()
            resumeCaptures()
        case .permissionChanged(let granted):
            permissionDenied = !granted
            if granted {
                permissionGrants += 1
                resumeCaptures()
            }
        case .displayCreated(let head, let display, let identity):
            displayCreated(head: head, display: display, identity: identity)
        case .displayCreationWaiting(let head, let display):
            displayCreationWaiting(head: head, display: display)
        case .identityMayBeFree:
            for head in heads.keys.sorted() { retryIdentity(head) }
        case .displayCreationFailed(let head, let display, let message):
            displayCreationFailed(head: head, display: display, message: message)
        case .displayTerminated(let display):
            displayTerminated(display)
        case .displayReleased(let display):
            displayReleased(display)
        case .captureStarted(let attempt):
            captureStarted(attempt)
        case .captureStartFailed(let attempt, let failure):
            captureEnded(attempt, failure)
        case .captureUsableFrame(let attempt):
            captureUsableFrame(attempt)
        case .captureStopped(let attempt, let failure):
            captureEnded(attempt, failure)
        case .modeSetupFinished(let head, let display, let outcome):
            modeSetupFinished(head: head, display: display, outcome: outcome)
        case .stopConfirmationChanged(let head, let unconfirmed):
            if unconfirmed {
                unconfirmedStops.insert(head)
            } else {
                unconfirmedStops.remove(head)
            }
        case .timerFired(let timer):
            timerFired(timer)
        }
    }

    // MARK: - Attach, detach, replace

    private mutating func attachMonitor(_ monitor: HeadMonitor) {
        let head = monitor.head
        if var waiting = replacements[head] {
            // The old display is still being released. Wait for the same release with the newest monitor.
            waiting.monitor = monitor
            replacements[head] = waiting
            return
        }
        if heads[head] != nil { detachHead(head, keepDisplay: true) }
        attach(monitor, rebuiltAfterTermination: false)
    }

    /// Makes `monitor`'s head live: reuses a retained display of the same shape, or waits for an old display to be
    /// released, or creates a display. The head must have no state. Its rotation is read from the stored rules.
    private mutating func attach(_ monitor: HeadMonitor, rebuiltAfterTermination: Bool) {
        let head = monitor.head
        let orientation = preferences.orientation(for: monitor.key)
        if let kept = retained.removeValue(forKey: head) {
            cancel(.reconnectGrace(head: head, display: kept.display))
            let keptShape = HeadShape(physical: kept.monitor.physical, refreshHz: kept.monitor.refreshHz,
                                      orientation: kept.orientation)
            let newShape = HeadShape(physical: monitor.physical, refreshHz: monitor.refreshHz, orientation: orientation)
            if kept.monitor.sameDisplay(as: monitor), keptShape.virtualDisplayReusable(for: newShape) {
                heads[head] = Head(monitor: monitor, orientation: orientation, display: kept.display,
                                   rebuiltAfterTermination: kept.rebuiltAfterTermination)
                // A default mode that never applied is tried again now, since the monitor is back.
                retryModeSetup(head: head, display: kept.display)
                materializeTwins()
                startCaptureIfReady(head)
                return
            }
            // The kept display has the wrong shape or identity: release it, then create a new one.
            releaseDisplay(head: head, display: kept.display, afterStopping: [])
            replacements[head] = Replacement(monitor: monitor, rebuiltAfterTermination: rebuiltAfterTermination,
                                             waitingFor: kept.display)
            return
        }
        if let display = releasingDisplay(for: head) {
            replacements[head] = Replacement(monitor: monitor, rebuiltAfterTermination: rebuiltAfterTermination,
                                             waitingFor: display)
            return
        }
        let display = nextID()
        heads[head] = Head(monitor: monitor, orientation: orientation, display: nil, creating: display,
                           rebuiltAfterTermination: rebuiltAfterTermination)
        commands.append(.createDisplay(head: head, display: display, monitor: monitor, orientation: orientation))
    }

    /// Ends a head's state. A kept display is held for the reconnect grace; otherwise it is released after its
    /// captures stop. Any pending replacement for the head is cancelled.
    private mutating func detachHead(_ head: UInt8, keepDisplay: Bool) {
        replacements[head] = nil
        guard let state = heads.removeValue(forKey: head) else { return }
        cancel(.captureRetry(head: head))
        if let creating = state.creating {
            cancel(.identityRetry(head: head, display: creating))
            cancel(.creationRetry(head: head, display: creating))
        }
        var stopping: [CaptureAttempt] = []
        if let attempt = state.capture.attempt {
            cancel(.firstFrame(attempt))
            stopping = [attempt]
        }
        guard let display = state.display else {
            for attempt in stopping { commands.append(.stopCapture(attempt)) }
            return
        }
        cancel(.modeRetry(head: head, display: display))
        if keepDisplay {
            if let previous = retained.removeValue(forKey: head) {
                cancel(.reconnectGrace(head: head, display: previous.display))
                releaseDisplay(head: head, display: previous.display, afterStopping: [])
            }
            retained[head] = Retained(monitor: state.monitor, orientation: state.orientation, display: display,
                                      rebuiltAfterTermination: state.rebuiltAfterTermination)
            schedule(.reconnectGrace(head: head, display: display), HeadTiming.reconnectGrace)
            for attempt in stopping { commands.append(.stopCapture(attempt)) }
        } else {
            releaseDisplay(head: head, display: display, afterStopping: stopping)
        }
    }

    private mutating func releaseDisplay(head: UInt8, display: UInt64, afterStopping: [CaptureAttempt]) {
        releasing[display] = head
        commands.append(.releaseDisplay(head: head, display: display, afterStopping: afterStopping))
    }

    private func releasingDisplay(for head: UInt8) -> UInt64? {
        releasing.first { $0.value == head }?.key
    }

    private mutating func displayReleased(_ display: UInt64) {
        releasing[display] = nil
        modes[display] = nil
        guard let head = replacements.first(where: { $0.value.waitingFor == display })?.key,
              let waiting = replacements.removeValue(forKey: head) else { return }
        attach(waiting.monitor, rebuiltAfterTermination: waiting.rebuiltAfterTermination)
    }

    private mutating func displayTerminated(_ display: UInt64) {
        if let head = heads.first(where: { $0.value.display == display })?.key, let state = heads[head] {
            detachHead(head, keepDisplay: false)
            if state.rebuiltAfterTermination {
                // A second loss: report it and wait for a new orientation choice or a reconnect.
                heads[head] = Head(monitor: state.monitor, orientation: .standard, display: nil, creating: nil,
                                   problem: "macOS removed the virtual display", rebuiltAfterTermination: true)
            } else {
                replacements[head] = Replacement(monitor: state.monitor, rebuiltAfterTermination: true,
                                                 waitingFor: display)
            }
            return
        }
        // A kept display that the window server removed while it was waiting for a reconnect.
        if let head = retained.first(where: { $0.value.display == display })?.key {
            retained[head] = nil
            cancel(.reconnectGrace(head: head, display: display))
            releaseDisplay(head: head, display: display, afterStopping: [])
        }
    }

    // MARK: - Display creation

    private mutating func displayCreated(head: UInt8, display: UInt64, identity: DisplayIdentity?) {
        guard var state = heads[head], state.creating == display else {
            // No longer wanted (the controller never reaches this with a synchronous creation). Release it.
            releaseDisplay(head: head, display: display, afterStopping: [])
            return
        }
        state.creating = nil
        state.display = display
        state.problem = nil
        state.waitingForIdentity = false
        state.identityRetries = 0
        state.creationRefused = false
        state.creationFailures = 0
        heads[head] = state
        // The default mode is recorded under the identity the display actually has, so twins given different
        // identities are configured independently. Without a claimed identity, the monitor's own one is used.
        let recordKey = MonitorKey.configuredModesKey(identity: identity ?? state.monitor.reportedIdentity,
                                                      orientation: state.orientation)
        if !configuredModes.contains(recordKey) {
            modes[display] = ModeSetup(recordKey: recordKey)
            issueModeSetup(head: head, display: display)
        }
        materializeTwins()
        startCaptureIfReady(head)
    }

    /// The platform refused the display. The head keeps its request and its error, and asks again after a bounded
    /// backoff. A refusal is not a permission matter, so the backoff runs whatever the Screen Recording state.
    private mutating func displayCreationFailed(head: UInt8, display: UInt64, message: String) {
        guard var state = heads[head], state.creating == display else { return }
        state.problem = message
        state.waitingForIdentity = false
        state.creationRefused = true
        state.creationFailures += 1
        heads[head] = state
        schedule(.creationRetry(head: head, display: display),
                 HeadTiming.creationRetryDelay(afterFailures: state.creationFailures))
    }

    /// Asks again for a head's display after a refusal. The refused request never produced a display, so the same
    /// generation is asked for again. Only a head whose creation was refused is asked.
    private mutating func retryCreation(_ head: UInt8) {
        guard var state = heads[head], let display = state.creating, state.creationRefused else { return }
        cancel(.creationRetry(head: head, display: display))
        state.creationRefused = false
        heads[head] = state
        commands.append(.createDisplay(head: head, display: display, monitor: state.monitor,
                                       orientation: state.orientation))
    }

    /// Wake: every refused creation is asked again now, with its backoff reset.
    private mutating func retryRefusedCreations() {
        for head in heads.keys.sorted() {
            guard var state = heads[head], state.creationRefused else { continue }
            state.creationFailures = 0
            heads[head] = state
            retryCreation(head)
        }
    }

    /// The identity is still held by a display being released: the head waits, and asks again on its timer or when an
    /// identity is released. Nothing is shown as a failure, and no other display is made for the head meanwhile.
    private mutating func displayCreationWaiting(head: UInt8, display: UInt64) {
        guard var state = heads[head], state.creating == display else {
            // No display is wanted for this head any more: nothing to wait for.
            return
        }
        state.waitingForIdentity = true
        state.problem = nil
        state.identityRetries += 1
        heads[head] = state
        schedule(.identityRetry(head: head, display: display),
                 HeadTiming.identityRetryDelay(afterFailures: state.identityRetries))
    }

    /// Asks again for a head's display after its identity was held. Only a head that is waiting is asked.
    private mutating func retryIdentity(_ head: UInt8) {
        guard var state = heads[head], let display = state.creating, state.waitingForIdentity else { return }
        cancel(.identityRetry(head: head, display: display))
        state.waitingForIdentity = false
        heads[head] = state
        commands.append(.createDisplay(head: head, display: display, monitor: state.monitor,
                                       orientation: state.orientation))
    }

    // MARK: - Orientation

    private mutating func setOrientation(head: UInt8, requested: DisplayOrientation) {
        // The head's old display is still being released (an earlier rotation or a rebuild). Its replacement is made
        // with the stored rotation when the release completes, so a rotation chosen meanwhile must be stored, not lost.
        if heads[head] == nil, let waiting = replacements[head] {
            let before = preferences
            preferences.setOrientation(requested, for: waiting.monitor.key, among: attachedKeys())
            if preferences != before { commands.append(.savePreferences(preferences.propertyList)) }
            return
        }
        guard let state = heads[head] else { return }
        let before = preferences
        preferences.setOrientation(requested, for: state.monitor.key, among: attachedKeys())
        if preferences != before { commands.append(.savePreferences(preferences.propertyList)) }
        let effective = preferences.orientation(for: state.monitor.key)
        switch OrientationApplication.plan(hasDisplay: state.display != nil, applied: state.orientation,
                                           requested: effective) {
        case .none:
            return
        case .createDisplay:
            // No display (its creation failed, or macOS removed it): create one for the chosen orientation.
            detachHead(head, keepDisplay: true)
            attach(state.monitor, rebuiltAfterTermination: state.rebuiltAfterTermination)
        case .restartCapture:
            heads[head]?.orientation = effective
            restartCapture(head)
        case .recreateDisplay:
            guard let display = state.display else { return }
            detachHead(head, keepDisplay: false)
            replacements[head] = Replacement(monitor: state.monitor, rebuiltAfterTermination: false,
                                             waitingFor: display)
        }
    }

    /// Stops the head's capture and starts it again with the current orientation. The display stays.
    private mutating func restartCapture(_ head: UInt8) {
        guard var state = heads[head] else { return }
        cancel(.captureRetry(head: head))
        if let attempt = state.capture.attempt {
            cancel(.firstFrame(attempt))
            commands.append(.stopCapture(attempt))
        }
        state.capture = .idle
        state.usableBeforeStart = nil
        heads[head] = state
        startCaptureIfReady(head)
    }

    // MARK: - Capture

    /// Starts a capture for a head that has a display and no capture, once the display's first mode attempt has
    /// resolved and while Screen Recording is granted. A failed mode attempt does not block the capture; only the
    /// attempt's own result gates it. Nothing starts while permission is denied: the head waits for a grant.
    private mutating func startCaptureIfReady(_ head: UInt8) {
        guard var state = heads[head], state.capture == .idle, let display = state.display else { return }
        if let setup = modes[display], !setup.resolvedOnce { return }
        guard !permissionDenied else {
            state.problem = Self.message(for: .permissionDenied, head: head)
            heads[head] = state
            return
        }
        cancel(.captureRetry(head: head))
        let attempt = CaptureAttempt(head: head, id: nextID())
        state.capture = .starting(attempt, grant: permissionGrants)
        heads[head] = state
        commands.append(.startCapture(attempt, display: display, monitor: state.monitor,
                                      orientation: state.orientation))
    }

    private mutating func captureStarted(_ attempt: CaptureAttempt) {
        guard var state = heads[attempt.head], case .starting(attempt, let grant) = state.capture else {
            commands.append(.stopCapture(attempt))
            return
        }
        // A usable frame that arrived during the start counts: the deadline is not armed for it.
        let usableEarly = state.usableBeforeStart == attempt
        state.usableBeforeStart = nil
        state.capture = .running(attempt, usable: usableEarly, grant: grant)
        state.problem = nil
        if usableEarly { state.retryFailures = 0 }
        heads[attempt.head] = state
        if !usableEarly { schedule(.firstFrame(attempt), HeadTiming.firstUsableFrameDeadline) }
    }

    private mutating func captureUsableFrame(_ attempt: CaptureAttempt) {
        guard var state = heads[attempt.head] else { return }
        if case .starting(attempt, _) = state.capture {
            // The stream delivers frames before its start has been reported. Kept for that start: captureStarted
            // adopts it, so the stream is live and no deadline is armed. Only this attempt's frame is kept.
            state.usableBeforeStart = attempt
            heads[attempt.head] = state
            return
        }
        guard case .running(attempt, usable: false, let grant) = state.capture else { return }
        state.capture = .running(attempt, usable: true, grant: grant)
        state.retryFailures = 0
        heads[attempt.head] = state
        cancel(.firstFrame(attempt))
    }

    /// Ends the capture `attempt` after a failed start or a stream that stopped. Ignored for any other attempt.
    private mutating func captureEnded(_ attempt: CaptureAttempt, _ failure: CaptureFailure) {
        guard var state = heads[attempt.head], state.capture.attempt == attempt else { return }
        // A denial from a stream issued before the latest grant describes permission that has been restored since: it
        // is neither a permission state nor a problem to show. The head retries as after any other failure. The grant
        // a stream was issued under stays with it while it runs, so a late report from a running stream is judged too.
        let stale = failure == .permissionDenied && state.capture.grant != permissionGrants
        cancel(.firstFrame(attempt))
        state.capture = .idle
        state.usableBeforeStart = nil
        state.problem = stale ? nil : Self.message(for: failure, head: attempt.head)
        heads[attempt.head] = state
        if failure == .permissionDenied, !stale { permissionDenied = true }
        commands.append(.stopCapture(attempt))
        scheduleCaptureRetry(attempt.head)
    }

    private mutating func scheduleCaptureRetry(_ head: UInt8) {
        guard !permissionDenied, var state = heads[head], state.display != nil else { return }
        let delay = HeadTiming.captureRetryDelay(afterFailures: state.retryFailures)
        state.retryFailures += 1
        heads[head] = state
        schedule(.captureRetry(head: head), delay)
    }

    /// Restarts captures that are down, now and with no backoff. A capture already starting or running is left.
    private mutating func resumeCaptures() {
        guard !permissionDenied else { return }
        for head in heads.keys.sorted() {
            guard var state = heads[head], state.display != nil else { continue }
            state.retryFailures = 0
            heads[head] = state
            if state.capture == .idle {
                cancel(.captureRetry(head: head))
                startCaptureIfReady(head)
            }
        }
    }

    // MARK: - Default mode

    private mutating func modeSetupFinished(head: UInt8, display: UInt64, outcome: ModeOutcome) {
        // A display that is being released, or was released, no longer has a setup: its late result changes nothing.
        guard releasing[display] == nil, var setup = modes[display] else { return }
        setup.inFlight = false
        setup.resolvedOnce = true
        switch outcome {
        case .applied:
            modes[display] = nil
            if !configuredModes.contains(setup.recordKey) {
                configuredModes.append(setup.recordKey)
                commands.append(.saveConfiguredModes(configuredModes))
            }
        case .failed(let reason):
            setup.failures += 1
            setup.lastFailure = reason
            setup.unavailable = setup.failures >= HeadTiming.maxModeAttempts
            modes[display] = setup
            if !setup.unavailable, let state = heads[head], state.display == display {
                schedule(.modeRetry(head: head, display: display),
                         HeadTiming.modeRetryDelay(afterFailures: setup.failures))
            }
        }
        startCaptureIfReady(head)
    }

    private mutating func issueModeSetup(head: UInt8, display: UInt64) {
        guard releasing[display] == nil, var setup = modes[display], !setup.inFlight, !setup.unavailable,
              let state = heads[head], state.display == display else { return }
        setup.inFlight = true
        modes[display] = setup
        commands.append(.configureMode(head: head, display: display, monitor: state.monitor,
                                       orientation: state.orientation))
    }

    /// A monitor came back on a kept display: a setup that is still outstanding starts again with fresh attempts.
    private mutating func retryModeSetup(head: UInt8, display: UInt64) {
        guard var setup = modes[display], !setup.inFlight else { return }
        setup.failures = 0
        setup.lastFailure = nil
        setup.unavailable = false
        modes[display] = setup
        issueModeSetup(head: head, display: display)
    }

    // MARK: - Timers

    private mutating func timerFired(_ timer: HeadTimer) {
        guard armed.remove(timer) != nil else { return }
        switch timer {
        case .firstFrame(let attempt):
            guard let state = heads[attempt.head], state.capture.isRunning(attempt, usable: false) else { return }
            captureEnded(attempt, .noUsableFrame)
        case .captureRetry(let head):
            guard let state = heads[head], state.capture == .idle, state.display != nil, !permissionDenied else { return }
            startCaptureIfReady(head)
        case .modeRetry(let head, let display):
            guard let state = heads[head], state.display == display, let setup = modes[display],
                  !setup.inFlight, !setup.unavailable else { return }
            issueModeSetup(head: head, display: display)
        case .reconnectGrace(let head, let display):
            guard let kept = retained[head], kept.display == display else { return }
            retained[head] = nil
            releaseDisplay(head: head, display: display, afterStopping: [])
        case .identityRetry(let head, let display):
            guard let state = heads[head], state.creating == display, state.waitingForIdentity else { return }
            retryIdentity(head)
        case .creationRetry(let head, let display):
            guard let state = heads[head], state.creating == display, state.creationRefused else { return }
            retryCreation(head)
        }
    }

    // MARK: - Helpers

    private mutating func schedule(_ timer: HeadTimer, _ delay: Duration) {
        armed.insert(timer)
        commands.append(.scheduleTimer(timer, after: delay))
    }

    private mutating func cancel(_ timer: HeadTimer) {
        guard armed.remove(timer) != nil else { return }
        commands.append(.cancelTimer(timer))
    }

    private mutating func nextID() -> UInt64 {
        lastID += 1
        return lastID
    }

    /// Every monitor that is physically attached: heads with state, and heads waiting for a replacement display.
    /// A kept display's monitor is unplugged, so it is not counted.
    private func attachedKeys() -> [MonitorKey] {
        heads.values.map { $0.monitor.key } + replacements.values.map { $0.monitor.key }
    }

    /// Records the port record of each twin that has a display now (see OrientationPreferences.materializeTwins).
    private mutating func materializeTwins() {
        let recordable = heads.values.compactMap { $0.display == nil ? nil : $0.monitor.key }
        let before = preferences
        preferences.materializeTwins(recordable, among: attachedKeys())
        if preferences != before { commands.append(.savePreferences(preferences.propertyList)) }
    }

    private mutating func publishCursorTargetsIfChanged() {
        let specs: [CursorTargetSpec] = heads.keys.sorted().compactMap { head in
            guard let state = heads[head], let display = state.display else { return nil }
            let policy = CapturePolicy(physical: state.monitor.physical, orientation: state.orientation,
                                       dockDrawsCursor: state.monitor.hardwareCursor)
            guard policy.usesHardwareCursor else { return nil }
            return CursorTargetSpec(head: head, display: display, width: state.monitor.width,
                                    height: state.monitor.height)
        }
        guard specs != lastCursorTargets else { return }
        lastCursorTargets = specs
        commands.append(.publishCursorTargets(specs))
    }

    private func problem(of state: Head) -> String? {
        if let problem = state.problem { return problem }
        guard let display = state.display, let setup = modes[display], setup.unavailable else { return nil }
        return "Default display mode unavailable (\(setup.lastFailure ?? "unknown")). Unplug and reconnect the monitor to retry."
    }

    private static func message(for failure: CaptureFailure, head: UInt8) -> String {
        switch failure {
        case .permissionDenied:
            "Screen Recording permission is required"
        case .noUsableFrame:
            "Head \(head) produced no usable frame within \(HeadTiming.firstUsableFrameDeadline.components.seconds) s"
        case .unusableFrames(let reason):
            "Head \(head) produced unusable frames (\(reason))"
        case .failed(let message):
            message
        }
    }
}

/// Runs a HeadController against platform effects. Commands run in order. Results that the effects can return at
/// once come back into the same loop. Later results come through `send`.
@MainActor
public final class HeadDriver {
    public private(set) var controller: HeadController
    public weak var effects: (any HeadEffects)?
    /// Called once after each `send` that came from outside the loop.
    public var onChange: (() -> Void)?
    private var queue: [HeadCommand] = []
    private var draining = false

    public init(controller: HeadController, effects: (any HeadEffects)? = nil) {
        self.controller = controller
        self.effects = effects
    }

    public func send(_ event: HeadEvent) {
        queue.append(contentsOf: controller.apply(event))
        // A result sent while the loop runs is queued, so commands keep their order.
        guard !draining else { return }
        draining = true
        while !queue.isEmpty {
            let command = queue.removeFirst()
            if let effects, let result = effects.perform(command) {
                queue.append(contentsOf: controller.apply(result))
            }
        }
        draining = false
        onChange?()
    }
}

/// The platform side of HeadDriver. `perform` returns an event only when the answer is already known.
@MainActor
public protocol HeadEffects: AnyObject {
    func perform(_ command: HeadCommand) -> HeadEvent?
}
