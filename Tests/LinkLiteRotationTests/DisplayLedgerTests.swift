// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import LinkLiteRotation

// These tests run DisplayLedger with real Tasks, real cancellation and real awaits. Nothing sleeps for a result:
// tests wait for recorded events. Two stand-ins replace the platform:
// - SystemCallGate is a default-mode operation suspended inside a system call. Like CoreGraphics, the call ignores
//   cancellation; it returns only when the test opens the gate.
// - TrackedDisplay stands in for CGVirtualDisplay and records its own deinit, so the order of teardown is observable.
// The last group drives the real HeadController through HeadDriver, with LedgerEffects routing commands the way
// DisplayHost does.

/// What happened, in order. Deinit can run on any thread that drops the last reference, so the log is locked.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    var all: [String] { lock.withLock { entries } }

    func index(of entry: String) -> Int? { all.firstIndex(of: entry) }
}

/// A display stand-in that records its own deinit.
private final class TrackedDisplay {
    let name: String
    private let log: EventLog

    init(_ name: String, log: EventLog) {
        self.name = name
        self.log = log
    }

    deinit { log.record("deinit \(name)") }
}

/// A one-shot event that tasks can await. Later waiters return at once.
@MainActor
private final class Waypoint {
    private(set) var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else { return }
        fired = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func reached() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class ProbeCounter {
    var count = 0
}

/// A default-mode operation suspended in a system call. Cancellation is observed (`cancelled`) but does not end the
/// call: it returns only when the test calls `open()`.
@MainActor
private final class SystemCallGate {
    let entered = Waypoint()
    let cancelled = Waypoint()
    private let opened = Waypoint()

    func open() { opened.fire() }

