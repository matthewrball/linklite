import Foundation
import Testing
@testable import LinkLiteCore

/// Stands in for a running capture stream. Counts how many are running at once, so a test can show
/// that two never overlap on one display.
private final class FakeStream: @unchecked Sendable {
    let name: String
    private let counter: StreamCounter

    init(_ name: String, counter: StreamCounter) {
        self.name = name
        self.counter = counter
        counter.started(name)
    }

    func stopped() {
        counter.stopped(name)
    }
}

/// Tracks running streams and the largest number running at any moment, and records the order of
/// events. Safe to write from any task.
private final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var peak = 0
    private var log: [String] = []

    func started(_ name: String) {
        lock.withLock {
            running += 1
            peak = max(peak, running)
            log.append("start \(name)")
        }
    }

    func stopped(_ name: String) {
        lock.withLock { running -= 1 }
    }

    func note(_ event: String) {
        lock.withLock { log.append(event) }
    }

    var events: [String] {
        lock.withLock { log }
    }
}

/// A gate a test opens explicitly. Waiting on a closed gate suspends without any timing assumption.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let pending = waiters
            waiters = []
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
}

private typealias Lifecycle = StreamLifecycle<UInt32, FakeStream>

/// A lifecycle whose stop is recorded by the counter, and optionally held at `stopGate`.
private func makeLifecycle(_ counter: StreamCounter, stopGate: Gate? = nil) -> Lifecycle {
    Lifecycle { stream in
        counter.note("stop begins \(stream.name)")
        await stopGate?.wait()
        stream.stopped()
        counter.note("stop ends \(stream.name)")
    }
}

@Test func aCancelledStreamIsStoppedOnce() async throws {
    let counter = StreamCounter()
    let lifecycle = makeLifecycle(counter)
    let (attempt, outcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    guard case .started(let stream) = try await outcome.value else {
        Issue.record("expected the stream to start")
        return
    }
    #expect(stream.name == "a")
    await lifecycle.cancel(attempt, on: 0).value
    await lifecycle.cancel(attempt, on: 0).value
    #expect(counter.events == ["start a", "stop begins a", "stop ends a"])
    #expect(counter.peak == 1)
}

@Test func aStartQueuedBehindAnUnfinishedOperationWaitsForIt() async throws {
    // Item 1. A quick reconnect starts a new stream while the old stream's stop is still running.
    // The new start must not begin until that stop has finished.
    let counter = StreamCounter()
    let stopGate = Gate()
    let lifecycle = makeLifecycle(counter, stopGate: stopGate)

    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("old", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)   // the stop now waits on the gate

    let (_, newOutcome) = lifecycle.start(0) {
        counter.note("new start requested")
        return FakeStream("new", counter: counter)
    }
    stopGate.open()
    guard case .started = try await newOutcome.value else {
        Issue.record("expected the new stream to start")
        return
    }
    #expect(counter.events == [
        "start old",
        "stop begins old",
        "stop ends old",
        "new start requested",
        "start new",
    ])
    #expect(counter.peak == 1)
}

@Test func anInFlightStartThatIsCancelledIsStoppedBeforeTheNextStartBegins() async throws {
    // Item 1, the in-flight case: the first start is still running when it is cancelled and a new
    // attempt is made. The first stream, once it starts, must be stopped; the second must wait.
    let counter = StreamCounter()
    let startGate = Gate()
    let entered = Gate()
    let lifecycle = makeLifecycle(counter)

    let (old, oldOutcome) = lifecycle.start(0) {
        counter.note("old start begins")
        entered.open()
        await startGate.wait()
        return FakeStream("old", counter: counter)
    }
    // Cancel only once the old start is really in flight, so this is not the queued-cancel case.
    await entered.wait()
    lifecycle.cancel(old, on: 0)
    let (_, newOutcome) = lifecycle.start(0) { FakeStream("new", counter: counter) }

    startGate.open()
    guard case .cancelled = try await oldOutcome.value else {
        Issue.record("a cancelled start must not be kept")
        return
    }
    guard case .started = try await newOutcome.value else {
        Issue.record("expected the new stream to start")
        return
    }
    #expect(counter.events == [
        "old start begins",
        "start old",
        "stop begins old",
        "stop ends old",
        "start new",
    ])
    #expect(counter.peak == 1)
}

@Test func anAttemptCancelledBeforeItsTurnNeverStarts() async throws {
    let counter = StreamCounter()
    let lifecycle = makeLifecycle(counter)
    let blocker = Gate()
    // Something earlier is still running on the display.
    let earlier = lifecycle.start(0) {
        await blocker.wait()
        counter.note("earlier")
        return FakeStream("earlier", counter: counter)
    }
    let (attempt, outcome) = lifecycle.start(0) {
        counter.note("cancelled attempt's make ran")
        return FakeStream("cancelled", counter: counter)
    }
    lifecycle.cancel(attempt, on: 0)
    blocker.open()
    _ = try await earlier.outcome.value
    guard case .cancelled = try await outcome.value else {
        Issue.record("a cancelled attempt must not start")
        return
    }
    #expect(!counter.events.contains("cancelled attempt's make ran"))
    #expect(!counter.events.contains("start cancelled"))
}

