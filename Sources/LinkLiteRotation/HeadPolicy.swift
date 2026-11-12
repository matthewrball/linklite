// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a head's virtual display was created for. A reconnect reuses a retained virtual display only if
/// the new attachment needs the same shape.
public struct HeadShape: Hashable, Sendable {
    public var physical: PixelSize
    public var refreshHz: UInt32
    public var orientation: DisplayOrientation

    public init(physical: PixelSize, refreshHz: UInt32, orientation: DisplayOrientation) {
        self.physical = physical
        self.refreshHz = refreshHz
        self.orientation = orientation
    }

    /// 180 degrees and standard share a virtual display (only the copy differs), as do the two portrait
    /// orientations. Switching between landscape and portrait needs a new one.
    public func virtualDisplayReusable(for other: HeadShape) -> Bool {
        physical == other.physical && refreshHz == other.refreshHz
            && orientation.swapsAxes == other.orientation.swapsAxes
    }
}

/// How a head's capture is set up for its orientation.
public struct CapturePolicy: Equatable, Sendable {
    public let geometry: RotationGeometry
    /// Whether the dock draws the pointer itself for this monitor.
    public let dockDrawsCursor: Bool

    public init(physical: PixelSize, orientation: DisplayOrientation, dockDrawsCursor: Bool) {
        geometry = RotationGeometry(physical: physical, orientation: orientation)
        self.dockDrawsCursor = dockDrawsCursor
    }

    /// The size ScreenCaptureKit captures: the logical size, which is the virtual display's size.
    public var captureSize: PixelSize { geometry.logical }

    /// Only an unrotated head may use the dock's hardware cursor. The dock's placement is not edge-aware
    /// (it clamps a negative origin instead of cropping), and it has no rotated image or hotspot.
    public var usesHardwareCursor: Bool { dockDrawsCursor && geometry.orientation == .standard }

    /// The pointer is part of the captured frames whenever the hardware cursor is not in use.
    public var showsCursorInFrames: Bool { !usesHardwareCursor }

    /// Rotated frames are sent whole. ScreenCaptureKit's damage rectangles are not mapped to physical
    /// rectangles yet, so an unrotated head keeps its damage path and a rotated one sends every frame.
    public var sendsWholeFrames: Bool { geometry.orientation != .standard }
}

/// What a change of orientation requires for a head that is already attached.
public enum OrientationChange: Equatable, Sendable {
    case unchanged
    /// 0 <-> 180 or 90 <-> 270: the virtual display keeps its size, so only capture restarts.
    case restartCapture
    /// Landscape <-> portrait: the virtual display must be made again, with its new size.
    case recreateDisplay

    public static func between(_ current: DisplayOrientation, and new: DisplayOrientation) -> OrientationChange {
        if current == new { return .unchanged }
        return current.swapsAxes == new.swapsAxes ? .restartCapture : .recreateDisplay
    }
}

/// What DisplayHost must do when a monitor's orientation is chosen. The choice is always stored; this says
/// how the head's display and capture follow it.
public enum OrientationApplication: Equatable, Sendable {
    case none
    /// The display is kept and its capture restarts (0 <-> 180, 90 <-> 270).
    case restartCapture
    /// The display is torn down and created again for the other shape (landscape <-> portrait).
    case recreateDisplay
    /// The head has no display (creation failed earlier), so one is created for the selected orientation.
    /// This runs even when the orientation is unchanged: a choice made after a failure is a retry.
    case createDisplay

    public static func plan(hasDisplay: Bool, applied: DisplayOrientation,
                            requested: DisplayOrientation) -> OrientationApplication {
        guard hasDisplay else { return .createDisplay }
        switch OrientationChange.between(applied, and: requested) {
        case .unchanged: return .none
        case .restartCapture: return .restartCapture
        case .recreateDisplay: return .recreateDisplay
        }
    }
}