    func call() async {
        entered.fire()
        await withTaskCancellationHandler {
            await opened.reached()
        } onCancel: {
            Task { @MainActor in self.cancelled.fire() }
        }
    }
}

/// A default-mode operation that does what DisplayHost's does: it may be cancelled, and it sets the mode only if it
/// has not been cancelled. `gate`, when given, stands in for the system call that holds it.
@MainActor
private func modeOperation(log: EventLog, gate: SystemCallGate? = nil)
    -> @MainActor (TrackedDisplay) async -> ModeOutcome {
    { display in
        log.record("mode entered \(display.name)")
        if let gate {
            await gate.call()
        } else {
            do { try await Task.sleep(for: .seconds(3600)) } catch {}     // ends at once when cancelled
        }
        guard !Task.isCancelled else { return .failed("cancelled") }
        log.record("setMode \(display.name)")
        return .applied
    }
}

// MARK: - DisplayLedger

@MainActor
@Test(.timeLimit(.minutes(1)))
func aReleaseWaitsForACancelledOperationStuckInASystemCallBeforeItDropsTheDisplayAndAcknowledges() async {
    let log = EventLog()
    let ledger = DisplayLedger<TrackedDisplay>()
    let gate = SystemCallGate()
    var display: TrackedDisplay? = TrackedDisplay("display 1", log: log)
    weak let oldDisplay = display
    ledger.register(display!, generation: 1)
    var reports: [ModeOutcome] = []

    #expect(ledger.start(1, operation: modeOperation(log: log, gate: gate), report: { reports.append($0) }) == .started)
    await gate.entered.reached()
    display = nil

    let release = Task { @MainActor in
        await ledger.release(1) {
            #expect(oldDisplay == nil, "the old display is gone before its replacement can be acknowledged")
            log.record("acknowledged display 1")
        }
    }
    await gate.cancelled.reached()                                        // release has cancelled the stuck call
    #expect(!log.all.contains("acknowledged display 1"), "no acknowledgement while the call is still inside")
    #expect(oldDisplay != nil, "the operation still holds the display it is using")

    gate.open()
    await release.value
    #expect(log.all == ["mode entered display 1", "deinit display 1", "acknowledged display 1"])
    #expect(reports.isEmpty, "a cancelled operation reports nothing, so a stale result cannot reach the controller")
    #expect(ledger[1] == nil)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aCancellableOperationEndsAtOnceAndNeverSetsTheModeAfterItsRelease() async {
    let log = EventLog()
    let ledger = DisplayLedger<TrackedDisplay>()
    var display: TrackedDisplay? = TrackedDisplay("display 1", log: log)
    weak let oldDisplay = display
    ledger.register(display!, generation: 1)
    var reports: [ModeOutcome] = []
    let entered = Waypoint()
    let operation = modeOperation(log: log)
    #expect(ledger.start(1, operation: { d in entered.fire(); return await operation(d) },
                         report: { reports.append($0) }) == .started)
    await entered.reached()                                               // the setup is sleeping, cancellably
    display = nil

    await ledger.release(1) { log.record("acknowledged display 1") }
    #expect(oldDisplay == nil)
    #expect(!log.all.contains("setMode display 1"), "a cancelled setup never changes the mode")
    #expect(log.all == ["mode entered display 1", "deinit display 1", "acknowledged display 1"])
    #expect(reports.isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aReleaseBeforeTheOperationStartsRunsNothing() async {
    let log = EventLog()
    let ledger = DisplayLedger<TrackedDisplay>()
    var display: TrackedDisplay? = TrackedDisplay("display 1", log: log)
    weak let oldDisplay = display
    ledger.register(display!, generation: 1)
    #expect(ledger.start(1, operation: modeOperation(log: log), report: { _ in }) == .started)
    display = nil

    // The operation's task has not run yet: release cancels it before its first step.
    await ledger.release(1) { log.record("acknowledged display 1") }
    #expect(oldDisplay == nil)
    #expect(log.all == ["deinit display 1", "acknowledged display 1"], "the cancelled operation never began")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aDisplayWithNoOperationIsDroppedBeforeItsAcknowledgement() async {
    let log = EventLog()
    let ledger = DisplayLedger<TrackedDisplay>()
    var display: TrackedDisplay? = TrackedDisplay("display 1", log: log)
    weak let oldDisplay = display
    ledger.register(display!, generation: 1)
    display = nil
    await ledger.release(1) {
        #expect(oldDisplay == nil)
        log.record("acknowledged display 1")
    }
    #expect(log.all == ["deinit display 1", "acknowledged display 1"])
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aSecondOperationCannotStartWhileOneIsOutstandingAndARetryFollowsItsReport() async {
    let log = EventLog()
    let ledger = DisplayLedger<TrackedDisplay>()
    let gate = SystemCallGate()
    let display = TrackedDisplay("display 1", log: log)
    ledger.register(display, generation: 1)
    var reports: [ModeOutcome] = []
    let reported = Waypoint()
    let operation = modeOperation(log: log, gate: gate)

    #expect(ledger.start(1, operation: operation, report: { reports.append($0); reported.fire() }) == .started)
    await gate.entered.reached()
    #expect(ledger.start(1, operation: operation, report: { _ in }) == .alreadyRunning, "no duplicate task")
    #expect(log.all.filter { $0.hasPrefix("mode entered") }.count == 1)

    gate.open()
    await reported.reached()
    #expect(reports == [.applied], "the call finished and was not cancelled, so its result is reported")
    #expect(log.all.filter { $0.hasPrefix("mode entered") }.count == 1)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aReportedOperationCanBeFollowedByAFreshAttemptAndAStartForAnUnknownDisplayIsRefused() async {
    let log = EventLog()
    let ledger = DisplayLedger<TrackedDisplay>()
    let display = TrackedDisplay("display 1", log: log)
    ledger.register(display, generation: 1)
    let first = Waypoint()
    let second = Waypoint()
    let failing: @MainActor (TrackedDisplay) async -> ModeOutcome = { _ in .failed("refused") }

    #expect(ledger.start(9, operation: failing, report: { _ in }) == .unknownDisplay)
    #expect(ledger.start(1, operation: failing, report: { _ in first.fire() }) == .started)
    await first.reached()
    #expect(ledger.start(1, operation: failing, report: { _ in second.fire() }) == .started, "a retry after a report")
    await second.reached()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aReleasedDisplayCannotTakeANewOperation() async {
    let log = EventLog()
    let ledger = DisplayLedger<TrackedDisplay>()
    let gate = SystemCallGate()
    let display = TrackedDisplay("display 1", log: log)
    ledger.register(display, generation: 1)
    #expect(ledger.start(1, operation: modeOperation(log: log, gate: gate), report: { _ in }) == .started)
    await gate.entered.reached()
    let release = Task { @MainActor in await ledger.release(1) { log.record("acknowledged display 1") } }
    await gate.cancelled.reached()
    #expect(ledger.start(1, operation: modeOperation(log: log), report: { _ in }) == .unknownDisplay)
    gate.open()
    await release.value
    #expect(ledger.start(1, operation: modeOperation(log: log), report: { _ in }) == .unknownDisplay)
    #expect(log.all.filter { $0.hasPrefix("mode entered") }.count == 1)
}

// MARK: - PollWait

@MainActor
@Test(.timeLimit(.minutes(1)))
func aValueFoundAtOnceNeverWaits() async {
    var probes = 0
    let value = await PollWait.firstValue(retries: 50, interval: .seconds(3600)) { () -> Int? in
        probes += 1
        return 7
    }
    #expect(value == 7)
    #expect(probes == 1)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aWaitWithoutAValueProbesOnceMoreThanItRetries() async {
    var probes = 0
    let value = await PollWait.firstValue(retries: 3, interval: .milliseconds(1)) { () -> Int? in
        probes += 1
        return nil
    }
    #expect(value == nil)
    #expect(probes == 4)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aCancelledWaitEndsWithoutFurtherProbesAndDoesNotFinishItsRetries() async {
    let counter = ProbeCounter()
    let probed = Waypoint()
    let task = Task { @MainActor in
        await PollWait.firstValue(retries: 50, interval: .seconds(3600)) { () -> Int? in
            counter.count += 1
            probed.fire()
            return nil
        }
    }
    await probed.reached()                                                // the first probe is done; the wait is sleeping
    task.cancel()
    let value = await task.value
    #expect(value == nil)
    #expect(counter.count == 1, "cancellation ends the wait; it does not keep probing")
}

// MARK: - Controller and ledger, through HeadDriver

/// Platform effects that route commands the way DisplayHost does: displays through a DisplayLedger, default-mode
/// work as ledger operations, releases after the captures stop and in one chain per head. Results come back
/// through the real driver, from real tasks. `until` waits for an observed state, bounded by the test's time limit.
@MainActor
private final class LedgerEffects: HeadEffects {
    private final class WeakDisplay {
        weak var value: TrackedDisplay?
    }

    let log: EventLog
    let ledger = DisplayLedger<TrackedDisplay>()
    var operation: @MainActor (TrackedDisplay) async -> ModeOutcome
    weak var driver: HeadDriver?
    private(set) var created: [UInt64] = []
    private(set) var pendingStarts: [CaptureAttempt] = []
    private(set) var stops: [CaptureAttempt] = []
    private(set) var reportedModes: [(display: UInt64, outcome: ModeOutcome)] = []
    private(set) var refusedModeStarts = 0
    private(set) var modeStarts = 0
    private var displayRefs: [UInt64: WeakDisplay] = [:]
    private var chains: [UInt8: Task<Void, Never>] = [:]
    private var waiters: [(predicate: @MainActor () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    init(log: EventLog, operation: @escaping @MainActor (TrackedDisplay) async -> ModeOutcome) {
        self.log = log
        self.operation = operation
    }

    func displayIsAlive(_ generation: UInt64) -> Bool { displayRefs[generation]?.value != nil }

    func until(_ predicate: @escaping @MainActor () -> Bool) async {
        if predicate() { return }
        await withCheckedContinuation { waiters.append((predicate, $0)) }
    }

    private func deliver(_ event: HeadEvent) {
        driver?.send(event)
        resumeWaiters()
    }

    private func resumeWaiters() {
        var pending: [(predicate: @MainActor () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if waiter.predicate() { waiter.continuation.resume() } else { pending.append(waiter) }
        }
        waiters = pending
    }

    func perform(_ command: HeadCommand) -> HeadEvent? {
        defer { resumeWaiters() }
        switch command {
        case .createDisplay(let head, let display, let monitor, _):
            let tracked = TrackedDisplay("display \(display) for \(monitor.name)", log: log)
            ledger.register(tracked, generation: display)
            let weak = WeakDisplay()
            weak.value = tracked
            displayRefs[display] = weak
            created.append(display)
            log.record("created display \(display)")
            return .displayCreated(head: head, display: display)

        case .releaseDisplay(let head, let display, let stopping):
            enqueue(head) { [weak self] in
                guard let self else { return }
                for attempt in stopping { self.stops.append(attempt) }
                await self.ledger.release(display) {
                    self.log.record("acknowledged display \(display)")
                    self.deliver(.displayReleased(display: display))
                }
            }
            return nil

        case .configureMode(let head, let display, _, _):
            modeStarts += 1
            switch ledger.start(display, operation: operation, report: { [weak self] outcome in
                self?.reportedModes.append((display, outcome))
                self?.deliver(.modeSetupFinished(head: head, display: display, outcome: outcome))
            }) {
            case .started:
                return nil
            case .alreadyRunning:
                refusedModeStarts += 1
                return nil
            case .unknownDisplay:
                return .modeSetupFinished(head: head, display: display, outcome: .failed("The virtual display is gone"))
            }

        case .startCapture(let attempt, _, _, _):
            pendingStarts.append(attempt)
            return nil

        case .stopCapture(let attempt):
            stops.append(attempt)
            return nil

        case .scheduleTimer, .cancelTimer, .publishCursorTargets, .savePreferences, .saveConfiguredModes:
            return nil
        }
    }

    private func enqueue(_ head: UInt8, _ work: @escaping @MainActor () async -> Void) {
        let previous = chains[head]
        chains[head] = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}

private func ledgerMonitor(_ head: UInt8) -> HeadMonitor {
    HeadMonitor(head: head, vendorID: 0x22f0, productCode: 0x3a4b, serial: 0x1234_5678, width: 3840, height: 2160,
                refreshHz: 60, widthMillimeters: 597, heightMillimeters: 336, name: "Dock \(head)", hardwareCursor: true)
}

@MainActor
private func ledgerDriver(_ effects: LedgerEffects) -> HeadDriver {
    let driver = HeadDriver(controller: HeadController(), effects: effects)
    effects.driver = driver
    return driver
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aRotationThatArrivesWhileADisplayIsStuckInASystemCallWaitsForTheCallAndLeavesNoStuckHead() async throws {
    let log = EventLog()
    let gate = SystemCallGate()
    let effects = LedgerEffects(log: log, operation: modeOperation(log: log, gate: gate))
    let driver = ledgerDriver(effects)

    driver.send(.monitorAttached(ledgerMonitor(0)))
    await gate.entered.reached()                                          // display 1's mode is inside its call
    driver.send(.setOrientation(head: 0, orientation: .turnedClockwise))  // portrait: display 1 is released
    driver.send(.setOrientation(head: 0, orientation: .upsideDown))       // the head has no state until the release
    await gate.cancelled.reached()                                        // the release cancelled the stuck call
    #expect(effects.created == [1], "no replacement while the old display is still inside its call")
    #expect(!log.all.contains("acknowledged display 1"))

    gate.open()
    await effects.until { effects.pendingStarts.count == 1 }
    #expect(effects.created == [1, 2])
    let oldDeinit = try #require(log.index(of: "deinit display 1 for Dock 0"))
    let acknowledgement = try #require(log.index(of: "acknowledged display 1"))
    let replacement = try #require(log.index(of: "created display 2"))
    #expect(oldDeinit < acknowledgement && acknowledgement < replacement,
            "the old display is dropped, then acknowledged, and only then is its replacement created")
    #expect(!effects.displayIsAlive(1))
    #expect(!log.all.contains("setMode display 1 for Dock 0"), "the cancelled display is never configured")
    #expect(effects.reportedModes.allSatisfy { $0.display != 1 }, "the released display's result is not reported")

    let attempt = try #require(effects.pendingStarts.first)
    driver.send(.captureStarted(attempt))
    driver.send(.captureUsableFrame(attempt))
    #expect(driver.controller.status(forHead: 0)?.hasUsableFrame == true, "the head is not stuck")
    // The second rotation was made while the head waited for its old display's release. The choice is stored and the
    // replacement is made with it, so it is not lost (the integrated controller keeps a rotation chosen during a release).
    #expect(driver.controller.status(forHead: 0)?.orientation == .upsideDown)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func aReattachWhileTheModeSetupIsOutstandingStartsNoSecondSetupOrCapture() async throws {
    let log = EventLog()
    let gate = SystemCallGate()
    let effects = LedgerEffects(log: log, operation: modeOperation(log: log, gate: gate))
    let driver = ledgerDriver(effects)

    driver.send(.monitorAttached(ledgerMonitor(0)))
    await gate.entered.reached()
    driver.send(.monitorDetached(head: 0))                                 // the display is kept for the reconnect grace
    driver.send(.monitorAttached(ledgerMonitor(0)))                        // the monitor is back on the kept display
    #expect(effects.modeStarts == 1, "the outstanding setup is not duplicated")
    #expect(effects.refusedModeStarts == 0)
    #expect(effects.created == [1], "the kept display is reused")

    gate.open()
    await effects.until { effects.pendingStarts.count == 1 }
    #expect(effects.reportedModes.count == 1)
    #expect(effects.reportedModes.first?.outcome == .applied)
    #expect(log.all.filter { $0.hasPrefix("setMode") }.count == 1)
}
