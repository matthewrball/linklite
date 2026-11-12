// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import LinkLiteRotation

// Per-head orientation storage: duplicate identities, unplug/reorder/reconnect, migration.
//
// Identity dependency (documented in docs/DISPLAY_ROTATION.md): EDID carries no unique ID. Two
// identical panels can report the same vendor, product and serial, so identity alone cannot
// name a monitor. These tests pin the policy the app uses to avoid collisions anyway.

private func twin(_ head: UInt8, serial: UInt32 = 0x1234_5678) -> MonitorKey {
    MonitorKey(vendorID: 0x22f0, productCode: 0x3a4b, serial: serial, head: head)
}

/// Stores and restores preferences the way a relaunch does: through a serialized property list.
private func relaunched(_ preferences: OrientationPreferences) throws -> OrientationPreferences {
    let data = try PropertyListSerialization.data(fromPropertyList: preferences.propertyList,
                                                  format: .binary, options: 0)
    let restored = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return OrientationPreferences(propertyList: restored)
}

// MARK: - Storage format and migration

@Test func preferencesRoundTripAndIgnoreJunk() {
    let a = twin(0, serial: 0x1234_5678)
    let b = twin(1, serial: 0x1234_5679)
    var preferences = OrientationPreferences()
    #expect(preferences[a] == .standard)
    preferences[a] = .turnedClockwise
    preferences[b] = .upsideDown
    let stored = preferences.propertyList
    #expect(stored == ["22f0-3a4b-12345678": 90, "22f0-3a4b-12345679": 180])
    #expect(OrientationPreferences(propertyList: stored) == preferences)

    // Setting standard removes the entry, so unrotated users store nothing new.
    preferences[b] = .standard
    #expect(preferences.propertyList == ["22f0-3a4b-12345678": 90])

    let junk: Any = ["22f0-3a4b-12345678": 270, "x": 45, "y": "90", "z": 90.5] as [String: Any]
    #expect(OrientationPreferences(propertyList: junk).propertyList == ["22f0-3a4b-12345678": 270])
    #expect(OrientationPreferences(propertyList: "not a dictionary").propertyList == [:])
    #expect(OrientationPreferences(propertyList: nil).propertyList == [:])
}

@Test func existingUnrotatedInstallsAreUnchangedByTheNewKey() {
    // An install that predates rotation has no MonitorOrientations value at all. Every monitor must
    // read as standard, and standard must keep its exact legacy ConfiguredMonitors entry.
    let preferences = OrientationPreferences(propertyList: nil)
    #expect(preferences.orientation(for: twin(0)) == .standard)
    #expect(preferences.orientation(for: twin(1, serial: 0)) == .standard)
    #expect(twin(0).configuredModesKey(.standard) == "22f0-3a4b-12345678")
}

@Test func singleMonitorRecordsWrittenBeforeTwinsExistedKeepTheirMeaning() {
    // The stored format is the single-monitor format, so a pre-existing identity record still applies.
    let legacy: Any = ["22f0-3a4b-12345678": 270] as [String: Any]
    let preferences = OrientationPreferences(propertyList: legacy)
    #expect(preferences.orientation(for: twin(1)) == .turnedCounterclockwise)
}

@Test func configuredModesKeyIsUnchangedForUnrotatedMonitors() {
    // DisplayHost's "ConfiguredMonitors" list keeps today's exact strings for standard. Rotated
    // shapes get their own entry, since their mode list differs.
    let key = twin(0)
    #expect(key.configuredModesKey(.standard) == "22f0-3a4b-12345678")
    #expect(key.configuredModesKey(.upsideDown) == "22f0-3a4b-12345678")
    #expect(key.configuredModesKey(.turnedClockwise) == "22f0-3a4b-12345678-portrait")
    #expect(key.configuredModesKey(.turnedCounterclockwise) == "22f0-3a4b-12345678-portrait")
}

// MARK: - Serial collisions

@Test func monitorsWithoutASerialAreKeptApartByHead() {
    // Two identical panels reporting serial 0 must not share a setting.
    let left = MonitorKey(vendorID: 0x22f0, productCode: 0x3a4b, serial: 0, head: 0)
    let right = MonitorKey(vendorID: 0x22f0, productCode: 0x3a4b, serial: 0, head: 1)
    #expect(left.storageKey != right.storageKey)
    #expect(left.storageKey == "22f0-3a4b-00000000-head0")
}

