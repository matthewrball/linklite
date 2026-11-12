// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import LinkLiteRotation

// ScreenRecordingAccess is the launch request and the activation recheck that DisplayHost and AppDelegate use, with the
// CoreGraphics calls injected. The fake OS below never prompts and never changes system state: the test decides what
// the check reports and what the explicit request does.

/// The OS side of Screen Recording access, as a test sees it.
@MainActor
private final class FakeScreenRecordingOS {
    /// What the check reports.
    var granted = false
    /// What the explicit request returns, and whether it grants access as a side effect.
    var requestReturns = false
    var requestGrants = false
    private(set) var requests = 0
    /// The preflight checks made. Every activation or panel check makes one.
    private(set) var checks = 0

    func platform() -> ScreenRecordingAccess.Platform {
        ScreenRecordingAccess.Platform(
            isGranted: { [self] in
                checks += 1
                return granted
            },
            requestAccess: { [self] in
                requests += 1
                if requestGrants { granted = true }
                return requestReturns
            }
        )
    }
}

/// What the access reports to the runtime, in order.
@MainActor
private final class ReportLog {
    private(set) var values: [Bool] = []

    func record(_ granted: Bool) {
        values.append(granted)
    }
}

@MainActor
@Test func aGrantFromTheLaunchRequestIsReportedAtOnceAndTheHeadStartsWithoutAnotherPrompt() async throws {
    let c = ComposedHeads()
    let os = FakeScreenRecordingOS()
    os.requestReturns = true
    os.requestGrants = true
    let access = ScreenRecordingAccess(platform: os.platform()) { c.runtime.send(.permissionChanged(granted: $0)) }

    access.checkAtLaunch()
    #expect(os.requests == 1, "the launch asks once")
    #expect(!c.runtime.controller.permissionDenied, "the grant is reported after the request, not left denied")

    c.attach(0)
    await c.eventually("the head starts") { c.backend.startRequests == [0] }
    #expect(os.requests == 1, "no further prompt")
}

/// The request shows the prompt and answers "not yet". Nothing is claimed as granted. The app is activated while the
/// user is still in Settings, then again after they grant access. Only the second activation starts the head.
@MainActor
@Test func aRequestThatIsNotAnsweredWithAGrantIsNotClaimedAndTheNextActivationConfirmsIt() async throws {
    let c = ComposedHeads()
    let os = FakeScreenRecordingOS()
    let access = ScreenRecordingAccess(platform: os.platform()) { c.runtime.send(.permissionChanged(granted: $0)) }

    access.checkAtLaunch()
    #expect(os.requests == 1)
    #expect(c.runtime.controller.permissionDenied, "denied until a check confirms access")
    c.attach(0)
    await c.settle()
    #expect(c.backend.startRequests.isEmpty)
    #expect(c.status(0)?.problem == "Screen Recording permission is required")

    access.recheck()          // activation while still in Settings
    #expect(c.runtime.controller.permissionDenied, "nothing was granted, so nothing is claimed")
    #expect(os.requests == 1, "an activation never prompts")

    os.granted = true                                                        // the user grants access in Settings
    access.recheck()
    await c.eventually("the head starts") { c.backend.startRequests == [0] }
    #expect(!c.runtime.controller.permissionDenied)
    #expect(os.requests == 1)
}

/// A request that reports a grant, which a check does not confirm, is not trusted on its own.
@MainActor
@Test func aRequestThatReportsAGrantIsNotTrustedUnlessACheckConfirmsIt() {
    let c = ComposedHeads()
    let os = FakeScreenRecordingOS()
    os.requestReturns = true                                                 // says yes, the check says no
    let access = ScreenRecordingAccess(platform: os.platform()) { c.runtime.send(.permissionChanged(granted: $0)) }

    access.checkAtLaunch()
    #expect(c.runtime.controller.permissionDenied)
    #expect(os.requests == 1)
}

