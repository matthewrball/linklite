// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import LinkLiteRotation

// Damage on a rotated head: ScreenCaptureKit's logical damage rectangles are mapped to physical rectangles,
// and only those regions are rotated into the persistent physical raster. A region rotation must write exactly
// what a whole-frame rotation writes there, and nothing anywhere else.

/// A small deterministic generator, so a failing frame can be reproduced.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func randomBytes(_ count: Int, _ rng: inout SplitMix64) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    for index in stride(from: 0, to: count, by: 8) {
        withUnsafeBytes(of: rng.next()) { word in
            for offset in 0..<min(8, count - index) { bytes[index + offset] = word[offset] }
        }
    }
    return bytes
}

private func allRects(in size: PixelSize) -> [PixelRect] {
    var rects: [PixelRect] = []
    for y in 0..<size.height {
        for x in 0..<size.width {
            for height in 1...(size.height - y) {
                for width in 1...(size.width - x) {
                    rects.append(PixelRect(x: x, y: y, width: width, height: height))
                }
            }
        }
    }
    return rects
}

private func rotate(_ source: [UInt8], sourceStride: Int, into destination: inout [UInt8], destinationStride: Int,
                    _ geometry: RotationGeometry, region: PixelRect? = nil) -> Bool {
    source.withUnsafeBytes { s in
        destination.withUnsafeMutableBytes { d in
            if let region {
                FrameRotator.rotate(source: s, sourceStride: sourceStride, into: d, destinationStride: destinationStride,
                                    geometry: geometry, region: region)
            } else {
                FrameRotator.rotate(source: s, sourceStride: sourceStride, into: d, destinationStride: destinationStride,
                                    geometry: geometry)
            }
        }
    }
}

/// The physical raster, built pixel by pixel from `logicalPoint` (independent of FrameRotator). Row padding is 0xAB.
private func mapped(_ source: [UInt8], sourceStride: Int, destinationStride: Int, _ geometry: RotationGeometry) -> [UInt8] {
    var physical = [UInt8](repeating: 0xAB, count: destinationStride * geometry.physical.height)
    source.withUnsafeBytes { s in
        physical.withUnsafeMutableBytes { d in
            for py in 0..<geometry.physical.height {
                for px in 0..<geometry.physical.width {
                    let l = geometry.logicalPoint(x: px, y: py)
                    d.storeBytes(of: s.loadUnaligned(fromByteOffset: l.y * sourceStride + l.x * 4, as: UInt32.self),
                                 toByteOffset: py * destinationStride + px * 4, as: UInt32.self)
                }
            }
        }
    }
    return physical
}

private func contains(_ rect: PixelRect, _ x: Int, _ y: Int) -> Bool {
    x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
}

// MARK: - Rectangle mapping

@Test(arguments: DisplayOrientation.allCases,
      [PixelSize(width: 5, height: 3), PixelSize(width: 4, height: 7), PixelSize(width: 9, height: 6)])
func physicalRectIsExactlyTheMappedPixels(_ orientation: DisplayOrientation, _ panel: PixelSize) throws {
    let geometry = RotationGeometry(physical: panel, orientation: orientation)
    var failures: [String] = []
    for rect in allRects(in: geometry.logical) {
        guard let result = geometry.physicalRect(rect) else {
            failures.append("\(rect) mapped to nothing")
            continue
        }
        // Each logical corner pixel lands on a corner pixel of the result, and the four are its four corners.
        let corners = [(rect.x, rect.y), (rect.x + rect.width - 1, rect.y),
                       (rect.x, rect.y + rect.height - 1), (rect.x + rect.width - 1, rect.y + rect.height - 1)]
            .map { geometry.physicalPoint(x: $0.0, y: $0.1) }
        let expectedCorners = [(result.x, result.y), (result.x + result.width - 1, result.y),
                               (result.x, result.y + result.height - 1),
                               (result.x + result.width - 1, result.y + result.height - 1)]
            .map { PixelPoint(x: $0.0, y: $0.1) }
        if Set(corners) != Set(expectedCorners) { failures.append("\(rect) corners \(corners) vs \(result)") }
        // Same area, and every pixel inside: with a bijective point mapping, the rectangle is exact.
        if result.width * result.height != rect.width * rect.height { failures.append("\(rect) area vs \(result)") }
        for y in rect.y..<rect.y + rect.height {
            for x in rect.x..<rect.x + rect.width {
                let p = geometry.physicalPoint(x: x, y: y)
                if !contains(result, p.x, p.y) { failures.append("\(rect): (\(x), \(y)) -> \(p) outside \(result)") }
            }
        }
        if !result.isInside(panel) { failures.append("\(result) outside the panel") }
    }
    #expect(failures.isEmpty, "\(failures.prefix(5))")
}