@Test func serialZeroMonitorsNeverReadAnIdentityRecord() {
    // Serial 0 cannot prove which panel is which, so an identity record must not reach such a monitor:
    // two identical serial-0 panels would otherwise share one setting.
    let stored: Any = ["22f0-3a4b-00000000": 90] as [String: Any]
    let preferences = OrientationPreferences(propertyList: stored)
    #expect(preferences.orientation(for: MonitorKey(vendorID: 0x22f0, productCode: 0x3a4b, serial: 0, head: 0)) == .standard)
    #expect(preferences.orientation(for: MonitorKey(vendorID: 0x22f0, productCode: 0x3a4b, serial: 0, head: 1)) == .standard)
}

@Test func duplicateNonzeroSerialsOnTwoHeadsKeepSeparateOrientations() {
    // Identical panels can report the same NONZERO serial, so a serial does not prove uniqueness.
    let attached = [twin(0), twin(1)]
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: attached)
    preferences.setOrientation(.upsideDown, for: twin(1), among: attached)
    #expect(preferences.orientation(for: twin(0)) == .turnedClockwise)
    #expect(preferences.orientation(for: twin(1)) == .upsideDown)
    #expect(twin(0).storageKey(among: attached) != twin(1).storageKey(among: attached))
    #expect(preferences.propertyList.count == 2)
}

@Test func uniqueSerialKeepsTheIdentityKeyWhenNoOtherMonitorSharesItsIdentity() {
    let only = twin(1)
    let other = twin(0, serial: 0x1234_5679)
    #expect(only.storageKey(among: [only, other]) == "22f0-3a4b-12345678")
    #expect(only.storageKey(among: [only]) == only.storageKey)
}

@Test func duplicatesThatSwapSocketsKeepTheSettingWithTheSocket() {
    // Documented limit: identical monitors cannot be told apart by EDID, so the setting stays with the
    // socket and follows whichever monitor is now on it.
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: [twin(0), twin(1)])
    // Head 0's socket holds the setting; head 1's socket is untouched.
    #expect(preferences.orientation(for: twin(0)) == .turnedClockwise)
    #expect(preferences.orientation(for: twin(1)) == .standard)
}

// MARK: - Identical twins: unplug, reorder, reconnect

/// The rotation each socket is given in the scenarios below.
private func choice(_ head: UInt8) -> DisplayOrientation { head == 0 ? .turnedClockwise : .upsideDown }

/// Sets each twin's rotation while both are attached, unplugs `unplugged`, relaunches, checks the survivor,
/// reconnects the unplugged panel in reverse attachment order, relaunches, and checks both.
private func twinsKeepTheirRotationAcrossUnplugAndReconnect(serial: UInt32, unplugged: UInt8) throws {
    let pair = [twin(0, serial: serial), twin(1, serial: serial)]
    var preferences = OrientationPreferences()
    for monitor in pair { preferences.setOrientation(choice(monitor.head), for: monitor, among: pair) }
    #expect(preferences.orientation(for: pair[0]) == choice(0))
    #expect(preferences.orientation(for: pair[1]) == choice(1))

    // Unplug: the survivor is now the only panel with its identity. It must keep its own rotation,
    // never fall back to standard and never take the unplugged head's value.
    let survivor = twin(1 - unplugged, serial: serial)
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: survivor) == choice(survivor.head),
            "survivor on head \(survivor.head) after head \(unplugged) was unplugged")

    // Reconnect in reverse attachment order.
    let reconnected = [twin(1, serial: serial), twin(0, serial: serial)]
    preferences = try relaunched(preferences)
    for monitor in reconnected {
        #expect(preferences.orientation(for: monitor) == choice(monitor.head),
                "head \(monitor.head) after reconnect")
        #expect(monitor.storageKey(among: reconnected) == twin(monitor.head, serial: serial).storageKey(among: pair),
                "a socket's key must not depend on attachment order")
    }
}

@Test(arguments: [UInt8(0), UInt8(1)])
func twinsKeepTheirSocketRotationWhenEitherHeadIsUnplugged(unplugged: UInt8) throws {
    try twinsKeepTheirRotationAcrossUnplugAndReconnect(serial: 0x1234_5678, unplugged: unplugged)
}

