import Foundation
import Testing
@testable import LinkLiteCore

// Reservations: a derived identity is held for its socket even while its display is not live, so a
// different monitor that reports the same serial must not take it. A monitor like that is a separate
// physical monitor, never an identical twin, and a socket that returns always gets its reservation.

/// Two identical monitors: `pair` is the reported identity of both.
private let pair = DisplayIdentity(vendorID: 9933, productCode: 24944, serial: 16_843_009)
/// A different monitor whose EDID reports a real serial.
private let other = DisplayIdentity(vendorID: 0x22f0, productCode: 0x3a7f, serial: 0x0102_0304)

/// A monitor's claim, held the way a VirtualDisplay holds it: the lease lives as long as the holder.
private final class Held {
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

    var attached: AttachedMonitor {
        AttachedMonitor(reported: reported, identity: identity, head: head)
    }
}

private func claim(_ allocator: DisplayIdentityAllocator, _ reported: DisplayIdentity, head: UInt8,
                   attached: [Held] = [], configured: Set<DisplayIdentity> = []) -> Held? {
    allocator.claim(reported: reported, head: head, attached: attached.map(\.attached), configured: configured)
        .map { Held($0, reported: reported, head: head) }
}

/// The serial a twin on `head` would be reserved, when nothing else is in the way.
private func reservedSerialFor(head: UInt8) -> DisplayIdentity {
    DisplayIdentity.derived(from: pair, head: head, avoiding: [])
}

// MARK: - No indefinite wait

@Test func aMonitorReportingAReservedSerialDoesNotMakeTheTwinWaitWhenItReturns() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, pair, head: 0))
    var twin: Held? = try require(claim(allocator, pair, head: 1, attached: [owner]))
    let reserved = try require(twin?.identity)
    drop(&twin)

    // The twin is offline. A physically different monitor reports exactly the reserved identity.
    let stranger = try require(claim(allocator, reserved, head: 2, attached: [owner]))
    #expect(stranger.identity != reserved)
    #expect(!allocator.records.twins.contains(reserved.configurationKey))
    #expect(allocator.records.owners[reserved.configurationKey] == nil)

    // While the stranger is still attached, the twin's socket gets its reservation at once.
    let back = try require(claim(allocator, pair, head: 1, attached: [owner, stranger]))
    #expect(back.identity == reserved)
}

@Test func aDockResetWithAReversedStartupNeverWaitsForAReservedSerial() throws {
    // Launch 1: the twin's socket is reserved a serial, then its monitor is offline when a different
    // monitor reports that serial.
    let first = DisplayIdentityAllocator()
    let owner = try require(claim(first, pair, head: 0))
    var twin: Held? = try require(claim(first, pair, head: 1, attached: [owner]))
    let reserved = try require(twin?.identity)
    drop(&twin)
    var stranger: Held? = try require(claim(first, reserved, head: 2, attached: [owner]))
    let strangerIdentity = try require(stranger?.identity)
    drop(&stranger)
    let saved = DisplayIdentityRecords(propertyList: first.records.propertyList)

    // Launch 2, after a dock reset, in reversed order: the stranger's socket comes up first.
    let second = DisplayIdentityAllocator(records: saved)
    let strangerAgain = try require(claim(second, reserved, head: 2))
    #expect(strangerAgain.identity == strangerIdentity)
    #expect(strangerAgain.identity != reserved)

    // The twin's socket comes up next and gets its reservation, with the stranger still attached.
    let twinAgain = try require(claim(second, pair, head: 1, attached: [strangerAgain]))
    #expect(twinAgain.identity == reserved)

    // The owner's socket comes up last and keeps the reported identity it owned.
    let ownerAgain = try require(claim(second, pair, head: 0, attached: [twinAgain, strangerAgain]))
    #expect(ownerAgain.identity == pair)
}

@Test func aStrangerReportingTheReservedSerialIsGrantedAtOnceAndNeverRecordedAsATwin() throws {
    // The stranger does not wait for the twin's socket either: it is granted at once, not refused.
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, pair, head: 0))
    let twin = try require(claim(allocator, pair, head: 1, attached: [owner]))
    let reserved = twin.identity
    #expect(claim(allocator, reserved, head: 2, attached: [owner, twin]) != nil)
    #expect(!allocator.records.twins.contains(reserved.configurationKey))
}

