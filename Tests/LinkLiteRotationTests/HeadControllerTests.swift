// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import LinkLiteRotation

// These tests run the real HeadController through HeadDriver, with fake platform effects and a fake clock.
// Nothing sleeps. Each test decides when a platform result arrives and how far time moves.

/// Timers are recorded with their due time. They fire only when a test moves time forward.
@MainActor
private final class FakeClock {
    private struct Entry {
        var timer: HeadTimer
        var due: Duration
        var order: Int
    }

    private(set) var now: Duration = .zero
    private var entries: [Entry] = []
    private var counter = 0

    func schedule(_ timer: HeadTimer, after delay: Duration) {
        entries.removeAll { $0.timer == timer }
        counter += 1
        entries.append(Entry(timer: timer, due: now + delay, order: counter))
    }

    func cancel(_ timer: HeadTimer) {
        entries.removeAll { $0.timer == timer }
    }

    var scheduled: [HeadTimer] { entries.map(\.timer) }

    /// Removes and returns the next timer due by `target`, and moves the clock to its due time.
    func next(by target: Duration) -> HeadTimer? {
        guard let index = entries.indices.min(by: { (entries[$0].due, entries[$0].order) < (entries[$1].due, entries[$1].order) }),
              entries[index].due <= target else { return nil }
        let entry = entries.remove(at: index)
        now = entry.due
        return entry.timer
    }

    func move(to target: Duration) {
        now = target
    }
}

/// Records every command and holds the results that the platform answers later.
@MainActor
private final class FakeEffects: HeadEffects {
    let clock: FakeClock
    var failCreation = false
    /// Heads whose creation is refused, whatever `failCreation` says.
    var failingHeads: Set<UInt8> = []
    var created: [(head: UInt8, display: UInt64, orientation: DisplayOrientation)] = []
    var creationRetryDelays: [Duration] = []
    var pendingStarts: [CaptureAttempt] = []
    var pendingReleases: [UInt64] = []
    var pendingModes: [(head: UInt8, display: UInt64)] = []
    var stops: [CaptureAttempt] = []
    var configureCount = 0
    var retryDelays: [Duration] = []
    var modeRetryDelays: [Duration] = []
    var published: [[CursorTargetSpec]] = []
    var savedPreferences: [[String: Int]] = []
    var savedModes: [[String]] = []

    init(clock: FakeClock) {
        self.clock = clock
    }

    func perform(_ command: HeadCommand) -> HeadEvent? {
        switch command {
        case .createDisplay(let head, let display, _, let orientation):
            created.append((head, display, orientation))
            if failCreation || failingHeads.contains(head) {
                return .displayCreationFailed(head: head, display: display, message: "CGVirtualDisplay refused")
            }
            return .displayCreated(head: head, display: display)
        case .releaseDisplay(_, let display, _):
            pendingReleases.append(display)
        case .startCapture(let attempt, _, _, _):
            pendingStarts.append(attempt)
        case .stopCapture(let attempt):
            stops.append(attempt)
        case .configureMode(let head, let display, _, _):
            configureCount += 1
            pendingModes.append((head, display))
        case .scheduleTimer(let timer, let after):
            if case .captureRetry = timer { retryDelays.append(after) }
            if case .modeRetry = timer { modeRetryDelays.append(after) }
            if case .creationRetry = timer { creationRetryDelays.append(after) }
            clock.schedule(timer, after: after)
        case .cancelTimer(let timer):
            clock.cancel(timer)
        case .publishCursorTargets(let specs):
            published.append(specs)
        case .savePreferences(let list):
            savedPreferences.append(list)
        case .saveConfiguredModes(let list):
            savedModes.append(list)
        }
        return nil
    }
}

@MainActor
private final class Rig {
    let clock = FakeClock()
    let effects: FakeEffects
    let driver: HeadDriver

    init(preferences: OrientationPreferences = OrientationPreferences(), configured: [String] = [],
         permissionDenied: Bool = false) {
        effects = FakeEffects(clock: clock)
        driver = HeadDriver(controller: HeadController(preferences: preferences, configuredModes: configured,
                                                       permissionDenied: permissionDenied),
                            effects: effects)
    }

    var controller: HeadController { driver.controller }

    func send(_ event: HeadEvent) { driver.send(event) }

    func status(_ head: UInt8) -> HeadStatus? { controller.status(forHead: head) }

    /// Moves time forward and delivers each timer that comes due, in order.
    func advance(by delta: Duration) {
        let target = clock.now + delta
        while let timer = clock.next(by: target) {
            send(.timerFired(timer))
        }
        clock.move(to: target)
    }

    /// Answers the next outstanding mode setup.
    func answerMode(_ outcome: ModeOutcome) {
        guard !effects.pendingModes.isEmpty else {
            Issue.record("no mode setup was pending to answer")
            return
        }
        let pending = effects.pendingModes.removeFirst()
        send(.modeSetupFinished(head: pending.head, display: pending.display, outcome: outcome))
    }

    /// A healthy platform: answers every outstanding request until none is left.
    func settle() {
        while true {
            if !effects.pendingReleases.isEmpty {
                send(.displayReleased(display: effects.pendingReleases.removeFirst()))
            } else if !effects.pendingModes.isEmpty {
                answerMode(.applied)
            } else if !effects.pendingStarts.isEmpty {
                let attempt = effects.pendingStarts.removeFirst()
                send(.captureStarted(attempt))
                send(.captureUsableFrame(attempt))
            } else {
                return
            }
        }
    }
}

