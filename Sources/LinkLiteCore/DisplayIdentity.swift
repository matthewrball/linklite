// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The vendor, product and serial a virtual display presents to macOS. macOS refuses a second
/// virtual display with the same three, and keys its saved per-display settings on them.
public struct DisplayIdentity: Hashable, Sendable {
    public var vendorID: UInt16
    public var productCode: UInt16
    public var serial: UInt32

    public init(vendorID: UInt16, productCode: UInt16, serial: UInt32) {
        self.vendorID = vendorID
        self.productCode = productCode
        self.serial = serial
    }

    /// Reads a key written by `configurationKey`; nil if it is malformed.
    public init?(configurationKey: String) {
        let parts = configurationKey.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 4, parts[2].count == 8,
              let vendor = UInt16(parts[0], radix: 16),
              let product = UInt16(parts[1], radix: 16),
              let serial = UInt32(parts[2], radix: 16) else { return nil }
        self.init(vendorID: vendor, productCode: product, serial: serial)
    }

    /// Entry in the ConfiguredMonitors default, which records the monitors already given the
    /// default mode once.
    public var configurationKey: String {
        String(format: "%04x-%04x-%08x", vendorID, productCode, serial)
    }

    /// A distinct identity for the monitor on `head` whose EDID reports `reported`, used when that
    /// identity is taken. Keeps the vendor and product and derives the serial from the reported
    /// serial and the head, so the same socket gets the same serial on every reconnect. Never
    /// returns `reported` or an identity in `taken`, and never a zero serial.
    public static func derived(from reported: DisplayIdentity, head: UInt8,
                               avoiding taken: Set<DisplayIdentity>) -> DisplayIdentity {
        // Terminates: `taken` is finite and each attempt hashes a different input.
        var attempt: UInt32 = 0
        while true {
            var candidate = reported
            candidate.serial = derivedSerial(reported.serial, head: head, attempt: attempt)
            if candidate.serial != 0, candidate != reported, !taken.contains(candidate) {
                return candidate
            }
            attempt += 1
        }
    }

    /// 32-bit FNV-1a over the serial, head and attempt (little-endian).
    static func derivedSerial(_ serial: UInt32, head: UInt8, attempt: UInt32) -> UInt32 {
        var bytes = withUnsafeBytes(of: serial.littleEndian, Array.init)
        bytes.append(head)
        bytes += withUnsafeBytes(of: attempt.littleEndian, Array.init)
        return bytes.reduce(0x811c_9dc5 as UInt32) { hash, byte in
            (hash ^ UInt32(byte)) &* 0x0100_0193
        }
    }
}
