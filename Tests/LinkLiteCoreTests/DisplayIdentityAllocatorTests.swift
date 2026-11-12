import Foundation
import Testing
@testable import LinkLiteCore

/// The identical pair from DisplayIdentityTests, and an unrelated monitor.
private let reported = DisplayIdentity(vendorID: 9933, productCode: 24944, serial: 16_843_009)
private let unrelated = DisplayIdentity(vendorID: 0x22f0, productCode: 0x3a7f, serial: 0x0102_0304)

/// Holds a claim the way a VirtualDisplay does: the lease lives as long as the holder.
private final class Holder {
    let reported: DisplayIdentity
    let identity: DisplayIdentity
    let head: UInt8
    let lease: IdentityLease
    init(_ claim: IdentityClaim, reported: DisplayIdentity, head: UInt8) {
        self.reported = reported
        identity = claim.identity
        self.head = head
        lease = claim.lease
    }

    /// This holder as a monitor attached on its socket.
    var attached: AttachedMonitor {
        AttachedMonitor(reported: reported, identity: identity, head: head)
    }
}

/// Claims `identity` for `head` while the holders in `attached` are attached on other heads.
private func claim(_ allocator: DisplayIdentityAllocator, _ identity: DisplayIdentity, head: UInt8,
                   attached: [Holder] = []) -> Holder? {
    allocator.claim(reported: identity, head: head, attached: attached.map(\.attached))
        .map { Holder($0, reported: identity, head: head) }
}

private let key = reported.configurationKey

@Test func singleMonitorKeepsItsReportedIdentityAndRecordsItsHead() throws {
    let allocator = DisplayIdentityAllocator()
    let first = try require(claim(allocator, reported, head: 0))
    #expect(first.identity == reported)
    #expect(allocator.records.owners[key] == 0)
    #expect(allocator.records.twins.isEmpty)
}

@Test func aLoneMonitorMovedToAnotherHeadKeepsItsIdentity() throws {
    let allocator = DisplayIdentityAllocator()
    var first: Holder? = try require(claim(allocator, reported, head: 0))
    #expect(first?.identity == reported)
    drop(&first)
    let moved = try require(claim(allocator, reported, head: 3))
    #expect(moved.identity == reported)
    #expect(allocator.records.owners[key] == 3)
}

@Test func identicalSecondMonitorGetsADistinctIdentityWhileTheFirstIsAttached() throws {
    let allocator = DisplayIdentityAllocator()
    let first = try require(claim(allocator, reported, head: 0))
    let second = try require(claim(allocator, reported, head: 1, attached: [first]))
    #expect(second.identity != reported)
    #expect(second.identity.serial != 0)
    #expect(second.identity.configurationKey != first.identity.configurationKey)
    #expect(allocator.records.twins.contains(key))
    #expect(allocator.records.owners[key] == 0)
}

@Test func secondMonitorKeepsItsIdentityAcrossATeardownAndReattach() throws {
    let allocator = DisplayIdentityAllocator()
    let first = try require(claim(allocator, reported, head: 0))
    var second: Holder? = try require(claim(allocator, reported, head: 1, attached: [first]))
    let original = try require(second?.identity)
    drop(&second)
    let again = try require(claim(allocator, reported, head: 1, attached: [first]))
    #expect(again.identity == original)
}

@Test func sameHeadReplacementWaitsForTheOldDisplayAndKeepsTheIdentity() throws {
    let allocator = DisplayIdentityAllocator()
    var old: Holder? = try require(claim(allocator, reported, head: 0))
    // A mode change on the same socket: the old display must be gone before a new one is made.
    #expect(claim(allocator, reported, head: 0) == nil)
    drop(&old)
    let replacement = try require(claim(allocator, reported, head: 0))
    #expect(replacement.identity == reported)
}

@Test func aSecondMonitorReplacementWaitsForItsOwnOldDisplayAndKeepsDerivedIdentity() throws {
    let allocator = DisplayIdentityAllocator()
    let first = try require(claim(allocator, reported, head: 0))
    var second: Holder? = try require(claim(allocator, reported, head: 1, attached: [first]))
    let original = try require(second?.identity)
    // Replacement while the old derived display is still alive must not pick a new serial.
    #expect(claim(allocator, reported, head: 1, attached: [first]) == nil)
    drop(&second)
    let replacement = try require(claim(allocator, reported, head: 1, attached: [first]))
    #expect(replacement.identity == original)
}

