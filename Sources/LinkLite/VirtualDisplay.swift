// SPDX-License-Identifier: GPL-2.0-or-later

import CDLLite
import CoreGraphics
import Foundation
import LinkLiteCore
import LinkLiteRotation
import os

private let log = Logger(subsystem: "com.ball.linklite", category: "display")

/// A macOS display backed by the private CGVirtualDisplay API, shaped like one dock monitor, turned to `orientation`.
/// The display exists while this object is alive.
@MainActor
final class VirtualDisplay {
    struct CreationError: Error, CustomStringConvertible {
        var description: String
    }

    /// Fallback physical size (27" 16:9) when the monitor's EDID reports none.
    static let fallbackSizeMillimeters = CGSize(width: 597, height: 336)

    /// Read from any isolation: a display's ID never changes, and the capture's start reads it off the main actor.
    nonisolated let displayID: CGDirectDisplayID
    /// The vendor, product and serial macOS knows this display by. Usually the monitor's own;
    /// see `DisplayIdentityAllocator` for when it differs.
    let identity: DisplayIdentity
    /// The display exists while this object does. The identity lease is attached to `display` itself
    /// (see `DisplayLease`), so the identity is free only once that display has been deallocated,
    /// whatever order this object's properties are released in.
    private let display: CGVirtualDisplay

    /// Creates the display with the claimed identity, shaped for `orientation`: a portrait head gets a portrait
    /// display (its modes and millimetres with width and height exchanged). `onTerminated` runs on the main queue if
    /// the window server removes it.
    init(monitor: HeadMonitor, orientation: DisplayOrientation = .standard, claim: IdentityClaim,
         onTerminated: @escaping @MainActor () -> Void) throws {
        let identity = claim.identity
        let geometry = RotationGeometry(physical: PixelSize(width: Int(monitor.width), height: Int(monitor.height)),
                                        orientation: orientation)
        let modes = geometry.logicalModes(
            Self.modeSizes(nativeWidth: monitor.width, nativeHeight: monitor.height).map {
                PixelSize(width: Int($0.width), height: Int($0.height))
            }
        ).map { (width: UInt32($0.width), height: UInt32($0.height)) }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = monitor.name
        descriptor.maxPixelsWide = modes.map(\.width).max() ?? UInt32(geometry.logical.width)
        descriptor.maxPixelsHigh = modes.map(\.height).max() ?? UInt32(geometry.logical.height)
        let millimeters = monitor.widthMillimeters > 0 && monitor.heightMillimeters > 0
            ? geometry.logicalMillimeters(width: Double(monitor.widthMillimeters), height: Double(monitor.heightMillimeters))
            : geometry.logicalMillimeters(width: Double(Self.fallbackSizeMillimeters.width),
                                          height: Double(Self.fallbackSizeMillimeters.height))
        descriptor.sizeInMillimeters = CGSize(width: millimeters.width, height: millimeters.height)
        descriptor.vendorID = UInt32(identity.vendorID)
        descriptor.productID = UInt32(identity.productCode)
        descriptor.serialNum = identity.serial
        // sRGB primaries: macOS renders sRGB, capture asks for sRGB, and the dock forwards the
        // pixels untouched, so no gamut conversion happens anywhere in the chain.
        descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.terminationHandler = { _, _ in
            MainActor.assumeIsolated { onTerminated() }
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw CreationError(description: "CGVirtualDisplay refused \(monitor.name)")
        }
        // Attached before anything else can fail: if setup throws below, `display` is released on
        // the way out, and the identity is released with it, never before.
        DisplayLease.attach(claim.lease, to: display)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        let refresh = Double(monitor.effectiveRefreshHz)
        settings.modes = modes.map {
            CGVirtualDisplayMode(width: $0.width, height: $0.height, refreshRate: refresh)
        }
        guard display.apply(settings) else {
            throw CreationError(description: "CGVirtualDisplay rejected the mode list for \(monitor.name)")
        }

        self.display = display
        self.identity = identity
        displayID = display.displayID
        log.info("Created virtual display \(self.displayID) for \(monitor.name, privacy: .public) \(orientation.rawValue)°")
    }

    /// Sizes handed to CGVirtualDisplay. With hiDPI on, macOS can list each one as a 1x mode and
    /// as a "looks like" mode at half its size. For a 3840x2160 panel this yields native 1x plus
    /// "looks like" 1920x1080 (backing = native), 2048x1152, 2304x1296 and 2560x1440 (backing up
    /// to 5120x2880, which capture scales back down to native).
    ///
    /// The 2/3 and 1/2 entries (2560x1440 and 1920x1080 1x) look redundant but are load-bearing:
    /// on macOS 26, without them the window server silently drops every HiDPI variant above
    /// 960x540 from the list.
    static func modeSizes(nativeWidth: UInt32, nativeHeight: UInt32) -> [(width: UInt32, height: UInt32)] {
        let scaled: [(UInt32, UInt32)] = [(4, 3), (6, 5), (16, 15), (2, 3), (1, 2)].map { numerator, denominator in
            (even(nativeWidth * numerator / denominator), even(nativeHeight * numerator / denominator))
        }
        return [(nativeWidth, nativeHeight)] + scaled
    }

    private static func even(_ value: UInt32) -> UInt32 { value & ~1 }

    /// Every mode macOS offers for this display, including HiDPI duplicates.
    func availableModes() -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
    }

    /// The default: HiDPI "looks like" half of native (1920x1080 on a 4K panel). Its backing store
    /// is exactly the panel's native size, so capture is 1:1 and text stays as sharp as it gets.
    func defaultMode(nativeWidth: UInt32, nativeHeight: UInt32) -> CGDisplayMode? {
        availableModes().first {
            $0.pixelWidth == Int(nativeWidth) && $0.pixelHeight == Int(nativeHeight)
                && $0.width * 2 == $0.pixelWidth && $0.height * 2 == $0.pixelHeight
        }
    }

    /// Switches to `mode` and records it in the user's display preferences.
    @discardableResult
    func setMode(_ mode: CGDisplayMode) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result != .success {
            log.error("Setting mode \(mode.width)x\(mode.height) on display \(self.displayID) failed: \(result.rawValue)")
        }
        return result == .success
    }
}
