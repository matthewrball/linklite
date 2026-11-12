// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// Per-head monitor rotation, pure rules only (no AppKit, CoreGraphics or USB). Vocabulary:
//   physical  the dock head's programmed mode raster, as the engine accepts it (e.g. 3840x2160).
//   logical   what the viewer sees upright: the virtual display macOS draws into and ScreenCaptureKit
//             captures (2160x3840 for a monitor turned on its side).

/// How far the monitor itself has been turned clockwise from its normal stand position. The raw value
/// is persisted in user defaults; never renumber it.
public enum DisplayOrientation: Int, CaseIterable, Sendable, Codable {
    case standard = 0
    /// The panel's top edge is now on the viewer's right.
    case turnedClockwise = 90
    case upsideDown = 180
    /// The panel's top edge is now on the viewer's left.
    case turnedCounterclockwise = 270

    /// Whether the logical (macOS) display is the panel's mode with width and height exchanged.
    public var swapsAxes: Bool { self == .turnedClockwise || self == .turnedCounterclockwise }
}

public struct PixelSize: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A size in millimetres (CGVirtualDisplayDescriptor.sizeInMillimeters).
public struct PhysicalSize: Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct PixelPoint: Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
    public var description: String { "(\(x), \(y))" }
}

/// Maps between a head's logical (upright, captured) raster and its physical (dock) raster.
public struct RotationGeometry: Hashable, Sendable {
    public let physical: PixelSize
    public let orientation: DisplayOrientation

    public init(physical: PixelSize, orientation: DisplayOrientation) {
        self.physical = physical
        self.orientation = orientation
    }

    public var logical: PixelSize {
        orientation.swapsAxes ? PixelSize(width: physical.height, height: physical.width) : physical
    }

    /// Where logical pixel (x, y) is stored in the physical raster.
    public func physicalPoint(x: Int, y: Int) -> PixelPoint {
        switch orientation {
        case .standard: PixelPoint(x: x, y: y)
        case .turnedClockwise: PixelPoint(x: y, y: physical.height - 1 - x)
        case .upsideDown: PixelPoint(x: physical.width - 1 - x, y: physical.height - 1 - y)
        case .turnedCounterclockwise: PixelPoint(x: physical.width - 1 - y, y: x)
        }
    }

    /// Which logical pixel physical pixel (x, y) shows. Inverse of `physicalPoint`.
    public func logicalPoint(x: Int, y: Int) -> PixelPoint {
        switch orientation {
        case .standard: PixelPoint(x: x, y: y)
        case .turnedClockwise: PixelPoint(x: physical.height - 1 - y, y: x)
        case .upsideDown: PixelPoint(x: physical.width - 1 - x, y: physical.height - 1 - y)
        case .turnedCounterclockwise: PixelPoint(x: y, y: physical.width - 1 - x)
        }
    }

    /// The virtual display's mode sizes, given the sizes an unrotated head would offer.
    public func logicalModes(_ physicalModes: [PixelSize]) -> [PixelSize] {
        orientation.swapsAxes ? physicalModes.map { PixelSize(width: $0.height, height: $0.width) } : physicalModes
    }

    /// The virtual display's size in millimetres, from the panel's EDID size.
    public func logicalMillimeters(width: Double, height: Double) -> PhysicalSize {
        orientation.swapsAxes ? PhysicalSize(width: height, height: width) : PhysicalSize(width: width, height: height)
    }
}

/// Rotates a whole captured logical BGRA frame into a persistent physical BGRA raster.
public enum FrameRotator {
    /// Writes the whole of `source` (logical, `sourceStride` bytes per row) into `destination` (physical,
    /// `destinationStride` bytes per row), rotated. Row padding in `destination` is left untouched.
    /// Returns false, writing nothing, if a stride is below one row or a buffer is too small.
    public static func rotate(source: UnsafeRawBufferPointer, sourceStride: Int,
                              into destination: UnsafeMutableRawBufferPointer, destinationStride: Int,
                              geometry: RotationGeometry) -> Bool {
        let logical = geometry.logical, physical = geometry.physical
        guard let sourceSpan = span(stride: sourceStride, width: logical.width, height: logical.height),
              let destinationSpan = span(stride: destinationStride, width: physical.width, height: physical.height),
              source.count >= sourceSpan, destination.count >= destinationSpan,
              let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress
        else { return false }

        // Each physical row walks one line of the logical frame. Moving one physical pixel to the right
        // moves one logical step, a constant byte offset for the whole row: +4 unrotated, -4 upside down,
        // +stride turned clockwise, -stride turned counterclockwise. So the inner loop is a load and a
        // store with no per-pixel coordinate arithmetic.
        let step: Int
        switch geometry.orientation {
        case .standard: step = 4
        case .upsideDown: step = -4
        case .turnedClockwise: step = sourceStride
        case .turnedCounterclockwise: step = -sourceStride
        }
        for py in 0..<physical.height {
            let start = geometry.logicalPoint(x: 0, y: py)
            var offset = start.y * sourceStride + start.x * 4
            let row = destinationBase + py * destinationStride
            for px in 0..<physical.width {
                row.storeBytes(of: sourceBase.loadUnaligned(fromByteOffset: offset, as: UInt32.self),
                               toByteOffset: px * 4, as: UInt32.self)
                offset += step
            }
        }
        return true
    }

    /// Bytes an image spans without trailing row padding, or nil if the dimensions are empty, a stride is
    /// below one row, or the span is not representable in `Int`.
    public static func span(stride: Int, width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow, stride >= rowBytes else { return nil }
        let (lastRows, rowsOverflow) = stride.multipliedReportingOverflow(by: height - 1)
        guard !rowsOverflow else { return nil }
        let (total, totalOverflow) = lastRows.addingReportingOverflow(rowBytes)
        return totalOverflow ? nil : total
    }
}
