// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import LinkLiteRotation

// Angle, direction, odd-size and stride coverage for the per-head rotation mapping. Every frame
// here is asymmetric and often odd-sized, so a transposed, mirrored or off-by-one mapping moves
// visible pixels.

/// A BGRA pixel that encodes its own logical coordinates, so a misplaced pixel names its origin.
private func tag(_ x: Int, _ y: Int, salt: UInt8 = 0) -> [UInt8] {
    [UInt8(x & 0xff), UInt8(y & 0xff), UInt8(((x >> 8) & 0xf) | ((y >> 8) & 0xf) << 4) ^ salt, 255]
}

/// A BGRA image whose every pixel is `tag(x, y)`. Row padding (when `stride` is larger) is 0xEE.
private func taggedImage(width: Int, height: Int, stride: Int? = nil, salt: UInt8 = 0) -> [UInt8] {
    let stride = stride ?? width * 4
    var image = [UInt8](repeating: 0xEE, count: stride * height)
    for y in 0..<height {
        for x in 0..<width {
            image.replaceSubrange(y * stride + x * 4..<y * stride + x * 4 + 4, with: tag(x, y, salt: salt))
        }
    }
    return image
}

private func pixel(_ image: [UInt8], stride: Int, _ x: Int, _ y: Int) -> [UInt8] {
    Array(image[y * stride + x * 4..<y * stride + x * 4 + 4])
}

/// Rotates a whole tightly packed logical frame into a fresh tightly packed physical raster.
private func rotateWhole(_ logical: [UInt8], _ geometry: RotationGeometry) -> [UInt8]? {
    var physical = [UInt8](repeating: 0, count: geometry.physical.width * geometry.physical.height * 4)
    let ok = logical.withUnsafeBytes { source in
        physical.withUnsafeMutableBytes { destination in
            FrameRotator.rotate(source: source, sourceStride: geometry.logical.width * 4,
                                into: destination, destinationStride: geometry.physical.width * 4,
                                geometry: geometry)
        }
    }
    return ok ? physical : nil
}

// MARK: - Orientation definitions

@Test func orientationRawValuesAreStableClockwiseDegrees() {
    // Persisted in user defaults; renumbering would silently turn users' monitors differently.
    #expect(DisplayOrientation.allCases.map(\.rawValue) == [0, 90, 180, 270])
    #expect(DisplayOrientation(rawValue: 45) == nil)
    #expect(!DisplayOrientation.standard.swapsAxes)
    #expect(!DisplayOrientation.upsideDown.swapsAxes)
    #expect(DisplayOrientation.turnedClockwise.swapsAxes)
    #expect(DisplayOrientation.turnedCounterclockwise.swapsAxes)
}

@Test func logicalGeometrySwapsOnlyForPortrait() {
    let panel = PixelSize(width: 3840, height: 2160)
    #expect(RotationGeometry(physical: panel, orientation: .standard).logical == panel)
    #expect(RotationGeometry(physical: panel, orientation: .upsideDown).logical == panel)
    #expect(RotationGeometry(physical: panel, orientation: .turnedClockwise).logical
        == PixelSize(width: 2160, height: 3840))
    #expect(RotationGeometry(physical: panel, orientation: .turnedCounterclockwise).logical
        == PixelSize(width: 2160, height: 3840))
}

// MARK: - Direction

@Test func panelCornersTurnTheWayTheMonitorTurns() {
    // A 5x3 panel (odd, asymmetric). Its top-left corner is physical (0, 0).
    let panel = PixelSize(width: 5, height: 3)
    let topLeft = PixelPoint(x: 0, y: 0)
    let topRight = PixelPoint(x: 4, y: 0)

    // Turned clockwise, the panel's top-left corner moves to the viewer's top-right.
    let cw = RotationGeometry(physical: panel, orientation: .turnedClockwise)
    #expect(cw.logicalPoint(x: topLeft.x, y: topLeft.y) == PixelPoint(x: cw.logical.width - 1, y: 0))

    // Turned counterclockwise, the top-right corner moves to the viewer's top-left.
    let ccw = RotationGeometry(physical: panel, orientation: .turnedCounterclockwise)
    #expect(ccw.logicalPoint(x: topRight.x, y: topRight.y) == PixelPoint(x: 0, y: 0))
    // ...and the top-left corner moves to the viewer's bottom-left.
    #expect(ccw.logicalPoint(x: topLeft.x, y: topLeft.y) == PixelPoint(x: 0, y: ccw.logical.height - 1))

    // Upside down, the top-left corner moves to the bottom-right.
    let flipped = RotationGeometry(physical: panel, orientation: .upsideDown)
    #expect(flipped.logicalPoint(x: topLeft.x, y: topLeft.y) == PixelPoint(x: 4, y: 2))
}