/// Activation with access already granted checks, reports the grant, and never prompts. Nothing is denied, so nothing
/// visible changes.
@MainActor
@Test func anActivationWithoutADenialChangesNothingAndPromptsNever() {
    let c = ComposedHeads()
    let os = FakeScreenRecordingOS()
    os.granted = true
    let access = ScreenRecordingAccess(platform: os.platform()) { c.runtime.send(.permissionChanged(granted: $0)) }

    access.checkAtLaunch()
    #expect(os.requests == 0, "access is already granted: no request")
    #expect(!c.runtime.controller.permissionDenied)

    access.recheck()
    #expect(os.requests == 0)
    #expect(!c.runtime.controller.permissionDenied)
}

// MARK: - Every check: preflight always runs, a confirmed grant is always reported, nothing prompts

/// A check that confirms access reports the grant even when the controller does not yet know it was denied. The OS may
/// have revoked and regranted access while a stream's denial is still in flight, so the grant has to reach the controller.
@MainActor
@Test func aCheckThatConfirmsAccessReportsTheGrantWhenNothingIsDenied() {
    let os = FakeScreenRecordingOS()
    os.granted = true
    let log = ReportLog()
    let access = ScreenRecordingAccess(platform: os.platform()) { log.record($0) }

    access.recheck()
    #expect(os.checks == 1, "the platform check runs on every check")
    #expect(log.values == [true], "a confirmed grant is reported though nothing was denied")
    #expect(os.requests == 0, "a check never prompts")
}

/// A check that does not confirm access reports nothing, whether or not the controller is denied, and never prompts.
@MainActor
@Test func aCheckThatDoesNotConfirmAccessReportsNothingAndNeverPrompts() {
    let os = FakeScreenRecordingOS()
    let log = ReportLog()
    let access = ScreenRecordingAccess(platform: os.platform()) { log.record($0) }

    access.recheck()
    access.recheck()
    #expect(os.checks == 2, "each check still asks the platform")
    #expect(log.values.isEmpty, "a check reports no denial, and no grant it cannot confirm")
    #expect(os.requests == 0)
}

/// Repeated checks, granted or not: each check asks the platform once, reports each confirmed grant once, and never prompts.
@MainActor
@Test func repeatedChecksReportEachConfirmedGrantAndNeverPrompt() {
    let os = FakeScreenRecordingOS()
    let log = ReportLog()
    let access = ScreenRecordingAccess(platform: os.platform()) { log.record($0) }

    os.granted = true
    for _ in 0..<3 { access.recheck() }
    os.granted = false
    for _ in 0..<2 { access.recheck() }
    #expect(os.checks == 5)
    #expect(log.values == [true, true, true])
    #expect(os.requests == 0)
}

// MARK: - Composed with the real HeadController and HeadRuntime

/// Regression: a capture started while granted is denied late. Before the denial arrives, the OS has revoked and
/// regranted access and an activation check confirms it, while the controller still thinks nothing is denied. The
/// check must count that grant, so the old denial is stale: it neither blocks the head nor shows a problem, and the
/// head restarts once under the grant.
@MainActor
@Test func aDelayedDenialThatArrivesAfterAnUnseenRegrantIsStaleAndDoesNotPermanentlyBlock() async throws {
    let c = ComposedHeads()
    let os = FakeScreenRecordingOS()
    os.granted = true
    let access = ScreenRecordingAccess(platform: os.platform()) { c.runtime.send(.permissionChanged(granted: $0)) }

    access.checkAtLaunch()
    c.attach(0)
    await c.eventually("the capture starts while granted") { c.backend.startRequests == [0] }
    let first = try c.stream(0)
    first.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }
    let running = try #require(c.status(0)?.captureAttempt)

    os.granted = false                                                       // revoked; the stream's denial is in flight
    os.granted = true                                                        // regranted, before the controller hears of it
    access.recheck()            // activation: the controller is not denied
    await c.settle()
    #expect(!c.runtime.controller.permissionDenied)
    #expect(c.backend.startRequests == [0], "a confirmed grant does not restart a running stream")

    c.runtime.send(.captureStopped(running, .permissionDenied))              // the old denial arrives now
    await c.settle()
    #expect(!c.runtime.controller.permissionDenied, "the denial was issued before the confirmed grant: stale")
    #expect(c.status(0)?.problem == nil, "a stale denial shows no problem")
    #expect(first.isConfirmedStopped, "the old stream is confirmed stopped")

    await c.eventually("the retry is due") { c.backend.sleeps.pending.contains(.seconds(1)) }
    #expect(c.backend.sleeps.release { $0 == .seconds(1) })
    await c.eventually("the head restarts under the grant") { c.backend.startRequests == [0, 0] }
    let second = try c.stream(1)
    second.deliverFrame()
    await c.eventually("live again") { c.status(0)?.captureRunning == true }
    #expect(!c.runtime.controller.permissionDenied)
    #expect(os.requests == 0, "nothing in the flow prompts")
}