@Test func otherDisplaysAreNotHeldUpByAnOperationOnOneDisplay() async throws {
    let counter = StreamCounter()
    let lifecycle = makeLifecycle(counter)
    let held = Gate()
    _ = lifecycle.start(1) {
        await held.wait()
        return FakeStream("blocked", counter: counter)
    }
    // Display 2 starts while display 1's start is still waiting. No gate is opened before this.
    let (_, other) = lifecycle.start(2) { FakeStream("free", counter: counter) }
    guard case .started = try await other.value else {
        Issue.record("display 2 should start independently")
        return
    }
    held.open()
}

@Test func aFailedStartReportsItsErrorAndLeavesNothingRunning() async throws {
    struct StartFailed: Error {}
    let counter = StreamCounter()
    let lifecycle = makeLifecycle(counter)
    let (attempt, outcome) = lifecycle.start(0) { throw StartFailed() }
    await #expect(throws: StartFailed.self) { _ = try await outcome.value }
    lifecycle.cancel(attempt, on: 0)
    let (_, next) = lifecycle.start(0) { FakeStream("next", counter: counter) }
    _ = try await next.value
    #expect(counter.events == ["start next"])
    #expect(counter.peak == 1)
}

@Test func manyReconnectsOnOneDisplayNeverOverlap() async throws {
    let counter = StreamCounter()
    let lifecycle = makeLifecycle(counter)
    var previous: Lifecycle.Attempt?
    for round in 0..<50 {
        // As the app does: the previous attempt is cancelled before the next one is queued.
        if let previous {
            lifecycle.cancel(previous, on: 7)
        }
        let (attempt, outcome) = lifecycle.start(7) { FakeStream("\(round)", counter: counter) }
        previous = attempt
        _ = try await outcome.value
    }
    if let previous {
        await lifecycle.cancel(previous, on: 7).value
    }
    #expect(counter.peak == 1)
}

// MARK: - Keyed by the physical head (item 2)

/// DisplayHost keys its lifecycle by head, so the key is the socket, and a display's stream is named by
/// its display ID. These tests replace the display ID on one head, as macOS does after a mode change or
/// a removal, and hold the old stream's stop with explicit gates. No test relies on timing.
private typealias HeadLifecycle = StreamLifecycle<UInt8, FakeStream>

private func makeHeadLifecycle(_ counter: StreamCounter, stopEntered: Gate, stopGate: Gate) -> HeadLifecycle {
    HeadLifecycle { stream in
        counter.note("stop begins \(stream.name)")
        stopEntered.open()
        await stopGate.wait()
        stream.stopped()
        counter.note("stop ends \(stream.name)")
    }
}

@Test func aReplacedDisplayIDOnTheSameHeadWaitsForTheOldStreamToStop() async throws {
    let counter = StreamCounter()
    let stopEntered = Gate()
    let stopGate = Gate()
    let lifecycle = makeHeadLifecycle(counter, stopEntered: stopEntered, stopGate: stopGate)

    // Head 0 is running display 10. Its display is detached, so its stop is queued and held.
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("display 10", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    await stopEntered.wait()

    // Head 0 gets display 11. Nothing for display 11 may start while display 10's stop is held.
    let (_, replacement) = lifecycle.start(0) {
        counter.note("display 11 start requested")
        return FakeStream("display 11", counter: counter)
    }
    // Whatever is not ordered behind the held stop gets to run now. A correct lifecycle runs nothing.
    for _ in 0..<1_000 { await Task.yield() }
    #expect(!counter.events.contains("display 11 start requested"))

    stopGate.open()
    guard case .started = try await replacement.value else {
        Issue.record("the replacement stream should start once the old one has stopped")
        return
    }
    #expect(counter.events == [
        "start display 10",
        "stop begins display 10",
        "stop ends display 10",
        "display 11 start requested",
        "start display 11",
    ])
    #expect(counter.peak == 1)
}

@Test func settledFinishesOnlyAfterEverythingQueuedOnTheHeadHasStopped() async throws {
    let counter = StreamCounter()
    let stopEntered = Gate()
    let stopGate = Gate()
    let lifecycle = makeHeadLifecycle(counter, stopEntered: stopEntered, stopGate: stopGate)

    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("display 10", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    await stopEntered.wait()

    let waiter = Task {
        await lifecycle.settled(0).value
        counter.note("settled")
    }
    for _ in 0..<1_000 { await Task.yield() }
    #expect(!counter.events.contains("settled"))

    stopGate.open()
    await waiter.value
    #expect(counter.events == [
        "start display 10",
        "stop begins display 10",
        "stop ends display 10",
        "settled",
    ])
}