private func monitor(_ head: UInt8, serial: UInt32 = 0x1234_5678, cursor: Bool = true) -> HeadMonitor {
    HeadMonitor(head: head, vendorID: 0x22f0, productCode: 0x3a4b, serial: serial, width: 3840, height: 2160,
                refreshHz: 60, widthMillimeters: 597, heightMillimeters: 336, name: "Dock \(head)",
                hardwareCursor: cursor)
}

private func target(_ head: UInt8, _ display: UInt64) -> CursorTargetSpec {
    CursorTargetSpec(head: head, display: display, width: 3840, height: 2160)
}

/// Brings a head to a started capture by hand: the mode is answered, the start is held, and the test answers it.
@MainActor
private func attachAndAnswerMode(_ rig: Rig, _ head: UInt8) {
    rig.send(.monitorAttached(monitor(head)))
    rig.answerMode(.applied)
}

// MARK: - Twins: a shared setting must not reach a twin that has its own (issue 1)

@MainActor
@Test(arguments: [false, true])
func aTwinKeepsItsRotationWhenTheSharedSettingChangesWhileItIsUnplugged(afterGrace: Bool) {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    rig.send(.setOrientation(head: 0, orientation: .turnedClockwise))   // alone: the identity record is 90
    rig.settle()
    rig.send(.monitorAttached(monitor(1)))                              // the twin inherits 90
    rig.settle()
    #expect(rig.status(1)?.orientation == .turnedClockwise)
    #expect(rig.controller.preferences.propertyList["22f0-3a4b-12345678-head1"] == 90,
            "the twin's own rotation is recorded as soon as it is first seen")

    rig.send(.monitorDetached(head: 1))
    rig.settle()
    if afterGrace {
        rig.advance(by: HeadTiming.reconnectGrace)                      // the twin's display is released
        rig.settle()
    }
    rig.send(.setOrientation(head: 0, orientation: .upsideDown))        // alone: the identity record becomes 180
    rig.settle()

    rig.send(.monitorAttached(monitor(1)))                              // the twin comes back
    rig.settle()
    #expect(rig.status(1)?.orientation == .turnedClockwise)
    #expect(rig.status(0)?.orientation == .upsideDown)
}

@MainActor
@Test(arguments: [false, true])
func aLegacyIdentityRecordReachesEachTwinWhicheverHeadComesUpFirst(bFirst: Bool) {
    let legacy = OrientationPreferences(propertyList: ["22f0-3a4b-12345678": 90] as [String: Any])
    let rig = Rig(preferences: legacy)
    for head: UInt8 in (bFirst ? [1, 0] : [0, 1]) {
        rig.send(.monitorAttached(monitor(head)))
        rig.settle()
    }
    #expect(rig.controller.preferences.propertyList == ["22f0-3a4b-12345678": 90,
                                                        "22f0-3a4b-12345678-head0": 90,
                                                        "22f0-3a4b-12345678-head1": 90])
    #expect(rig.status(0)?.orientation == .turnedClockwise)
    #expect(rig.status(1)?.orientation == .turnedClockwise)
}

@MainActor
@Test func aFailedTwinCreationWritesNothingAndIsRecordedOnceItSucceeds() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    rig.effects.failCreation = true
    rig.send(.monitorAttached(monitor(1)))
    rig.settle()
    #expect(rig.status(1)?.display == nil)
    #expect(rig.status(1)?.problem == "CGVirtualDisplay refused")
    #expect(rig.effects.savedPreferences.isEmpty, "a failed creation changes no stored rotation")

    rig.effects.failCreation = false
    rig.send(.setOrientation(head: 1, orientation: .standard))          // the retry the menu offers
    rig.settle()
    #expect(rig.status(1)?.display != nil)
    #expect(rig.controller.preferences.propertyList == ["22f0-3a4b-12345678-head0": 0,
                                                        "22f0-3a4b-12345678-head1": 0])
}

@MainActor
@Test func aStandardTwinStaysStandardWhenTheOtherPanelIsChangedAloneWhileItIsAbsent() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    rig.send(.monitorAttached(monitor(1)))
    rig.settle()
    rig.send(.setOrientation(head: 0, orientation: .turnedCounterclockwise))   // a twin is attached: socket only
    rig.settle()
    rig.send(.monitorDetached(head: 1))
    rig.settle()
    rig.send(.setOrientation(head: 0, orientation: .upsideDown))               // alone: the identity record
    rig.settle()

    rig.send(.monitorAttached(monitor(1)))
    rig.settle()
    #expect(rig.status(1)?.orientation == .standard)
    #expect(rig.status(0)?.orientation == .upsideDown)
}

// MARK: - Dock cursor targets follow the displays (issue 2)

