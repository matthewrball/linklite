// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore
import Testing
@testable import LinkLiteRotation

// The composed orchestration: HeadController through HeadRuntime, with the real StreamLifecycle and the real
// DisplayIdentityAllocator. Only the platform is faked (see ComposedHeadSupport.swift). Each race is decided by
// the test releasing a gate, never by time.

// MARK: - Starts and modes

@MainActor
@Test func aNewHeadStartsOnlyOnceItsModeIsAppliedAndIsLiveOnItsFirstFrame() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    #expect(stream.deliverFrame())
    await c.eventually("the head is live") { c.status(0)?.hasUsableFrame == true }
    #expect(c.status(0)?.captureRunning == true)
}

@MainActor
@Test func aStartWaitsForTheFirstModeSetupEvenIfTheModeIsSlow() async {
    let c = ComposedHeads()
    c.recorder.holdModes = true
    c.attach(0)
    await c.eventually("the mode setup is in flight") { c.recorder.heldModeCount == 1 }
    await c.settle()
    #expect(c.backend.startRequests.isEmpty, "no stream may start before the first mode attempt resolves")

    #expect(c.recorder.answerHeldMode(.applied))
    await c.eventually("the capture starts after the mode") { c.backend.startRequests == [0] }
}

/// Rotation while the initial mode setup is in flight. The display is still held by that setup, so its identity is
/// held too: the replacement waits, and is made only once the old display is really gone.
@MainActor
@Test func rotatingWhileTheInitialModeSetupIsInFlightHoldsTheOldDisplayUntilItIsGone() async throws {
    let c = ComposedHeads()
    c.recorder.holdModes = true
    c.attach(0)
    await c.eventually("the mode setup is in flight") { c.recorder.heldModeCount == 1 }

    c.rotate(0, .turnedClockwise)
    // The release waits for the display's mode setup to return: the setup is cancelled and awaited before the display
    // is dropped. So the replacement is not even asked for while the setup is held.
    await c.eventually("the release is waiting for the held setup") { c.recorder.heldModeCount == 1 }
    await c.settle()
    #expect(c.recorder.creations.count == 1, "no second display may exist while the first is alive")
    #expect(c.recorder.isAlive(creation: 0))

    #expect(c.recorder.answerHeldMode(.applied))
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    #expect(!c.recorder.isAlive(creation: 0), "the old display was deallocated before its identity was reused")
    let first = try c.madeDisplay(0)
    let second = try c.madeDisplay(1)
    #expect(second.orientation == .turnedClockwise)
    #expect(second.identity == first.identity)
}

// MARK: - Rotation storms

/// Rotations while the old display is held by a stalled stop: each rotation stores its choice, and exactly one
/// replacement is made, with the last choice, once the stop is confirmed.
@MainActor
@Test func rapidOppositeRotationsWhileAStopIsPendingCreateOneDisplayWithTheLastChoice() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    stream.scriptStops([.stall])
    c.rotate(0, .turnedClockwise)
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(stream.id) }
    c.rotate(0, .upsideDown)
    c.rotate(0, .turnedCounterclockwise)
    c.rotate(0, .standard)
    c.rotate(0, .turnedClockwise)
    c.rotate(0, .standard)
    await c.settle()
    #expect(c.recorder.creations.count == 1, "nothing is made while the old stream may still run")
    #expect(c.recorder.isAlive(creation: 0))
    #expect(!stream.isConfirmedStopped)
    // The stop is stalled and the stream still runs, but it is retired: its frames must already be refused.
    #expect(stream.deliverFrame() == false, "a retired stream submits nothing while its stop is pending")
    #expect(stream.submittedFrames == 1)

    #expect(c.backend.stops.release { $0 == stream.id })
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    let first = try c.madeDisplay(0)
    let second = try c.madeDisplay(1)
    #expect(second.orientation == .standard, "the last choice is the one applied")
    #expect(stream.isConfirmedStopped)
    #expect(!c.recorder.isAlive(creation: 0))
    #expect(second.identity == first.identity)
    #expect(stream.deliverFrame() == false, "a retired stream submits no frame")
    #expect(stream.submittedFrames == 1, "only the frame delivered while live reached the engine")
}