@Test func settledOnAnIdleHeadReturnsAtOnce() async {
    let counter = StreamCounter()
    let lifecycle = makeLifecycle(counter)
    await lifecycle.settled(5).value
    #expect(counter.events.isEmpty)
}

@Test func aHeldStopOnOneHeadDoesNotHoldTheStartOnAnother() async throws {
    let counter = StreamCounter()
    let stopEntered = Gate()
    let stopGate = Gate()
    let lifecycle = makeHeadLifecycle(counter, stopEntered: stopEntered, stopGate: stopGate)

    let (first, firstOutcome) = lifecycle.start(0) { FakeStream("head 0", counter: counter) }
    _ = try await firstOutcome.value
    lifecycle.cancel(first, on: 0)
    await stopEntered.wait()

    // Head 1 starts while head 0's stop is still held. It must not wait for head 0.
    let (_, other) = lifecycle.start(1) { FakeStream("head 1", counter: counter) }
    guard case .started = try await other.value else {
        Issue.record("head 1 should start while head 0 is stopping")
        stopGate.open()
        return
    }
    stopGate.open()
    #expect(counter.events.contains("start head 1"))
}

// MARK: - A stop that cannot be confirmed fails closed

/// Fails the stops of the named streams while `failures` is positive. Each failed stop uses one.
private final class FlakyStops: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private let names: Set<String>

    init(failures: Int, names: Set<String> = ["a"]) {
        self.failures = failures
        self.names = names
    }

    func shouldFail(_ name: String) -> Bool {
        lock.withLock {
            guard names.contains(name), failures > 0 else { return false }
            failures -= 1
            return true
        }
    }
}

private struct StopRefused: Error, CustomStringConvertible {
    var description: String { "the stream did not answer the stop" }
}

/// Background retries wait on this gate. No test opens it, so unless a test passes its own retry pause,
/// only a start's own retry runs and the order of events stays exact.
private let parkedRetries = Gate()

/// A lifecycle whose stop can throw, as a ScreenCaptureKit stop can.
private func makeFlakyLifecycle(
    _ counter: StreamCounter,
    _ flaky: FlakyStops,
    retryDelay: @escaping @Sendable (Int) async -> Void = { _ in await parkedRetries.wait() },
    unconfirmedChanged: @escaping @Sendable (UInt32) -> Void = { _ in }
) -> Lifecycle {
    Lifecycle(stopStream: { stream in
        counter.note("stop begins \(stream.name)")
        if flaky.shouldFail(stream.name) {
            counter.note("stop failed \(stream.name)")
            throw StopRefused()
        }
        stream.stopped()
        counter.note("stop ends \(stream.name)")
    }, retryDelay: retryDelay, unconfirmedChanged: unconfirmedChanged)
}

@Test func aStopThatFailsIsRetriedAndNoReplacementStartsUntilItSucceeds() async throws {
    let counter = StreamCounter()
    let lifecycle = makeFlakyLifecycle(counter, FlakyStops(failures: 1))
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    await lifecycle.cancel(old, on: 0).value
    #expect(lifecycle.unconfirmedCount(0) == 1)

    let (_, next) = lifecycle.start(0) {
        counter.note("make b")
        return FakeStream("b", counter: counter)
    }
    guard case .started = try await next.value else {
        Issue.record("the replacement should start once the old stream is confirmed stopped")
        return
    }
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(counter.events == [
        "start a", "stop begins a", "stop failed a", "stop begins a", "stop ends a", "make b", "start b",
    ])
    #expect(counter.peak == 1)
}

@Test func aStopThatStillFailsBlocksEveryStartOnItsKeyAndNeverRunsItsMake() async throws {
    let counter = StreamCounter()
    let lifecycle = makeFlakyLifecycle(counter, FlakyStops(failures: 2))
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    await lifecycle.cancel(old, on: 0).value

    // The retry before this start fails too, so the start is refused and its make never runs.
    let (_, blocked) = lifecycle.start(0) {
        counter.note("make b")
        return FakeStream("b", counter: counter)
    }
    await #expect(throws: StreamStopNotConfirmed.self) { _ = try await blocked.value }
    #expect(lifecycle.unconfirmedCount(0) == 1)

    // A later start retries the stop, which now succeeds, and only then starts.
    let (_, later) = lifecycle.start(0) {
        counter.note("make c")
        return FakeStream("c", counter: counter)
    }
    guard case .started = try await later.value else {
        Issue.record("the start should proceed once the old stream is confirmed stopped")
        return
    }
    #expect(counter.events == [
        "start a", "stop begins a", "stop failed a", "stop begins a", "stop failed a",
        "stop begins a", "stop ends a", "make c", "start c",
    ])
    #expect(!counter.events.contains("make b"))
    #expect(counter.peak == 1)
}

