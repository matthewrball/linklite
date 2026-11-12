import Foundation
import Testing
@testable import LinkLiteCore

/// Holds scheduled deliveries until a test runs them, so every run is explicit.
@MainActor
private final class Scheduler {
    private(set) var queued: [@MainActor () -> Void] = []

    func schedule(_ work: @escaping @MainActor () -> Void) {
        queued.append(work)
    }

    /// Runs the deliveries queued so far, not any queued by those deliveries.
    func runQueued() {
        let batch = queued
        queued = []
        for work in batch { work() }
    }
}

/// An observer that counts deliveries and can ask for another from inside one, as a callback that
/// changes state would.
@MainActor
private final class Observer {
    private(set) var deliveries = 0
    var notifier: CoalescedNotifier?
    var requestsAgainWhenDelivered = false

    func deliver() {
        deliveries += 1
        if requestsAgainWhenDelivered {
            notifier?.request()
        }
    }
}

@MainActor
@Test func requestsMadeBeforeADeliveryAreDeliveredOnce() {
    let observer = Observer()
    let scheduler = Scheduler()
    let notifier = CoalescedNotifier(schedule: scheduler.schedule, deliver: observer.deliver)
    notifier.request()
    notifier.request()
    notifier.request()
    // Never delivered from inside the request.
    #expect(observer.deliveries == 0)
    scheduler.runQueued()
    #expect(observer.deliveries == 1)
    #expect(scheduler.queued.isEmpty)
}

@MainActor
@Test func aChangeAfterADeliveryIsDeliveredToo() {
    let observer = Observer()
    let scheduler = Scheduler()
    let notifier = CoalescedNotifier(schedule: scheduler.schedule, deliver: observer.deliver)
    notifier.request()
    scheduler.runQueued()
    notifier.request()
    scheduler.runQueued()
    #expect(observer.deliveries == 2)
}

@MainActor
@Test func aRequestMadeDuringDeliveryIsDeliveredInALaterRunNotInside() {
    let observer = Observer()
    let scheduler = Scheduler()
    let notifier = CoalescedNotifier(schedule: scheduler.schedule, deliver: observer.deliver)
    observer.notifier = notifier
    observer.requestsAgainWhenDelivered = true

    notifier.request()
    scheduler.runQueued()
    // The request made inside the first delivery is queued, not run: the first run is not re-entered.
    #expect(observer.deliveries == 1)
    #expect(scheduler.queued.count == 1)

    scheduler.runQueued()
    #expect(observer.deliveries == 2)
}

@MainActor
@Test func aDeliveryThatAlwaysRequestsAgainAdvancesOneRunAtATime() {
    // Each run delivers once and only queues the next run. No run delivers twice.
    let observer = Observer()
    let scheduler = Scheduler()
    let notifier = CoalescedNotifier(schedule: scheduler.schedule, deliver: observer.deliver)
    observer.notifier = notifier
    observer.requestsAgainWhenDelivered = true
    notifier.request()
    for run in 1...5 {
        scheduler.runQueued()
        #expect(observer.deliveries == run)
        #expect(scheduler.queued.count == 1)
    }
}
