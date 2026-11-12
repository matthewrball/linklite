// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import LinkLiteRotation

// Where the dock's hardware cursor is told to be. The engine keeps the last position it was given, so a
// head whose pointer has gone (removed target, or a rotated head that has no dock cursor) must be told
// explicitly. These tests drive the router with a fake control function; no engine, display or event is used.

/// Records every report the router sends. `accepts` decides whether the fake dock takes it.
private final class FakeDock {
    var sent: [DockCursorReport] = []
    var accepts = true

    func send(_ report: DockCursorReport) -> Bool {
        sent.append(report)
        return accepts
    }
}

/// Dock head 0: a 1920x1080-point display at the origin, driven at 3840 pixels (scale 2).
private let hiDPIHead = DockCursorTarget(head: 0, originX: 0, originY: 0, widthPoints: 1920, heightPoints: 1080, modeWidth: 3840)
/// Dock head 1: a 1920-point display to its right, driven at 1920 pixels (scale 1).
private let plainHead = DockCursorTarget(head: 1, originX: 1920, originY: 0, widthPoints: 1920, heightPoints: 1080, modeWidth: 1920)
/// A rotated head: the pointer is in its frames, so it is never a target. Sits right of both dock heads.
private let rotatedHeadX = 3900.0

// MARK: - Reporting a position

@Test func pointerOnADockHeadReportsItsPositionInDockPixels() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    let hit = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    #expect(hit?.report == DockCursorReport(head: 0, x: 200, y: 100))
    #expect(hit?.scale == 2)
    #expect(dock.sent == [DockCursorReport(head: 0, x: 200, y: 100)])
}

@Test func aRepeatedPositionSendsNothing() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    _ = router.pointerMoved(x: 100.2, y: 50.4) { dock.send($0) }
    #expect(dock.sent.count == 1, "same dock pixel, so nothing new to tell the dock")
}

@Test func multipleHeadsRouteThePointerToTheHeadItIsOn() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead, plainHead], pointerX: 0, pointerY: 0) { dock.send($0) }
    let right = router.pointerMoved(x: 2000, y: 10) { dock.send($0) }
    #expect(right?.report == DockCursorReport(head: 1, x: 80, y: 10))
    #expect(right?.scale == 1)
    let left = router.pointerMoved(x: 10, y: 10) { dock.send($0) }
    #expect(left?.report == DockCursorReport(head: 0, x: 20, y: 20))
    #expect(dock.sent.last == DockCursorReport(head: 0, x: 20, y: 20))
}

@Test func theLeftAndTopEdgesBelongToADisplayAndTheRightAndBottomEdgesDoNot() {
    // CGRect.contains is half-open: x in [minX, maxX). Head 0 spans 0..<1920 points, head 1 spans 1920..<3840.
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead, plainHead], pointerX: 0, pointerY: 0) { dock.send($0) }
    #expect(router.pointerMoved(x: 1919.99, y: 0) { dock.send($0) }?.report == DockCursorReport(head: 0, x: 3839, y: 0))
    #expect(router.pointerMoved(x: 1920, y: 0) { dock.send($0) }?.report == DockCursorReport(head: 1, x: 0, y: 0))
    #expect(router.pointerMoved(x: 3839.99, y: 0) { dock.send($0) }?.report == DockCursorReport(head: 1, x: 1919, y: 0))
    #expect(router.pointerMoved(x: 3840, y: 0) { dock.send($0) } == nil, "past the last target")
    #expect(router.pointerMoved(x: -0.5, y: 0) { dock.send($0) } == nil, "left of the first target")
}

// MARK: - Pointer on a rotated head (no dock cursor there)

@Test func pointerOnARotatedHeadHidesTheDockCursorOnceNotRepeatedly() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    _ = router.pointerMoved(x: rotatedHeadX, y: 50) { dock.send($0) }
    _ = router.pointerMoved(x: rotatedHeadX + 10, y: 60) { dock.send($0) }
    #expect(dock.sent == [DockCursorReport(head: 0, x: 200, y: 100), .hidden])
}

@Test func pointerOnARotatedHeadWithNoDockCursorShownSendsNothing() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: rotatedHeadX, pointerY: 50) { dock.send($0) }
    #expect(dock.sent.isEmpty, "the dock never showed a cursor, so there is nothing to hide")
}

@Test func pointerMovingFromADockHeadToARotatedHeadHidesOnTheDock() {
    // Two dock heads and a rotated head: the pointer crosses from dock head 0 to the rotated head.
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead, plainHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    _ = router.pointerMoved(x: rotatedHeadX, y: 50) { dock.send($0) }
    #expect(dock.sent.last == .hidden)
    #expect(dock.sent.filter { $0.isHidden }.count == 1)
}