@Test func aStopThatFailsOnOneKeyDoesNotBlockAnotherKey() async throws {
    let counter = StreamCounter()
    let lifecycle = makeFlakyLifecycle(counter, FlakyStops(failures: 1))
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    await lifecycle.cancel(old, on: 0).value

    let (_, other) = lifecycle.start(1) { FakeStream("b", counter: counter) }
    guard case .started = try await other.value else {
        Issue.record("key 1 has no unconfirmed stop and should start")
        return
    }
    #expect(lifecycle.unconfirmedCount(0) == 1)
    #expect(lifecycle.unconfirmedCount(1) == 0)
}

@Test func anInFlightStartCancelledWhoseStopFailsStillBlocksTheNextStartUntilConfirmed() async throws {
    let counter = StreamCounter()
    let startGate = Gate()
    let entered = Gate()
    let lifecycle = makeFlakyLifecycle(counter, FlakyStops(failures: 1))

    let (old, oldOutcome) = lifecycle.start(0) {
        entered.open()
        await startGate.wait()
        return FakeStream("a", counter: counter)
    }
    await entered.wait()
    lifecycle.cancel(old, on: 0)
    let (_, next) = lifecycle.start(0) {
        counter.note("make b")
        return FakeStream("b", counter: counter)
    }
    startGate.open()

    guard case .cancelled = try await oldOutcome.value else {
        Issue.record("a cancelled start must not be kept")
        return
    }
    guard case .started = try await next.value else {
        Issue.record("the next start should proceed once the in-flight stream is confirmed stopped")
        return
    }
    #expect(counter.events == [
        "start a", "stop begins a", "stop failed a", "stop begins a", "stop ends a", "make b", "start b",
    ])
    #expect(counter.peak == 1)
}

// MARK: - A stop that fails is retried until it is confirmed (item 1)

/// Stands in for a VirtualDisplay. Its deallocation goes into the same log as the stream events, so a
/// test can tell whether it came before or after the stop was confirmed.
private final class FakeDisplay {
    private let counter: StreamCounter

    init(_ counter: StreamCounter) {
        self.counter = counter
    }

    deinit {
        counter.note("display deinit")
    }
}

/// Keeps `holder` alive until every stream on `key` is confirmed stopped, then releases it. DisplayHost does
/// the same with a main-actor task. The release is explicit here, so a test can see it before the task ends.
private final class Hold: @unchecked Sendable {
    private var holder: AnyObject?

    init(_ holder: AnyObject) {
        self.holder = holder
    }

    func release() {
        holder = nil
    }
}

private func holdUntilStopped(_ holder: AnyObject, _ lifecycle: Lifecycle, _ key: UInt32) -> Task<Void, Never> {
    let hold = Hold(holder)
    let stopped = lifecycle.confirmedStopped(key)
    return Task {
        await stopped.value
        hold.release()
    }
}

/// Lets a retry pause report whether a display is alive, without keeping it alive.
private final class DisplayProbe: @unchecked Sendable {
    weak var display: FakeDisplay?
}

/// Lets a retry pause report the retry task count, without keeping the lifecycle alive.
private final class LifecycleProbe: @unchecked Sendable {
    weak var lifecycle: Lifecycle?
}

/// Numbers the stop attempts, so a test can hold one particular attempt.
private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

@Test func aStopThatFailsWithNoReplacementIsRetriedUntilItIsConfirmed() async throws {
    // Nothing replaces the stream, so the lifecycle's own retry must confirm the stop.
    let counter = StreamCounter()
    let notices = StreamCounter()
    let lifecycle = makeFlakyLifecycle(counter, FlakyStops(failures: 3), retryDelay: { counter.note("pause \($0)") },
                                       unconfirmedChanged: { _ in notices.note("changed") })

    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    await lifecycle.cancel(old, on: 0).value
    await lifecycle.confirmedStopped(0).value

    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(lifecycle.retrierCount == 0)
    #expect(counter.events == [
        "start a",
        "stop begins a", "stop failed a",
        "pause 1", "stop begins a", "stop failed a",
        "pause 2", "stop begins a", "stop failed a",
        "pause 3", "stop begins a", "stop ends a",
    ])
    // Once when the stop failed and was recorded, once when it was confirmed.
    #expect(notices.events == ["changed", "changed"])
    #expect(counter.peak == 1)
}