// MARK: - Real serial versus a reserved derived serial

@Test func aRealSerialEqualToAReservedDerivedSerialIsADifferentMonitorNotATwin() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, pair, head: 0))
    var twin: Held? = try require(claim(allocator, pair, head: 1, attached: [owner]))
    let reserved = try require(twin?.identity)
    drop(&twin)

    // A monitor reporting the same vendor and product with a real serial equal to the reservation.
    let real = try require(claim(allocator, reserved, head: 2, attached: [owner]))
    #expect(real.identity.vendorID == pair.vendorID)
    #expect(real.identity.productCode == pair.productCode)
    #expect(real.identity != reserved)
    // Its reported identity is recorded as a monitor of its own, with its own socket reservation.
    #expect(allocator.records.reported.contains(reserved.configurationKey))
    #expect(allocator.records.assignments[DisplayIdentityRecords.assignmentKey(for: reserved, head: 2)]
        == real.identity.configurationKey)
    #expect(allocator.records.owners[reserved.configurationKey] == nil)
}

@Test func aSingleMonitorWithAnUnreservedRealSerialKeepsItsIdentity() throws {
    // Single-display compatibility: no reservation conflict, so the reported identity is used as before.
    let allocator = DisplayIdentityAllocator()
    let single = try require(claim(allocator, other, head: 4))
    #expect(single.identity == other)
    #expect(allocator.records.assignments.isEmpty)
    #expect(allocator.records.twins.isEmpty)
    #expect(allocator.records.owners[other.configurationKey] == 4)
}

// MARK: - Legal same-socket reattachment

@Test func aSocketReattachingWithItsOwnReservationIsNotACollision() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, pair, head: 0))
    var twin: Held? = try require(claim(allocator, pair, head: 1, attached: [owner]))
    let reserved = try require(twin?.identity)
    let before = allocator.records
    drop(&twin)

    // Its own reservation is not another monitor's, so the same socket gets it back and nothing else moves.
    let again = try require(claim(allocator, pair, head: 1, attached: [owner]))
    #expect(again.identity == reserved)
    #expect(allocator.records.assignments == before.assignments)
    #expect(allocator.records.owners == before.owners)
    #expect(allocator.records.twins == before.twins)
}

@Test func aSocketReattachingWhileItsOwnReservationIsLiveWaitsForItsOwnDisplayOnly() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, pair, head: 0))
    var twin: Held? = try require(claim(allocator, pair, head: 1, attached: [owner]))
    let reserved = try require(twin?.identity)
    // Its own display is still alive: the same socket waits for it, and only it.
    #expect(claim(allocator, pair, head: 1, attached: [owner]) == nil)
    drop(&twin)
    #expect(try require(claim(allocator, pair, head: 1, attached: [owner])).identity == reserved)
}

// MARK: - Derived serials avoid everything known

@Test func aDerivedSerialAvoidsConfiguredMonitorKeys() throws {
    let candidate = reservedSerialFor(head: 1)
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, pair, head: 0))
    let twin = try require(claim(allocator, pair, head: 1, attached: [owner], configured: [candidate]))
    #expect(twin.identity != candidate)
    #expect(twin.identity.serial != 0)
}

@Test func aDerivedSerialAvoidsEveryHistoricalReportedIdentity() throws {
    let candidate = reservedSerialFor(head: 1)
    // A monitor with that exact identity was seen before (its record outlived its display).
    let records = DisplayIdentityRecords(reported: [candidate.configurationKey])
    let allocator = DisplayIdentityAllocator(records: records)
    let owner = try require(claim(allocator, pair, head: 0))
    let twin = try require(claim(allocator, pair, head: 1, attached: [owner]))
    #expect(twin.identity != candidate)
}

@Test func everyReportedIdentityClaimedIsRecorded() throws {
    let allocator = DisplayIdentityAllocator()
    let owner = try require(claim(allocator, pair, head: 0))
    _ = try require(claim(allocator, other, head: 3))
    _ = owner
    #expect(allocator.records.reported == [pair.configurationKey, other.configurationKey])
}

