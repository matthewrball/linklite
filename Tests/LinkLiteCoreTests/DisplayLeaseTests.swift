import Foundation
import LinkLiteCore
import Testing

private let identity = DisplayIdentity(vendorID: 0x1e6d, productCode: 0x7c5b, serial: 0x0a0b_0c0d)

/// Stands in for CGVirtualDisplay: an Objective-C object whose deinit records that it has died and
/// asks the allocator, at that moment, whether its identity is still claimed.
private final class MockDisplay: NSObject {
    private let log: EventLog
    private let allocator: DisplayIdentityAllocator

    init(log: EventLog, allocator: DisplayIdentityAllocator) {
        self.log = log
        self.allocator = allocator
    }

    deinit {
        log.record("display deinit")
        // A claim that succeeds here means a replacement display could be created while this one
        // still exists. The claim is dropped at once, so a success does not leave the identity held.
        let reclaimed = allocator.claim(reported: identity, head: 9, attached: [])
        log.record(reclaimed == nil ? "identity held" : "identity REUSED")
    }
}

/// Records the identity's release on the same thread, at the moment the lease is deallocated.
private func recordReleases(of allocator: DisplayIdentityAllocator, in log: EventLog) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: DisplayIdentityAllocator.identityReleasedNotification, object: allocator, queue: nil
    ) { _ in log.record("identity released") }
}

/// Makes a display the way VirtualDisplay does: claim, create, attach the lease to the display. The
/// claim is not kept, so the display is the only owner of the lease.
private func makeDisplay(_ allocator: DisplayIdentityAllocator, _ log: EventLog) throws -> MockDisplay {
    let claim = try require(allocator.claim(reported: identity, head: 0, attached: []))
    let display = MockDisplay(log: log, allocator: allocator)
    DisplayLease.attach(claim.lease, to: display)
    return display
}

private func isClaimable(_ allocator: DisplayIdentityAllocator) -> Bool {
    allocator.claim(reported: identity, head: 1, attached: []) != nil
}

/// The order every teardown must follow: the display's deinit runs with the identity still held,
/// and the identity is released only after it.
private let expectedTeardown = ["display deinit", "identity held", "identity released"]

@Test func identityIsHeldUntilTheDisplayIsDeallocated() throws {
    let log = EventLog()
    let allocator = DisplayIdentityAllocator()
    let token = recordReleases(of: allocator, in: log)
    defer { NotificationCenter.default.removeObserver(token) }

    var display: MockDisplay? = try makeDisplay(allocator, log)
    #expect(!isClaimable(allocator))
    #expect(log.events.isEmpty)

    drop(&display)
    #expect(log.events == expectedTeardown)
    #expect(isClaimable(allocator))
}

@Test func anotherStrongReferenceToTheDisplayKeepsTheIdentityHeld() throws {
    let log = EventLog()
    let allocator = DisplayIdentityAllocator()
    let token = recordReleases(of: allocator, in: log)
    defer { NotificationCenter.default.removeObserver(token) }

    var display: MockDisplay? = try makeDisplay(allocator, log)
    var elsewhere: MockDisplay? = display
    drop(&display)
    // The owner is gone but the display lives on, so macOS may still be tearing it down.
    #expect(log.events.isEmpty)
    #expect(!isClaimable(allocator))

    drop(&elsewhere)
    #expect(log.events == expectedTeardown)
    #expect(isClaimable(allocator))
}

@Test func aSetUpThatFailsReleasesTheIdentityBeforeTheFailureIsReported() throws {
    struct SetUpFailed: Error {}
    // Mirrors VirtualDisplay.init: the display is attached to its lease, then setup throws.
    func setUpThenFail(_ allocator: DisplayIdentityAllocator, _ log: EventLog) throws {
        _ = try makeDisplay(allocator, log)
        throw SetUpFailed()
    }

    let log = EventLog()
    let allocator = DisplayIdentityAllocator()
    let token = recordReleases(of: allocator, in: log)
    defer { NotificationCenter.default.removeObserver(token) }

    #expect(throws: SetUpFailed.self) { try setUpThenFail(allocator, log) }
    #expect(log.events == expectedTeardown)
    #expect(isClaimable(allocator))
}

@Test func teardownOrderHoldsAcrossManyDisplaysOnTheSameIdentity() throws {
    let log = EventLog()
    let allocator = DisplayIdentityAllocator()
    let token = recordReleases(of: allocator, in: log)
    defer { NotificationCenter.default.removeObserver(token) }

    for _ in 0..<200 {
        var display: MockDisplay? = try makeDisplay(allocator, log)
        drop(&display)
    }
    let expected = Array(repeating: expectedTeardown, count: 200).flatMap { $0 }
    #expect(log.events == expected)
}