@Test func anIdentityStaysHeldUntilEveryReferenceToItsDisplayIsGone() throws {
    let allocator = DisplayIdentityAllocator()
    var a: Holder? = try require(claim(allocator, reported, head: 0))
    var b = a
    drop(&a)
    // Still referenced: the identity is not free.
    #expect(claim(allocator, reported, head: 1) == nil)
    drop(&b)
    #expect(b == nil)
    let free = try require(claim(allocator, reported, head: 1))
    #expect(free.identity == reported)
}

@Test func aRetainedDisplayOfAnotherHeadBlocksItsIdentityUntilReleased() throws {
    let allocator = DisplayIdentityAllocator()
    var retained: Holder? = try require(claim(allocator, reported, head: 0))
    // Head 0 is in its reconnect grace; the monitor appears on head 1 with nothing attached elsewhere.
    #expect(claim(allocator, reported, head: 1) == nil)
    drop(&retained)
    #expect(try require(claim(allocator, reported, head: 1)).identity == reported)
}

@Test func startupOrderDoesNotChangeWhichSocketHasWhichIdentity() throws {
    // First launch: head 1 comes up before head 0.
    let first = DisplayIdentityAllocator()
    var h1: Holder? = try require(claim(first, reported, head: 1))
    var h0: Holder? = try require(claim(first, reported, head: 0, attached: [h1!]))
    let h0Identity = try require(h0?.identity)
    #expect(h1?.identity == reported)
    #expect(h0Identity != reported)
    let saved = first.records
    drop(&h1)
    drop(&h0)

    // Next launch: head 0 comes up first. Each socket keeps its identity.
    let second = DisplayIdentityAllocator(records: saved)
    let a = try require(claim(second, reported, head: 0))
    #expect(a.identity == h0Identity)
    let b = try require(claim(second, reported, head: 1, attached: [a]))
    #expect(b.identity == reported)
}

@Test func aLongUnplugOfTheOwnerReturnsItToItsIdentity() throws {
    let allocator = DisplayIdentityAllocator()
    var owner: Holder? = try require(claim(allocator, reported, head: 0))
    let other = try require(claim(allocator, reported, head: 1, attached: [owner!]))
    let otherIdentity = other.identity
    drop(&owner) // unplugged, grace expired
    let back = try require(claim(allocator, reported, head: 0, attached: [other]))
    #expect(back.identity == reported)
    #expect(other.identity == otherIdentity)
}

@Test func aLongUnplugOfTheSecondMonitorReturnsItToItsIdentity() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, reported, head: 0))
    var second: Holder? = try require(claim(allocator, reported, head: 1, attached: [owner]))
    let secondIdentity = try require(second?.identity)
    drop(&second)
    let back = try require(claim(allocator, reported, head: 1, attached: [owner]))
    #expect(back.identity == secondIdentity)
    #expect(owner.identity == reported)
}

@Test func unavoidableAmbiguityAfterATwinWasSeenAMonitorOnAnotherSocketGetsADerivedIdentity() throws {
    // Once two identical monitors have been seen, the owner socket is kept for them. A lone monitor
    // that later shows up on a different socket cannot be told apart from the twin, so it gets the
    // derived identity. Documented trade-off; see DisplayIdentityAllocator.
    let allocator = DisplayIdentityAllocator()
    var owner: Holder? = try require(claim(allocator, reported, head: 0))
    var twin: Holder? = try require(claim(allocator, reported, head: 1, attached: [owner!]))
    drop(&owner)
    drop(&twin)
    let lone = try require(claim(allocator, reported, head: 2))
    #expect(lone.identity != reported)
}

@Test func aTwinGroupOwnerKeepsItsIdentityOnItsSocketAfterTheTwinLeaves() throws {
    let allocator = DisplayIdentityAllocator()
    var owner: Holder? = try require(claim(allocator, reported, head: 0))
    var twin: Holder? = try require(claim(allocator, reported, head: 1, attached: [owner!]))
    drop(&owner)
    drop(&twin)
    let again = try require(claim(allocator, reported, head: 0, attached: []))
    #expect(again.identity == reported)
}

@Test func aMigratedSingleMonitorKeepsItsIdentityWhileAnUnrelatedOneIsUntouched() throws {
    // 0.3.15 migration: no records yet, one monitor, its identity is the reported one.
    let migrated = DisplayIdentityAllocator(records: DisplayIdentityRecords())
    let single = try require(claim(migrated, reported, head: 0))
    #expect(single.identity == reported)
    let other = try require(claim(migrated, unrelated, head: 1))
    #expect(other.identity == unrelated)
}

@Test func manyIdenticalMonitorsGetDistinctIdentities() throws {
    let allocator = DisplayIdentityAllocator()
    var held: [Holder] = []
    for head: UInt8 in 0...3 {
        let next = try require(claim(allocator, reported, head: head, attached: held))
        #expect(!held.map(\.identity).contains(next.identity))
        held.append(next)
    }
    #expect(Set(held.map(\.identity)).count == 4)
}

