// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What LinkLite remembers about identical monitors, persisted between launches. It holds only
/// identity keys already stored in ConfiguredMonitors and dock socket numbers: no names, no EDID
/// blobs and no per-display settings.
public struct DisplayIdentityRecords: Equatable, Sendable {
    /// For each reported identity (its configuration key), the socket that was last given the
    /// reported identity itself.
    public var owners: [String: UInt8]
    /// Reported identities (configuration keys) that have been seen on two sockets at once, so
    /// they are known to be identical monitors rather than one monitor that moved.
    public var twins: Set<String>
    /// The derived identity each (reported identity, socket) was given, by `assignmentKey`. Kept
    /// so that a socket keeps its serial across launches even when other displays come and go.
    /// Each value is a reservation: no other monitor is given it, whether or not its display is live.
    public var assignments: [String: String]
    /// Every reported identity (configuration key) ever claimed on any socket. A derived identity
    /// avoids all of them, so a generated serial never impersonates a monitor seen before.
    public var reported: Set<String>

    public init(owners: [String: UInt8] = [:], twins: Set<String> = [], assignments: [String: String] = [:],
                reported: Set<String> = []) {
        self.owners = owners
        self.twins = twins
        self.assignments = assignments
        self.reported = reported
    }

    /// Reads the default written by `propertyList`; anything missing or malformed reads as empty.
    public init(propertyList: Any?) {
        let dictionary = propertyList as? [String: Any] ?? [:]
        let rawOwners = dictionary["owners"] as? [String: Int] ?? [:]
        owners = rawOwners.compactMapValues { UInt8(exactly: $0) }
        twins = Set(dictionary["twins"] as? [String] ?? [])
        assignments = dictionary["assignments"] as? [String: String] ?? [:]
        reported = Set(dictionary["reported"] as? [String] ?? [])
    }

    /// A property-list value suitable for UserDefaults.
    public var propertyList: [String: Any] {
        ["owners": owners.mapValues { Int($0) }, "twins": twins.sorted(), "assignments": assignments,
         "reported": reported.sorted()]
    }

    /// The key under which the derived identity for `reported` on `head` is stored.
    public static func assignmentKey(for reported: DisplayIdentity, head: UInt8) -> String {
        "\(reported.configurationKey)@\(head)"
    }

    /// Reads a key written by `assignmentKey`: the reported identity and the socket it is for.
    static func parseAssignmentKey(_ key: String) -> (reported: DisplayIdentity, head: UInt8)? {
        guard let at = key.lastIndex(of: "@"),
              let reported = DisplayIdentity(configurationKey: String(key[..<at])),
              let head = UInt8(key[key.index(after: at)...]) else { return nil }
        return (reported, head)
    }

    /// Brings records written by an earlier rule into line with the current one, so that every
    /// reservation is honoured and no two claims can name the same identity. Deterministic: the same
    /// input always gives the same output, and applying it twice changes nothing more.
    ///
    /// - A malformed reservation, one that is not for the reported identity it names, one with a zero
    ///   serial, or one equal to its own reported identity is dropped. The socket gets a new serial
    ///   the next time it is claimed, as a malformed reservation always has.
    /// - Two reservations with the same identity: the one whose slot sorts first keeps it, and the
    ///   other is dropped. Two sockets cannot share one serial.
    /// - A reported identity that is also a reservation keeps only the reservation. The socket that
    ///   owned that identity loses ownership, so the monitor takes a separate stable identity when it is
    ///   next claimed. The reservation is kept because it is the one already waited for by its twin.
    ///   Settings may move here: macOS keys per-display settings by identity, so if that identity is in
    ///   ConfiguredMonitors, those settings now apply to the reserved socket's display, not to the former
    ///   owner, which starts again with a new identity. The records do not say which socket the settings
    ///   were made for, so this keeps the reservation rather than guessing. Only records written before
    ///   the current rules can hit this; the test `aConfiguredOwnerThatCollidesWithAReservation…` pins it.
    /// - Every owner, twin and reservation key is added to `reported`, so a historical identity is
    ///   never handed out as a generated one.
    ///
    /// Nothing here changes a live display: this runs when records are loaded, before any display exists.
    public func reconciled() -> DisplayIdentityRecords {
        var result = self
        var claimed = Set<DisplayIdentity>()
        var kept: [String: String] = [:]
        for slot in assignments.keys.sorted() {
            guard let value = assignments[slot],
                  let parsed = Self.parseAssignmentKey(slot),
                  let reservation = DisplayIdentity(configurationKey: value),
                  reservation.vendorID == parsed.reported.vendorID,
                  reservation.productCode == parsed.reported.productCode,
                  reservation.serial != 0, reservation != parsed.reported,
                  !claimed.contains(reservation) else { continue }
            claimed.insert(reservation)
            kept[slot] = value
        }
        result.assignments = kept
        let reservedKeys = Set(kept.values)
        result.owners = owners.filter { !reservedKeys.contains($0.key) }
        result.reported = reported
            .union(owners.keys).union(twins)
            .union(assignments.keys.compactMap { Self.parseAssignmentKey($0)?.reported.configurationKey })
        return result
    }
}
