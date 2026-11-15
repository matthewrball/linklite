// SPDX-License-Identifier: GPL-2.0-or-later

import Accelerate
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

/// A rectangle of whole pixels: columns `x..<x + width`, rows `y..<y + height`.
public struct PixelRect: Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var description: String { "(\(x), \(y), \(width)x\(height))" }

    /// The part of this rectangle inside a `bounds`-sized raster, or nil if none is. Never overflows.
    public func clamped(to bounds: PixelSize) -> PixelRect? {
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        // width and height are positive, so a sum can only overflow upwards, past every bound.
        let (right, rightOverflow) = x.addingReportingOverflow(width)
        let (bottom, bottomOverflow) = y.addingReportingOverflow(height)
        let x0 = max(x, 0), y0 = max(y, 0)
        let x1 = rightOverflow ? bounds.width : min(right, bounds.width)
        let y1 = bottomOverflow ? bounds.height : min(bottom, bounds.height)
        guard x0 < x1, y0 < y1 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Whether this rectangle is non-empty and lies wholly inside a `bounds`-sized raster.
    public func isInside(_ bounds: PixelSize) -> Bool {
        width > 0 && height > 0 && x >= 0 && y >= 0
            && width <= bounds.width && height <= bounds.height
            && x <= bounds.width - width && y <= bounds.height - height
    }
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

    /// Where a logical rectangle is stored in the physical raster, after clamping it to the logical raster.
    /// Nil if no part of it is inside. Every pixel of the result is `physicalPoint` of one pixel of the
    /// clamped rectangle, and the reverse.
    public func physicalRect(_ rect: PixelRect) -> PixelRect? {
        guard let rect = rect.clamped(to: logical) else { return nil }
        return Self.bounding(physicalPoint(x: rect.x, y: rect.y),
                             physicalPoint(x: rect.x + rect.width - 1, y: rect.y + rect.height - 1))
    }

    /// Which logical rectangle a physical rectangle inside the physical raster shows.
    func logicalRect(ofPhysical rect: PixelRect) -> PixelRect {
        Self.bounding(logicalPoint(x: rect.x, y: rect.y),
                      logicalPoint(x: rect.x + rect.width - 1, y: rect.y + rect.height - 1))
    }

    /// The whole logical pixels a damage rectangle (in logical pixels, as ScreenCaptureKit reports it) touches,
    /// rounded outwards and clamped to the logical raster. Nil if it is empty, inverted, not finite, or outside.
    public func logicalRect(minX: Double, minY: Double, maxX: Double, maxY: Double) -> PixelRect? {
        guard let (x, width) = Self.pixelSpan(minX, maxX, limit: logical.width),
              let (y, height) = Self.pixelSpan(minY, maxY, limit: logical.height)
        else { return nil }
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    /// The rectangle with opposite corner pixels `a` and `b`.
    private static func bounding(_ a: PixelPoint, _ b: PixelPoint) -> PixelRect {
        PixelRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)
    }

    /// The whole pixels `low..<high` touches within `0..<limit`, as (start, length).
    private static func pixelSpan(_ low: Double, _ high: Double, limit: Int) -> (Int, Int)? {
        guard low.isFinite, high.isFinite, low < high, limit > 0 else { return nil }
        let start = max(low.rounded(.down), 0), end = high.rounded(.up), bound = Double(limit)
        guard start < bound, end > 0 else { return nil }
        // `start` is a whole number below `bound` (at most 2^63), so it converts exactly.
        let first = Int(start), last = end >= bound ? limit : Int(end)
        return first < last ? (first, last - first) : nil
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

/// Rotates a captured logical BGRA frame, whole or in part, into a persistent physical BGRA raster.
public enum FrameRotator {
    /// Writes the whole of `source` (logical, `sourceStride` bytes per row) into `destination` (physical,
    /// `destinationStride` bytes per row), rotated. Row padding in `destination` is left untouched.
    /// Returns false, writing nothing, if a stride is below one row or a buffer is too small.
    public static func rotate(source: UnsafeRawBufferPointer, sourceStride: Int,
                              into destination: UnsafeMutableRawBufferPointer, destinationStride: Int,
                              geometry: RotationGeometry) -> Bool {
        rotate(source: source, sourceStride: sourceStride, into: destination, destinationStride: destinationStride,
               geometry: geometry,
               region: PixelRect(x: 0, y: 0, width: geometry.physical.width, height: geometry.physical.height))
    }

    /// Writes only `region` of the physical raster (from `RotationGeometry.physicalRect`), rotated from the
    /// logical pixels it shows. Every other byte of `destination` is left untouched, so a persistent raster keeps
    /// the previous frame outside the region. The pixels written are exactly those a whole-frame rotation writes
    /// there. Both buffers must hold whole frames. Returns false, writing nothing, if a stride is below one row,
    /// a buffer is too small, or `region` is empty or not wholly inside the physical raster.
    public static func rotate(source: UnsafeRawBufferPointer, sourceStride: Int,
                              into destination: UnsafeMutableRawBufferPointer, destinationStride: Int,
                              geometry: RotationGeometry, region: PixelRect) -> Bool {
        let logical = geometry.logical, physical = geometry.physical
        guard let sourceSpan = span(stride: sourceStride, width: logical.width, height: logical.height),
              let destinationSpan = span(stride: destinationStride, width: physical.width, height: physical.height),
              source.count >= sourceSpan, destination.count >= destinationSpan, region.isInside(physical),
              let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress
        else { return false }

        let bands = bandCount(region)
        if bands == 1 {
            return rotateBand(source: sourceBase, sourceStride: sourceStride, destination: destinationBase,
                              destinationStride: destinationStride, geometry: geometry, band: region)
        }
        // Large regions are split into row bands of the physical raster. Bands write disjoint rows, so they
        // run in parallel. Results are kept on the stack: nothing is allocated per frame.
        return withUnsafeTemporaryAllocation(of: Bool.self, capacity: bands) { results in
            DispatchQueue.concurrentPerform(iterations: bands) { index in
                let top = region.y + region.height * index / bands
                let bottom = region.y + region.height * (index + 1) / bands
                results[index] = rotateBand(
                    source: sourceBase, sourceStride: sourceStride, destination: destinationBase,
                    destinationStride: destinationStride, geometry: geometry,
                    band: PixelRect(x: region.x, y: top, width: region.width, height: bottom - top))
            }
            return results.allSatisfy { $0 }
        }
    }

    /// Regions with at least this many pixels are rotated in parallel row bands.
    static let parallelPixels = 1 << 19
    /// The most bands a region is split into, and the fewest rows a band has.
    static let maximumBands = min(8, ProcessInfo.processInfo.activeProcessorCount)
    static let minimumBandRows = 64

    /// How many row bands `region` (inside the physical raster) is rotated in. 1 means on the calling thread.
    static func bandCount(_ region: PixelRect) -> Int {
        let (pixels, overflow) = region.width.multipliedReportingOverflow(by: region.height)
        guard overflow || pixels >= parallelPixels else { return 1 }
        return max(1, min(maximumBands, region.height / minimumBandRows))
    }

    /// Rotates one validated band with vImage, which measured about 3x faster than a blocked scalar transpose
    /// (docs/DISPLAY_ROTATION.md). The band's logical rectangle is rotated into the band; nothing else is written.
    private static func rotateBand(source: UnsafeRawPointer, sourceStride: Int,
                                   destination: UnsafeMutableRawPointer, destinationStride: Int,
                                   geometry: RotationGeometry, band: PixelRect) -> Bool {
        let from = geometry.logicalRect(ofPhysical: band)
        var sourceBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source + from.y * sourceStride + from.x * 4),
            height: vImagePixelCount(from.height), width: vImagePixelCount(from.width), rowBytes: sourceStride)
        var destinationBuffer = vImage_Buffer(
            data: destination + band.y * destinationStride + band.x * 4,
            height: vImagePixelCount(band.height), width: vImagePixelCount(band.width), rowBytes: destinationStride)
        // vImage names the turn applied to the picture. It is the opposite of the monitor's turn.
        let turn: Int
        switch geometry.orientation {
        case .standard: turn = kRotate0DegreesClockwise
        case .turnedClockwise: turn = kRotate90DegreesCounterClockwise
        case .upsideDown: turn = kRotate180DegreesClockwise
        case .turnedCounterclockwise: turn = kRotate90DegreesClockwise
        }
        // A 90° turn fills the whole destination, so the background colour is never used.
        let background: Pixel_8888 = (0, 0, 0, 0)
        return withUnsafePointer(to: background) { colour in
            colour.withMemoryRebound(to: UInt8.self, capacity: 4) { colour in
                vImageRotate90_ARGB8888(&sourceBuffer, &destinationBuffer, UInt8(turn), colour,
                                        vImage_Flags(kvImageDoNotTile)) == kvImageNoError
            }
        }
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
