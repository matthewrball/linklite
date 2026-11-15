import Foundation
import Testing
@testable import LinkLiteCore

// Portrait identities: a portrait display is made with its own identity, paired with the landscape identity the
// monitor gets, so macOS never applies one shape's saved mode, arrangement or mirroring to the other, and a
// landscape <-> portrait rebuild never re-creates the identity of the display it has just removed.

/// Two identical monitors: `pair` is the reported identity of both.
private let pair = DisplayIdentity(vendorID: 9933, productCode: 24944, serial: 16_843_009)
/// A different monitor.
private let other = DisplayIdentity(vendorID: 0x22f0, productCode: 0x3a7f, serial: 0x0102_0304)

/// A claim held the way a VirtualDisplay holds it: the lease lives as long as the holder.
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
                   portrait: Bool = false, attached: [Held] = []) -> Held? {
    allocator.claim(reported: reported, head: head, attached: attached.map(\.attached), portrait: portrait)
        .map { Held($0, reported: reported, head: head) }
}

/// Records as a relaunch reads them: through a serialized property list.
private func relaunched(_ records: DisplayIdentityRecords) throws -> DisplayIdentityRecords {
    let data = try PropertyListSerialization.data(fromPropertyList: records.propertyList, format: .binary, options: 0)
    return DisplayIdentityRecords(propertyList: try PropertyListSerialization.propertyList(from: data, format: nil))
}

@Test func aPortraitDisplayHasItsOwnIdentityThatIsStableAcrossRebuildsAndRelaunches() throws {
    let allocator = DisplayIdentityAllocator()
    var landscape: Held? = try require(claim(allocator, pair, head: 0))
    #expect(landscape?.identity == pair, "a landscape display keeps the monitor's identity, as before")
    drop(&landscape)

    var portrait: Held? = try require(claim(allocator, pair, head: 0, portrait: true))
    let portraitIdentity = try require(portrait?.identity)
    #expect(portraitIdentity != pair, "a portrait display must not share the landscape display's identity")
    #expect(portraitIdentity.vendorID == pair.vendorID && portraitIdentity.productCode == pair.productCode)
    #expect(portraitIdentity.serial != 0)
    drop(&portrait)

    #expect(try require(claim(allocator, pair, head: 0, portrait: true)).identity == portraitIdentity)
    let again = DisplayIdentityAllocator(records: try relaunched(allocator.records))
    #expect(try require(claim(again, pair, head: 0)).identity == pair)
    #expect(try require(claim(again, pair, head: 0, portrait: true)).identity == portraitIdentity,
            "a relaunch must give the portrait display the identity macOS saved its settings under")
}

@Test func aPortraitClaimNeverWaitsForTheLandscapeDisplayItReplaces() throws {
    let allocator = DisplayIdentityAllocator()
    let landscape = try require(claim(allocator, pair, head: 0))
    // The landscape display is still being torn down; the portrait one does not reuse its identity.
    let portrait = try require(claim(allocator, pair, head: 0, portrait: true))
    #expect(portrait.identity != landscape.identity)
    // And the reverse: a held portrait display never makes the landscape identity wait.
    #expect(claim(allocator, pair, head: 0, portrait: true) == nil, "its own portrait identity is still held")
    _ = landscape
}

@Test func twinsGetFourDistinctIdentitiesAndKeepThemPerSocket() throws {
    let allocator = DisplayIdentityAllocator()
    var first: Held? = try require(claim(allocator, pair, head: 0))
    var second: Held? = try require(claim(allocator, pair, head: 1, attached: [first!]))
    let landscape = [try require(first?.identity), try require(second?.identity)]
    drop(&first)
    // Head 0 is rebuilt in portrait while head 1 is still landscape, then head 1 follows.
    let portrait0 = try require(claim(allocator, pair, head: 0, portrait: true, attached: [second!]))
    drop(&second)
    let portrait1 = try require(claim(allocator, pair, head: 1, portrait: true, attached: [portrait0]))

    let all = landscape + [portrait0.identity, portrait1.identity]
    #expect(Set(all).count == 4, "no two of the twins' displays may share an identity: \(all)")
    #expect(landscape[0] == pair)
    // Each socket's portrait identity is paired with its own landscape identity.
    #expect(allocator.records.portraits[landscape[0].configurationKey] == portrait0.identity.configurationKey)
    #expect(allocator.records.portraits[landscape[1].configurationKey] == portrait1.identity.configurationKey)
}

