// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import LinkLiteRotation

// Capture, cursor, lifecycle and default-mode decisions for one head. DisplayHost applies these;
// the rules are pure so they can be checked without a dock, a display or Screen Recording access.

private let panel = PixelSize(width: 3840, height: 2160)

// MARK: - Capture and cursor

@Test(arguments: DisplayOrientation.allCases)
func capturesTheLogicalSizeThatMacOSDraws(_ orientation: DisplayOrientation) {
    let policy = CapturePolicy(physical: panel, orientation: orientation, dockDrawsCursor: false)
    #expect(policy.captureSize == RotationGeometry(physical: panel, orientation: orientation).logical)
}

@Test func unrotatedHeadKeepsTheExistingCapturePath() {
    // The original path: the dock's mode is captured, damage comes from ScreenCaptureKit, and the
    // hardware cursor is used when the dock draws one.
    let withDockCursor = CapturePolicy(physical: panel, orientation: .standard, dockDrawsCursor: true)
    #expect(withDockCursor.captureSize == panel)
    #expect(withDockCursor.usesHardwareCursor)
    #expect(!withDockCursor.showsCursorInFrames)
    #expect(!withDockCursor.sendsWholeFrames)

    let withoutDockCursor = CapturePolicy(physical: panel, orientation: .standard, dockDrawsCursor: false)
    #expect(!withoutDockCursor.usesHardwareCursor)
    #expect(withoutDockCursor.showsCursorInFrames)
    #expect(!withoutDockCursor.sendsWholeFrames)
}

@Test(arguments: [DisplayOrientation.turnedClockwise, .upsideDown, .turnedCounterclockwise])
func rotatedHeadsDrawThePointerIntoFramesAndNeverUseTheDockCursor(_ orientation: DisplayOrientation) {
    // The dock's cursor placement is not edge-aware (it clamps a negative origin instead of cropping),
    // and it has no rotated image or hotspot. So a rotated head shows the pointer inside its frames.
    for dockDrawsCursor in [true, false] {
        let policy = CapturePolicy(physical: panel, orientation: orientation, dockDrawsCursor: dockDrawsCursor)
        #expect(!policy.usesHardwareCursor)
        #expect(policy.showsCursorInFrames)
    }
}

@Test(arguments: DisplayOrientation.allCases)
func rotatedHeadsSendWholeFramesAndUnrotatedHeadsDoNot(_ orientation: DisplayOrientation) {
    // Full-frame updates are the safe first step for rotation: no damage rectangles are mapped.
    let policy = CapturePolicy(physical: panel, orientation: orientation, dockDrawsCursor: true)
    #expect(policy.sendsWholeFrames == (orientation != .standard))
}

@Test func asymmetricOddFramesAreMappedWithTheirOwnSize() {
    // A rotated 5x3 panel captures 3x5 and must hand the engine exactly 5x3 frames.
    let odd = PixelSize(width: 5, height: 3)
    let policy = CapturePolicy(physical: odd, orientation: .turnedClockwise, dockDrawsCursor: false)
    #expect(policy.captureSize == PixelSize(width: 3, height: 5))
    #expect(policy.geometry.physical == odd)
}

// MARK: - Lifecycle

@Test func orientationChangesRestartCaptureOnlyWithinAShape() {
    #expect(OrientationChange.between(.standard, and: .standard) == .unchanged)
    #expect(OrientationChange.between(.standard, and: .upsideDown) == .restartCapture)
    #expect(OrientationChange.between(.upsideDown, and: .standard) == .restartCapture)
    #expect(OrientationChange.between(.turnedClockwise, and: .turnedCounterclockwise) == .restartCapture)
}

@Test func changingBetweenLandscapeAndPortraitRecreatesTheDisplay() {
    #expect(OrientationChange.between(.standard, and: .turnedClockwise) == .recreateDisplay)
    #expect(OrientationChange.between(.upsideDown, and: .turnedCounterclockwise) == .recreateDisplay)
    #expect(OrientationChange.between(.turnedClockwise, and: .standard) == .recreateDisplay)
}