@Test(arguments: [UInt8(0), UInt8(1)])
func twinsWithoutASerialKeepTheirSocketRotationWhenEitherHeadIsUnplugged(unplugged: UInt8) throws {
    try twinsKeepTheirRotationAcrossUnplugAndReconnect(serial: 0, unplugged: unplugged)
}

@Test func legacyUniqueSettingCarriesIntoATwinPairAndSurvivesUnplug() throws {
    // Stored while the panel was alone, as the single-monitor rules always did.
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedCounterclockwise, for: twin(1), among: [twin(1)])
    let pair = [twin(0), twin(1)]
    #expect(preferences.orientation(for: twin(0)) == .turnedCounterclockwise)
    #expect(preferences.orientation(for: twin(1)) == .turnedCounterclockwise)

    preferences.setOrientation(.turnedClockwise, for: twin(0), among: pair)
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: twin(1)) == .turnedCounterclockwise)
    #expect(preferences.orientation(for: twin(0)) == .turnedClockwise)
}

@Test func standardOverATwinPairDoesNotShowThroughToTheLegacySetting() throws {
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedCounterclockwise, for: twin(1), among: [twin(1)])
    let pair = [twin(0), twin(1)]
    preferences.setOrientation(.standard, for: twin(0), among: pair)
    #expect(preferences.orientation(for: twin(0)) == .standard)
    #expect(preferences.orientation(for: twin(1)) == .turnedCounterclockwise)

    // The explicit standard survives relaunch, so unplugging head 1 leaves head 0 standard.
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: twin(0)) == .standard)
    #expect(preferences.orientation(for: twin(1)) == .turnedCounterclockwise)
}

@Test func aChangeMadeWhileAloneKeepsTheAbsentTwinsPortRecord() throws {
    // Head 1's panel is unplugged while head 0's panel is changed. Head 1's record belongs to a panel
    // that may come back, so it must survive. Only head 0's own record is removed: it would otherwise
    // shadow the new identity setting on head 0.
    let pair = [twin(0), twin(1)]
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: pair)
    preferences.setOrientation(.upsideDown, for: twin(1), among: pair)
    preferences = try relaunched(preferences)
    preferences.setOrientation(.turnedCounterclockwise, for: twin(0), among: [twin(0)])
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: twin(0)) == .turnedCounterclockwise)
    #expect(preferences.propertyList == ["22f0-3a4b-12345678": 270, "22f0-3a4b-12345678-head1": 180])

    // Head 1's panel returns and gets its own rotation back. Head 0 now has no port record, so it reads
    // the identity setting it chose while alone.
    #expect(preferences.orientation(for: twin(1)) == .upsideDown)
    #expect(preferences.orientation(for: twin(0)) == .turnedCounterclockwise)
}

@Test(arguments: [false, true])
func startOrderDoesNotChangeWhichPanelGetsWhichRotation(bFirst: Bool) throws {
    // Each twin reads its own port first, so the order in which the engine reports them cannot matter.
    let pair = [twin(0), twin(1)]
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: pair)
    preferences.setOrientation(.upsideDown, for: twin(1), among: pair)
    preferences = try relaunched(preferences)
    let order = bFirst ? [twin(1), twin(0)] : [twin(0), twin(1)]
    #expect(order.map { preferences.orientation(for: $0) } == order.map { $0.head == 0 ? .turnedClockwise : .upsideDown })
}

@Test func twinChangedAfterTheOtherUnpluggedKeepsItsOwnRotationWhenTheOtherReturns() throws {
    // Head 0 is unplugged. Head 1's panel alone is changed, then the unplugged panel returns to head 0.
    let pair = [twin(0), twin(1)]
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: pair)
    preferences.setOrientation(.upsideDown, for: twin(1), among: pair)
    preferences.setOrientation(.turnedCounterclockwise, for: twin(1), among: [twin(1)])
    preferences = try relaunched(preferences)
    // Head 0's panel returns. It keeps its record, not the value chosen while head 1 was alone.
    #expect(preferences.orientation(for: twin(0)) == .turnedClockwise)
    #expect(preferences.orientation(for: twin(1)) == .turnedCounterclockwise)
}

