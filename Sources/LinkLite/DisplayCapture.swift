// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import LinkLiteRotation
import os
@preconcurrency import ScreenCaptureKit

private let log = Logger(subsystem: "com.ball.linklite", category: "capture")

/// Captures one virtual display with ScreenCaptureKit at the dock's native mode and hands every
/// complete, usable frame to the engine.
///
/// Frames are read only while the frame gate is open: from just before the stream starts, until the runtime retires it
/// (stop) or it fails. The gate is owned by the runtime, which closes it at once when the stream is retired, so no
/// frame or cursor report from a retired stream reaches the engine. A stream that keeps delivering unusable frames
/// closes its gate and is reported through `onStop`; it does not stop itself. Stopping is the runtime's job, through
/// `stop()`, so a stream has exactly one owner.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: Error, CustomStringConvertible {
        case displayNotShareable(CGDirectDisplayID)
        case unusableFrames(head: UInt8, reason: String)
        case stopFailed(head: UInt8, underlying: String)

        var description: String {
            switch self {
            case .displayNotShareable(let id):
                "Display \(id) never appeared in ScreenCaptureKit's shareable content"
            case .unusableFrames(let head, let reason):
                "Head \(head) produced unusable frames (\(reason))"
            case .stopFailed(let head, let underlying):
                "Stopping capture for head \(head) was not confirmed: \(underlying)"
            }
        }
    }

    let head: UInt8
    /// The dock's programmed mode: the size of every frame handed to the engine.
    let width: UInt32
    let height: UInt32
    /// How the captured logical frame becomes the dock's physical frame (see LinkLiteRotation).
    private let policy: CapturePolicy
    private let engine: EngineHandle
    private let queue: DispatchQueue
    private let onStop: @Sendable (Error) -> Void
    private let onUsableFrame: @Sendable () -> Void
    /// Owned by the runtime, which closes it when this stream is retired. Read on the capture queue.
    private let gate: FrameGate
    /// True once ScreenCaptureKit has reported this stream stopped, or a stop has succeeded. Such a stream needs no
    /// stop, and must not be reported as one that could not be stopped.
    private let endedLock = NSLock()
    private var streamEnded = false
    /// Set once in start() before capture begins, read afterwards; never mutated concurrently.
    private var stream: SCStream?
    /// Everything below is touched only on the capture queue.
    private var health = FrameHealth()
    private var loggedRejection = false
    /// Set once the stream's first frame has been sent whole.
    private var sentFirstFrame = false
    /// Reused on the serial capture queue; the engine only borrows it during submitFrame.
    private var dirtyRects: [UInt32] = []
    /// A rotated head's physical frame, rebuilt for every captured frame. Empty for an unrotated head.
    private var rotatedFrame: [UInt8] = []

    private init(head: UInt8, monitor: HeadMonitor, orientation: DisplayOrientation, engine: EngineHandle,
                 gate: FrameGate, onUsableFrame: @escaping @Sendable () -> Void,
                 onStop: @escaping @Sendable (Error) -> Void) {
        self.head = head
        width = monitor.width
        height = monitor.height
        policy = CapturePolicy(physical: PixelSize(width: Int(monitor.width), height: Int(monitor.height)),
                               orientation: orientation, dockDrawsCursor: monitor.hardwareCursor)
        self.engine = engine
        self.gate = gate
        self.onUsableFrame = onUsableFrame
        self.onStop = onStop
        queue = DispatchQueue(label: "com.ball.linklite.capture.head\(head)", qos: .userInteractive)
    }

    /// Finds `displayID` in the shareable content (a freshly created virtual display can take a
    /// moment to show up) and starts streaming it. An unrotated head streams at the monitor's native
    /// size; a rotated head streams the logical (upright) size and is rotated into the native size.
    /// `onUsableFrame` runs once, at the first usable frame. `onStop` runs if the stream later dies on its own,
    /// or fails because of unusable frames. `gate` is the runtime's gate for this stream; it is opened here, just
    /// before the stream starts, unless the runtime has already closed it.
    static func start(displayID: CGDirectDisplayID, monitor: HeadMonitor, orientation: DisplayOrientation,
                      engine: EngineHandle, gate: FrameGate, onUsableFrame: @escaping @Sendable () -> Void,
                      onStop: @escaping @Sendable (Error) -> Void) async throws -> DisplayCapture {
        let display = try await shareableDisplay(displayID)
        let capture = DisplayCapture(head: monitor.head, monitor: monitor, orientation: orientation,
                                     engine: engine, gate: gate, onUsableFrame: onUsableFrame, onStop: onStop)
        try await capture.begin(display: display, refreshHz: monitor.effectiveRefreshHz)
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

    private func begin(display: SCDisplay, refreshHz: UInt32) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // The upright size: the dock's mode for an unrotated head (a HiDPI backing store gets scaled to the
        // panel), or the portrait size of the virtual display for a rotated head.
        config.width = policy.captureSize.width
        config.height = policy.captureSize.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // A dock with a hardware cursor draws the pointer itself (CursorTracker); leaving it out of the frames
        // means pointer movement sends no video at all. A rotated head has no such cursor, so the pointer
        // stays in its frames.
        config.showsCursor = policy.showsCursorInFrames
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(refreshHz))
        config.queueDepth = 3
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        // Open before the stream starts: no frame can arrive before that, and a first frame dropped here would
        // leave a static display without a picture (and the card on "Starting") until something changed.
        gate.open()
        do {
            try await stream.startCapture()
        } catch {
            gate.close()
            throw error
        }
        let orientation = policy.geometry.orientation.rawValue
        log.info("Capturing display \(display.displayID) for head \(self.head) at \(self.policy.captureSize.width)x\(self.policy.captureSize.height) (\(orientation)°) → \(self.width)x\(self.height)@\(refreshHz)")
    }

    /// Stops the stream. Frames that arrive afterwards are dropped, and the gate never reopens. Returns only once the
    /// stream is known to have stopped. Throws when the stop failed and the stream may still run; the runtime then
    /// keeps it, retries, and starts no other stream on this head until the stop is confirmed.
    func stop() async throws {
        gate.close()
        guard let stream, !endedLock.withLock({ streamEnded }) else { return }
        do {
            try await stream.stopCapture()
        } catch {
            log.error("stopCapture for head \(self.head) failed: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.stopFailed(head: head, underlying: error.localizedDescription)
        }
        endedLock.withLock { streamEnded = true }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, gate.isOpen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else {
            recordFrame(usable: false, reason: "no frame status")
            return
        }
        // Idle and other incomplete frames carry no new pixels. They are normal, so they are not counted.
        guard status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            recordFrame(usable: false, reason: "no pixel buffer")
            return
        }

        // Checked before any byte is read: format, size, and a stride whose byte span is representable.
        if let rejection = CaptureFrameCheck.check(pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
                                                   width: CVPixelBufferGetWidth(pixelBuffer),
                                                   height: CVPixelBufferGetHeight(pixelBuffer),
                                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                   expected: policy.captureSize) {
            recordFrame(usable: false, reason: rejection.description)
            return
        }

        // Submitted while the gate is held open, so a stop that closes it waits for this frame and no later one
        // reaches the engine. A closed gate means the stream was retired meanwhile: the frame is dropped.
        guard let usable = gate.whileOpen({ () -> Bool in
            policy.sendsWholeFrames ? submitRotated(pixelBuffer) : submitUnrotated(pixelBuffer, info: info)
        }) else { return }
        recordFrame(usable: usable, reason: "the frame could not be read")
    }

    /// Counts one complete frame. The first usable frame reports `onUsableFrame`. A sustained run of unusable
    /// frames stops the stream and reports the failure. Runs on the capture queue.
    private func recordFrame(usable: Bool, reason: String) {
        if !usable, !loggedRejection {
            loggedRejection = true
            log.error("Head \(self.head) frame rejected: \(reason, privacy: .public)")
        }
        switch health.record(usable: usable) {
        case .firstUsable:
            onUsableFrame()
        case .usable, .unusable:
            break
        case .failed:
            fail(CaptureError.unusableFrames(head: head, reason: reason))
        }
    }

    /// Closes the gate and reports the failure once. The stream is not stopped here: the runtime stops it when the
    /// controller retires the attempt, so the stop has one owner. Later frames are dropped by the closed gate.
    private func fail(_ error: CaptureError) {
        guard gate.close() else { return }
        log.error("\(error.description, privacy: .public)")
        onStop(error)
    }

    /// Sends an unrotated frame with ScreenCaptureKit's damage rectangles. Returns false if the frame could not
    /// be read. Runs on the capture queue.
    private func submitUnrotated(_ pixelBuffer: CVPixelBuffer, info: [SCStreamFrameInfo: Any]) -> Bool {
        // ScreenCaptureKit reports what changed, in output-frame pixels (measured: a 62x60 menu bar
        // item on a 3840x2160 stream of a 1920x1080-point display). That holds only while the
        // display is captured 1:1; when macOS renders it at another size and the stream scales it
        // ("looks like" 2560x1440), the whole frame is sent. The first frame of a stream carries
        // no useful report, so it is sent whole too.
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

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        engine.submitFrame(head: head, bgra: base.assumingMemoryBound(to: UInt8.self),
                           stride: CVPixelBufferGetBytesPerRow(pixelBuffer),
                           width: UInt32(policy.captureSize.width), height: UInt32(policy.captureSize.height),
                           dirty: dirty)
        sentFirstFrame = true
        return true
    }

    /// Rotates a whole captured frame into the head's physical raster and sends it as unknown damage (a
    /// full frame). Returns false if the frame could not be read. Runs on the capture queue. Rotated heads
    /// send every frame whole for now: ScreenCaptureKit's damage rectangles are not mapped yet.
    private func submitRotated(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let logical = policy.captureSize
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationStride = Int(width) * 4
        // The source span and the destination size are both computed with overflow checks before any read.
        // The frame's own span was already validated by CaptureFrameCheck.
        guard let sourceBytes = FrameRotator.span(stride: sourceStride, width: logical.width, height: logical.height),
              let destinationBytes = FrameRotator.span(stride: destinationStride, width: Int(width), height: Int(height))
        else { return false }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        if rotatedFrame.count != destinationBytes {
            rotatedFrame = [UInt8](repeating: 0, count: destinationBytes)
        }
        let rotated = rotatedFrame.withUnsafeMutableBytes { destination in
            FrameRotator.rotate(source: UnsafeRawBufferPointer(start: base, count: sourceBytes),
                                sourceStride: sourceStride, into: destination,
                                destinationStride: destinationStride, geometry: policy.geometry)
        }
        guard rotated else { return false }
        rotatedFrame.withUnsafeBufferPointer { frame in
            engine.submitFrame(head: head, bgra: frame.baseAddress!, stride: destinationStride,
                               width: width, height: height, dirty: nil)
        }
        return true
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Capture for head \(self.head) stopped: \(error.localizedDescription, privacy: .public)")
        endedLock.withLock { streamEnded = true }
        gate.close()
        onStop(error)
    }
}