@Test func aLongLivedStopFailureKeepsOneRetryTaskAndHoldsItsDisplayUntilItSucceeds() async throws {
    // Forty failures in a row. Throughout, there is one retry task, and the display stays alive.
    let counter = StreamCounter()
    let probe = DisplayProbe()
    let owner = LifecycleProbe()
    let lifecycle = makeFlakyLifecycle(counter, FlakyStops(failures: 40), retryDelay: { failures in
        let display = probe.display == nil ? "gone" : "alive"
        let retriers = owner.lifecycle?.retrierCount ?? -1
        counter.note("pause \(failures) display \(display) retriers \(retriers)")
    })
    owner.lifecycle = lifecycle

    var display: FakeDisplay? = FakeDisplay(counter)
    probe.display = display
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    let retained = holdUntilStopped(try require(display), lifecycle, 0)
    drop(&display)
    await retained.value

    let events = counter.events
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(lifecycle.retrierCount == 0)
    #expect(events.filter { $0 == "stop failed a" }.count == 40)
    let pauses = events.filter { $0.hasPrefix("pause") }
    #expect(pauses.count == 40)
    #expect(pauses.allSatisfy { $0.hasSuffix("display alive retriers 1") })
    // The display goes only after the stop is confirmed, and with no later event.
    #expect(events.suffix(2) == ["stop ends a", "display deinit"])
    #expect(counter.peak == 1)
}

@Test func theRetryBackoffStartsAtOneSecondDoublesAndStopsAtThirtySeconds() {
    #expect(StreamRetry.interval(afterFailures: 1) == .seconds(1))
    #expect(StreamRetry.interval(afterFailures: 2) == .seconds(2))
    #expect(StreamRetry.interval(afterFailures: 5) == .seconds(16))
    #expect(StreamRetry.interval(afterFailures: 6) == .seconds(30))
    #expect(StreamRetry.interval(afterFailures: 0) == .seconds(1))
    #expect((1...10_000).allSatisfy { StreamRetry.interval(afterFailures: $0) <= .seconds(30) })
}

@Test func repeatedDetachesWhileAStopFailsHoldEveryDisplayWithOneRetryTask() async throws {
    // Each round detaches a display and tries a replacement. The replacement is refused every time,
    // and the stop is retried by one task only.
    let counter = StreamCounter()
    let retries = Gate()
    let lifecycle = makeFlakyLifecycle(counter, FlakyStops(failures: 25), retryDelay: { _ in await retries.wait() })
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    await lifecycle.cancel(old, on: 0).value

    var holds: [Task<Void, Never>] = []
    for round in 0..<20 {
        holds.append(holdUntilStopped(FakeDisplay(counter), lifecycle, 0))
        let (_, next) = lifecycle.start(0) { FakeStream("next \(round)", counter: counter) }
        await #expect(throws: StreamStopNotConfirmed.self) { _ = try await next.value }
        #expect(lifecycle.retrierCount == 1)
    }

    retries.open()
    for hold in holds {
        await hold.value
    }
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(lifecycle.retrierCount == 0)
    let events = counter.events
    #expect(events.filter { $0 == "display deinit" }.count == 20)
    #expect(!events.contains { $0.hasPrefix("start next") })
    // Every display went only after the stop was confirmed.
    let confirmed = events.firstIndex(of: "stop ends a")
    #expect(confirmed != nil)
    if let confirmed {
        #expect(events.firstIndex(of: "display deinit") ?? -1 > confirmed)
    }
}

@Test func cancellingTheWaitingTaskDoesNotReleaseTheDisplayBeforeItsStopIsConfirmed() async throws {
    let counter = StreamCounter()
    let retries = Gate()
    let lifecycle = makeFlakyLifecycle(counter, FlakyStops(failures: 1), retryDelay: { _ in await retries.wait() })
    let probe = DisplayProbe()
    var display: FakeDisplay? = FakeDisplay(counter)
    probe.display = display
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    let waiting = holdUntilStopped(try require(display), lifecycle, 0)
    drop(&display)

    waiting.cancel()
    for _ in 0..<1_000 { await Task.yield() }
    #expect(probe.display != nil)

    retries.open()
    await waiting.value
    #expect(probe.display == nil)
    #expect(counter.events.suffix(2) == ["stop ends a", "display deinit"])
}

@Test func aLifecycleWithAPendingStopStaysAliveUntilItIsConfirmedThenIsReleased() async throws {
    // Dropping the last reference to the lifecycle must not abandon a stop that is still unconfirmed.
    let counter = StreamCounter()
    let retries = Gate()
    let owner = LifecycleProbe()
    var lifecycle: Lifecycle? = makeFlakyLifecycle(counter, FlakyStops(failures: 1),
                                                   retryDelay: { _ in await retries.wait() })
    owner.lifecycle = lifecycle
    let (old, oldOutcome) = lifecycle!.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle!.cancel(old, on: 0)
    let retained = holdUntilStopped(FakeDisplay(counter), lifecycle!, 0)
    lifecycle = nil

    #expect(owner.lifecycle != nil)
    retries.open()
    await retained.value
    for _ in 0..<1_000 where owner.lifecycle != nil { await Task.yield() }
    #expect(owner.lifecycle == nil)
}