/// Repeated confirmed checks while a capture runs: no restart, no second stream, and no change in what is shown.
@MainActor
@Test func repeatedConfirmedChecksWhileACaptureRunsNeitherRestartNorDuplicate() async throws {
    let c = ComposedHeads()
    let os = FakeScreenRecordingOS()
    os.granted = true
    let access = ScreenRecordingAccess(platform: os.platform()) { c.runtime.send(.permissionChanged(granted: $0)) }

    access.checkAtLaunch()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    for _ in 0..<5 { access.recheck() }
    await c.settle()
    #expect(c.backend.startRequests == [0], "no duplicate start")
    #expect(c.backend.streams.count == 1, "no second stream")
    #expect(c.status(0)?.captureRunning == true)
    #expect(stream.stopAttempts == 0, "a confirmed grant stops nothing")
    #expect(os.requests == 0)
}

/// A check that does not confirm access while a capture runs changes nothing: the running stream is not stopped and
/// no denial is reported. The OS reports a revocation through the stream itself.
@MainActor
@Test func aCheckThatDoesNotConfirmAccessWhileACaptureRunsChangesNothing() async throws {
    let c = ComposedHeads()
    let os = FakeScreenRecordingOS()
    os.granted = true
    let access = ScreenRecordingAccess(platform: os.platform()) { c.runtime.send(.permissionChanged(granted: $0)) }

    access.checkAtLaunch()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let stream = try c.stream(0)
    stream.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }

    os.granted = false
    access.recheck()
    await c.settle()
    #expect(!c.runtime.controller.permissionDenied, "a check reports no denial")
    #expect(c.status(0)?.captureRunning == true)
    #expect(stream.stopAttempts == 0)
    #expect(c.backend.startRequests == [0])
    #expect(os.requests == 0)
}

/// A denial from a start issued under the current grant is real: it blocks until a check confirms access again.
@MainActor
@Test func aDenialFromAStartIssuedUnderAConfirmedGrantBlocksUntilACheckConfirmsAccessAgain() async throws {
    let c = ComposedHeads()
    let os = FakeScreenRecordingOS()
    os.granted = true
    let access = ScreenRecordingAccess(platform: os.platform()) { c.runtime.send(.permissionChanged(granted: $0)) }

    access.checkAtLaunch()
    c.attach(0)
    await c.eventually("the capture starts") { c.backend.startRequests == [0] }
    let first = try c.stream(0)
    first.deliverFrame()
    await c.eventually("live") { c.status(0)?.hasUsableFrame == true }
    let running = try #require(c.status(0)?.captureAttempt)

    os.granted = false
    os.granted = true
    access.recheck()           // a confirmed grant: the count advances
    c.runtime.send(.captureStopped(running, .permissionDenied))             // stale: issued before it
    await c.settle()
    #expect(!c.runtime.controller.permissionDenied)

    c.backend.failNextStart(FakeError.screenRecordingDenied)                // the retry is refused: a current denial
    await c.eventually("the retry is due") { c.backend.sleeps.pending.contains(.seconds(1)) }
    #expect(c.backend.sleeps.release { $0 == .seconds(1) })
    await c.eventually("the refused start blocks") { c.runtime.controller.permissionDenied }
    #expect(c.status(0)?.problem == "Screen Recording permission is required")
    #expect(c.backend.startRequests == [0, 0])

    os.granted = false
    access.recheck()           // still not granted
    await c.settle()
    #expect(c.runtime.controller.permissionDenied, "nothing is claimed while access is missing")
    #expect(c.backend.startRequests == [0, 0], "no start while denied")

    os.granted = true
    access.recheck()           // the check confirms access
    await c.eventually("the head restarts") { c.backend.startRequests == [0, 0, 0] }
    #expect(!c.runtime.controller.permissionDenied)
    #expect(os.requests == 0)
}