@MainActor
@Test func aPortraitToStandardRebuildInstallsTheCursorTargetWhenTheReplacementDisplayExists() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    let first = try #require(rig.effects.created.first?.display)
    #expect(rig.effects.published.last == [target(0, first)])

    rig.send(.setOrientation(head: 0, orientation: .turnedClockwise))          // portrait: no dock cursor
    #expect(rig.effects.published.last == [])
    rig.settle()
    #expect(rig.effects.published.last == [])

    rig.send(.setOrientation(head: 0, orientation: .standard))                 // portrait -> standard rebuild
    #expect(rig.effects.published.last == [])
    let releasedPortrait = try #require(rig.effects.pendingReleases.first)
    rig.effects.pendingReleases.removeFirst()
    rig.send(.displayReleased(display: releasedPortrait))                     // the replacement is created now

    let replacement = try #require(rig.effects.created.last?.display)
    #expect(replacement != releasedPortrait)
    // The target is installed as soon as the display exists, before its mode is set or its capture starts.
    #expect(rig.effects.published.last == [target(0, replacement)])
    rig.settle()
    #expect(rig.effects.published.last == [target(0, replacement)])
}

@MainActor
@Test func aReplacementCancelledByADetachNeverInstallsItsDisplayOrItsTarget() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    rig.send(.setOrientation(head: 0, orientation: .turnedClockwise))         // the old display is being released
    rig.send(.monitorDetached(head: 0))                                       // the replacement is cancelled
    rig.effects.pendingReleases.removeAll()
    rig.send(.displayReleased(display: try #require(rig.effects.created.first?.display)))
    rig.settle()

    #expect(rig.effects.created.count == 1, "no replacement display was created")
    #expect(rig.effects.published.last == [])
    #expect(rig.status(0) == nil)
}

@MainActor
@Test func aReattachDuringTheOldReleaseWaitsForIt() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    rig.send(.setOrientation(head: 0, orientation: .turnedClockwise))
    let old = try #require(rig.effects.pendingReleases.first)
    rig.send(.monitorDetached(head: 0))
    rig.send(.monitorAttached(monitor(0)))
    #expect(rig.effects.created.count == 1, "the new display waits for the old one to be released")

    rig.effects.pendingReleases.removeAll()
    rig.send(.displayReleased(display: old))
    #expect(rig.effects.created.count == 2)
    rig.settle()
    #expect(rig.status(0)?.orientation == .turnedClockwise)
}

@MainActor
@Test func aHeadWithoutAHardwareCursorIsNeverACursorTarget() {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0, cursor: false)))
    rig.settle()
    #expect(rig.effects.published.allSatisfy { $0.isEmpty })
}

// MARK: - First usable frame (issue 3)

@MainActor
@Test func idleAndBadFramesCannotHoldTheStartingStateForever() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let first = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(first))
    // One bad complete frame, then only idle frames: the platform reports nothing for any of them.
    #expect(rig.status(0)?.hasUsableFrame == false)

    rig.advance(by: .seconds(9))
    #expect(rig.effects.stops.isEmpty)
    rig.advance(by: .seconds(1))                                              // the deadline is 10 s
    #expect(rig.effects.stops == [first])
    #expect(rig.status(0)?.captureAttempt == nil)
    #expect(rig.status(0)?.problem == "Head 0 produced no usable frame within 10 s")

    rig.advance(by: .seconds(1))                                              // the retry after 1 s
    let second = try #require(rig.effects.pendingStarts.first)
    #expect(second != first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(second))
    rig.send(.captureUsableFrame(second))
    #expect(rig.status(0)?.hasUsableFrame == true)
    #expect(rig.status(0)?.problem == nil)
}

@MainActor
@Test func resultsFromAnEndedAttemptCannotTouchTheNewCapture() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let first = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(first))
    rig.advance(by: .seconds(10))
    rig.advance(by: .seconds(1))
    let second = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(second))
    rig.send(.captureUsableFrame(second))
    #expect(!rig.controller.armedTimers.contains(.firstFrame(second)), "the usable capture's deadline is cancelled")

    // Late results from the first attempt, and its stale deadline.
    let stopsBefore = rig.effects.stops.count
    rig.send(.captureUsableFrame(first))
    rig.send(.captureStopped(first, .unusableFrames(reason: "late")))
    rig.send(.captureStarted(first))
    rig.send(.timerFired(.firstFrame(first)))

    #expect(rig.status(0)?.captureAttempt == second)
    #expect(rig.status(0)?.hasUsableFrame == true)
    #expect(rig.effects.stops.count == stopsBefore + 1, "a late start of the old attempt is stopped, not installed")
    #expect(rig.effects.stops.last == first)
    #expect(rig.effects.pendingStarts.isEmpty)

    rig.advance(by: .seconds(120))
    #expect(!rig.effects.stops.contains(second), "the usable capture has no deadline left")
    #expect(rig.status(0)?.captureAttempt == second)
}

@MainActor
@Test func aFailedStartArmsNoDeadlineAndKeepsItsReason() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStartFailed(attempt, .failed("display not shareable")))

    #expect(!rig.clock.scheduled.contains(.firstFrame(attempt)))
    #expect(rig.status(0)?.problem == "display not shareable")
    #expect(rig.clock.scheduled.contains(.captureRetry(head: 0)))
}

@MainActor
@Test func detachingWhileStartingCancelsTheDeadlineAndALateStartIsStopped() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.monitorDetached(head: 0))
    #expect(rig.effects.stops.contains(attempt))

    rig.send(.captureStarted(attempt))                                        // the start completes late
    rig.advance(by: .seconds(120))
    #expect(rig.effects.stops.last == attempt)
    #expect(!rig.clock.scheduled.contains(.firstFrame(attempt)))
    #expect(!rig.clock.scheduled.contains(.captureRetry(head: 0)))
}

