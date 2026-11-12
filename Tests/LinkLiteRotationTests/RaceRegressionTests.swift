// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore
import Testing
@testable import LinkLiteRotation

// Regressions found in review of the combined production path. The real HeadController, HeadRuntime,
// StreamLifecycle and DisplayIdentityAllocator run here; only the platform is faked (ComposedHeadSupport.swift).
// Each race is decided by a gate the test releases. Nothing sleeps.

// MARK: - Release: the mode is cancelled as soon as the release is requested

/// A release is requested while the stream's stop stalls and a mode call is held inside the platform. The mode is
/// cancelled at once, so its answer, given during the stalled stop, is discarded. No further mode call is made on the
/// retired display, and the display is kept until both the stop and the held call have returned.
@MainActor
@Test func aLateModeAnswerDuringAStalledStopIsDiscardedAndTheDisplayIsKeptUntilBothReturn() async throws {
    let c = ComposedHeads()
    // The first attempt fails, so the stream starts without its mode and a mode retry is due after 1 s.
    c.recorder.scriptModes([.failed("no HiDPI mode")])
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    c.recorder.holdModes = true
    await c.eventually("the mode retry is due") { c.backend.sleeps.pending.contains(.seconds(1)) }
    c.backend.sleeps.release { $0 == .seconds(1) }
    await c.eventually("the retry is held inside its call") { c.recorder.heldModeCount == 1 }
    let oldDisplayModeCalls = c.recorder.modeDisplays.filter { $0 == 1 }.count

    stream.scriptStops([.stall])
    c.rotate(0, .turnedClockwise)                           // the release is requested
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(stream.id) }

    #expect(c.recorder.answerHeldMode(.applied), "the held call returns during the stalled stop")
    await c.settle()
    #expect(c.recorder.savedModes.isEmpty, "the answer of a cancelled setup records nothing")
    #expect(c.recorder.modeDisplays.filter { $0 == 1 }.count == oldDisplayModeCalls,
            "no mode call is begun on the retired display")
    #expect(c.recorder.creations.count == 1, "no replacement while the stop is unconfirmed")
    #expect(c.recorder.isAlive(creation: 0), "the display is kept while the stop is still pending")

    c.backend.stops.release { $0 == stream.id }
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    #expect(!c.recorder.isAlive(creation: 0))
    #expect(c.recorder.savedModes.isEmpty, "nothing from the retired display was recorded")
    #expect(c.recorder.modeDisplays.filter { $0 == 1 }.count == oldDisplayModeCalls)
    #expect(stream.isConfirmedStopped)
    #expect(try c.madeDisplay(1).orientation == .turnedClockwise)
}

/// A release requested while the mode call is held and the stop stalls, then the head is rotated again while both
/// are still pending. The retired display is held through all of it, and one replacement is made with the last choice.
@MainActor
@Test func aRotationDuringAReleaseThatWaitsOnAStopAndAHeldCallMakesOneReplacementAfterBoth() async throws {
    let c = ComposedHeads()
    c.recorder.scriptModes([.failed("no HiDPI mode")])
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    c.recorder.holdModes = true
    await c.eventually("the mode retry is due") { c.backend.sleeps.pending.contains(.seconds(1)) }
    c.backend.sleeps.release { $0 == .seconds(1) }
    await c.eventually("the retry is held") { c.recorder.heldModeCount == 1 }

    stream.scriptStops([.stall])
    c.rotate(0, .turnedClockwise)
    c.rotate(0, .upsideDown)
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(stream.id) }
    c.rotate(0, .turnedCounterclockwise)
    await c.settle()
    #expect(c.recorder.creations.count == 1)

    c.backend.stops.release { $0 == stream.id }
    await c.settle()
    #expect(c.recorder.isAlive(creation: 0), "the held call still holds the display")
    #expect(c.recorder.creations.count == 1)

    #expect(c.recorder.answerHeldMode(.applied))
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    #expect(try c.madeDisplay(1).orientation == .turnedCounterclockwise, "the last choice is the one applied")
    #expect(c.recorder.savedModes.isEmpty)
}

// MARK: - A head that is being rebuilt stays listed

