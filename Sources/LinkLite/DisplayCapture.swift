// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
@preconcurrency import ScreenCaptureKit

private let log = Logger(subsystem: "com.ball.linklite", category: "capture")

/// Captures one virtual display with ScreenCaptureKit at the dock's native mode and hands every
/// complete frame to the engine.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: Error, CustomStringConvertible {
        case displayNotShareable(CGDirectDisplayID)

        var description: String {
            switch self {
            case .displayNotShareable(let id):
                "Display \(id) never appeared in ScreenCaptureKit's shareable content"
            }
        }
    }

    let head: UInt8
    let width: UInt32
    let height: UInt32
    private let engine: EngineHandle
    private let queue: DispatchQueue
    private let onStop: @Sendable (Error) -> Void
    /// Set once in start() before capture begins, read afterwards; never mutated concurrently.
    private var stream: SCStream?
    private var loggedSizeMismatch = false
    /// Set once the stream's first frame has been sent whole; touched only on the capture queue.
    private var sentFirstFrame = false
    /// Reused on the serial capture queue; the engine only borrows it during submitFrame.
    private var dirtyRects: [UInt32] = []

    private init(head: UInt8, width: UInt32, height: UInt32, engine: EngineHandle,
                 onStop: @escaping @Sendable (Error) -> Void) {
        self.head = head
        self.width = width
        self.height = height
        self.engine = engine
        self.onStop = onStop
        queue = DispatchQueue(label: "com.ball.linklite.capture.head\(head)", qos: .userInteractive)
    }

    /// Finds `displayID` in the shareable content (a freshly created virtual display can take a
    /// moment to show up) and starts streaming it at the monitor's native size.
    /// `onStop` runs if the stream later dies on its own.
    static func start(displayID: CGDirectDisplayID, monitor: MonitorInfo, engine: EngineHandle,
                      onStop: @escaping @Sendable (Error) -> Void) async throws -> DisplayCapture {
        let display = try await shareableDisplay(displayID)
        let capture = DisplayCapture(head: monitor.head, width: monitor.width, height: monitor.height,
                                     engine: engine, onStop: onStop)
        try await capture.begin(display: display, refreshHz: monitor.effectiveRefreshHz,
                                drawsCursor: !monitor.hardwareCursor)
        return capture
    }

    private static func shareableDisplay(_ displayID: CGDirectDisplayID) async throws -> SCDisplay {
        for attempt in 1...20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                if attempt > 1 { log.info("Display \(displayID) shareable after \(attempt) attempts") }
                return display
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CaptureError.displayNotShareable(displayID)
    }

    private func begin(display: SCDisplay, refreshHz: UInt32, drawsCursor: Bool) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // The dock's mode, not the macOS mode: a HiDPI backing store gets scaled to the panel.
        config.width = Int(width)
        config.height = Int(height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // A dock with a hardware cursor draws the pointer itself (CursorTracker); leaving it out of
        // the frames means pointer movement sends no video at all.
        config.showsCursor = drawsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(refreshHz))
        config.queueDepth = 3
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
        log.info("Capturing display \(display.displayID) for head \(self.head) at \(self.width)x\(self.height)@\(refreshHz)")
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            log.debug("stopCapture for head \(self.head): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let frameWidth = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = UInt32(CVPixelBufferGetHeight(pixelBuffer))
        if frameWidth != width || frameHeight != height {
            if !loggedSizeMismatch {
                loggedSizeMismatch = true
                log.error("Head \(self.head) got \(frameWidth)x\(frameHeight) frames, expected \(self.width)x\(self.height)")
            }
            return
        }

        // ScreenCaptureKit reports what changed, in output-frame pixels (measured: a 62x60 menu bar
        // item on a 3840x2160 stream of a 1920x1080-point display). That holds only while the
        // display is captured 1:1; when macOS renders it at another size and the stream scales it
        // ("looks like" 2560x1440), the whole frame is sent. The first frame of a stream carries
        // no useful report, so it is sent whole too.
        let info = attachments.first ?? [:]
        let unscaled = (info[.contentScale] as? CGFloat).map { abs($0 - 1) < 0.001 } ?? false
        var dirty: [UInt32]?
        if sentFirstFrame, unscaled, let reported = info[.dirtyRects] as? [NSDictionary] {
            dirtyRects.removeAll(keepingCapacity: true)
            dirtyRects.reserveCapacity(reported.count * 4)
            for entry in reported {
                guard let rect = CGRect(dictionaryRepresentation: entry)?.integral, !rect.isEmpty else { continue }
                dirtyRects.append(UInt32(max(0, rect.minX)))
                dirtyRects.append(UInt32(max(0, rect.minY)))
                dirtyRects.append(UInt32(rect.width))
                dirtyRects.append(UInt32(rect.height))
            }
            dirty = dirtyRects
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        engine.submitFrame(head: head, bgra: base.assumingMemoryBound(to: UInt8.self),
                           stride: CVPixelBufferGetBytesPerRow(pixelBuffer),
                           width: frameWidth, height: frameHeight, dirty: dirty)
        sentFirstFrame = true
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Capture for head \(self.head) stopped: \(error.localizedDescription, privacy: .public)")
        onStop(error)
    }
}
