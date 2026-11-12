import Foundation
import Testing
@testable import LinkLiteCore

/// Two monitors as reported in the field: same manufacturer, product and a placeholder numeric serial
/// (0x01010101), so the parsed identity alone cannot tell them apart. The allocator sees only parsed
/// identities, so these tests cover monitors whose EDIDs differ in some byte but parse to this identity.
/// Byte-identical EDIDs never reach the allocator: the engine refuses the second head first.
private let reported = DisplayIdentity(vendorID: 9933, productCode: 24944, serial: 16_843_009)

@Test func configurationKeyFormatIsUnchanged() {
    // Existing ConfiguredMonitors entries were written in this format.
    #expect(reported.configurationKey == "26cd-6170-01010101")
}

@Test func derivedIdentityDiffersFromReportedAndBetweenHeads() {
    var seen: Set<DisplayIdentity> = [reported]
    for head: UInt8 in 0...3 {
        let identity = DisplayIdentity.derived(from: reported, head: head, avoiding: [])
        #expect(identity.vendorID == reported.vendorID)
        #expect(identity.productCode == reported.productCode)
        #expect(identity.serial != 0)
        #expect(!seen.contains(identity))
        seen.insert(identity)
    }
}

@Test func derivedIdentityIsDeterministicForAHead() {
    let first = DisplayIdentity.derived(from: reported, head: 2, avoiding: [])
    let again = DisplayIdentity.derived(from: reported, head: 2, avoiding: [])
    #expect(first == again)
}

@Test func derivedIdentityAvoidsTakenIdentities() {
    let first = DisplayIdentity.derived(from: reported, head: 1, avoiding: [])
    let next = DisplayIdentity.derived(from: reported, head: 1, avoiding: [first])
    #expect(next != first)
    #expect(next != reported)
    #expect(next.serial != 0)
}

@Test func recordsSurviveAPropertyListRoundTrip() {
    let records = DisplayIdentityRecords(owners: ["26cd-6170-01010101": 3], twins: ["26cd-6170-01010101"])
    #expect(DisplayIdentityRecords(propertyList: records.propertyList) == records)
    #expect(DisplayIdentityRecords(propertyList: nil) == DisplayIdentityRecords())
}