@MainActor
@Test func distinctErrorsReadDifferentlyAndAUnusableRunIsNotADeadline() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(attempt))
    rig.send(.captureStopped(attempt, .unusableFrames(reason: "frame size 10x10")))
    #expect(rig.status(0)?.problem == "Head 0 produced unusable frames (frame size 10x10)")
}

@MainActor
@Test func retryDelaysGrowWhileNoStreamDeliversAUsableFrame() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    var delays: [Duration] = []
    for _ in 0..<7 {
        let attempt = try #require(rig.effects.pendingStarts.first)
        rig.effects.pendingStarts.removeFirst()
        rig.send(.captureStarted(attempt))
        rig.advance(by: .seconds(10))                                         // no usable frame
        let delay = try #require(rig.effects.retryDelays.last)
        delays.append(delay)
        rig.advance(by: delay)
    }
    #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
}

@MainActor
@Test func permissionDeniedStopsRetriesUntilAccessIsGranted() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStartFailed(attempt, .permissionDenied))

    #expect(rig.controller.permissionDenied)
    #expect(rig.status(0)?.problem == "Screen Recording permission is required")
    rig.advance(by: .seconds(120))
    #expect(rig.effects.pendingStarts.isEmpty, "no retry while permission is missing")

    rig.send(.permissionChanged(granted: true))
    #expect(!rig.controller.permissionDenied)
    #expect(rig.effects.pendingStarts.count == 1)
}

@MainActor
@Test func resumeRestartsAFailedCaptureNowInsteadOfAfterItsBackoff() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStartFailed(attempt, .failed("x")))
    rig.send(.resumeCapture)
    #expect(rig.effects.pendingStarts.count == 1)
    #expect(!rig.clock.scheduled.contains(.captureRetry(head: 0)))
}

// MARK: - Default mode setup (issue 4)

@MainActor
@Test func aFailedModeSetupDoesNotStopTheHealthyCaptureAndIsRetriedOnTheFakeClock() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    #expect(rig.effects.pendingStarts.isEmpty, "the first capture waits for the first mode attempt")
    let display = try #require(rig.effects.created.first?.display)

    rig.answerMode(.failed("no HiDPI mode"))
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(attempt))
    rig.send(.captureUsableFrame(attempt))
    #expect(rig.status(0)?.hasUsableFrame == true, "the capture starts after the failed attempt")
    #expect(rig.status(0)?.problem == nil)
    #expect(rig.clock.scheduled.contains(.modeRetry(head: 0, display: display)))

    rig.advance(by: .seconds(1))
    #expect(rig.effects.configureCount == 2)
    #expect(rig.effects.stops.isEmpty, "a mode retry never stops a running capture")
    rig.answerMode(.applied)
    #expect(rig.effects.savedModes == [["22f0-3a4b-12345678"]])

    rig.advance(by: .seconds(120))
    #expect(rig.effects.configureCount == 2, "no further setup once the mode is applied")
    #expect(rig.effects.modeRetryDelays == [.seconds(1)])
}

@MainActor
@Test func aPermanentModeFailureStopsRetryingAndIsReportedAsAStatusWhileCaptureContinues() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    let backoff: [Int64] = [1, 2, 4, 8, 16]
    for failure in 1...HeadTiming.maxModeAttempts {
        if failure > 1 { rig.advance(by: .seconds(backoff[failure - 2])) }
        rig.answerMode(.failed("no HiDPI mode"))
    }
    #expect(rig.effects.configureCount == HeadTiming.maxModeAttempts)
    #expect(rig.effects.modeRetryDelays == backoff.map { Duration.seconds($0) })
    #expect(!rig.clock.scheduled.contains { if case .modeRetry = $0 { true } else { false } })
    #expect(rig.status(0)?.problem?.hasPrefix("Default display mode unavailable") == true)
    #expect(rig.effects.savedModes.isEmpty)

    rig.settle()
    #expect(rig.status(0)?.hasUsableFrame == true, "the capture was never stopped for the mode")
    #expect(rig.effects.stops.isEmpty)
}

@MainActor
@Test func detachCancelsTheModeRetryAndReattachStartsTheSetupAgain() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    let display = try #require(rig.effects.created.first?.display)
    rig.answerMode(.failed("no HiDPI mode"))                                  // a retry is armed for 1 s
    rig.send(.monitorDetached(head: 0))                                       // the kept display's retry is cancelled

    rig.advance(by: .seconds(5))
    #expect(rig.effects.configureCount == 1, "no retry while the monitor is away")
    rig.send(.timerFired(.modeRetry(head: 0, display: display)))              // stale key: ignored
    #expect(rig.effects.configureCount == 1)

    rig.send(.monitorAttached(monitor(0)))                                    // back on the kept display
    #expect(rig.effects.configureCount == 2, "the setup starts again at once, with fresh attempts")
    rig.answerMode(.applied)
    #expect(rig.effects.savedModes.count == 1)
}

@MainActor
@Test func aLateModeResultForAReleasedDisplayChangesNothing() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    let old = try #require(rig.effects.created.first?.display)
    rig.send(.setOrientation(head: 0, orientation: .turnedClockwise))         // the old display is released
    rig.effects.pendingReleases.removeAll()
    rig.send(.displayReleased(display: old))

    rig.send(.modeSetupFinished(head: 0, display: old, outcome: .applied))    // late success for the old display
    #expect(rig.effects.savedModes.isEmpty)
    #expect(rig.effects.pendingStarts.isEmpty)
}