/// While its display is being rebuilt, a head is still listed: as waiting, with the latest rotation selected.
@MainActor
@Test func aHeadWhoseDisplayIsRebuildingStaysListedWithItsLatestRotationWhileItsStopStalls() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    stream.scriptStops([.stall])
    c.rotate(0, .turnedClockwise)
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(stream.id) }
    let waiting = try #require(c.status(0), "the head stays listed while its display is rebuilt")
    #expect(waiting.display == nil)
    #expect(waiting.waitingForIdentity, "the replacement waits for the old display to be released")
    #expect(waiting.orientation == .turnedClockwise)
    #expect(!waiting.stopUnconfirmed, "a stop in flight is not reported as unconfirmed")
    #expect(c.runtime.controller.attachedMonitors.map(\.head) == [0])

    c.rotate(0, .upsideDown)
    c.rotate(0, .turnedCounterclockwise)
    #expect(c.runtime.controller.statuses.filter { $0.monitor.head == 0 }.count == 1, "one row per head")
    #expect(c.status(0)?.orientation == .turnedCounterclockwise, "the latest choice stays selected")

    c.backend.stops.release { $0 == stream.id }
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    #expect(try c.madeDisplay(1).orientation == .turnedCounterclockwise)
    await c.eventually("the head shows its new display") { c.status(0)?.display != nil }
    #expect(c.status(0)?.waitingForIdentity == false)
}

/// A stop that fails is shown on its head while it is unconfirmed, and cleared once the retry confirms it.
@MainActor
@Test func aStopThatFailsIsShownOnItsHeadUntilTheRetryConfirmsIt() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    stream.scriptStops([.fail, .succeed])
    c.rotate(0, .turnedClockwise)
    await c.eventually("the unconfirmed stop is shown on the head") { c.status(0)?.stopUnconfirmed == true }
    #expect(c.status(0)?.waitingForIdentity == true)
    #expect(c.recorder.creations.count == 1)

    #expect(c.backend.sleeps.release { $0 == .seconds(1) }, "the stop is retried after 1 s")
    await c.eventually("the replacement is made") { c.recorder.creations.count == 2 }
    #expect(c.status(0)?.stopUnconfirmed == false)
    #expect(stream.isConfirmedStopped)
}

/// A detach while the old display is being rebuilt removes the head's row. The release that follows makes no display.
@MainActor
@Test func aDetachWhileARebuildWaitsOnAStallingStopRemovesTheRowAndMakesNoDisplayAfterward() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    stream.scriptStops([.stall])
    c.rotate(0, .turnedClockwise)
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(stream.id) }
    c.detach(0)
    #expect(c.status(0) == nil, "the detached head's row goes")

    c.backend.stops.release { $0 == stream.id }
    await c.eventually("the old display is released") { !c.recorder.isAlive(creation: 0) }
    await c.settle()
    #expect(c.recorder.creations.count == 1, "a stale release makes no display for the detached head")
    #expect(c.runtime.controller.attachedMonitors.isEmpty)
}

// MARK: - Screen Recording: a denial from a stream started before a grant

/// A stream started under the old grant reports its denial after the regrant. The denial describes permission that has
/// since been restored, so it does not block the head, and the head restarts under the grant.
@MainActor
@Test func aDelayedDenialFromAStreamStartedBeforeARegrantDoesNotBlockTheHead() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }
    let running = try #require(c.status(0)?.captureAttempt)

    c.runtime.send(.permissionChanged(granted: false))     // revoked
    c.runtime.send(.permissionChanged(granted: true))      // granted again while the stream still runs
    await c.settle()
    #expect(c.backend.startRequests == [0], "a grant does not restart a stream that is running")

    c.runtime.send(.captureStopped(running, .permissionDenied))   // the old stream's denial arrives late
    await c.settle()
    #expect(!c.runtime.controller.permissionDenied, "the stale denial must not undo the grant")
    #expect(c.status(0)?.problem == nil)
    #expect(stream.isConfirmedStopped)

    #expect(c.backend.sleeps.release { $0 == .seconds(1) })
    await c.eventually("the head restarts under the grant") { c.backend.startRequests == [0, 0] }
    await c.eventually("live again") { c.status(0)?.captureRunning == true }
}

// MARK: - Display creation: a refused creation is retried

/// A refused display creation is retried once after its 1 s backoff, and the error stays shown until the retry works.
@MainActor
@Test func aRefusedDisplayCreationIsRetriedAfterItsBackoffAndTheHeadStarts() async throws {
    let c = ComposedHeads()
    c.recorder.scriptCreations(["CGVirtualDisplay refused"])
    c.attach(0)
    await c.eventually("the retry is due after 1 s") { c.backend.sleeps.pending.contains(.seconds(1)) }
    #expect(c.recorder.creationAttempts == 1)
    #expect(c.status(0)?.display == nil)
    #expect(c.status(0)?.problem == "CGVirtualDisplay refused")

    #expect(c.backend.sleeps.release { $0 == .seconds(1) })
    await c.eventually("the retry creates the display") { c.recorder.creations.count == 1 }
    await c.eventually("the head starts") { c.backend.startRequests == [0] }
    #expect(c.recorder.creationAttempts == 2, "one retry, not one per event")
    #expect(c.status(0)?.problem == nil)
}
