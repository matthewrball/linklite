// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import CoreGraphics

/// Feeds the dock's hardware cursor: where the pointer is, and what it looks like.
///
/// With the pointer drawn by the dock instead of into the captured frames, moving the mouse costs
/// a few bytes of control traffic rather than re-encoding and resending the strips around it.
@MainActor
final class CursorTracker {
    /// A dock head showing a virtual display, in global display coordinates (top-left origin).
    struct Target {
        var head: UInt8
        var displayID: CGDirectDisplayID
        /// The dock's mode size; the pointer position is reported in these pixels.
        var width: UInt32
        var height: UInt32
    }

    /// Largest image the dock cursor takes.
    private static let maxSide = 64
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let engine: EngineHandle
    private var targets: [Target] = []
    private var monitors: [Any] = []
    private var lastImage: [UInt8] = []
    private var renderedImage: [UInt8] = []
    private var lastHotspot = (x: Int32(0), y: Int32(0))
    private var lastScale: CGFloat = 0
    private var lastShapeCheck = Date.distantPast

    init(engine: EngineHandle) {
        self.engine = engine
    }

    func setTargets(_ targets: [Target]) {
        self.targets = targets
        if targets.isEmpty {
            stop()
        } else if monitors.isEmpty {
            start()
        }
        lastShapeCheck = .distantPast
        update()
    }

    private func start() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                             .otherMouseDragged, .leftMouseDown, .leftMouseUp, .cursorUpdate]
        // Global monitors see other apps' pointer events; local ones see this app's (its menu).
        // Pointer events need no Accessibility or Input Monitoring permission.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.update() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func update() {
        guard !targets.isEmpty, let location = CGEvent(source: nil)?.location else { return }
        guard let (target, bounds) = targets.lazy
            .map({ ($0, CGDisplayBounds($0.displayID)) })
            .first(where: { $0.1.contains(location) })
        else {
            engine.moveCursor(head: -1, x: 0, y: 0)
            return
        }
        let scale = CGFloat(target.width) / bounds.width
        updateShape(scale: scale)
        let x = Int32(((location.x - bounds.minX) * scale).rounded(.down))
        let y = Int32(((location.y - bounds.minY) * scale).rounded(.down))
        engine.moveCursor(head: Int32(target.head), x: x, y: y)
    }

    /// Re-renders the system cursor at the dock's pixel scale when it may have changed shape,
    /// and sends it only if the pixels differ from what the dock already holds.
    private func updateShape(scale: CGFloat) {
        let now = Date()
        guard scale != lastScale || now.timeIntervalSince(lastShapeCheck) > 0.05 else { return }
        lastShapeCheck = now
        guard let cursor = NSCursor.currentSystem else { return }
        let side = Self.maxSide
        let size = cursor.image.size
        // Fit the pointer, at the dock's scale, into the dock's 64x64 cursor.
        let fit = min(scale, CGFloat(side) / max(size.width, 1), CGFloat(side) / max(size.height, 1))
        let pixelWidth = max(1, min(side, Int((size.width * fit).rounded(.up))))
        let pixelHeight = max(1, min(side, Int((size.height * fit).rounded(.up))))
        if renderedImage.isEmpty {
            renderedImage = [UInt8](repeating: 0, count: side * side * 4)
        }
        let drawn = renderedImage.withUnsafeMutableBytes { buffer -> Bool in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: Self.colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            // CGContext's origin is bottom-left; draw the image in the top-left of the 64x64 canvas.
            let rect = CGRect(x: 0, y: CGFloat(side - pixelHeight), width: CGFloat(pixelWidth),
                              height: CGFloat(pixelHeight))
            var proposed = rect
            guard let image = cursor.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            return true
        }
        guard drawn else { return }
        let hotspot = (x: Int32((cursor.hotSpot.x * fit).rounded()), y: Int32((cursor.hotSpot.y * fit).rounded()))
        guard renderedImage != lastImage || hotspot != lastHotspot || scale != lastScale else { return }
        // Keep both allocations: the next shape check renders into the previous image's buffer.
        swap(&renderedImage, &lastImage)
        lastHotspot = hotspot
        lastScale = scale
        engine.setCursor(bgra: lastImage, width: UInt32(side), height: UInt32(side), hotX: hotspot.x, hotY: hotspot.y)
    }
}