@Test func releasingALeasePostsANotification() throws {
    let allocator = DisplayIdentityAllocator()
    let log = EventLog()
    let token = NotificationCenter.default.addObserver(
        forName: DisplayIdentityAllocator.identityReleasedNotification, object: allocator, queue: nil
    ) { _ in log.record("posted") }
    defer { NotificationCenter.default.removeObserver(token) }
    var holder: Holder? = try require(claim(allocator, reported, head: 0))
    drop(&holder)
    #expect(log.events == ["posted"])
}

// MARK: - Generated serials are not physical monitors (item 3)

@Test func aMonitorReportingAGeneratedSerialIsNotATwinOfTheMonitorThatHoldsIt() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, reported, head: 0))
    let twin = try require(claim(allocator, reported, head: 1, attached: [owner]))
    let generated = twin.identity
    #expect(generated != reported)

    // An unrelated monitor whose EDID happens to report the twin's generated identity.
    let stranger = try require(claim(allocator, generated, head: 2, attached: [owner, twin]))

    #expect(!allocator.records.twins.contains(generated.configurationKey))
    #expect(allocator.records.owners[generated.configurationKey] == nil)
    // It is not a twin, so it is not given the reported identity of the pair, and it is given a
    // distinct identity rather than waiting for the twin to go.
    #expect(stranger.identity != generated)
    #expect(stranger.identity != reported)
}

@Test func anUnrelatedMonitorReportingAnAssignedSerialIsNotDelayedByTheMonitorThatHoldsIt() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, reported, head: 0))
    let twin = try require(claim(allocator, reported, head: 1, attached: [owner]))
    // Assigned clash: the stranger's own identity is taken by an attached display. It takes a distinct
    // identity immediately, rather than being refused while the twin is attached.
    #expect(claim(allocator, twin.identity, head: 2, attached: [owner, twin]) != nil)
}

@Test func aTwinsPhysicalIdentityStillMarksTheTwinWhenTheOtherSocketIsAttached() throws {
    // The physical check uses the reported identity of attached monitors: a second physical copy is a
    // twin even when the first copy's display is currently known only by its generated serial.
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, reported, head: 0))
    _ = try require(claim(allocator, reported, head: 1, attached: [owner]))
    #expect(allocator.records.twins.contains(key))
}

// MARK: - Derived serials are stable across launches and reserved (item 2)

@Test func aDerivedSerialIsStoredAndNotRecomputedAfterARestart() throws {
    // The first candidate for head 1 is taken by another monitor during the first launch, so the twin
    // gets the second candidate. After a restart nothing takes the first candidate, and the twin must
    // still get the second.
    let firstCandidate = DisplayIdentity.derived(from: reported, head: 1, avoiding: [])

    let firstLaunch = DisplayIdentityAllocator()
    let owner = try require(claim(firstLaunch, reported, head: 0))
    let blocker = try require(claim(firstLaunch, firstCandidate, head: 3))
    var twin: Holder? = try require(claim(firstLaunch, reported, head: 1, attached: [owner, blocker]))
    let assigned = try require(twin?.identity)
    #expect(assigned != firstCandidate)
    let saved = firstLaunch.records
    drop(&twin)

    let secondLaunch = DisplayIdentityAllocator(records: saved)
    let again = try require(claim(secondLaunch, reported, head: 1, attached: []))
    #expect(again.identity == assigned)
}

@Test func aStoredDerivedSerialSurvivesAPropertyListRoundTrip() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, reported, head: 0))
    let twin = try require(claim(allocator, reported, head: 1, attached: [owner]))
    let plist = allocator.records.propertyList
    let restored = DisplayIdentityRecords(propertyList: plist)
    #expect(restored == allocator.records)
    #expect(restored.assignments[DisplayIdentityRecords.assignmentKey(for: reported, head: 1)]
        == twin.identity.configurationKey)
}

@Test func aSocketsReservedSerialIsKeptForItsTwinWhenAThirdMonitorReportsIt() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, reported, head: 0))
    var twin: Holder? = try require(claim(allocator, reported, head: 1, attached: [owner]))
    let reserved = try require(twin?.identity)
    drop(&twin)

    // A third, unrelated monitor reports the reserved serial. It is a different monitor, so it is given
    // its own stable serial rather than being refused, and it is not recorded as a twin.
    let third = try require(claim(allocator, reserved, head: 2, attached: [owner]))
    #expect(third.identity != reserved)
    #expect(!allocator.records.twins.contains(reserved.configurationKey))

    // The twin's socket comes back at once with its reserved serial. It does not wait for the third monitor.
    let back = try require(claim(allocator, reported, head: 1, attached: [owner, third]))
    #expect(back.identity == reserved)
    #expect(allocator.records.assignments[DisplayIdentityRecords.assignmentKey(for: reported, head: 1)]
        == reserved.configurationKey)
}