// MARK: - Transitions in the target set

@Test func removingTheLastTargetHidesBeforeAnythingElseAndOnlyOnce() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    let before = dock.sent.count
    let hit = router.setTargets([], pointerX: 100, pointerY: 50) { dock.send($0) }
    #expect(hit == nil)
    #expect(Array(dock.sent.dropFirst(before)) == [.hidden])
    _ = router.setTargets([], pointerX: 100, pointerY: 50) { dock.send($0) }
    #expect(dock.sent.count == before + 1, "a second removal with nothing shown sends nothing")
}

@Test func removingALastTargetWhileNothingWasShownSendsNoHide() {
    // A head that never showed a cursor: no hide is needed, so none is sent.
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: rotatedHeadX, pointerY: 0) { dock.send($0) }
    _ = router.setTargets([], pointerX: rotatedHeadX, pointerY: 0) { dock.send($0) }
    #expect(dock.sent.isEmpty)
}

@Test func removingANonLastTargetDoesNotHideWhileThePointerIsOnARemainingTarget() {
    // Head 1 is removed while the pointer is on head 0, which is still a target. Nothing is hidden.
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead, plainHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    let before = dock.sent
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    #expect(!dock.sent.dropFirst(before.count).contains { $0.isHidden }, "the cursor stays on head 0")
    #expect(dock.sent.last == DockCursorReport(head: 0, x: 200, y: 100))
}

@Test func removingTheHeadUnderThePointerHidesItBecauseTheCursorIsNoLongerOnTheDock() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead, plainHead], pointerX: 2000, pointerY: 10) { dock.send($0) }
    _ = router.setTargets([hiDPIHead], pointerX: 2000, pointerY: 10) { dock.send($0) }
    #expect(dock.sent.last == .hidden)
}

@Test func aTargetWhoseScaleChangesSendsItsNewPosition() {
    // A changed mode is a new dock pixel position for the same point.
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    let halved = DockCursorTarget(head: 0, originX: 0, originY: 0, widthPoints: 1920, heightPoints: 1080, modeWidth: 1920)
    _ = router.setTargets([halved], pointerX: 100, pointerY: 50) { dock.send($0) }
    #expect(dock.sent.last == DockCursorReport(head: 0, x: 100, y: 50))
}

// MARK: - Failure and cancellation of the control function

@Test func aFailedHideIsRetriedNotForgotten() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    dock.accepts = false
    _ = router.setTargets([], pointerX: 100, pointerY: 50) { dock.send($0) }
    #expect(router.reporter.believed == .unknown)
    dock.accepts = true
    _ = router.setTargets([], pointerX: 100, pointerY: 50) { dock.send($0) }
    #expect(dock.sent.last == .hidden)
    #expect(router.reporter.believed == .hidden)
}

@Test func aFailedPositionIsSentAgainOnTheNextMove() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    dock.accepts = false
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    dock.accepts = true
    _ = router.pointerMoved(x: 100, y: 50) { dock.send($0) }
    #expect(dock.sent.count == 2)
    #expect(dock.sent.last == DockCursorReport(head: 0, x: 200, y: 100))
}

@Test func aHideThatFailedIsNotLostWhenTheTargetReturnsBeforeItIsDelivered() {
    // Cancellation: a head returns while the hide from its removal is still undelivered. The dock must end up
    // showing the pointer where it is, and the stale hide must not be sent after the new position.
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    dock.accepts = false
    _ = router.setTargets([], pointerX: 100, pointerY: 50) { dock.send($0) }
    dock.accepts = true
    let hit = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    #expect(hit?.report == DockCursorReport(head: 0, x: 200, y: 100))
    #expect(dock.sent.last == DockCursorReport(head: 0, x: 200, y: 100))
    #expect(router.reporter.believed == .shown(DockCursorReport(head: 0, x: 200, y: 100)))
}

@Test func aHideRetriedWhileThePointerIsOnARotatedHeadIsNotAPosition() {
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    dock.accepts = false
    _ = router.pointerMoved(x: rotatedHeadX, y: 50) { dock.send($0) }
    dock.accepts = true
    _ = router.setTargets([], pointerX: rotatedHeadX, pointerY: 50) { dock.send($0) }
    #expect(dock.sent.last == .hidden)
}

@Test func forgettingTheDockStateResendsTheCurrentPosition() {
    // Used after sleep or a target change: the dock may have lost its state, so the current position is sent again.
    let dock = FakeDock()
    var router = DockCursorRouter()
    _ = router.setTargets([hiDPIHead], pointerX: 100, pointerY: 50) { dock.send($0) }
    router.reporter.forget()
    _ = router.pointerMoved(x: 100, y: 50) { dock.send($0) }
    #expect(dock.sent.count == 2)
}