@Test(arguments: DisplayOrientation.allCases)
func physicalRectClampsToTheLogicalRasterWithoutOverflow(_ orientation: DisplayOrientation) throws {
    let geometry = RotationGeometry(physical: PixelSize(width: 7, height: 4), orientation: orientation)
    let logical = geometry.logical
    // Partly outside: only the inside part is mapped.
    let clampedCases: [(PixelRect, PixelRect)] = [
        (PixelRect(x: -2, y: -3, width: 4, height: 5), PixelRect(x: 0, y: 0, width: 2, height: 2)),
        (PixelRect(x: 1, y: 1, width: 100, height: 100),
         PixelRect(x: 1, y: 1, width: logical.width - 1, height: logical.height - 1)),
        (PixelRect(x: 2, y: 0, width: Int.max, height: Int.max),
         PixelRect(x: 2, y: 0, width: logical.width - 2, height: logical.height)),
    ]
    for (input, clamped) in clampedCases {
        #expect(geometry.physicalRect(input) == geometry.physicalRect(clamped), "\(input)")
        #expect(input.clamped(to: logical) == clamped, "\(input)")
    }
    let nothing: [PixelRect] = [
        PixelRect(x: Int.min, y: Int.min, width: Int.max, height: Int.max), // ends at -1
        PixelRect(x: 0, y: 0, width: 0, height: 3),
        PixelRect(x: 0, y: 0, width: 3, height: -1),
        PixelRect(x: logical.width, y: 0, width: 1, height: 1),
        PixelRect(x: 0, y: logical.height, width: 1, height: 1),
        PixelRect(x: -5, y: 0, width: 5, height: 1),
        PixelRect(x: Int.max, y: Int.max, width: Int.max, height: Int.max),
    ]
    for rect in nothing {
        #expect(geometry.physicalRect(rect) == nil, "\(rect)")
    }
}

@Test func damageRectsRoundOutwardsAndClampToTheLogicalRaster() {
    let geometry = RotationGeometry(physical: PixelSize(width: 10, height: 6), orientation: .turnedClockwise)
    // Logical raster is 6x10.
    #expect(geometry.logicalRect(minX: 0.5, minY: 1.25, maxX: 2.2, maxY: 3) == PixelRect(x: 0, y: 1, width: 3, height: 2))
    #expect(geometry.logicalRect(minX: -4, minY: -1e300, maxX: 2, maxY: 1e300) == PixelRect(x: 0, y: 0, width: 2, height: 10))
    #expect(geometry.logicalRect(minX: 5.9, minY: 9.9, maxX: 7, maxY: 11) == PixelRect(x: 5, y: 9, width: 1, height: 1))
    #expect(geometry.logicalRect(minX: 0, minY: 0, maxX: 6, maxY: 10) == PixelRect(x: 0, y: 0, width: 6, height: 10))
    let rejected: [(Double, Double, Double, Double)] = [
        (.nan, 0, 1, 1), (0, 0, .infinity, 1), (-.infinity, 0, 1, 1), (0, .nan, 1, .nan),
        (2, 0, 2, 1), (3, 0, 2, 1),          // empty, inverted
        (6, 0, 9, 1), (0, 10, 1, 12),        // past the right and bottom edges
        (-3, 0, 0, 1), (0, -2, 1, -0.5),     // before the left and top edges
    ]
    for (minX, minY, maxX, maxY) in rejected {
        #expect(geometry.logicalRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY) == nil, "\((minX, minY, maxX, maxY))")
    }
    // Sizes at the limit of Int convert without trapping.
    let huge = RotationGeometry(physical: PixelSize(width: Int.max, height: Int.max), orientation: .standard)
    #expect(huge.logicalRect(minX: 1, minY: 2, maxX: 1e30, maxY: 3) == PixelRect(x: 1, y: 2, width: Int.max - 1, height: 1))
    #expect(huge.logicalRect(minX: 1e30, minY: 0, maxX: 2e30, maxY: 1) == nil)
}

