// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore

/// Identifies one dock monitor for per-head settings.
///
/// IDENTITY DEPENDENCY. EDID has no unique ID. `identity` (vendor, product, serial) is the only stable
/// handle, and two identical panels can report the same nonzero serial. The head number tells sockets
/// apart, so the policy below keeps identical panels from overwriting each other. It cannot tell two
/// identical panels apart once they are swapped between sockets.
public struct MonitorKey: Hashable, Sendable {
    public var vendorID: UInt16
    public var productCode: UInt16
    public var serial: UInt32
    public var head: UInt8

    public init(vendorID: UInt16, productCode: UInt16, serial: UInt32, head: UInt8) {
        self.vendorID = vendorID
        self.productCode = productCode
        self.serial = serial
        self.head = head
    }

    /// The same string DisplayHost already uses for its "ConfiguredMonitors" list.
    public var identity: String { String(format: "%04x-%04x-%08x", vendorID, productCode, serial) }

    /// The socket record: `identity` plus the head. Holds the setting of a monitor whose identity is
    /// shared with another attached monitor, or whose serial is 0.
    var socketKey: String { "\(identity)-head\(head)" }

    /// True when this monitor has a nonzero serial and no other attached monitor shares its identity.
    /// Its setting then lives under the identity record.
    public func isAlone(among attached: [MonitorKey]) -> Bool {
        serial != 0 && !attached.contains { $0.identity == identity && $0.head != head }
    }

    /// The key a change to this monitor is written under, given every monitor attached at once.
    public func storageKey(among attached: [MonitorKey]) -> String {
        isAlone(among: attached) ? identity : socketKey
    }

    /// The key when this is the only monitor attached.
    public var storageKey: String { storageKey(among: [self]) }

    /// How this monitor's rotation is kept, given every monitor attached at once. The menu says so when it
    /// is not `followsMonitor`.
    public enum RotationScope: Equatable, Sendable {
        /// Alone with its identity: the setting belongs to the panel, wherever it is plugged.
        case followsMonitor
        /// An identical panel is attached: the setting belongs to the port.
        case perPortIdentical
        /// The panel reports serial 0, so no identity can prove which panel it is: per port.
        case perPortWithoutSerial
    }

    public func rotationScope(among attached: [MonitorKey]) -> RotationScope {
        if serial == 0 { return .perPortWithoutSerial }
        return isAlone(among: attached) ? .followsMonitor : .perPortIdentical
    }

    /// Entry for DisplayHost's "ConfiguredMonitors" list (default mode applied once). Unchanged for
    /// landscape shapes. A portrait virtual display has a different mode list, so it gets its own entry.
    public func configuredModesKey(_ orientation: DisplayOrientation) -> String {
        Self.configuredModesKey(identity: DisplayIdentity(vendorID: vendorID, productCode: productCode, serial: serial),
                                orientation: orientation)
    }

    /// The same entry for the identity a display was actually created with. A display given a derived identity
    /// is recorded under that identity, so it does not share a record with the monitor it was derived from.
    public static func configuredModesKey(identity: DisplayIdentity, orientation: DisplayOrientation) -> String {
        orientation.swapsAxes ? identity.configurationKey + portraitRecordSuffix : identity.configurationKey
    }

    /// Marks the entry of a portrait display in "ConfiguredMonitors".
    public static let portraitRecordSuffix = "-portrait"

    /// Whether the default HiDPI mode still needs applying for this orientation, given the entries
    /// already recorded in `ConfiguredMonitors`.
    public func needsDefaultMode(_ orientation: DisplayOrientation, configured: [String]) -> Bool {
        !configured.contains(configuredModesKey(orientation))
    }
}