@MainActor
@Test func noSecondDefaultModeSetterIsIssuedWhileOneIsInFlight() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    let display = try #require(rig.effects.created.first?.display)
    rig.send(.timerFired(.modeRetry(head: 0, display: display)))              // not armed: ignored
    rig.advance(by: .seconds(60))
    #expect(rig.effects.configureCount == 1)

    rig.answerMode(.failed("x"))                                              // a retry is armed
    rig.advance(by: .seconds(1))                                              // the retry issues the second setter
    #expect(rig.effects.configureCount == 2)
    rig.send(.timerFired(.modeRetry(head: 0, display: display)))              // already fired: ignored
    #expect(rig.effects.configureCount == 2)
}

// MARK: - Other transitions

@MainActor
@Test func turningBy180KeepsTheDisplayAndRestartsOnlyTheCapture() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    let display = try #require(rig.status(0)?.display)
    let old = try #require(rig.status(0)?.captureAttempt)

    rig.send(.setOrientation(head: 0, orientation: .upsideDown))
    #expect(rig.effects.stops.contains(old))
    #expect(rig.effects.created.count == 1)
    #expect(rig.status(0)?.display == display)
    #expect(rig.status(0)?.orientation == .upsideDown)
    #expect(rig.effects.pendingStarts.count == 1)
}

@MainActor
@Test func aSecondRemovalOfTheVirtualDisplayReportsTheHeadLost() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    let first = try #require(rig.status(0)?.display)

    rig.send(.displayTerminated(display: first))
    rig.settle()
    let second = try #require(rig.status(0)?.display)
    #expect(second != first, "the first removal is rebuilt")

    rig.send(.displayTerminated(display: second))
    rig.settle()
    #expect(rig.status(0)?.display == nil)
    #expect(rig.status(0)?.problem == "macOS removed the virtual display")
}

@MainActor
@Test func aKeptDisplayIsReleasedWhenTheReconnectGraceEnds() throws {
    let rig = Rig()
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    let display = try #require(rig.status(0)?.display)
    rig.send(.monitorDetached(head: 0))

    rig.advance(by: .seconds(19))
    #expect(rig.effects.pendingReleases.isEmpty)
    rig.advance(by: .seconds(1))
    #expect(rig.effects.pendingReleases == [display])
}

// MARK: - A usable frame can beat the start result

/// The stream is open while its start is still completing, so its first usable frame can reach the controller before
/// .captureStarted. The frame belongs to one attempt, and only that attempt's start may adopt it.

@MainActor
@Test(arguments: [false, true])
func aUsableFrameAndItsStartResultInEitherOrderLeaveTheCaptureLiveAndWithoutADeadline(frameFirst: Bool) throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    if frameFirst {
        rig.send(.captureUsableFrame(attempt))
        rig.send(.captureStarted(attempt))
    } else {
        rig.send(.captureStarted(attempt))
        rig.send(.captureUsableFrame(attempt))
    }
    #expect(rig.status(0)?.hasUsableFrame == true)
    #expect(rig.status(0)?.captureAttempt == attempt)
    #expect(!rig.controller.armedTimers.contains(.firstFrame(attempt)), "no deadline is armed for a live stream")

    rig.advance(by: .seconds(120))
    #expect(rig.effects.stops.isEmpty, "a healthy stream is never failed by the first-frame deadline")
    #expect(rig.status(0)?.problem == nil)
}

@MainActor
@Test func anEarlyFrameForACancelledStartIsDroppedAndTheLateStartIsStopped() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureUsableFrame(attempt))
    rig.send(.monitorDetached(head: 0))                                    // cancels the start before its result
    rig.send(.captureStarted(attempt))

    #expect(rig.effects.stops.last == attempt)
    #expect(rig.status(0) == nil)
    rig.advance(by: .seconds(120))
    #expect(!rig.clock.scheduled.contains(.firstFrame(attempt)))
    #expect(rig.effects.pendingStarts.isEmpty, "nothing restarts after the detach")
}

@MainActor
@Test func anEarlyFrameDoesNotSurviveAFailedStartAndCannotMakeTheNextAttemptLive() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let first = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureUsableFrame(first))                                   // early frame of the first attempt
    rig.send(.captureStartFailed(first, .failed("start refused")))
    #expect(rig.status(0)?.hasUsableFrame == false)

    rig.advance(by: .seconds(1))                                           // the retry after the first failure
    let second = try #require(rig.effects.pendingStarts.first)
    #expect(second != first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureUsableFrame(first))                                   // the previous generation's frame, late
    rig.send(.captureStarted(second))

    #expect(rig.status(0)?.hasUsableFrame == false, "the old generation's frame does not make the new one live")
    #expect(rig.controller.armedTimers.contains(.firstFrame(second)), "the new attempt keeps its own deadline")
    rig.advance(by: .seconds(10))
    #expect(rig.effects.stops.contains(second))
    #expect(rig.status(0)?.problem == "Head 0 produced no usable frame within 10 s")
}

@MainActor
@Test func aUsableFrameThatMatchesNoStartingAttemptIsIgnored() throws {
    let rig = Rig()
    rig.send(.captureUsableFrame(CaptureAttempt(head: 7, id: 1)))         // no such head
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureUsableFrame(CaptureAttempt(head: 0, id: 999)))       // an attempt that was never issued
    rig.send(.captureStarted(attempt))

    #expect(rig.status(0)?.hasUsableFrame == false)
    #expect(rig.controller.armedTimers.contains(.firstFrame(attempt)))
    rig.advance(by: .seconds(10))
    #expect(rig.effects.stops == [attempt])
}

