// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore
import Testing
@testable import LinkLiteRotation

// Rotation with two monitors attached: the composed controller, runtime, lifecycle and identity allocator over the
// fake platform (ComposedHeadSupport.swift). Every race is decided by a gate the test releases.

/// Two identical monitors, both attached, turned to portrait one right after the other. Each replacement display has
/// its own identity: not the landscape one it replaces (which macOS may still be tearing down, and whose saved mode
/// and arrangement are landscape), and not its twin's. Both heads capture again, and each portrait default mode is
/// recorded under its own identity.
@MainActor
@Test func twinsTurnedTogetherGetFourDistinctIdentitiesAndBothCaptureAgain() async throws {
    let c = ComposedHeads()
    c.attach(0, serial: 0x0000_0042)
    c.attach(1, serial: 0x0000_0042)
    await c.eventually("both heads capture") { c.backend.startRequests.sorted() == [0, 1] }

    c.rotate(0, .turnedClockwise)
    c.rotate(1, .turnedClockwise)
    await c.eventually("both replacements are made") { c.recorder.creations.count == 4 }
    await c.eventually("both heads capture again") { c.backend.startRequests.count == 4 }

    let made = try (0..<4).map { try c.madeDisplay($0) }
    #expect(Set(made.map(\.identity)).count == 4, "no two displays may share an identity: \(made.map(\.identity))")
    for portrait in made[2...] {
        #expect(portrait.orientation == .turnedClockwise)
        #expect(!made[..<2].contains { $0.identity == portrait.identity },
                "a portrait display must not reuse a landscape display's identity")
    }
    await c.eventually("both portrait modes are recorded") { c.recorder.savedModes.last?.count == 4 }
    let saved = Set(c.recorder.savedModes.last ?? [])
    for portrait in made[2...] {
        #expect(saved.contains(portrait.identity.configurationKey + MonitorKey.portraitRecordSuffix))
    }
    #expect(c.status(0)?.problem == nil)
    #expect(c.status(1)?.problem == nil)
}

/// A capture start that never returns is given up after HeadTiming.captureOperationTimeout. The head shows why and
/// retries, and a rotation is no longer held behind the hung start: the old display is released and the replacement
/// made. When the hung start does return, its stream is stopped and never reaches the engine.
@MainActor
@Test func aStartThatNeverReturnsIsGivenUpSoTheHeadAndItsDisplayAreFreed() async throws {
    let c = ComposedHeads()
    c.backend.setHoldStarts(true)
    c.attach(0)
    await c.eventually("the start is in flight") { c.backend.starts.pending == [0] }

    await c.eventually("the start has a deadline") {
        c.backend.sleeps.pending.contains(HeadTiming.captureOperationTimeout)
    }
    #expect(await c.releaseSleep(HeadTiming.captureOperationTimeout))
    await c.eventually("the head reports the hung start") { c.status(0)?.problem?.contains("did not start") == true }
    #expect(c.status(0)?.captureAttempt == nil, "the given-up start no longer holds the head")

    c.rotate(0, .turnedClockwise)
    await c.eventually("the old display is released and the replacement made") { c.recorder.creations.count == 2 }
    await c.eventually("the replacement's start is in flight") { c.backend.starts.pending == [0, 0] }

    // The hung start returns at last, then the replacement's start.
    #expect(c.backend.starts.release { $0 == 0 })
    await c.eventually("the late stream exists") { c.backend.streams.count == 1 }
    let late = try c.stream(0)
    #expect(c.backend.starts.release { $0 == 0 })
    await c.eventually("the late stream is stopped") { late.isConfirmedStopped }
    #expect(late.deliverFrame() == false, "a given-up start's stream never submits a frame")
    #expect(late.submittedFrames == 0)
    // The platform call held the old display while it ran; it is gone once that call has returned.
    await c.eventually("the old display is deallocated") { !c.recorder.isAlive(creation: 0) }

    await c.eventually("the replacement stream exists") { c.backend.streams.count == 2 }
    let current = try c.stream(1)
    #expect(current.deliverFrame())
    await c.eventually("the replacement is live") { c.status(0)?.hasUsableFrame == true }
}

/// A stop that never returns is given up after HeadTiming.captureOperationTimeout and kept as unconfirmed: the head
/// shows it, and it is retried. Once a retry confirms it, the rotation that was waiting for it goes ahead.
@MainActor
@Test func aStopThatNeverReturnsIsShownAsUnconfirmedAndRetried() async throws {
    let c = ComposedHeads()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    stream.scriptStops([.stall])
    c.rotate(0, .turnedClockwise)
    await c.eventually("the stop is in flight") { c.backend.stops.pending.contains(stream.id) }
    await c.eventually("the stop has a deadline") {
        c.backend.sleeps.pending.contains(HeadTiming.captureOperationTimeout)
    }
    #expect(await c.releaseSleep(HeadTiming.captureOperationTimeout))
    await c.eventually("the hung stop is shown as unconfirmed") { c.status(0)?.stopUnconfirmed == true }
    #expect(c.recorder.creations.count == 1, "nothing is made while the old stream may still run")
    #expect(stream.deliverFrame() == false)

    await c.eventually("the stop is retried after 1 s") { c.backend.sleeps.pending.contains(.seconds(1)) }
    #expect(await c.releaseSleep(.seconds(1)))
    await c.eventually("the replacement is made once the stop is confirmed") { c.recorder.creations.count == 2 }
    #expect(!c.runtime.hasUnconfirmedStops)
    #expect(c.status(0)?.stopUnconfirmed == false)
    // The first, hung stop call finally returns; nothing changes.
    #expect(c.backend.stops.release { $0 == stream.id })
    await c.settle()
    #expect(c.recorder.creations.count == 2)
}