// MARK: - Region rotation

@Test(arguments: DisplayOrientation.allCases,
      [PixelSize(width: 37, height: 21), PixelSize(width: 16, height: 33)])
func regionRotationWritesWhatWholeRotationWritesAndNothingElse(_ orientation: DisplayOrientation,
                                                               _ panel: PixelSize) throws {
    let geometry = RotationGeometry(physical: panel, orientation: orientation)
    let logical = geometry.logical
    var rng = SplitMix64(state: UInt64(orientation.rawValue * 1000 + panel.width))
    let sourceStride = logical.width * 4 + 12
    let destinationStride = panel.width * 4 + 8
    let previous = randomBytes(sourceStride * logical.height, &rng)
    let current = randomBytes(sourceStride * logical.height, &rng)

    // The persistent raster holds the previous frame; padding is 0xAB.
    var old = [UInt8](repeating: 0xAB, count: destinationStride * panel.height)
    #expect(rotate(previous, sourceStride: sourceStride, into: &old, destinationStride: destinationStride, geometry))
    var whole = [UInt8](repeating: 0xAB, count: destinationStride * panel.height)
    #expect(rotate(current, sourceStride: sourceStride, into: &whole, destinationStride: destinationStride, geometry))
    #expect(whole == mapped(current, sourceStride: sourceStride, destinationStride: destinationStride, geometry))

    // Edge-touching rectangles, single pixels and lines, the whole frame, and random rectangles.
    var damage: [PixelRect] = [
        PixelRect(x: 0, y: 0, width: logical.width, height: logical.height),
        PixelRect(x: 0, y: 0, width: 1, height: 1),
        PixelRect(x: logical.width - 1, y: logical.height - 1, width: 1, height: 1),
        PixelRect(x: 0, y: 0, width: logical.width, height: 1),
        PixelRect(x: 0, y: logical.height - 1, width: logical.width, height: 1),
        PixelRect(x: 0, y: 0, width: 1, height: logical.height),
        PixelRect(x: logical.width - 1, y: 0, width: 1, height: logical.height),
        PixelRect(x: logical.width - 5, y: 3, width: 5, height: logical.height - 3),
    ]
    for _ in 0..<40 {
        let x = Int.random(in: 0..<logical.width, using: &rng), y = Int.random(in: 0..<logical.height, using: &rng)
        damage.append(PixelRect(x: x, y: y, width: Int.random(in: 1...(logical.width - x), using: &rng),
                                height: Int.random(in: 1...(logical.height - y), using: &rng)))
    }

    for rect in damage {
        let region = try #require(geometry.physicalRect(rect))
        var raster = old
        #expect(rotate(current, sourceStride: sourceStride, into: &raster, destinationStride: destinationStride,
                       geometry, region: region))
        var wrong = 0
        for index in raster.indices {
            let py = index / destinationStride, px = (index % destinationStride) / 4
            let inside = index % destinationStride < panel.width * 4 && contains(region, px, py)
            if raster[index] != (inside ? whole[index] : old[index]) { wrong += 1 }
        }
        #expect(wrong == 0, "\(rect) -> \(region): \(wrong) bytes wrong")
    }

    // A frame's damage applied rectangle by rectangle builds the same raster as rotating the whole frame,
    // once the rectangles cover it.
    var raster = old
    let quarters = [PixelRect(x: 0, y: 0, width: logical.width / 2, height: logical.height / 2),
                    PixelRect(x: logical.width / 2, y: 0, width: logical.width, height: logical.height / 2),
                    PixelRect(x: -3, y: logical.height / 2, width: logical.width + 6, height: logical.height)]
    for rect in quarters {
        let region = try #require(geometry.physicalRect(rect))
        #expect(rotate(current, sourceStride: sourceStride, into: &raster, destinationStride: destinationStride,
                       geometry, region: region))
    }
    #expect(raster == whole)
}