// MARK: - Screen Recording denied: nothing starts on attach, rotation or resume

@MainActor
@Test func aHeadAttachedWhileScreenRecordingIsDeniedGetsADisplayButNoCapture() throws {
    let rig = Rig(permissionDenied: true)
    rig.send(.monitorAttached(monitor(0)))
    rig.settle()
    #expect(rig.effects.created.count == 1)
    #expect(rig.status(0)?.display != nil)
    #expect(rig.effects.pendingStarts.isEmpty, "no capture starts while permission is denied")
    #expect(rig.status(0)?.captureAttempt == nil)
    #expect(rig.status(0)?.problem == "Screen Recording permission is required")

    rig.advance(by: .seconds(120))
    #expect(rig.effects.pendingStarts.isEmpty)
    rig.send(.permissionChanged(granted: true))
    #expect(rig.effects.pendingStarts.count == 1, "the grant starts the head that was waiting")
}

@MainActor
@Test(arguments: [DisplayOrientation.upsideDown, .turnedClockwise])
func aRotationWhileScreenRecordingIsDeniedStartsNoCaptureAndStartsOneWhenItIsGranted(to orientation: DisplayOrientation) throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let attempt = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStartFailed(attempt, .permissionDenied))
    #expect(rig.controller.permissionDenied)

    rig.send(.setOrientation(head: 0, orientation: orientation))
    rig.settle()                                                          // releases and mode setups only
    #expect(rig.effects.pendingStarts.isEmpty, "rotation waits for permission too")
    #expect(rig.status(0)?.orientation == orientation)
    #expect(rig.status(0)?.display != nil)

    rig.send(.permissionChanged(granted: true))
    #expect(rig.effects.pendingStarts.count == 1)
    let restarted = try #require(rig.effects.pendingStarts.first)
    rig.send(.captureStarted(restarted))
    rig.send(.captureUsableFrame(restarted))
    #expect(rig.status(0)?.hasUsableFrame == true)
}

@MainActor
@Test func resumeWhileScreenRecordingIsDeniedStartsNothingUntilItIsGranted() throws {
    let rig = Rig(permissionDenied: true)
    attachAndAnswerMode(rig, 0)
    rig.send(.resumeCapture)
    #expect(rig.effects.pendingStarts.isEmpty)
    rig.send(.permissionChanged(granted: true))
    #expect(rig.effects.pendingStarts.count == 1)
}

// MARK: - Permission notification races

@MainActor
@Test func aDenialFromAStartIssuedBeforeTheLatestGrantDoesNotBlockTheRestoredPermission() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let stale = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.permissionChanged(granted: true))                           // a grant arrives while the start is in flight
    rig.send(.captureStartFailed(stale, .permissionDenied))                // the start reports the old denial

    #expect(!rig.controller.permissionDenied, "the denial describes permission that was restored")
    #expect(rig.status(0)?.problem == nil)
    rig.advance(by: .seconds(1))                                          // the normal first retry
    #expect(rig.effects.pendingStarts.count == 1)
}

@MainActor
@Test func aDenialFromAStartIssuedAfterTheLatestGrantStillBlocksUntilTheNextGrant() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let stale = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.permissionChanged(granted: true))
    rig.send(.captureStartFailed(stale, .permissionDenied))
    rig.advance(by: .seconds(1))
    let current = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()

    rig.send(.captureStartFailed(current, .permissionDenied))             // issued after the grant: a real denial
    #expect(rig.controller.permissionDenied)
    rig.advance(by: .seconds(120))
    #expect(rig.effects.pendingStarts.isEmpty)
    rig.send(.permissionChanged(granted: true))
    #expect(rig.effects.pendingStarts.count == 1)
}

// MARK: - Screen Recording revoked, granted again, and failures that are not permission

@MainActor
@Test func aStreamThatLosesPermissionStaysDownUntilTheGrantAndThenRestartsOnce() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let first = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(first))
    rig.send(.captureUsableFrame(first))
    rig.send(.captureStopped(first, .permissionDenied))                    // revoked while running
    #expect(rig.controller.permissionDenied)
    #expect(rig.status(0)?.captureAttempt == nil)
    #expect(rig.effects.stops.contains(first))

    rig.advance(by: .seconds(120))
    #expect(rig.effects.pendingStarts.isEmpty, "no retry while permission is denied")
    rig.send(.permissionChanged(granted: true))
    #expect(rig.effects.pendingStarts.count == 1, "the grant restarts the head once")
    #expect(!rig.controller.permissionDenied)
}

@MainActor
@Test func aNonPermissionFailureDoesNotCountAsAGrantSoALaterDenialStillBlocks() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let first = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStartFailed(first, .failed("stream refused")))
    #expect(!rig.controller.permissionDenied, "a failure that is not a permission failure denies nothing")
    #expect(rig.status(0)?.problem == "stream refused")

    rig.advance(by: .seconds(1))
    let second = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStartFailed(second, .permissionDenied))              // issued with no grant since: a real denial
    #expect(rig.controller.permissionDenied, "no grant was counted, so this denial is current")
    #expect(rig.status(0)?.problem == "Screen Recording permission is required")
}

