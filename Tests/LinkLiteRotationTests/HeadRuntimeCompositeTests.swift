// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore
import Testing
@testable import LinkLiteRotation

// Composite tests over the real HeadController, HeadDriver, HeadRuntime, StreamLifecycle and DisplayIdentityAllocator,
// with the platform replaced by the fakes in ComposedHeadSupport. Every mode setup, stream start, stream stop, retry
// timer and permission event waits on a gate the test opens, so each ordering here is deterministic.

// MARK: - A release waits for the default-mode setup and for the stream stop

@MainActor
@Test func aReleaseWaitsForAStuckModeSetupAndItsLateAnswerNeverSetsTheMode() async throws {
    let c = ComposedHeads()
    c.recorder.holdModes = true
    c.attach(0)
    await c.eventually("the setup is held inside its call") { c.recorder.heldModeCount == 1 }

    c.rotate(0, .turnedClockwise)                           // the old display is released: its setup is cancelled
    await c.settle()
    #expect(c.recorder.isAlive(creation: 0), "the display is kept while its setup is inside its call")
    #expect(c.recorder.creations.count == 1, "no replacement while the old display is alive")

    #expect(c.recorder.answerHeldMode(.applied))            // the call returns late, after the cancellation
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    #expect(!c.recorder.isAlive(creation: 0), "the old display is dropped before its replacement exists")
    #expect(c.recorder.modeSetDisplays.isEmpty, "the cancelled setup set no mode")
    #expect(c.recorder.savedModes.isEmpty, "the cancelled setup's .applied recorded nothing")
    #expect(try c.madeDisplay(1).orientation == .turnedClockwise)
    await c.eventually("only the replacement's own setup is in flight") { c.recorder.heldModeCount == 1 }
    #expect(c.recorder.modeCalls == 2)
}

@MainActor
@Test func aReleaseWaitsForBothAStalledStreamStopAndAStuckModeSetup() async throws {
    let c = ComposedHeads()
    c.recorder.scriptModes([.failed("refused")])            // the first attempt fails, so a retry is scheduled
    c.attach(0)
    await c.eventually("the capture starts once the first attempt resolved") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    c.recorder.holdModes = true
    await c.eventually("the mode retry is due") { c.backend.sleeps.pending.contains(.seconds(1)) }
    c.backend.sleeps.release { $0 == .seconds(1) }
    await c.eventually("the retry is held inside its call") { c.recorder.heldModeCount == 1 }

    stream.scriptStops([.stall])
    c.rotate(0, .turnedClockwise)
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(stream.id) }
    await c.settle()
    #expect(c.recorder.isAlive(creation: 0))

    c.backend.stops.release { $0 == stream.id }             // the stream is confirmed stopped...
    await c.settle()
    #expect(c.recorder.isAlive(creation: 0), "...but the held setup still keeps the display")
    #expect(c.recorder.creations.count == 1)

    #expect(c.recorder.answerHeldMode(.applied))            // ...and once it returns, the display is released
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    #expect(!c.recorder.isAlive(creation: 0))
    #expect(c.recorder.modeSetDisplays.isEmpty, "the cancelled setup set no mode")
    #expect(stream.isConfirmedStopped)
}

// MARK: - Rapid retries never overlap a mode setup

@MainActor
@Test func rapidRotationsWhileTheSetupIsHeldMakeOneReplacementWithTheLastChoiceAndNeverTwoSetups() async throws {
    let c = ComposedHeads()
    c.recorder.holdModes = true
    c.attach(0)
    await c.eventually("the setup is held") { c.recorder.heldModeCount == 1 }

    for orientation in [DisplayOrientation.turnedClockwise, .upsideDown, .turnedCounterclockwise, .standard,
                        .turnedClockwise] {
        c.rotate(0, orientation)
        #expect(c.recorder.heldModeCount <= 1, "never two setups in flight")
    }
    await c.settle()
    #expect(c.recorder.creations.count == 1, "the old display is still alive")

    #expect(c.recorder.answerHeldMode(.applied))
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    await c.settle()
    #expect(c.recorder.creations.count == 2, "one replacement, not one per rotation")
    #expect(try c.madeDisplay(1).orientation == .turnedClockwise, "the last choice")
    #expect(c.recorder.modeCalls == 2, "the first setup and the replacement's only")
    #expect(c.recorder.heldModeCount == 1)
}

// MARK: - A usable frame before the start returns