@Test func loneMonitorMovedToAnEmptyPortKeepsItsIdentitySetting() throws {
    // A panel that is alone keeps its setting wherever it is plugged, when that port has no record.
    var preferences = OrientationPreferences()
    preferences.setOrientation(.upsideDown, for: twin(0), among: [twin(0)])
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: twin(2)) == .upsideDown)
}

@Test func loneMonitorMovedOntoAPortWithAParkedTwinRecordTakesThatRecord() throws {
    // Unavoidable ambiguity, pinned by this test. Head 1 holds an identical twin's record while that twin
    // is away. A lone panel plugged into head 1 cannot be told apart from that twin, so it reads the record.
    // Changing it there replaces the record; the identity setting it chose elsewhere is untouched.
    let pair = [twin(0), twin(1)]
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: pair)
    preferences.setOrientation(.upsideDown, for: twin(1), among: pair)
    // The panel on head 0 is changed while alone, so its identity setting is 270 and head 0's record is gone.
    preferences.setOrientation(.turnedCounterclockwise, for: twin(0), among: [twin(0)])
    // Head 1 now has a panel alone (the other one has gone). Head 1's parked record wins over the identity.
    #expect(preferences.orientation(for: twin(1)) == .upsideDown)
    // Head 0 is empty of records, so a panel there takes the identity setting.
    #expect(preferences.orientation(for: twin(2)) == .turnedCounterclockwise)
}

@Test func differentSerialOfTheSameModelNeverReadsTheTwinsRecords() throws {
    // Records are keyed by vendor, product and serial, so another unit of the same model must not inherit.
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: [twin(0), twin(1)])
    preferences.setOrientation(.upsideDown, for: twin(1), among: [twin(0), twin(1)])
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: twin(0, serial: 0x0bad_cafe)) == .standard)
    #expect(preferences.orientation(for: twin(1, serial: 0x0bad_cafe)) == .standard)
}

@Test func serialZeroTwinsKeepTheirPortRecordsWhenOneIsChangedAsIfAlone() throws {
    // Serial 0 is never "alone": its records are per port, and changing one leaves its neighbour's alone.
    let pair = [twin(0, serial: 0), twin(1, serial: 0)]
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: pair[0], among: pair)
    preferences.setOrientation(.upsideDown, for: pair[1], among: pair)
    preferences.setOrientation(.turnedCounterclockwise, for: pair[0], among: [pair[0]])
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: pair[0]) == .turnedCounterclockwise)
    #expect(preferences.orientation(for: pair[1]) == .upsideDown)
    #expect(preferences.propertyList == ["22f0-3a4b-00000000-head0": 270, "22f0-3a4b-00000000-head1": 180])
}

@Test func rotationScopeSaysWhetherAMonitorKeepsItsRotationPerPort() {
    #expect(twin(0).rotationScope(among: [twin(0)]) == .followsMonitor)
    #expect(twin(0).rotationScope(among: [twin(0), twin(1)]) == .perPortIdentical)
    #expect(twin(0, serial: 0).rotationScope(among: [twin(0, serial: 0)]) == .perPortWithoutSerial)
}

@Test func identicalPanelsThatSwapPortsFollowThePorts() throws {
    // Documented limit: EDID cannot tell identical panels apart, so the rotation stays with the port.
    let pair = [twin(0), twin(1)]
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: pair)
    preferences.setOrientation(.upsideDown, for: twin(1), among: pair)
    preferences = try relaunched(preferences)
    let swapped = [twin(1), twin(0)]
    #expect(preferences.orientation(for: swapped[1]) == .turnedClockwise)
    #expect(preferences.orientation(for: swapped[0]) == .upsideDown)
}

@Test func storedStandardIsExplicitForTwinsAndAbsentForSerialZero() throws {
    let lone = twin(1)
    var preferences = OrientationPreferences()
    preferences.setOrientation(.standard, for: lone, among: [lone])
    #expect(preferences.propertyList.isEmpty)

    preferences.setOrientation(.turnedCounterclockwise, for: lone, among: [lone])
    preferences.setOrientation(.standard, for: twin(0), among: [twin(0), twin(1)])
    #expect(preferences.propertyList == ["22f0-3a4b-12345678": 270, "22f0-3a4b-12345678-head0": 0])
    #expect(try relaunched(preferences) == preferences)

    // An explicit 0 is accepted; unknown degrees are still dropped.
    let stored: Any = ["22f0-3a4b-12345678-head0": 0, "x": 45] as [String: Any]
    #expect(OrientationPreferences(propertyList: stored).propertyList == ["22f0-3a4b-12345678-head0": 0])
}

