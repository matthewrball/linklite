// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import LinkLiteRotation

// Frame checks that run before DisplayCapture reads any byte of a frame. These are pure: the Core Video
// values are passed in as plain numbers, so no pixel buffer or ScreenCaptureKit stream is needed.

private let expected = PixelSize(width: 3840, height: 2160)
private let bgra = CaptureFrameCheck.bgra32
/// 'l10r' (ARGB 2101010): a format the capture must refuse rather than read as BGRA.
private let ten_bit: UInt32 = 0x6c31_3072
/// '420v' (bi-planar 4:2:0 video): planar, so its first plane is not BGRA at all.
private let planarVideo: UInt32 = 0x3432_3076

// MARK: - Format, size and stride

@Test func aWellFormedBGRAFrameIsAccepted() {
    #expect(CaptureFrameCheck.check(pixelFormat: bgra, width: 3840, height: 2160,
                                    bytesPerRow: 3840 * 4, expected: expected) == nil)
    // Row padding is allowed: a stride above one row.
    #expect(CaptureFrameCheck.check(pixelFormat: bgra, width: 3840, height: 2160,
                                    bytesPerRow: 3840 * 4 + 64, expected: expected) == nil)
}

@Test func aFrameInAnotherPixelFormatIsRefusedBeforeAnyByteIsRead() {
    #expect(CaptureFrameCheck.check(pixelFormat: ten_bit, width: 3840, height: 2160,
                                    bytesPerRow: 3840 * 4, expected: expected) == .pixelFormat(ten_bit))
    #expect(CaptureFrameCheck.check(pixelFormat: planarVideo, width: 3840, height: 2160,
                                    bytesPerRow: 3840 * 4, expected: expected) == .pixelFormat(planarVideo))
}

@Test func aFrameOfTheWrongSizeIsRefused() {
    #expect(CaptureFrameCheck.check(pixelFormat: bgra, width: 1920, height: 1080,
                                    bytesPerRow: 1920 * 4, expected: expected)
            == .size(width: 1920, height: 1080))
    // Swapped axes (a portrait frame for a landscape head) is also a size mismatch.
    #expect(CaptureFrameCheck.check(pixelFormat: bgra, width: 2160, height: 3840,
                                    bytesPerRow: 2160 * 4, expected: expected)
            == .size(width: 2160, height: 3840))
}

@Test func aStrideBelowOneRowIsRefused() {
    #expect(CaptureFrameCheck.check(pixelFormat: bgra, width: 3840, height: 2160,
                                    bytesPerRow: 3840 * 4 - 4, expected: expected) == .rowBytes(stride: 3840 * 4 - 4))
}

@Test func emptyFramesAreRefused() {
    let zero = PixelSize(width: 0, height: 0)
    #expect(CaptureFrameCheck.check(pixelFormat: bgra, width: 0, height: 0, bytesPerRow: 0, expected: zero)
            == .size(width: 0, height: 0))
}

@Test func overflowingBufferArithmeticIsRefusedWithoutTrapping() {
    // The expected size matches, so the size check passes and the byte span is what overflows.
    let huge = PixelSize(width: Int.max / 4, height: 2)
    #expect(CaptureFrameCheck.check(pixelFormat: bgra, width: Int.max / 4, height: 2,
                                    bytesPerRow: Int.max, expected: huge) == .rowBytes(stride: Int.max))
    // Row bytes themselves overflow Int.
    let wide = PixelSize(width: Int.max, height: 1)
    #expect(CaptureFrameCheck.check(pixelFormat: bgra, width: Int.max, height: 1,
                                    bytesPerRow: Int.max, expected: wide) == .rowBytes(stride: Int.max))
}

@Test func theRejectionsReadWellInTheLog() {
    #expect(CaptureFrameCheck.Rejection.pixelFormat(planarVideo).description == "pixel format '420v'")
    #expect(CaptureFrameCheck.Rejection.size(width: 1, height: 2).description == "1x2 pixels")
}

// MARK: - Sustained unusable frames

@Test func aSingleUnusableFrameIsDroppedAndDoesNotFailTheStream() {
    var health = FrameHealth(limit: 30)
    #expect(health.record(usable: false) == .unusable)
    #expect(health.record(usable: true) == .firstUsable)
    #expect(!health.failed)
}

@Test func onlyASustainedRunOfUnusableFramesFailsTheStreamAndItFailsOnce() {
    var health = FrameHealth(limit: 3)
    #expect(health.record(usable: false) == .unusable)
    #expect(health.record(usable: false) == .unusable)
    #expect(health.record(usable: false) == .failed)
    #expect(health.failed)
    // Once failed, later frames are never reported as the failure again.
    #expect(health.record(usable: false) == .unusable)
    #expect(health.record(usable: true) == .unusable, "after a failure the stream is being stopped: nothing is delivered")
}

@Test func aUsableFrameInTheMiddleResetsTheRun() {
    var health = FrameHealth(limit: 3)
    _ = health.record(usable: false)
    _ = health.record(usable: false)
    _ = health.record(usable: true)
    #expect(health.unusableRun == 0)
    _ = health.record(usable: false)
    _ = health.record(usable: false)
    #expect(!health.failed, "two in a row after a reset are below the limit of three")
}

@Test func theFirstUsableFrameIsReportedOnlyOnce() {
    var health = FrameHealth(limit: 30)
    #expect(health.record(usable: true) == .firstUsable)
    #expect(health.record(usable: true) == .usable)
    #expect(health.record(usable: true) == .usable)
}

@Test func aNewStreamStartsWithNoRunAndNoFirstFrame() {
    // A restarted capture gets a fresh health value, so an old run cannot count against the new stream.
    var old = FrameHealth(limit: 3)
    _ = old.record(usable: false)
    _ = old.record(usable: false)
    let fresh = FrameHealth(limit: 3)
    #expect(fresh.unusableRun == 0)
    #expect(!fresh.failed)
    var restarted = fresh
    #expect(restarted.record(usable: false) == .unusable)
    #expect(restarted.unusableRun == 1)
}

// MARK: - Frames only after the stream is open

@Test func framesArrivingBeforeTheStreamStartsOrAfterItStopsAreNotAccepted() {
    var gate = CaptureGate()
    #expect(!gate.accepts, "a frame before start() has returned must not be submitted")
    gate.open()
    #expect(gate.accepts)
    gate.close()
    #expect(!gate.accepts, "a stale callback after stop must not be submitted")
}

@Test func aClosedGateNeverReopens() {
    // A stopped stream cannot come back under the same gate. Restarting makes a new DisplayCapture.
    var gate = CaptureGate()
    gate.open()
    gate.close()
    gate.open()
    #expect(!gate.accepts)
    #expect(gate.state == .closed)
}

@Test func stoppingBeforeStartCompletesStillClosesTheGate() {
    var gate = CaptureGate()
    gate.close()
    gate.open()
    #expect(gate.state == .closed)
}