/// Hand-worked 3x2 panel. The logical image is what the viewer sees upright.
///   portrait (2x3)   a b      landscape (3x2)  a b c
///                    c d                       d e f
///                    e f
private func handWorked(_ orientation: DisplayOrientation) -> (logical: [Character], physical: [Character]) {
    switch orientation {
    case .standard: (Array("abcdef"), Array("abcdef"))
    // Panel top edge now on the viewer's right: its first row runs down the right-hand column.
    case .turnedClockwise: (Array("abcdef"), Array("bdface"))
    // Panel top edge now on the viewer's left: its first row runs up the left-hand column.
    case .turnedCounterclockwise: (Array("abcdef"), Array("ecafdb"))
    case .upsideDown: (Array("abcdef"), Array("fedcba"))
    }
}

@Test(arguments: DisplayOrientation.allCases)
func pixelMappingMatchesHandWorkedPanel(_ orientation: DisplayOrientation) {
    let geometry = RotationGeometry(physical: PixelSize(width: 3, height: 2), orientation: orientation)
    let (logical, expected) = handWorked(orientation)
    var physical = [Character](repeating: "?", count: 6)
    for ly in 0..<geometry.logical.height {
        for lx in 0..<geometry.logical.width {
            let p = geometry.physicalPoint(x: lx, y: ly)
            physical[p.y * 3 + p.x] = logical[ly * geometry.logical.width + lx]
        }
    }
    #expect(physical == expected)
}

@Test(arguments: DisplayOrientation.allCases, [PixelSize(width: 5, height: 3), PixelSize(width: 4, height: 7)])
func mappingIsABijectionInBothDirectionsOnOddSizes(_ orientation: DisplayOrientation, _ panel: PixelSize) {
    let geometry = RotationGeometry(physical: panel, orientation: orientation)
    var seen = Set<PixelPoint>()
    for ly in 0..<geometry.logical.height {
        for lx in 0..<geometry.logical.width {
            let p = geometry.physicalPoint(x: lx, y: ly)
            #expect((0..<panel.width).contains(p.x) && (0..<panel.height).contains(p.y))
            #expect(geometry.logicalPoint(x: p.x, y: p.y) == PixelPoint(x: lx, y: ly))
            seen.insert(p)
        }
    }
    #expect(seen.count == panel.width * panel.height)
}

// MARK: - Frames

@Test(arguments: DisplayOrientation.allCases, [PixelSize(width: 5, height: 3), PixelSize(width: 37, height: 21)])
func wholeFrameRotationMatchesThePixelMapping(_ orientation: DisplayOrientation, _ panel: PixelSize) throws {
    let geometry = RotationGeometry(physical: panel, orientation: orientation)
    let logical = taggedImage(width: geometry.logical.width, height: geometry.logical.height)
    let physical = try #require(rotateWhole(logical, geometry))
    for py in 0..<panel.height {
        for px in 0..<panel.width {
            let l = geometry.logicalPoint(x: px, y: py)
            #expect(pixel(physical, stride: panel.width * 4, px, py) == tag(l.x, l.y), "physical (\(px), \(py))")
        }
    }
}

@Test(arguments: DisplayOrientation.allCases)
func paddedStridesAreHonouredAndDestinationPaddingIsUntouched(_ orientation: DisplayOrientation) {
    let geometry = RotationGeometry(physical: PixelSize(width: 5, height: 3), orientation: orientation)
    let sourceStride = geometry.logical.width * 4 + 12
    let destinationStride = geometry.physical.width * 4 + 8
    let logical = taggedImage(width: geometry.logical.width, height: geometry.logical.height, stride: sourceStride)
    var physical = [UInt8](repeating: 0xAB, count: destinationStride * geometry.physical.height)
    let ok = logical.withUnsafeBytes { source in
        physical.withUnsafeMutableBytes { destination in
            FrameRotator.rotate(source: source, sourceStride: sourceStride, into: destination,
                                destinationStride: destinationStride, geometry: geometry)
        }
    }
    #expect(ok)
    for py in 0..<geometry.physical.height {
        for px in 0..<geometry.physical.width {
            let l = geometry.logicalPoint(x: px, y: py)
            #expect(pixel(physical, stride: destinationStride, px, py) == tag(l.x, l.y))
        }
        let padding = physical[py * destinationStride + geometry.physical.width * 4..<(py + 1) * destinationStride]
        #expect(padding.allSatisfy { $0 == 0xAB })
    }
}