@Test func aLifecycleWithNoFailureIsReleasedOnceItsDisplayIsReleased() async throws {
    // The normal path keeps no task or reference behind once the stop is confirmed.
    let counter = StreamCounter()
    let owner = LifecycleProbe()
    var lifecycle: Lifecycle? = makeFlakyLifecycle(counter, FlakyStops(failures: 0))
    owner.lifecycle = lifecycle
    let (old, oldOutcome) = lifecycle!.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    await lifecycle!.cancel(old, on: 0).value
    await holdUntilStopped(FakeDisplay(counter), lifecycle!, 0).value
    lifecycle = nil

    for _ in 0..<1_000 where owner.lifecycle != nil { await Task.yield() }
    #expect(owner.lifecycle == nil)
    #expect(counter.events.suffix(2) == ["stop ends a", "display deinit"])
}

// MARK: - A cancelled start never runs make (item 2)

@Test func aCancelledStartBlockedOnARetriedStopNeverRunsItsMake() async throws {
    // The start for `b` is inside its own retry of the stop for `a` when it is cancelled. Once that
    // retry succeeds, the start must end as cancelled, and `make` must not run.
    let counter = StreamCounter()
    let attempts = Attempts()
    let stopEntered = Gate()
    let stopGate = Gate()
    let retries = Gate()
    let lifecycle = Lifecycle(stopStream: { stream in
        counter.note("stop begins \(stream.name)")
        let attempt = attempts.next()
        if attempt == 1 {
            counter.note("stop failed \(stream.name)")
            throw StopRefused()
        }
        if attempt == 2 {
            // The start's own retry, held until the test has cancelled the start.
            stopEntered.open()
            await stopGate.wait()
        }
        stream.stopped()
        counter.note("stop ends \(stream.name)")
    }, retryDelay: { _ in await retries.wait() })

    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    let (blocked, blockedOutcome) = lifecycle.start(0) {
        counter.note("make b")
        return FakeStream("b", counter: counter)
    }
    await stopEntered.wait()
    lifecycle.cancel(blocked, on: 0)
    stopGate.open()

    let result = try await blockedOutcome.value
    retries.open()
    guard case .cancelled = result else {
        Issue.record("a start cancelled while it waits on a stop must end as cancelled")
        return
    }
    await lifecycle.confirmedStopped(0).value
    #expect(counter.events == ["start a", "stop begins a", "stop failed a", "stop begins a", "stop ends a"])
    #expect(!counter.events.contains("make b"))
    #expect(counter.peak == 1)
}

// MARK: - A foreground confirmation releases a waiting stop at once (review follow-up)

/// Fails the first stop of each named stream. A later stop of that stream succeeds.
private final class FailFirstStops: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<String>

    init(_ names: Set<String>) {
        pending = names
    }

    func shouldFail(_ name: String) -> Bool {
        lock.withLock { pending.remove(name) != nil }
    }
}

/// A lifecycle whose stop fails the first time for each named stream, with the given retry pause.
private func makeFailFirstLifecycle(
    _ counter: StreamCounter,
    _ firstStops: FailFirstStops,
    retryDelay: @escaping @Sendable (Int) async -> Void
) -> Lifecycle {
    Lifecycle(stopStream: { stream in
        counter.note("stop begins \(stream.name)")
        if firstStops.shouldFail(stream.name) {
            counter.note("stop failed \(stream.name)")
            throw StopRefused()
        }
        stream.stopped()
        counter.note("stop ends \(stream.name)")
    }, retryDelay: retryDelay)
}

@Test func aForegroundConfirmationReleasesAWaitingStopWhileItsRetryStillSleeps() async throws {
    // "a" fails to stop, and its retry sleeps on a gate that stays closed. A start on the key retries
    // "a", and that succeeds. The waiting stop must finish then, with the gate still closed and no timer.
    let counter = StreamCounter()
    let entered = Gate()
    let retries = Gate()
    let lifecycle = makeFailFirstLifecycle(counter, FailFirstStops(["a"])) { _ in
        entered.open()
        await retries.wait()
    }
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    await entered.wait()

    let stopped = lifecycle.confirmedStopped(0)
    let waiting = Task {
        await stopped.value
        counter.note("confirmed stopped")
    }
    let (_, next) = lifecycle.start(0) { FakeStream("b", counter: counter) }
    guard case .started = try await next.value else {
        Issue.record("the start should proceed once the foreground retry confirms 'a'")
        retries.open()
        await waiting.value
        return
    }
    // Bounded by yields, not time: a waiter that is still blocked after this many yields is blocked.
    for _ in 0..<1_000 { await Task.yield() }
    #expect(counter.events.contains("confirmed stopped"))
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(lifecycle.retrierCount == 0)

    // Clean up: the sleeping retry wakes and must do nothing (see the next test).
    retries.open()
    await waiting.value
}