@MainActor
@Test func aNonPermissionFailureWhileDeniedLeavesTheDenialInPlace() throws {
    let rig = Rig(permissionDenied: true)
    attachAndAnswerMode(rig, 0)
    rig.send(.captureStartFailed(CaptureAttempt(head: 0, id: 999), .failed("stray")))
    rig.send(.captureStopped(CaptureAttempt(head: 0, id: 998), .failed("stray")))
    #expect(rig.controller.permissionDenied)
    #expect(rig.effects.pendingStarts.isEmpty)
    rig.send(.permissionChanged(granted: true))
    #expect(rig.effects.pendingStarts.count == 1)
}

// MARK: - A rebuilding head stays listed

@MainActor
@Test func aHeadWaitingForItsRebuiltDisplayStaysListedWithItsLatestRotationAsOneRow() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    rig.settle()
    rig.send(.setOrientation(head: 0, orientation: .turnedClockwise))
    let released = try #require(rig.effects.pendingReleases.first)

    let waiting = try #require(rig.status(0), "the head is listed while its old display is released")
    #expect(waiting.display == nil)
    #expect(waiting.waitingForIdentity, "its replacement waits for the old display to be released")
    #expect(waiting.orientation == .turnedClockwise)

    rig.send(.setOrientation(head: 0, orientation: .upsideDown))
    rig.send(.setOrientation(head: 0, orientation: .turnedCounterclockwise))
    #expect(rig.controller.statuses.count == 1, "rapid choices keep one row for the head")
    #expect(rig.status(0)?.orientation == .turnedCounterclockwise)
    #expect(rig.effects.pendingReleases == [released], "one release, not one per choice")

    rig.send(.displayReleased(display: released))
    #expect(rig.effects.created.count == 2)
    #expect(rig.effects.created.last?.orientation == .turnedCounterclockwise, "the replacement gets the last choice")
    #expect(rig.status(0)?.display == rig.effects.created.last?.display)
}

@MainActor
@Test func aDetachWhileAHeadWaitsForItsReleaseRemovesItsRowAndTheLateReleaseMakesNoDisplay() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    rig.settle()
    rig.send(.setOrientation(head: 0, orientation: .turnedClockwise))
    let released = try #require(rig.effects.pendingReleases.first)

    rig.send(.monitorDetached(head: 0))
    #expect(rig.status(0) == nil, "the detached head's row goes")
    #expect(rig.controller.statuses.isEmpty)

    rig.send(.displayReleased(display: released))
    #expect(rig.effects.created.count == 1, "a stale release makes no display for the detached head")
    #expect(rig.controller.attachedMonitors.isEmpty)
}

@MainActor
@Test func aStopThatIsNotConfirmedIsReportedOnTheWaitingHeadUntilItIsConfirmed() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    rig.settle()
    rig.send(.setOrientation(head: 0, orientation: .turnedClockwise))
    #expect(rig.status(0)?.stopUnconfirmed == false)

    rig.send(.stopConfirmationChanged(head: 0, unconfirmed: true))
    #expect(rig.status(0)?.stopUnconfirmed == true)
    rig.send(.stopConfirmationChanged(head: 0, unconfirmed: false))
    #expect(rig.status(0)?.stopUnconfirmed == false)
}

// MARK: - Permission: a denial counts only from the grant it was issued under

@MainActor
@Test func aDenialFromAStreamThatStartedBeforeAGrantIsStaleEvenWhileItStillRuns() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let first = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(first))
    rig.send(.captureUsableFrame(first))                  // running under grant 0
    rig.send(.permissionChanged(granted: false))           // revoked
    rig.send(.permissionChanged(granted: true))            // granted again: the running stream is left alone
    #expect(rig.effects.pendingStarts.isEmpty)

    rig.send(.captureStopped(first, .permissionDenied))    // the old stream's denial arrives late
    #expect(!rig.controller.permissionDenied, "the stream was issued before the grant, so its denial is stale")
    #expect(rig.status(0)?.problem == nil)
    rig.advance(by: .seconds(1))
    #expect(rig.effects.pendingStarts.count == 1, "the head restarts under the grant")
}

@MainActor
@Test func aDenialFromAStreamThatRunsUnderTheCurrentGrantStillBlocks() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let first = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(first))
    rig.send(.captureUsableFrame(first))
    rig.send(.permissionChanged(granted: true))            // grant 1
    rig.send(.captureStopped(first, .failed("stream ended")))
    rig.advance(by: .seconds(1))
    let second = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()
    rig.send(.captureStarted(second))
    rig.send(.captureUsableFrame(second))                  // running under grant 1
    rig.send(.captureStopped(second, .permissionDenied))   // a real revocation: issued under the current grant
    #expect(rig.controller.permissionDenied)
    rig.advance(by: .seconds(120))
    #expect(rig.effects.pendingStarts.isEmpty, "no restart while permission is denied")
}