@Test func unrotatedFrameIsCopiedRowForRow() throws {
    // Standard orientation must be a plain copy; this is the path every existing user runs.
    let geometry = RotationGeometry(physical: PixelSize(width: 5, height: 3), orientation: .standard)
    let logical = taggedImage(width: 5, height: 3)
    #expect(try #require(rotateWhole(logical, geometry)) == logical)
}

@Test func undersizedAndUnderstridedBuffersAreRejectedWithoutWriting() {
    let geometry = RotationGeometry(physical: PixelSize(width: 4, height: 2), orientation: .turnedClockwise)
    let logical = taggedImage(width: 2, height: 4)
    var physical = [UInt8](repeating: 0x11, count: 4 * 2 * 4)
    var shortDestination = [UInt8](repeating: 0x11, count: 4 * 2 * 4 - 1)
    let shortSource = Array(logical.dropLast())
    let results: [Bool] = [
        shortSource.withUnsafeBytes { s in physical.withUnsafeMutableBytes { d in
            FrameRotator.rotate(source: s, sourceStride: 8, into: d, destinationStride: 16, geometry: geometry) } },
        logical.withUnsafeBytes { s in shortDestination.withUnsafeMutableBytes { d in
            FrameRotator.rotate(source: s, sourceStride: 8, into: d, destinationStride: 16, geometry: geometry) } },
        logical.withUnsafeBytes { s in physical.withUnsafeMutableBytes { d in
            FrameRotator.rotate(source: s, sourceStride: 4, into: d, destinationStride: 16, geometry: geometry) } },
    ]
    #expect(results == [false, false, false])
    #expect(physical.allSatisfy { $0 == 0x11 })
    #expect(shortDestination.allSatisfy { $0 == 0x11 })
}

@Test func spanIsCheckedAndRepresentable() {
    #expect(FrameRotator.span(stride: 8, width: 2, height: 3) == 24)
    #expect(FrameRotator.span(stride: 4, width: Int.max, height: 1) == nil)
    #expect(FrameRotator.span(stride: Int.max, width: 1, height: 2) == nil)
    #expect(FrameRotator.span(stride: 4, width: 1, height: Int.max) == nil)
    #expect(FrameRotator.span(stride: Int.max / 2 + 1, width: 1, height: 3) == nil)
    #expect(FrameRotator.span(stride: 4, width: 1, height: 0) == nil)
}

@Test func overflowingGeometryIsRejectedWithoutWriting() {
    let wide = RotationGeometry(physical: PixelSize(width: Int.max, height: 1), orientation: .standard)
    let tall = RotationGeometry(physical: PixelSize(width: 2, height: Int.max), orientation: .turnedClockwise)
    let source = [UInt8](repeating: 0x22, count: 16)
    for geometry in [wide, tall] {
        var destination = [UInt8](repeating: 0x11, count: 16)
        let ok = source.withUnsafeBytes { s in
            destination.withUnsafeMutableBytes { d in
                FrameRotator.rotate(source: s, sourceStride: 8, into: d, destinationStride: 8, geometry: geometry)
            }
        }
        #expect(!ok)
        #expect(destination.allSatisfy { $0 == 0x11 })
    }
}

// MARK: - Virtual display shape

@Test func virtualDisplayModesAndSizeFollowTheOrientation() {
    let native = PixelSize(width: 3840, height: 2160)
    let modes = [native, PixelSize(width: 2560, height: 1440)]
    let portrait = RotationGeometry(physical: native, orientation: .turnedCounterclockwise)
    #expect(portrait.logicalModes(modes) == [PixelSize(width: 2160, height: 3840), PixelSize(width: 1440, height: 2560)])
    #expect(portrait.logicalMillimeters(width: 597, height: 336) == PhysicalSize(width: 336, height: 597))
    let flipped = RotationGeometry(physical: native, orientation: .upsideDown)
    #expect(flipped.logicalModes(modes) == modes)
    #expect(flipped.logicalMillimeters(width: 597, height: 336) == PhysicalSize(width: 597, height: 336))
}
