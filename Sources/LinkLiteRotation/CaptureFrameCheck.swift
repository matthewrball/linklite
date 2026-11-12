// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// Checks on captured frames, before any byte is read (pure: Core Video values arrive as plain numbers).
// DisplayCapture reports each complete frame here and acts on the answer.

public enum CaptureFrameCheck {
    /// kCVPixelFormatType_32BGRA ('BGRA'). Passed as a number because this module does not import CoreVideo.
    public static let bgra32: UInt32 = 0x4247_5241

    public enum Rejection: Equatable, Sendable, CustomStringConvertible {
        case pixelFormat(UInt32)
        /// Not the size the stream was configured for, or not a positive size.
        case size(width: Int, height: Int)
        /// A row shorter than one row of pixels, or a byte span that does not fit in `Int`.
        case rowBytes(stride: Int)

        public var description: String {
            switch self {
            case .pixelFormat(let code):
                let letters = (0..<4).map { index in
                    Character(UnicodeScalar(UInt8((code >> (24 - 8 * UInt32(index))) & 0xff)))
                }
                return "pixel format '\(String(letters))'"
            case .size(let width, let height):
                return "\(width)x\(height) pixels"
            case .rowBytes(let stride):
                return "row stride \(stride) bytes"
            }
        }
    }

    /// Returns why a frame must not be read, or nil if it is safe to read. The format is checked first, then
    /// the size, then the stride and byte span, so an unexpected layout never reaches a pointer read.
    public static func check(pixelFormat: UInt32, width: Int, height: Int, bytesPerRow: Int,
                             expected: PixelSize) -> Rejection? {
        guard pixelFormat == bgra32 else { return .pixelFormat(pixelFormat) }
        guard width > 0, height > 0, width == expected.width, height == expected.height else {
            return .size(width: width, height: height)
        }
        guard FrameRotator.span(stride: bytesPerRow, width: width, height: height) != nil else {
            return .rowBytes(stride: bytesPerRow)
        }
        return nil
    }
}

/// Counts consecutive unusable complete frames for one capture. A usable frame ends the run. A run that reaches
/// `limit` fails the stream once, so the caller can stop it and report the failure. Idle or incomplete frames are
/// not reported to this type.
public struct FrameHealth: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The first usable frame of this stream.
        case firstUsable
        case usable
        case unusable
        /// The run reached the limit on this frame. Reported once per stream.
        case failed
    }

    public static let defaultLimit = 30

    public let limit: Int
    public private(set) var unusableRun = 0
    public private(set) var failed = false
    private var deliveredUsable = false

    public init(limit: Int = FrameHealth.defaultLimit) {
        self.limit = limit
    }

    public mutating func record(usable: Bool) -> Outcome {
        // Once failed, the stream is being stopped and nothing more is delivered or reported.
        if failed { return .unusable }
        guard usable else {
            unusableRun += 1
            if unusableRun >= limit {
                failed = true
                return .failed
            }
            return .unusable
        }
        unusableRun = 0
        if deliveredUsable { return .usable }
        deliveredUsable = true
        return .firstUsable
    }
}

/// Whether frames from one stream may be read: closed until the stream has started, open while it runs, and
/// closed for good once it stops or fails. A closed gate never reopens, so a stale callback cannot revive a stream.
public struct CaptureGate: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        case open
        case closed
    }

    public private(set) var state: State = .waiting

    public init() {}

    public var accepts: Bool { state == .open }

    public mutating func open() {
        if state == .waiting { state = .open }
    }

    public mutating func close() {
        state = .closed
    }
}
