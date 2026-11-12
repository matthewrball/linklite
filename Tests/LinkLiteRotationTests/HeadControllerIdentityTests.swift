// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import LinkLiteCore
import Testing
@testable import LinkLiteRotation

// The controller's answers for identity waits, claimed identities, early frames, and the frame gate's lifecycle.
// The controller is driven directly with apply(_:): these run the decisions without a platform.

private func identityMonitor(_ head: UInt8 = 0, serial: UInt32 = 0x1234_5678) -> HeadMonitor {
    HeadMonitor(head: head, vendorID: 0x22f0, productCode: 0x3a4b, serial: serial, width: 3840, height: 2160,
                refreshHz: 60, widthMillimeters: 597, heightMillimeters: 336, name: "Dock", hardwareCursor: true)
}

private func startedAttempts(_ commands: [HeadCommand]) -> [CaptureAttempt] {
    commands.compactMap { command in
        if case .startCapture(let attempt, _, _, _) = command { return attempt }
        return nil
    }
}

private func savedModes(_ commands: [HeadCommand]) -> [[String]] {
    commands.compactMap { command in
        if case .saveConfiguredModes(let list) = command { return list }
        return nil
    }
}

/// A usable frame that arrives before its start is reported counts: the stream is live, and no deadline is armed for it.
@Test func aUsableFrameThatArrivesBeforeItsStartIsReportedCountsAsUsable() {
    var controller = HeadController()
    _ = controller.apply(.monitorAttached(identityMonitor()))
    _ = controller.apply(.displayCreated(head: 0, display: 1))
    let started = controller.apply(.modeSetupFinished(head: 0, display: 1, outcome: .applied))
    guard let attempt = startedAttempts(started).first else {
        Issue.record("no capture was started")
        return
    }

    _ = controller.apply(.captureUsableFrame(attempt))
    let afterStart = controller.apply(.captureStarted(attempt))

    #expect(controller.status(forHead: 0)?.hasUsableFrame == true)
    #expect(controller.status(forHead: 0)?.captureRunning == true)
    #expect(!afterStart.contains { command in
        if case .scheduleTimer(.firstFrame, _) = command { return true }
        return false
    }, "the deadline is not armed for a stream that is already usable")
}

/// A display whose identity is still held waits, and asks again on its backoff timer or as soon as an identity is
/// released. Only one display is wanted for the head, so the waiting display is the one asked for.
@Test func aDisplayWaitingForItsIdentityIsAskedAgainOnItsTimerAndWhenAnIdentityIsReleased() {
    let monitor = identityMonitor()
    var controller = HeadController()
    _ = controller.apply(.monitorAttached(monitor))

    let first = controller.apply(.displayCreationWaiting(head: 0, display: 1))
    #expect(controller.status(forHead: 0)?.waitingForIdentity == true)
    #expect(first.contains(.scheduleTimer(.identityRetry(head: 0, display: 1), after: .seconds(1))))

    let retried = controller.apply(.timerFired(.identityRetry(head: 0, display: 1)))
    #expect(retried == [.createDisplay(head: 0, display: 1, monitor: monitor, orientation: .standard)])
    #expect(controller.status(forHead: 0)?.waitingForIdentity == false)

    let waitedAgain = controller.apply(.displayCreationWaiting(head: 0, display: 1))
    #expect(waitedAgain.contains(.scheduleTimer(.identityRetry(head: 0, display: 1), after: .seconds(2))),
            "the wait doubles after each refusal")

    let released = controller.apply(.identityMayBeFree)
    #expect(released.contains(.createDisplay(head: 0, display: 1, monitor: monitor, orientation: .standard)))
    #expect(released.contains(.cancelTimer(.identityRetry(head: 0, display: 1))),
            "the pending retry is cancelled, not left to fire again")
}

/// A detach ends the wait: no retry is asked for afterwards, and a late timer does nothing.
@Test func aDetachEndsTheWaitForAnIdentity() {
    var controller = HeadController()
    _ = controller.apply(.monitorAttached(identityMonitor()))
    _ = controller.apply(.displayCreationWaiting(head: 0, display: 1))

    _ = controller.apply(.monitorDetached(head: 0))
    #expect(controller.apply(.timerFired(.identityRetry(head: 0, display: 1))).isEmpty)
    #expect(controller.apply(.identityMayBeFree).isEmpty)
}

/// The default mode is recorded under the identity the display was created with. A twin given a derived identity
/// is configured on its own record, and the monitor's own record does not stand in for it.
@Test func theDefaultModeIsRecordedUnderTheClaimedIdentity() {
    let monitor = identityMonitor(serial: 0x0000_0042)
    let derived = DisplayIdentity(vendorID: 0x22f0, productCode: 0x3a4b, serial: 0xABCD_0001)

    var controller = HeadController(configuredModes: [monitor.reportedIdentity.configurationKey])
    _ = controller.apply(.monitorAttached(monitor))
    let created = controller.apply(.displayCreated(head: 0, display: 1, identity: derived))
    #expect(created.contains { command in
        if case .configureMode = command { return true }
        return false
    }, "the derived identity has no default mode yet, even though the reported one does")
    let saved = savedModes(controller.apply(.modeSetupFinished(head: 0, display: 1, outcome: .applied)))
    #expect(saved == [[monitor.reportedIdentity.configurationKey, derived.configurationKey]])
}

/// A rotation chosen while the old display is still being released is kept for the replacement, not dropped.
@Test func aRotationChosenDuringARebuildIsTheOneTheReplacementIsMadeWith() {
    let monitor = identityMonitor()
    var controller = HeadController(configuredModes: [monitor.reportedIdentity.configurationKey])
    _ = controller.apply(.monitorAttached(monitor))
    _ = controller.apply(.displayCreated(head: 0, display: 1))

    // The rotation releases the display; the stream is still being stopped.
    let turned = controller.apply(.setOrientation(head: 0, orientation: .turnedClockwise))
    #expect(turned.contains { command in
        if case .releaseDisplay(0, 1, _) = command { return true }
        return false
    })
    let laterChoice = controller.apply(.setOrientation(head: 0, orientation: .upsideDown))
    #expect(laterChoice.contains { command in
        if case .savePreferences = command { return true }
        return false
    }, "the new choice is stored while the old display is still released")
    #expect(!laterChoice.contains { command in
        if case .createDisplay = command { return true }
        return false
    }, "no replacement is made before the old display is released")

    let replaced = controller.apply(.displayReleased(display: 1))
    let made = replaced.compactMap { command -> DisplayOrientation? in
        if case .createDisplay(0, _, _, let orientation) = command { return orientation }
        return nil
    }
    #expect(made == [.upsideDown], "the replacement is made with the last choice")
}

// MARK: - Frame gate

@Test func aFrameGateOpensOnceAndNeverReopensOnceClosed() {
    let gate = FrameGate()
    #expect(!gate.isOpen)
    #expect(gate.whileOpen { 1 } == nil, "a stream that has not started submits nothing")

    gate.open()
    #expect(gate.isOpen)
    #expect(gate.whileOpen { 2 } == 2)

    #expect(gate.close(), "the first close reports that the gate was open")
    #expect(!gate.close(), "a repeated close reports nothing new")
    gate.open()
    #expect(!gate.isOpen, "a closed gate never reopens")
    #expect(gate.whileOpen { 3 } == nil)
}

@Test func aGateClosedBeforeItsStreamOpensStaysClosed() {
    let gate = FrameGate()
    #expect(!gate.close(), "closing a gate that never opened reports that it was not open")
    gate.open()
    #expect(!gate.isOpen, "a stream whose start is late cannot open a gate that was retired")
}