/// Per-monitor orientations as stored in user defaults: record key -> clockwise degrees.
///
/// Policy. Because there is no unique ID, this is a rule for identical panels, not a fact about hardware.
/// Two kinds of record, both in the single-monitor format:
/// - The identity record (`vendor-product-serial`) is the setting of a panel that is alone with its identity.
/// - A socket record (`…-headN`) is the setting of a panel on head N while identical panels (or a serial-0
///   panel) were attached.
///
/// Reads check the socket record first, then the identity record (serial 0 never reads the identity record).
/// So each panel keeps its socket's rotation through unplug, reorder and reconnect, and a socket with no
/// record shows the identity setting.
///
/// Writes:
/// - A change made while alone writes the identity record and removes only this head's socket record. That
///   record would otherwise shadow the new identity setting. Other heads' socket records are kept: they
///   belong to identical panels that may be plugged back in, and keep their rotation.
/// - A change made with an identical panel attached writes only this head's socket record. A serial-0
///   panel's standard is stored as no record; a serial panel's standard is stored explicitly (as 0), so an
///   identity record set later, while this panel is absent, cannot reach it.
/// - When a twin is first seen with its identical panel (`materializeTwins`), each twin's current orientation
///   is written to its socket record. A twin then keeps its own rotation while its twin is absent, and a
///   later change made alone does not reach it.
///
/// Limits, which no software can remove because EDID has no unique ID:
/// - A lone panel moved onto a port that still holds an identical twin's record reads that record, and a
///   change made there replaces it. The panel cannot be told apart from the twin that left the record.
/// - Identical panels that swap ports keep their rotations with the ports.
///
/// The stored format is the single-monitor format unchanged, so existing entries keep their meaning and
/// nothing needs migrating.
public struct OrientationPreferences: Equatable, Sendable {
    /// The user-defaults key holding `propertyList`. Absent on installs that never rotated a monitor.
    public static let defaultsKey = "MonitorOrientations"

    private var entries: [String: DisplayOrientation] = [:]

    public init() {}

    /// Reads stored values, dropping anything that is not a known orientation.
    public init(propertyList: Any?) {
        guard let dictionary = propertyList as? [String: Any] else { return }
        for (key, value) in dictionary {
            guard let degrees = value as? Int, let orientation = DisplayOrientation(rawValue: degrees) else {
                continue
            }
            entries[key] = orientation
        }
    }

    /// The orientation of `monitor`: its socket record, else its identity record, else standard.
    /// Needs no list of attached monitors, because the socket record always wins where it exists.
    public func orientation(for monitor: MonitorKey) -> DisplayOrientation {
        if let stored = entries[monitor.socketKey] { return stored }
        guard monitor.serial != 0 else { return .standard }
        return entries[monitor.identity] ?? .standard
    }

    /// Records `orientation` for `monitor`, given every monitor attached at once. See the policy above.
    public mutating func setOrientation(_ orientation: DisplayOrientation, for monitor: MonitorKey,
                                        among attached: [MonitorKey]) {
        if monitor.isAlone(among: attached) {
            // Only this head's record can shadow the new identity record, so only it is removed. The other
            // heads' records belong to identical panels that may come back and must keep their rotation.
            entries[monitor.socketKey] = nil
            entries[monitor.identity] = orientation == .standard ? nil : orientation
        } else if orientation == .standard && monitor.serial == 0 {
            // No identity record is ever read for serial 0, so standard needs no record.
            entries[monitor.socketKey] = nil
        } else {
            // Explicit, even for standard: see the policy above.
            entries[monitor.socketKey] = orientation
        }
    }

    /// Writes the socket record of each monitor in `recordable` that is one of identical twins (serial nonzero,
    /// not alone among `attached`) and has no socket record yet. The record holds the orientation the monitor
    /// has now, so later changes elsewhere cannot alter it. Changes nothing else; returns whether it wrote.
    /// `recordable` is the set of monitors whose display exists, so a failed attach writes nothing.
    @discardableResult
    public mutating func materializeTwins(_ recordable: [MonitorKey], among attached: [MonitorKey]) -> Bool {
        var wrote = false
        for monitor in recordable where monitor.serial != 0 && !monitor.isAlone(among: attached) {
            guard entries[monitor.socketKey] == nil else { continue }
            entries[monitor.socketKey] = orientation(for: monitor)
            wrote = true
        }
        return wrote
    }

    /// Single-monitor shorthand: the monitor is treated as alone with its identity.
    public subscript(monitor: MonitorKey) -> DisplayOrientation {
        get { orientation(for: monitor) }
        set { setOrientation(newValue, for: monitor, among: [monitor]) }
    }

    public var propertyList: [String: Int] { entries.mapValues(\.rawValue) }
}
