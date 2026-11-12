// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// Where the dock's hardware cursor is told to be (pure: no AppKit, CoreGraphics or engine). The dock keeps
// the last position it was given, so a pointer that leaves the dock, or a dock head that stops being a
// target, must be reported explicitly. CursorTracker supplies the display bounds and the engine call.

/// A position for the dock's hardware cursor: on `head` at (x, y) in that head's mode pixels, or on no head.
public struct DockCursorReport: Equatable, Sendable, CustomStringConvertible {
    public var head: Int32
    public var x: Int32
    public var y: Int32

    public init(head: Int32, x: Int32, y: Int32) {
        self.head = head
        self.x = x
        self.y = y
    }

    /// The pointer is on no dock head (the engine hides the cursor).
    public static let hidden = DockCursorReport(head: -1, x: 0, y: 0)

    public var isHidden: Bool { head < 0 }

    public var description: String { isHidden ? "hidden" : "head \(head) at (\(x), \(y))" }
}

/// A dock head that draws the pointer: its display's bounds in global points (top-left origin, as
/// CGDisplayBounds reports them) and the dock's mode width in pixels.
public struct DockCursorTarget: Equatable, Sendable {
    public var head: Int32
    public var originX: Double
    public var originY: Double
    public var widthPoints: Double
    public var heightPoints: Double
    public var modeWidth: Double

    public init(head: Int32, originX: Double, originY: Double, widthPoints: Double, heightPoints: Double,
                modeWidth: Double) {
        self.head = head
        self.originX = originX
        self.originY = originY
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.modeWidth = modeWidth
    }

    /// Dock pixels per point.
    public var scale: Double { modeWidth / widthPoints }

    /// Half-open, as CGRect.contains is: a point on the right or bottom edge belongs to the next display.
    public func contains(x: Double, y: Double) -> Bool {
        x >= originX && x < originX + widthPoints && y >= originY && y < originY + heightPoints
    }
}

/// The pointer's place on a dock head.
public struct DockCursorHit: Equatable, Sendable {
    public var report: DockCursorReport
    /// Dock pixels per point on that head, for sizing the cursor image.
    public var scale: Double
}

/// What the dock is believed to show, and sends only what changes it. A failed send leaves the state unknown,
/// so the next report sends again rather than trusting a position the dock may not have.
public struct DockCursorReporter: Equatable, Sendable {
    public enum Believed: Equatable, Sendable {
        /// No cursor is shown on the dock. This is also the state of a fresh engine.
        case hidden
        case shown(DockCursorReport)
        /// The last send failed, or the state was forgotten (after sleep, or when heads change).
        case unknown
    }

    public private(set) var believed: Believed = .hidden

    /// Tells the dock `report` unless it already shows it. Hiding is sent only if something is shown.
    public mutating func report(_ report: DockCursorReport, send: (DockCursorReport) -> Bool) {
        switch believed {
        case .shown(let current) where current == report:
            return
        case .hidden where report.isHidden:
            return
        default:
            deliver(report, send: send)
        }
    }

    /// Hides the cursor on the dock if it may be shown. Call before tracking stops, so the dock does not keep
    /// the last position after nothing is left to move it.
    public mutating func retire(send: (DockCursorReport) -> Bool) {
        if believed != .hidden { deliver(.hidden, send: send) }
    }

    /// The dock may have lost its state, so the next report is sent whatever it is.
    public mutating func forget() {
        believed = .unknown
    }

    private mutating func deliver(_ report: DockCursorReport, send: (DockCursorReport) -> Bool) {
        if send(report) {
            believed = report.isHidden ? .hidden : .shown(report)
        } else {
            believed = .unknown
        }
    }
}

/// Routes the pointer to a dock head, or to none, and reports it through a DockCursorReporter.
public struct DockCursorRouter: Equatable, Sendable {
    public private(set) var targets: [DockCursorTarget] = []
    public var reporter = DockCursorReporter()

    public init() {}

    /// Replaces the targets and reports the pointer's place. Removing the last target hides the cursor first.
    /// Removing one of several keeps the cursor wherever the pointer still is. A change in which heads are
    /// targets forgets what the dock holds, so the current position is sent again.
    @discardableResult
    public mutating func setTargets(_ new: [DockCursorTarget], pointerX: Double, pointerY: Double,
                                    send: (DockCursorReport) -> Bool) -> DockCursorHit? {
        let previousHeads = Set(targets.map(\.head))
        targets = new
        if new.isEmpty {
            reporter.retire(send: send)
            return nil
        }
        // From no targets the dock is already known to be hidden (or unknown after a failed send), so a first
        // target needs no forgetting; that avoids a needless hide on launch.
        if !previousHeads.isEmpty, Set(new.map(\.head)) != previousHeads { reporter.forget() }
        return pointerMoved(x: pointerX, y: pointerY, send: send)
    }

    /// Reports the pointer's place on the current targets.
    @discardableResult
    public mutating func pointerMoved(x: Double, y: Double, send: (DockCursorReport) -> Bool) -> DockCursorHit? {
        let hit = self.hit(x: x, y: y)
        reporter.report(hit?.report ?? .hidden, send: send)
        return hit
    }

    /// Where the pointer is on the targets, or nil when it is on none of them.
    public func hit(x: Double, y: Double) -> DockCursorHit? {
        guard let target = targets.first(where: { $0.contains(x: x, y: y) }) else { return nil }
        let scale = target.scale
        let report = DockCursorReport(
            head: target.head,
            x: Int32(clamping: Int(((x - target.originX) * scale).rounded(.down))),
            y: Int32(clamping: Int(((y - target.originY) * scale).rounded(.down))))
        return DockCursorHit(report: report, scale: scale)
    }
}