/// A monitor attached while the old display is still being released: the replacement is made for the newest monitor.
@MainActor
@Test func aMonitorAttachedDuringARebuildIsTheOneTheReplacementIsMadeFor() async throws {
    let c = ComposedHeads()
    c.attach(0, serial: 0x1111_1111)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.scriptStops([.stall])
    c.detach(0)
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(stream.id) }

    c.attach(0, serial: 0x2222_2222)
    await c.settle()
    #expect(c.recorder.creations.count == 1)

    #expect(c.backend.stops.release { $0 == stream.id })
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    #expect(try c.madeDisplay(1).identity.serial == 0x2222_2222)
}

// MARK: - Stops

/// A failed stop is retried with backoff and never counted as stopped. Until it is confirmed the head keeps its
/// display, and no other stream starts on it. Once the retries confirm the stop, the head recovers on its own.
@MainActor
@Test func aFailedStopIsRetriedAndTheHeadRecoversOnceItIsConfirmed() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    stream.scriptStops([.fail, .fail, .succeed])
    c.detach(0)                                    // kept for the reconnect grace; its stop fails
    await c.eventually("the failed stop is retried after 1 s") { c.backend.sleeps.pending.contains(.seconds(1)) }
    await c.eventually("the head reports the unconfirmed stop") { c.runtime.hasUnconfirmedStops }
    #expect(!stream.isConfirmedStopped, "a failed stop does not count as stopped")

    // No monitor comes back. The retry fails again, then succeeds after 2 s.
    #expect(c.backend.sleeps.release { $0 == .seconds(1) })
    await c.eventually("the second retry is due after 2 s") { c.backend.sleeps.pending.contains(.seconds(2)) }
    #expect(c.runtime.hasUnconfirmedStops)
    #expect(c.recorder.creations.count == 1, "no new display while the old stream is unconfirmed")

    #expect(c.backend.sleeps.release { $0 == .seconds(2) })
    await c.eventually("the stop is confirmed") { !c.runtime.hasUnconfirmedStops }
    #expect(stream.isConfirmedStopped)
    #expect(c.backend.startRequests == [0], "no start was attempted on the head while its stop was unconfirmed")

    // The reconnect grace ends with nobody back: the display is released now that its streams are stopped.
    #expect(c.backend.sleeps.release { $0 == .seconds(20) })
    await c.eventually("the display is released") { !c.recorder.isAlive(creation: 0) }

    // Recovery: the monitor comes back and a new display and stream are made.
    c.attach(0)
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    await c.eventually("the new stream starts") { c.backend.startRequests == [0, 0] }
    #expect(try c.madeDisplay(1).identity == c.madeDisplay(0).identity)
}

/// A rebuild while a start is still in flight: the old display is released only after the start has returned and
/// its stream is stopped. The replacement waits for the identity, so it is never made while the old one exists.
@MainActor
@Test func aRebuildDuringAnInFlightStartHoldsTheOldDisplayUntilItsStreamIsStopped() async throws {
    let c = ComposedHeads()
    c.backend.setHoldStarts(true)
    c.attach(0)
    await c.eventually("the start is in flight") { c.backend.starts.pending == [0] }

    c.rotate(0, .turnedClockwise)            // a rebuild: the old display is released, not kept
    await c.settle()
    #expect(c.recorder.creations.count == 1)
    #expect(c.recorder.isAlive(creation: 0), "the in-flight start still holds the display")

    #expect(c.backend.starts.release { $0 == 0 })
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    let stream = try c.stream(0)
    #expect(stream.isConfirmedStopped, "the display was released only after its stream was stopped")
    #expect(stream.submittedFrames == 0)
    #expect(!c.recorder.isAlive(creation: 0))
    #expect(try c.madeDisplay(1).identity == c.madeDisplay(0).identity)
}