@MainActor
@Test func aUsableFrameBeforeTheStartReturnsIsKeptForThatStartAndArmsNoDeadline() async throws {
    let c = ComposedHeads()
    c.backend.setHoldAfterOpen(true)
    c.attach(0)
    await c.eventually("the stream is open and its start is held") { c.backend.openedHolds.pending.contains(0) }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.settle()
    #expect(c.status(0)?.hasUsableFrame == false, "not live until its start returns")

    c.backend.openedHolds.release { $0 == 0 }
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }
    #expect(c.status(0)?.captureRunning == true)
    #expect(!c.backend.sleeps.pending.contains(HeadTiming.firstUsableFrameDeadline),
            "no first-frame deadline is armed for a live stream")
    #expect(stream.submittedFrames == 1)
}

// MARK: - Screen Recording: nothing starts while denied

@MainActor
@Test func noStreamStartsWhileScreenRecordingIsDeniedThroughAttachRotationAndResume() async throws {
    let c = ComposedHeads()
    c.runtime.send(.permissionChanged(granted: false))
    c.attach(0)
    await c.settle()
    #expect(c.recorder.creations.count == 1, "the head gets its display")
    #expect(c.backend.startRequests.isEmpty, "no start on attach")

    c.rotate(0, .turnedClockwise)
    await c.settle()
    #expect(c.recorder.creations.count == 2)
    #expect(c.backend.startRequests.isEmpty, "no start on rotation")

    c.runtime.send(.resumeCapture)
    await c.settle()
    #expect(c.backend.startRequests.isEmpty, "no start on resume")
    #expect(c.status(0)?.problem == "Screen Recording permission is required")

    c.runtime.send(.permissionChanged(granted: true))
    await c.eventually("the grant starts the head") { c.backend.startRequests == [0] }
    await c.settle()
    #expect(c.backend.startRequests == [0], "exactly one start")
}

@MainActor
@Test func aStreamThatLosesPermissionStaysDownUntilTheGrantAndRestartsOnce() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }
    let running = try #require(c.status(0)?.captureAttempt)

    c.runtime.send(.captureStopped(running, .permissionDenied))   // revoked while running
    await c.settle()
    #expect(c.runtime.controller.permissionDenied)
    #expect(c.backend.startRequests == [0], "no restart while revoked")
    #expect(stream.isConfirmedStopped, "the stream the controller stopped is confirmed stopped")

    c.runtime.send(.permissionChanged(granted: true))
    await c.eventually("the regrant restarts the head") { c.backend.startRequests == [0, 0] }
    await c.settle()
    #expect(c.backend.startRequests == [0, 0], "one restart")
}

@MainActor
@Test func aDenialFromAStartIssuedBeforeARegrantRetriesWithoutBlockingTheHead() async throws {
    let c = ComposedHeads()
    c.backend.setHoldStarts(true)
    c.backend.failNextStart(FakeError.screenRecordingDenied)
    c.attach(0)
    await c.eventually("the start is held") { c.backend.starts.pending.contains(0) }
    c.backend.setHoldStarts(false)                               // the retry is not held

    c.runtime.send(.permissionChanged(granted: false))           // revoked while the start is in flight
    c.runtime.send(.permissionChanged(granted: true))            // and granted again
    c.backend.starts.release { $0 == 0 }
    await c.eventually("the retry is due") { c.backend.sleeps.pending.contains(.seconds(1)) }
    #expect(!c.runtime.controller.permissionDenied, "the stale denial describes permission already restored")
    #expect(c.status(0)?.problem == nil)

    c.backend.sleeps.release { $0 == .seconds(1) }
    await c.eventually("the head is running") { c.status(0)?.captureRunning == true }
    #expect(c.backend.startRequests == [0, 0])
}

// MARK: - A stream failure never overlaps its own stop

@MainActor
@Test func aRestartAfterAStreamFailureWaitsForItsStalledStopAndRunsOneStreamAtATime() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let first = try c.stream(0)
    first.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }
    let running = try #require(c.status(0)?.captureAttempt)

    first.scriptStops([.stall])
    c.runtime.send(.captureStopped(running, .failed("the stream stopped")))
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(first.id) }
    await c.eventually("the retry is due") { c.backend.sleeps.pending.contains(.seconds(1)) }
    c.backend.sleeps.release { $0 == .seconds(1) }
    await c.settle()
    #expect(c.backend.startRequests == [0], "no second stream while the first stop is unconfirmed")
    #expect(!first.isConfirmedStopped)

    c.backend.stops.release { $0 == first.id }
    await c.eventually("the restart runs once the stop is confirmed") { c.backend.startRequests == [0, 0] }
    #expect(first.isConfirmedStopped)
    #expect(c.backend.streams.count == 2)
    #expect(c.backend.streams.filter { !$0.isConfirmedStopped }.count == 1, "one live stream at a time")
}
