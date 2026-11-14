// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Bounds for a monitor timing LinkLite will program and capture.
///
/// Keep these identical to `acceptable_desktop_mode` in `engine/src/edid.rs`. A dock EDID is
/// untrusted: a 1×1 timing or a refresh of hundreds of megahertz must not become a virtual display.
enum MonitorLimits {
    static let minEdge: UInt32 = 480
    static let maxEdge: UInt32 = 5120
    static let minHz: UInt32 = 1
    static let maxHz: UInt32 = 240

    static func accepts(width: UInt32, height: UInt32, refreshHz: UInt32) -> Bool {
        (minEdge...maxEdge).contains(width) && (minEdge...maxEdge).contains(height)
            && (minHz...maxHz).contains(refreshHz)
    }

    /// Printable ASCII only. An EDID name is device-controlled and is shown in System Settings,
    /// the menu, and the log.
    static func displayName(_ raw: String, fallback: String) -> String {
        let printable = raw.unicodeScalars.filter { scalar in
            scalar.value == 0x20 || (0x21...0x7e).contains(scalar.value)
        }
        let collapsed = String(String.UnicodeScalarView(printable))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return fallback }
        return String(collapsed.prefix(32))
    }
}