// MARK: - Twins observed before the shared setting changes

@Test func aTwinsStandardIsStoredExplicitlySoALaterIdentityRecordCannotReachIt() throws {
    let pair = [twin(0), twin(1)]
    var preferences = OrientationPreferences()
    preferences.setOrientation(.standard, for: twin(1), among: pair)
    #expect(preferences.propertyList == ["22f0-3a4b-12345678-head1": 0])

    // Head 1's panel is unplugged, and head 0's panel alone is set to 270: that writes the identity record.
    preferences.setOrientation(.turnedCounterclockwise, for: twin(0), among: [twin(0)])
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: twin(1)) == .standard)
    #expect(preferences.orientation(for: twin(0)) == .turnedCounterclockwise)
}

@Test func aTwinObservedBeforeTheSharedSettingChangesKeepsItsRotation() throws {
    // Set alone at 90. The twin attaches and inherits 90. The twin is then recorded, while the other panel is
    // still attached, so the twin's 90 is written to its own port.
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: [twin(0)])
    preferences.materializeTwins([twin(0), twin(1)], among: [twin(0), twin(1)])
    preferences = try relaunched(preferences)

    // The twin is unplugged, and the remaining panel is changed alone. The twin must not follow.
    preferences.setOrientation(.upsideDown, for: twin(0), among: [twin(0)])
    preferences = try relaunched(preferences)
    #expect(preferences.orientation(for: twin(1)) == .turnedClockwise)
    #expect(preferences.orientation(for: twin(0)) == .upsideDown)
}

@Test(arguments: [false, true])
func legacyIdentityRecordIsMaterializedIntoEachTwinWhicheverIsObservedFirst(bFirst: Bool) throws {
    // Stored by an older version while the panel was alone.
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: [twin(0)])
    var attached: [MonitorKey] = []
    for head: UInt8 in (bFirst ? [1, 0] : [0, 1]) {
        attached.append(twin(head))
        preferences.materializeTwins(attached, among: attached)
    }
    #expect(preferences.propertyList == ["22f0-3a4b-12345678": 90, "22f0-3a4b-12345678-head0": 90,
                                         "22f0-3a4b-12345678-head1": 90])
    #expect(try relaunched(preferences) == preferences)
}

@Test func aMonitorWithoutADisplayIsNotMaterialized() {
    // Head 1's display failed, so it is attached but not recordable. Head 0 is recorded.
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: [twin(0)])
    let wrote = preferences.materializeTwins([twin(0)], among: [twin(0), twin(1)])
    #expect(wrote)
    #expect(preferences.propertyList == ["22f0-3a4b-12345678": 90, "22f0-3a4b-12345678-head0": 90])
    var repeated = preferences
    let wroteAgain = repeated.materializeTwins([twin(0)], among: [twin(0), twin(1)])
    #expect(!wroteAgain, "already recorded")
}

@Test func serialZeroMonitorsAreNeverMaterialized() {
    let pair = [twin(0, serial: 0), twin(1, serial: 0)]
    var preferences = OrientationPreferences()
    let wrote = preferences.materializeTwins(pair, among: pair)
    #expect(!wrote)
    #expect(preferences.propertyList.isEmpty)
}

@Test func materializationTouchesOnlyTheTwinsOwnRecords() {
    let other = MonitorKey(vendorID: 0x1111, productCode: 0x2222, serial: 0x9999, head: 2)
    var preferences = OrientationPreferences()
    preferences.setOrientation(.turnedCounterclockwise, for: other, among: [other])
    preferences.setOrientation(.turnedClockwise, for: twin(0), among: [twin(0)])
    preferences.materializeTwins([twin(0), twin(1)], among: [twin(0), twin(1), other])
    #expect(preferences.propertyList == ["1111-2222-00009999": 270, "22f0-3a4b-12345678": 90,
                                         "22f0-3a4b-12345678-head0": 90, "22f0-3a4b-12345678-head1": 90])
}