@Test(arguments: DisplayOrientation.allCases)
func largeRegionsAreRotatedInParallelBandsAndStillMatchThePixelMapping(_ orientation: DisplayOrientation) throws {
    // 1031x523 is above the parallel threshold, odd in both directions, and not a multiple of any band count.
    let panel = PixelSize(width: 1031, height: 523)
    let geometry = RotationGeometry(physical: panel, orientation: orientation)
    let logical = geometry.logical
    let whole = PixelRect(x: 0, y: 0, width: panel.width, height: panel.height)
    #expect(FrameRotator.bandCount(whole) == min(FrameRotator.maximumBands, panel.height / FrameRotator.minimumBandRows))
    #expect(FrameRotator.bandCount(PixelRect(x: 0, y: 0, width: 100, height: 100)) == 1)

    var rng = SplitMix64(state: UInt64(orientation.rawValue + 7))
    let sourceStride = logical.width * 4 + 64
    let destinationStride = panel.width * 4 + 4
    let source = randomBytes(sourceStride * logical.height, &rng)
    let expected = mapped(source, sourceStride: sourceStride, destinationStride: destinationStride, geometry)

    var raster = [UInt8](repeating: 0xAB, count: destinationStride * panel.height)
    #expect(rotate(source, sourceStride: sourceStride, into: &raster, destinationStride: destinationStride, geometry))
    #expect(raster == expected)

    // A large damaged region, also banded, touches only its own pixels.
    let region = try #require(geometry.physicalRect(PixelRect(x: 3, y: 5, width: logical.width - 4, height: logical.height - 9)))
    #expect(FrameRotator.bandCount(region) > 1 || FrameRotator.maximumBands == 1)
    let blank = [UInt8](repeating: 0xCD, count: destinationStride * panel.height)
    var partial = blank
    #expect(rotate(source, sourceStride: sourceStride, into: &partial, destinationStride: destinationStride,
                   geometry, region: region))
    var wrong = 0
    for index in partial.indices {
        let py = index / destinationStride, px = (index % destinationStride) / 4
        let inside = index % destinationStride < panel.width * 4 && contains(region, px, py)
        if partial[index] != (inside ? expected[index] : blank[index]) { wrong += 1 }
    }
    #expect(wrong == 0)
}

@Test(arguments: DisplayOrientation.allCases)
func regionsOutsideThePhysicalRasterAreRejectedWithoutWriting(_ orientation: DisplayOrientation) {
    let panel = PixelSize(width: 6, height: 4)
    let geometry = RotationGeometry(physical: panel, orientation: orientation)
    let source = [UInt8](repeating: 0x22, count: panel.width * panel.height * 4)
    let stride = geometry.logical.width * 4
    let regions: [PixelRect] = [
        PixelRect(x: -1, y: 0, width: 2, height: 1),
        PixelRect(x: 0, y: -1, width: 1, height: 2),
        PixelRect(x: 0, y: 0, width: 0, height: 1),
        PixelRect(x: 0, y: 0, width: 1, height: -3),
        PixelRect(x: 1, y: 0, width: panel.width, height: 1),
        PixelRect(x: 0, y: 1, width: 1, height: panel.height),
        PixelRect(x: Int.max, y: 0, width: 1, height: 1),
        PixelRect(x: 0, y: Int.max - 1, width: 1, height: 2),
        PixelRect(x: 1, y: 1, width: Int.max, height: Int.max),
        PixelRect(x: Int.min, y: Int.min, width: Int.max, height: Int.max),
    ]
    for region in regions {
        var destination = [UInt8](repeating: 0x11, count: panel.width * panel.height * 4)
        #expect(!rotate(source, sourceStride: stride, into: &destination, destinationStride: panel.width * 4,
                        geometry, region: region), "\(region)")
        #expect(destination.allSatisfy { $0 == 0x11 }, "\(region)")
    }
    // An undersized destination is rejected for a region too, even one that would fit.
    var short = [UInt8](repeating: 0x11, count: panel.width * panel.height * 4 - 1)
    #expect(!rotate(source, sourceStride: stride, into: &short, destinationStride: panel.width * 4, geometry,
                    region: PixelRect(x: 0, y: 0, width: 1, height: 1)))
    #expect(short.allSatisfy { $0 == 0x11 })
}