// MARK: - Migration of records written before these rules

@Test func aPersistedCollisionKeepsTheReservationAndDropsTheStaleOwnership() throws {
    // Written by the earlier rules: the stranger was given the reserved serial as its own identity.
    let reserved = reservedSerialFor(head: 1)
    let legacy = DisplayIdentityRecords(
        owners: [reserved.configurationKey: 2, pair.configurationKey: 0],
        twins: [pair.configurationKey],
        assignments: [DisplayIdentityRecords.assignmentKey(for: pair, head: 1): reserved.configurationKey]
    )
    let migrated = legacy.reconciled()
    #expect(migrated.owners == [pair.configurationKey: 0])
    #expect(migrated.assignments == legacy.assignments)
    // The stranger's reported identity was genuinely seen, so it stays on record.
    #expect(migrated.reported.contains(reserved.configurationKey))
    #expect(migrated.reported.contains(pair.configurationKey))

    // The reservation's twin returns to its serial; the stranger takes a separate one.
    let allocator = DisplayIdentityAllocator(records: legacy)
    let owner = try require(claim(allocator, pair, head: 0))
    let stranger = try require(claim(allocator, reserved, head: 2, attached: [owner]))
    #expect(stranger.identity != reserved)
    let twin = try require(claim(allocator, pair, head: 1, attached: [owner, stranger]))
    #expect(twin.identity == reserved)
}

@Test func aPersistedDuplicateReservationKeepsOnlyTheFirstSlot() {
    let reserved = reservedSerialFor(head: 1)
    let legacy = DisplayIdentityRecords(assignments: [
        DisplayIdentityRecords.assignmentKey(for: pair, head: 1): reserved.configurationKey,
        DisplayIdentityRecords.assignmentKey(for: pair, head: 2): reserved.configurationKey,
    ])
    let migrated = legacy.reconciled()
    #expect(migrated.assignments == [DisplayIdentityRecords.assignmentKey(for: pair, head: 1): reserved.configurationKey])
}

@Test func aPersistedDuplicateReservationGivesTheLaterSlotANewSerialOnItsClaim() throws {
    let reserved = reservedSerialFor(head: 1)
    let legacy = DisplayIdentityRecords(assignments: [
        DisplayIdentityRecords.assignmentKey(for: pair, head: 1): reserved.configurationKey,
        DisplayIdentityRecords.assignmentKey(for: pair, head: 2): reserved.configurationKey,
    ])
    let allocator = DisplayIdentityAllocator(records: legacy)
    let owner = try require(claim(allocator, pair, head: 0))
    let first = try require(claim(allocator, pair, head: 1, attached: [owner]))
    let second = try require(claim(allocator, pair, head: 2, attached: [owner, first]))
    #expect(first.identity == reserved)
    #expect(second.identity != reserved)
    #expect(second.identity != pair)
}

@Test func malformedSelfAndWrongVendorReservationsAreDropped() {
    let slot = DisplayIdentityRecords.assignmentKey(for: pair, head: 1)
    let legacy = DisplayIdentityRecords(assignments: [
        slot: "not-a-key",
        DisplayIdentityRecords.assignmentKey(for: pair, head: 2): pair.configurationKey,
        DisplayIdentityRecords.assignmentKey(for: pair, head: 3):
            DisplayIdentity(vendorID: 1, productCode: 2, serial: 5).configurationKey,
        DisplayIdentityRecords.assignmentKey(for: pair, head: 4):
            DisplayIdentity(vendorID: pair.vendorID, productCode: pair.productCode, serial: 0).configurationKey,
        "garbage": reservedSerialFor(head: 5).configurationKey,
    ])
    #expect(legacy.reconciled().assignments.isEmpty)
}

@Test func reconciliationIsIdempotent() {
    let reserved = reservedSerialFor(head: 1)
    let legacy = DisplayIdentityRecords(
        owners: [reserved.configurationKey: 2],
        twins: [pair.configurationKey],
        assignments: [
            DisplayIdentityRecords.assignmentKey(for: pair, head: 1): reserved.configurationKey,
            DisplayIdentityRecords.assignmentKey(for: pair, head: 2): reserved.configurationKey,
        ]
    )
    let once = legacy.reconciled()
    #expect(once.reconciled() == once)
}