@Test func virtualDisplayIsReusedOnlyForTheSameShape() {
    let base = HeadShape(physical: panel, refreshHz: 60, orientation: .standard)
    var flipped = base
    flipped.orientation = .upsideDown
    var portrait = base
    portrait.orientation = .turnedClockwise
    var otherPortrait = base
    otherPortrait.orientation = .turnedCounterclockwise
    // 180 degrees keeps the virtual display (same logical size); only the copy changes.
    #expect(base.virtualDisplayReusable(for: flipped))
    #expect(!base.virtualDisplayReusable(for: portrait))
    // Both portrait orientations share a portrait virtual display.
    #expect(portrait.virtualDisplayReusable(for: otherPortrait))
    var faster = base
    faster.refreshHz = 30
    #expect(!base.virtualDisplayReusable(for: faster))
    var otherPanel = base
    otherPanel.physical = PixelSize(width: 2560, height: 1440)
    #expect(!base.virtualDisplayReusable(for: otherPanel))
}

@Test func aRetainedPortraitDisplayIsNotReusedForALandscapeReconnect() {
    // A grace-period reconnect must not hand a portrait display to a landscape head, or the reverse.
    let retainedPortrait = HeadShape(physical: panel, refreshHz: 60, orientation: .turnedClockwise)
    let returningLandscape = HeadShape(physical: panel, refreshHz: 60, orientation: .standard)
    #expect(!retainedPortrait.virtualDisplayReusable(for: returningLandscape))
    #expect(!returningLandscape.virtualDisplayReusable(for: retainedPortrait))
}

// MARK: - Default mode

@Test func portraitHeadsGetTheirOwnDefaultModeEvenWhenLandscapeWasConfigured() {
    // ConfiguredMonitors records that the default HiDPI mode was applied. A portrait shape offers a
    // different mode list, so an earlier landscape entry must not suppress its default.
    let key = MonitorKey(vendorID: 0x22f0, productCode: 0x3a4b, serial: 0x1234_5678, head: 0)
    let configured = [key.configuredModesKey(.standard)]
    #expect(configured.contains(key.configuredModesKey(.standard)))
    #expect(!configured.contains(key.configuredModesKey(.turnedClockwise)))
}

@Test func thePortraitDefaultModeIsRememberedAcrossCounterclockwiseToo() {
    // Both portrait orientations share a mode list, so the default is applied once for both.
    let key = MonitorKey(vendorID: 0x22f0, productCode: 0x3a4b, serial: 0x1234_5678, head: 0)
    let configured = [key.configuredModesKey(.turnedClockwise)]
    #expect(configured.contains(key.configuredModesKey(.turnedCounterclockwise)))
}

// MARK: - Selecting an orientation (finding: a failed display creation must be retried, not ignored)

@Test func aHeadWithoutADisplayCreatesOneForTheSelectedOrientation() {
    // A head whose display creation failed has no display. Choosing an orientation, including the one it
    // already shows, must try again. Doing nothing here was the bug.
    for orientation in DisplayOrientation.allCases {
        #expect(OrientationApplication.plan(hasDisplay: false, applied: orientation, requested: orientation)
                == .createDisplay)
    }
    #expect(OrientationApplication.plan(hasDisplay: false, applied: .standard, requested: .upsideDown)
            == .createDisplay)
    #expect(OrientationApplication.plan(hasDisplay: false, applied: .standard, requested: .turnedClockwise)
            == .createDisplay)
}

@Test func aHeadWithADisplayFollowsTheSameRulesAsBefore() {
    #expect(OrientationApplication.plan(hasDisplay: true, applied: .standard, requested: .standard) == .none)
    #expect(OrientationApplication.plan(hasDisplay: true, applied: .standard, requested: .upsideDown)
            == .restartCapture)
    #expect(OrientationApplication.plan(hasDisplay: true, applied: .turnedClockwise,
                                        requested: .turnedCounterclockwise) == .restartCapture)
    #expect(OrientationApplication.plan(hasDisplay: true, applied: .standard, requested: .turnedClockwise)
            == .recreateDisplay)
}

// MARK: - Default mode setup survives a capture restart

@Test func aNewDisplayStillNeedsItsDefaultModeUnlessTheShapeIsRecorded() {
    let key = MonitorKey(vendorID: 0x22f0, productCode: 0x3a4b, serial: 0x1234_5678, head: 0)
    #expect(key.needsDefaultMode(.standard, configured: []))
    #expect(!key.needsDefaultMode(.standard, configured: [key.configuredModesKey(.standard)]))
    // 180 shares the landscape entry, so it needs nothing more.
    #expect(!key.needsDefaultMode(.upsideDown, configured: [key.configuredModesKey(.standard)]))
    // A portrait display has its own entry.
    #expect(key.needsDefaultMode(.turnedClockwise, configured: [key.configuredModesKey(.standard)]))
}
// The pending mode setup, its retries, and its gating of the first capture are tested with the controller
// (HeadControllerTests), where they run through the real state machine.
