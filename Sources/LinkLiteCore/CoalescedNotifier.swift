// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Tells an observer about state changes without calling it from inside the change.
///
/// `request()` may be called any number of times, from anywhere on the main actor, including from a
/// retry or a notification callback. The first request in a run schedules one delivery through
/// `schedule`; later requests before it runs are absorbed into that delivery. `deliver` never runs
/// inside `request()`, and a request made from inside `deliver` schedules a new delivery rather than
/// recursing, so a change made while the observer is reading state cannot re-enter the observer.
@MainActor
public final class CoalescedNotifier {
    private var pending = false
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private let deliver: @MainActor () -> Void

    /// `schedule` must run its work later, on the main actor (for example in a new Task).
    public init(schedule: @escaping (@escaping @MainActor () -> Void) -> Void,
                deliver: @escaping @MainActor () -> Void) {
        self.schedule = schedule
        self.deliver = deliver
    }

    /// Records that something the observer shows has changed.
    public func request() {
        guard !pending else { return }
        pending = true
        schedule { [self] in
            // Cleared before delivering, so a change made by the observer is delivered in a later run.
            pending = false
            deliver()
        }
    }
}