@Test func aRetryThatWakesAfterItsStreamIsConfirmedStopsNothingAndANewFailureGetsOneRetry() async throws {
    // "a" fails to stop and its retry sleeps. A start confirms "a". Then "b" starts and fails to stop
    // while the old retry still sleeps. Opening the gate wakes both: the old retry must stop nothing,
    // and "b" gets exactly one retry, which succeeds.
    let counter = StreamCounter()
    let entered = Gate()
    let retries = Gate()
    let lifecycle = makeFailFirstLifecycle(counter, FailFirstStops(["a", "b"])) { _ in
        entered.open()
        await retries.wait()
    }
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    await entered.wait()

    let (current, currentOutcome) = lifecycle.start(0) { FakeStream("b", counter: counter) }
    guard case .started = try await currentOutcome.value else {
        Issue.record("the start should proceed once 'a' is confirmed stopped")
        retries.open()
        return
    }
    lifecycle.cancel(current, on: 0)
    let stopped = lifecycle.confirmedStopped(0)
    for _ in 0..<1_000 { await Task.yield() }
    #expect(lifecycle.unconfirmedCount(0) == 1)
    #expect(lifecycle.retrierCount == 1)

    retries.open()
    await stopped.value
    for _ in 0..<1_000 { await Task.yield() }
    #expect(counter.events == [
        "start a", "stop begins a", "stop failed a", "stop begins a", "stop ends a",
        "start b", "stop begins b", "stop failed b", "stop begins b", "stop ends b",
    ])
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(lifecycle.retrierCount == 0)
    #expect(counter.peak == 1)
}

// MARK: - A waiter covers only the stops queued before it (review follow-up)

@Test func aWaiterCalledBeforeAGatedStartCompletesOnceTheStopItCoversIsConfirmed() async throws {
    // The waiter is called after the stop of "a" is queued. A start for "b" is queued after the waiter, and
    // its make is held at a gate that stays closed until the test has checked. The stop of "a" is confirmed,
    // so the waiter must complete while the start is still blocked. Waiting for the queued-later start
    // would hold the waiter, and so the display it keeps, for as long as the gate stays closed.
    let counter = StreamCounter()
    let makeGate = Gate()
    let lifecycle = makeLifecycle(counter)
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)                  // the stop of "a" is queued and completes
    let stopped = lifecycle.confirmedStopped(0)   // called before the later start is queued
    let waiter = Task {
        await stopped.value
        counter.note("confirmed stopped")
    }
    let (_, blocked) = lifecycle.start(0) {
        counter.note("gated make begins")
        await makeGate.wait()
        return FakeStream("b", counter: counter)
    }
    // Bounded by yields, not time: a waiter that is still blocked after this many yields is blocked.
    for _ in 0..<1_000 { await Task.yield() }
    #expect(counter.events.contains("stop ends a"))
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(counter.events.contains("confirmed stopped"))
    #expect(!counter.events.contains("start b"))

    makeGate.open()
    guard case .started = try await blocked.value else {
        Issue.record("the later start should start once its gate opens")
        await waiter.value
        return
    }
    await waiter.value
    #expect(counter.peak == 1)
}

@Test func aWaiterCalledWhileAStopIsRetriedWaitsForThatRetryToConfirmIt() async throws {
    // The stop of "a" fails and its retry is held. The waiter covers that stop, so it waits for the retry.
    let counter = StreamCounter()
    let entered = Gate()
    let retries = Gate()
    let lifecycle = makeFailFirstLifecycle(counter, FailFirstStops(["a"])) { _ in
        entered.open()
        await retries.wait()
    }
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    await entered.wait()

    let stopped = lifecycle.confirmedStopped(0)
    let waiter = Task {
        await stopped.value
        counter.note("confirmed stopped")
    }
    for _ in 0..<1_000 { await Task.yield() }
    #expect(lifecycle.unconfirmedCount(0) == 1)
    #expect(!counter.events.contains("confirmed stopped"))

    retries.open()
    await waiter.value
    #expect(counter.events == [
        "start a", "stop begins a", "stop failed a", "stop begins a", "stop ends a", "confirmed stopped",
    ])
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(lifecycle.retrierCount == 0)
}