/// The same monitor coming back during an in-flight start reuses the kept display, so no second identity is claimed.
/// The cancelled start's stream is stopped before the next start on the head begins, and it submits no frame.
@MainActor
@Test func aReattachDuringAnInFlightStartReusesTheDisplayAndStopsTheCancelledStartFirst() async throws {
    let c = ComposedHeads()
    c.backend.setHoldStarts(true)
    c.attach(0)
    await c.eventually("start 1 is in flight") { c.backend.starts.pending == [0] }

    c.detach(0)
    c.attach(0)
    await c.settle()
    #expect(c.recorder.creations.count == 1, "the same monitor reuses its display")
    #expect(c.backend.startRequests == [0], "the next start waits for the cancelled one to finish")

    #expect(c.backend.starts.release { $0 == 0 })
    await c.eventually("start 2 is requested") { c.backend.startRequests == [0, 0] }
    let cancelled = try c.stream(0)
    #expect(cancelled.stopAttempts == 1, "the cancelled stream was stopped before the next start began")
    #expect(cancelled.deliverFrame() == false)
    #expect(cancelled.submittedFrames == 0)

    await c.eventually("start 2 is in flight") { c.backend.starts.pending == [0] }
    #expect(c.backend.starts.release { $0 == 0 })
    await c.eventually("the second stream is kept") { c.status(0)?.captureRunning == true }
    let kept = try c.stream(1)
    #expect(kept.stopAttempts == 0)
    #expect(kept.deliverFrame())
}

/// A stream that is already delivering frames while its start has not yet returned. Once its attempt is retired, its
/// frames are refused at once, before the start returns and before any stop is attempted.
@MainActor
@Test func aFrameFromARetiredStreamIsRefusedEvenWhileItsStartIsStillReturning() async throws {
    let c = ComposedHeads()
    c.backend.setHoldAfterOpen(true)
    c.attach(0)
    await c.eventually("the stream is open but its start has not returned") { c.backend.openedHolds.pending == [0] }
    let stream = try c.stream(0)
    #expect(stream.deliverFrame(), "the stream is live while its start is still returning")

    c.detach(0)
    #expect(stream.deliverFrame() == false, "a retired stream submits nothing")
    #expect(stream.submittedFrames == 1)

    #expect(c.backend.openedHolds.release { $0 == 0 })
    await c.eventually("the late stream is stopped") { stream.stopAttempts == 1 }
    #expect(stream.deliverFrame() == false)
    #expect(stream.submittedFrames == 1)
}

/// A start that returns after its attempt was cancelled: the stream is stopped, its gate was closed at the cancel,
/// and no frame from it reaches the engine.
@MainActor
@Test func aLateStartIsStoppedAndItsFramesNeverReachTheEngine() async throws {
    let c = ComposedHeads()
    c.backend.setHoldStarts(true)
    c.attach(0)
    await c.eventually("the start is in flight") { c.backend.starts.pending == [0] }

    c.detach(0)
    #expect(c.backend.starts.release { $0 == 0 })
    await c.eventually("the late stream is stopped") { c.backend.streams.first?.stopAttempts == 1 }
    let stream = try c.stream(0)
    #expect(stream.deliverFrame() == false)
    #expect(stream.submittedFrames == 0)
    #expect(stream.isConfirmedStopped)
    #expect(c.backend.startRequests == [0], "the cancelled start was not repeated")
}

// MARK: - Mode retries