@Test func aMalformedStoredAssignmentIsReplacedRatherThanUsed() throws {
    let slot = DisplayIdentityRecords.assignmentKey(for: reported, head: 1)
    let corrupt = DisplayIdentityRecords(assignments: [slot: "not-a-key"])
    let allocator = DisplayIdentityAllocator(records: corrupt)
    let owner = try require(claim(allocator, reported, head: 0))
    let twin = try require(claim(allocator, reported, head: 1, attached: [owner]))
    #expect(twin.identity != reported)
    #expect(DisplayIdentity(configurationKey: allocator.records.assignments[slot] ?? "")
        == twin.identity)
}

// MARK: - A refused claim moves no owner (item 3)

@Test func aRefusedClaimDoesNotMoveTheOwnerNorPersistIt() throws {
    // Only successful claims and recorded changes are persisted; a refusal must leave both alone.
    let persisted = EventLog()
    let allocator = DisplayIdentityAllocator(persist: { records in
        persisted.record("owner \(records.owners[key].map { "\($0)" } ?? "none")")
    })
    let owner = try require(claim(allocator, reported, head: 0))
    #expect(persisted.events == ["owner 0"])

    // Head 1's monitor: head 0's display is retained, so nothing is attached on head 0 and the
    // identity is held by a live lease. The claim is refused.
    #expect(claim(allocator, reported, head: 1) == nil)
    #expect(allocator.records.owners[key] == 0)
    #expect(persisted.events == ["owner 0"])
    _ = owner
}

@Test func aRefusedClaimDoesNotTakeOwnershipFromTheSocketThatHoldsIt() throws {
    // The same thing through the path a second socket takes when its twin appears: owner stays put.
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, reported, head: 0))
    #expect(claim(allocator, reported, head: 1) == nil)
    #expect(allocator.records.owners[key] == 0)
    #expect(owner.identity == reported)
}

@Test func aRetainedOwnerRefusedASecondSocketThenReattachedKeepsStableIdentitiesAcrossAReversedRestart() throws {
    // Launch 1, in this order:
    // 1. Head 0 claims the reported identity. Its display is kept for a reconnect, so it stays live.
    let first = DisplayIdentityAllocator()
    let owner = try require(claim(first, reported, head: 0))
    // 2. Head 1's monitor is refused: the identity is still held by head 0's kept display.
    #expect(claim(first, reported, head: 1) == nil)
    // 3. Head 0's monitor reattaches to its kept display (no new claim), so it is attached again.
    // 4. Head 1 is now a twin of the attached monitor and is given its own derived serial.
    let twin = try require(claim(first, reported, head: 1, attached: [owner]))
    let twinIdentity = twin.identity
    #expect(twinIdentity != reported)
    #expect(owner.identity == reported)
    let saved = first.records
    #expect(saved.owners[key] == 0)
    #expect(saved.twins.contains(key))

    // Launch 2, reversed: head 1 comes up first with nothing attached. It gets the same derived serial.
    let second = DisplayIdentityAllocator(records: DisplayIdentityRecords(propertyList: saved.propertyList))
    let relaunchedTwin = try require(claim(second, reported, head: 1))
    #expect(relaunchedTwin.identity == twinIdentity)
    // Then head 0 comes up and keeps the reported identity it owned.
    let relaunchedOwner = try require(claim(second, reported, head: 0, attached: [relaunchedTwin]))
    #expect(relaunchedOwner.identity == reported)
}

@Test func aRefusedClaimStillRecordsATwinItSaw() throws {
    // Twin recognition is a fact about the monitors on the bus, not a claim, so it survives a refusal.
    let allocator = DisplayIdentityAllocator()
    var old: Holder? = try require(claim(allocator, reported, head: 0))
    let twinOnHead1 = AttachedMonitor(reported: reported, identity: nil, head: 1)
    #expect(allocator.claim(reported: reported, head: 0, attached: [twinOnHead1]) == nil)
    #expect(allocator.records.twins.contains(key))
    #expect(allocator.records.owners[key] == 0)

    // Once the old display is released, the same socket gets its identity back.
    drop(&old)
    #expect(allocator.claim(reported: reported, head: 0, attached: [twinOnHead1])?.identity == reported)
}