@Test func aStopQueuedAfterTheWaiterIsNotWaitedFor() async throws {
    // The waiter covers the stop of "a", which succeeds. Then "b" starts and is cancelled, and its stop fails
    // with the retry held. The waiter completes anyway, because "b" was queued after it. "b" still gets its
    // own retry, and is confirmed only when that retry succeeds.
    let counter = StreamCounter()
    let retries = Gate()
    let lifecycle = makeFailFirstLifecycle(counter, FailFirstStops(["b"])) { _ in await retries.wait() }
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    let stopped = lifecycle.confirmedStopped(0)
    let waiter = Task {
        await stopped.value
        counter.note("confirmed stopped")
    }
    let (current, currentOutcome) = lifecycle.start(0) { FakeStream("b", counter: counter) }
    guard case .started = try await currentOutcome.value else {
        Issue.record("b should start")
        retries.open()
        await waiter.value
        return
    }
    lifecycle.cancel(current, on: 0)
    for _ in 0..<1_000 { await Task.yield() }
    #expect(counter.events.contains("confirmed stopped"))
    #expect(lifecycle.unconfirmedCount(0) == 1)
    #expect(lifecycle.retrierCount == 1)

    retries.open()
    await lifecycle.confirmedStopped(0).value
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(lifecycle.retrierCount == 0)
    #expect(counter.peak == 1)
    await waiter.value
}

@Test func aWaiterReleasesOnceItsStopIsConfirmedEvenWhileALaterStopFailsAndIsRetried() async throws {
    // The waiter covers the stop of "a". A start confirms "a" with its own retry, then starts "b", whose
    // stop fails. The waiter completes at once after "a", with "b" still unconfirmed and its retry running.
    let counter = StreamCounter()
    let entered = Gate()
    let retries = Gate()
    let lifecycle = makeFailFirstLifecycle(counter, FailFirstStops(["a", "b"])) { _ in
        entered.open()
        await retries.wait()
    }
    let (old, oldOutcome) = lifecycle.start(0) { FakeStream("a", counter: counter) }
    _ = try await oldOutcome.value
    lifecycle.cancel(old, on: 0)
    await entered.wait()

    let stopped = lifecycle.confirmedStopped(0)
    let waiter = Task {
        await stopped.value
        counter.note("confirmed stopped")
    }
    let (current, currentOutcome) = lifecycle.start(0) { FakeStream("b", counter: counter) }
    guard case .started = try await currentOutcome.value else {
        Issue.record("the start should proceed once 'a' is confirmed stopped")
        retries.open()
        await waiter.value
        return
    }
    await lifecycle.cancel(current, on: 0).value
    for _ in 0..<1_000 { await Task.yield() }
    #expect(counter.events.contains("confirmed stopped"))
    #expect(lifecycle.unconfirmedCount(0) == 1)
    #expect(lifecycle.retrierCount == 1)

    retries.open()
    await lifecycle.confirmedStopped(0).value
    await waiter.value
    #expect(counter.events.filter { $0 != "confirmed stopped" } == [
        "start a", "stop begins a", "stop failed a", "stop begins a", "stop ends a",
        "start b", "stop begins b", "stop failed b", "stop begins b", "stop ends b",
    ])
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(lifecycle.retrierCount == 0)
    #expect(counter.peak == 1)
}

@Test func aWaiterCoveringACancelledInFlightStartIsNotReleasedByCancellingTheWaiter() async throws {
    // "x" is in flight when it is cancelled, so its stop runs when it starts and fails. The waiter covers
    // that stop. Cancelling the waiter does not release it, and only the confirmed stop does.
    let counter = StreamCounter()
    let started = Gate()
    let startGate = Gate()
    let retries = Gate()
    let lifecycle = makeFailFirstLifecycle(counter, FailFirstStops(["x"])) { _ in await retries.wait() }
    let (old, oldOutcome) = lifecycle.start(0) {
        started.open()
        await startGate.wait()
        return FakeStream("x", counter: counter)
    }
    await started.wait()
    lifecycle.cancel(old, on: 0)
    let stopped = lifecycle.confirmedStopped(0)
    let waiter = Task {
        await stopped.value
        counter.note("confirmed stopped")
    }
    startGate.open()
    guard case .cancelled = try await oldOutcome.value else {
        Issue.record("a cancelled start must not be kept")
        retries.open()
        await waiter.value
        return
    }
    for _ in 0..<1_000 { await Task.yield() }
    #expect(lifecycle.unconfirmedCount(0) == 1)
    #expect(!counter.events.contains("confirmed stopped"))

    waiter.cancel()
    for _ in 0..<1_000 { await Task.yield() }
    #expect(!counter.events.contains("confirmed stopped"))

    retries.open()
    await waiter.value
    #expect(counter.events == [
        "start x", "stop begins x", "stop failed x", "stop begins x", "stop ends x", "confirmed stopped",
    ])
    #expect(lifecycle.unconfirmedCount(0) == 0)
    #expect(counter.peak == 1)
}

@Test func confirmedStoppedOnAnIdleKeyReturnsAtOnce() async {
    let counter = StreamCounter()
    let lifecycle = makeLifecycle(counter)
    await lifecycle.confirmedStopped(5).value
    #expect(counter.events.isEmpty)
}