@Test func aMigratedRecordIsWrittenBackOnceAndACleanOneIsNotWritten() {
    let log = EventLog()
    let reserved = reservedSerialFor(head: 1)
    let legacy = DisplayIdentityRecords(owners: [reserved.configurationKey: 2])
    _ = DisplayIdentityAllocator(records: legacy, persist: { _ in log.record("migrated") })
    #expect(log.events == ["migrated"])

    // Already in the current form: reconciling changes nothing, so nothing is written.
    let clean = DisplayIdentityRecords(owners: [pair.configurationKey: 0], reported: [pair.configurationKey]).reconciled()
    _ = DisplayIdentityAllocator(records: clean, persist: { _ in log.record("clean") })
    #expect(log.events == ["migrated"])
}

@Test func reconciledRecordsSurviveAPropertyListRoundTrip() {
    let reserved = reservedSerialFor(head: 1)
    let records = DisplayIdentityRecords(
        owners: [pair.configurationKey: 0],
        twins: [pair.configurationKey],
        assignments: [DisplayIdentityRecords.assignmentKey(for: pair, head: 1): reserved.configurationKey],
        reported: [other.configurationKey]
    )
    #expect(DisplayIdentityRecords(propertyList: records.propertyList) == records)
}

// MARK: - Conflict migration: a configured owner against a reservation (item 3)

@Test func aConfiguredOwnerThatCollidesWithAReservationLosesOwnershipAndTheReservationWins() throws {
    // Written by an earlier rule. `reserved` is an identity macOS already keeps per-display settings
    // for (it is configured). Head 2 owned it, and head 1's twin of `pair` holds it as a reservation.
    let reserved = reservedSerialFor(head: 1)
    let configured: Set<DisplayIdentity> = [reserved]
    let legacy = DisplayIdentityRecords(
        owners: [reserved.configurationKey: 2, pair.configurationKey: 0],
        twins: [pair.configurationKey],
        assignments: [DisplayIdentityRecords.assignmentKey(for: pair, head: 1): reserved.configurationKey]
    )

    // Deterministic priority: the reservation keeps its value, and the owner entry for that identity is
    // dropped. Migrating again changes nothing.
    let migrated = legacy.reconciled()
    #expect(migrated.assignments == legacy.assignments)
    #expect(migrated.owners == [pair.configurationKey: 0])
    #expect(migrated.reconciled() == migrated)

    // Whatever order the sockets come up in, the twin on head 1 gets the reservation, and the monitor
    // reporting `reserved` on head 2 gets a serial of its own that avoids the configured identity.
    let owner = DisplayIdentityAllocator(records: legacy)
    let ownerFirst = try require(claim(owner, pair, head: 0, configured: configured))
    let twin = try require(claim(owner, pair, head: 1, attached: [ownerFirst], configured: configured))
    let stranger = try require(claim(owner, reserved, head: 2, attached: [ownerFirst, twin], configured: configured))
    #expect(ownerFirst.identity == pair)
    #expect(twin.identity == reserved)
    #expect(stranger.identity != reserved)
    #expect(!configured.contains(stranger.identity))

    let strangerFirst = DisplayIdentityAllocator(records: legacy)
    let early = try require(claim(strangerFirst, reserved, head: 2, configured: configured))
    #expect(!configured.contains(early.identity))
    let ownerLater = try require(claim(strangerFirst, pair, head: 0, attached: [early], configured: configured))
    let twinLater = try require(claim(strangerFirst, pair, head: 1, attached: [ownerLater, early],
                                      configured: configured))
    #expect(ownerLater.identity == pair)
    // The settings stored for `reserved` now apply to head 1's display, not to the monitor that owned it.
    // The records cannot say which socket those settings were made for, so this is kept, not guessed.
    #expect(twinLater.identity == reserved)
    #expect(configured.contains(twinLater.identity))
}