@MainActor
@Test func aFailedModeRetryNeverStopsARunningCapture() async throws {
    let c = ComposedHeads()
    c.recorder.scriptModes([.failed("no HiDPI mode")])
    c.attach(0)
    await c.eventually("the capture starts without the mode") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    #expect(c.backend.sleeps.release { $0 == .seconds(1) }, "the mode retry is due after 1 s")
    await c.eventually("the mode is tried again") { c.recorder.modeCalls == 2 }
    await c.settle()
    #expect(stream.stopAttempts == 0, "a mode retry must not stop the capture")
    #expect(c.backend.startRequests == [0], "a mode retry must not restart the capture")
    #expect(c.status(0)?.hasUsableFrame == true)
}

@MainActor
@Test func aDetachCancelsAPendingModeRetry() async {
    let c = ComposedHeads()
    c.recorder.scriptModes([.failed("no HiDPI mode")])
    c.attach(0)
    await c.eventually("the mode retry is due") { c.backend.sleeps.pending.contains(.seconds(1)) }
    c.detach(0)
    await c.settle()
    #expect(!c.backend.sleeps.pending.contains(.seconds(1)), "the cancelled retry is no longer waiting")
    #expect(c.recorder.modeCalls == 1)
}

// MARK: - Cursor

@MainActor
@Test func cursorTargetsHideWhenAHeadTurnsAndReturnWhenItIsUpright() async throws {
    let c = ComposedHeads()
    c.attach(0, cursor: true)
    await c.eventually("the cursor target is published") { c.recorder.published.last?.count == 1 }
    #expect(c.recorder.published.last?.first?.head == 0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    try c.stream(0).deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    c.rotate(0, .turnedClockwise)
    await c.eventually("the cursor target is withdrawn") { c.recorder.published.last == [] }
    await c.eventually("the turned head starts") { c.backend.startRequests == [0, 0] }
    await c.settle()
    #expect(c.recorder.published.last == [], "a turned head draws no hardware cursor")

    c.rotate(0, .standard)
    await c.eventually("the cursor target returns") { c.recorder.published.last?.count == 1 }
    #expect(c.recorder.published.last?.first?.head == 0)
}

// MARK: - Twins and restart

@MainActor
@Test func identicalTwinsGetDistinctIdentitiesAndEachRecordsItsDefaultModeUnderItsOwn() async throws {
    let c = ComposedHeads()
    c.attach(0, serial: 0x0000_0042)
    await c.eventually("head 0 has its display") { c.recorder.creations.count == 1 }
    c.attach(1, serial: 0x0000_0042)
    await c.eventually("head 1 has its display") { c.recorder.creations.count == 2 }

    let first = try c.madeDisplay(0).identity
    let second = try c.madeDisplay(1).identity
    #expect(first != second, "identical monitors must not share an identity")
    await c.eventually("both default modes are recorded") { c.recorder.savedModes.last?.count == 2 }
    let saved = c.recorder.savedModes.last ?? []
    #expect(saved.contains(first.configurationKey))
    #expect(saved.contains(second.configurationKey))
}

@MainActor
@Test func aRestartKeepsEachMonitorsRotationAndDefaultMode() async throws {
    let first = ComposedHeads()
    first.attach(0, serial: 0x0000_0077)
    await first.eventually("the mode is recorded") { first.recorder.savedModes.last != nil }
    first.rotate(0, .upsideDown)
    await first.eventually("the rotation is saved") { first.recorder.savedPreferences.last != nil }
    let preferences = first.recorder.savedPreferences.last ?? [:]
    let modes = first.recorder.savedModes.last ?? []

    // A new launch reads the saved state.
    let second = ComposedHeads(preferences: OrientationPreferences(propertyList: preferences), configured: modes)
    second.attach(0, serial: 0x0000_0077)
    await second.eventually("the display is made") { second.recorder.creations.count == 1 }
    #expect(try second.madeDisplay(0).orientation == .upsideDown)
    await second.eventually("the capture starts") { second.backend.startRequests == [0] }
    #expect(second.recorder.modeCalls == 0, "a monitor already configured is not configured again")
}