@MainActor
@Test func aStaleDenialForAnEarlierStartDoesNotTouchTheHeadsNewerStart() throws {
    let rig = Rig()
    attachAndAnswerMode(rig, 0)
    let old = try #require(rig.effects.pendingStarts.first)
    rig.effects.pendingStarts.removeFirst()                // start A is in flight under grant 0
    rig.send(.monitorDetached(head: 0))                    // A is retired
    rig.send(.permissionChanged(granted: true))            // grant 1
    rig.send(.monitorAttached(monitor(0)))                 // the head is back: start B under grant 1
    let current = try #require(rig.effects.pendingStarts.first)
    #expect(current != old)

    rig.send(.captureStartFailed(old, .permissionDenied))  // A reports its old denial
    #expect(!rig.controller.permissionDenied)
    #expect(rig.status(0)?.captureAttempt == current, "the newer start is left alone")
    #expect(!rig.effects.stops.contains(current))
}

// MARK: - Display creation: refused creations are retried with bounded backoff

@MainActor
@Test func aTransientCreationFailureIsRetriedAfterOneSecondAndSucceeds() throws {
    let rig = Rig()
    rig.effects.failCreation = true
    rig.send(.monitorAttached(monitor(0)))
    #expect(rig.status(0)?.problem == "CGVirtualDisplay refused")
    #expect(rig.effects.creationRetryDelays == [.seconds(1)])

    rig.effects.failCreation = false
    rig.advance(by: .seconds(1))
    #expect(rig.effects.created.count == 2)
    #expect(rig.status(0)?.display != nil)
    #expect(rig.status(0)?.problem == nil)
}

@MainActor
@Test func aPersistentCreationFailureBacksOffToAThirtySecondCapAndNeverStorms() throws {
    let rig = Rig()
    rig.effects.failCreation = true
    rig.send(.monitorAttached(monitor(0)))
    // Attempts at 0, 1, 3, 7, 15, 31, 61 and 91 s.
    rig.advance(by: .seconds(91))
    #expect(rig.effects.created.count == 8, "the first attempt and seven retries")
    #expect(rig.effects.creationRetryDelays == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
    #expect(rig.status(0)?.problem == "CGVirtualDisplay refused", "the refusal stays shown")
    #expect(rig.status(0)?.display == nil)

    rig.advance(by: .seconds(29))
    #expect(rig.effects.created.count == 8, "no attempt between the 30 s retries")
    rig.advance(by: .seconds(1))
    #expect(rig.effects.created.count == 9)
}

@MainActor
@Test func aStaleCreationRetryAfterADetachOrANewAttachCreatesNothing() throws {
    let rig = Rig()
    rig.effects.failCreation = true
    rig.send(.monitorAttached(monitor(0)))
    let old = try #require(rig.effects.created.first?.display)

    rig.send(.monitorDetached(head: 0))
    rig.advance(by: .seconds(5))
    #expect(rig.effects.created.count == 1, "the detached head's retry is cancelled")

    rig.effects.failCreation = false
    rig.send(.monitorAttached(monitor(0)))
    #expect(rig.effects.created.count == 2, "a new attach makes one new display")
    rig.send(.timerFired(.creationRetry(head: 0, display: old)))   // the old retry arrives late
    #expect(rig.effects.created.count == 2, "a late retry of an earlier display creates nothing")
    #expect(rig.status(0)?.display != nil)
}

@MainActor
@Test func failedCreationsOnTwoHeadsRetryOnTheirOwnTimersWithoutDuplicateCreates() throws {
    let rig = Rig()
    rig.effects.failingHeads = [0, 1]
    rig.send(.monitorAttached(monitor(0)))
    rig.send(.monitorAttached(monitor(1)))
    #expect(rig.effects.created.count == 2)

    // Both are retried after 1 s. Head 1 now succeeds; head 0 is refused again, with a 2 s backoff.
    rig.effects.failingHeads = [0]
    rig.advance(by: .seconds(1))
    #expect(rig.effects.created.count == 4, "each head is retried once")
    #expect(rig.status(1)?.display != nil)
    #expect(rig.status(0)?.display == nil)

    rig.effects.failingHeads = []
    rig.advance(by: .seconds(1))
    #expect(rig.effects.created.count == 4, "head 0's next retry is 2 s after its failure")
    rig.advance(by: .seconds(1))
    #expect(rig.status(0)?.display != nil)
    #expect(rig.effects.created.filter { $0.head == 0 }.count == 3)
    #expect(rig.effects.created.filter { $0.head == 1 }.count == 2, "head 1 is created once and never again")
}

@MainActor
@Test func aPermissionDenialDoesNotStopARefusedCreationFromBeingRetried() throws {
    let rig = Rig(permissionDenied: true)
    rig.effects.failCreation = true
    rig.send(.monitorAttached(monitor(0)))
    rig.effects.failCreation = false
    rig.advance(by: .seconds(1))
    #expect(rig.effects.created.count == 2, "a virtual display needs no Screen Recording: its creation is retried")
    rig.answerMode(.applied)                               // the head's first mode attempt resolves; then permission gates it
    #expect(rig.status(0)?.problem == "Screen Recording permission is required")
    #expect(rig.effects.pendingStarts.isEmpty, "the capture waits for the permission")
}

@MainActor
@Test func aWakeRetriesARefusedCreationNowAndCancelsItsBackoff() throws {
    let rig = Rig()
    rig.effects.failCreation = true
    rig.send(.monitorAttached(monitor(0)))
    rig.effects.failCreation = false
    rig.send(.resumeCapture)
    #expect(rig.effects.created.count == 2, "the wake retries at once")
    rig.advance(by: .seconds(1))
    #expect(rig.effects.created.count == 2, "the backoff timer it replaces is cancelled")
    #expect(rig.status(0)?.display != nil)
}