@Test func aMonitorFirstSeenInPortraitOwnsItsIdentitySoItsTwinStillGetsADerivedOne() throws {
    let allocator = DisplayIdentityAllocator()
    let portrait = try require(claim(allocator, pair, head: 0, portrait: true))
    #expect(allocator.records.owners[pair.configurationKey] == 0)
    let twin = try require(claim(allocator, pair, head: 1, attached: [portrait]))
    #expect(twin.identity != pair, "the socket that owns the identity in portrait keeps it for landscape")
    #expect(twin.identity != portrait.identity)
    // Head 0 later turns back to landscape: it gets the reported identity, which nobody else took.
    _ = try require(claim(allocator, pair, head: 0, attached: [twin]))
}

@Test func portraitReservationsAreAvoidedByDerivedSerialsAndNeverGivenToAStranger() throws {
    let allocator = DisplayIdentityAllocator()
    let portrait = try require(claim(allocator, pair, head: 0, portrait: true))
    // A different monitor whose EDID happens to report the portrait identity does not take it.
    let stranger = try require(claim(allocator, portrait.identity, head: 2, attached: [portrait]))
    #expect(stranger.identity != portrait.identity)
    // A twin's derived serial avoids it too.
    let twin = try require(claim(allocator, pair, head: 1, attached: [portrait, stranger]))
    #expect(twin.identity != portrait.identity)
}

@Test func reconciliationDropsPortraitPairingsThatCollideOrAreMalformed() {
    let landscape = pair.configurationKey
    let twinSlot = DisplayIdentityRecords.assignmentKey(for: pair, head: 1)
    let reserved = DisplayIdentity(vendorID: pair.vendorID, productCode: pair.productCode, serial: 0x0000_0042)
    let good = DisplayIdentity(vendorID: pair.vendorID, productCode: pair.productCode, serial: 0x0000_0043)
    // Sorts after `landscape`, so its pairing is the later duplicate.
    let later = DisplayIdentity(vendorID: pair.vendorID, productCode: pair.productCode, serial: 0x7fff_ffff)
    let records = DisplayIdentityRecords(
        owners: [landscape: 0], twins: [landscape], assignments: [twinSlot: reserved.configurationKey],
        reported: [landscape, other.configurationKey],
        portraits: [
            landscape: good.configurationKey,
            later.configurationKey: good.configurationKey,              // duplicate of the first pairing
            other.configurationKey: pair.configurationKey,              // wrong vendor, and a monitor's identity
            "junk": good.configurationKey,
            "0000-0000-00000001": "0000-0000-00000000",                 // zero serial
        ])
    let reconciled = records.reconciled()
    #expect(reconciled.portraits == [landscape: good.configurationKey])
    #expect(reconciled.reconciled() == reconciled, "reconciliation is idempotent")

    let colliding = DisplayIdentityRecords(reported: [landscape], portraits: [landscape: landscape]).reconciled()
    #expect(colliding.portraits.isEmpty, "a portrait identity equal to its landscape one is dropped")
    let onReservation = DisplayIdentityRecords(assignments: [twinSlot: reserved.configurationKey],
                                               portraits: [landscape: reserved.configurationKey]).reconciled()
    #expect(onReservation.portraits.isEmpty, "a portrait identity equal to a landscape reservation is dropped")
}
