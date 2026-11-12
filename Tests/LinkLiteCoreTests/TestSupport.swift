import Foundation

/// An ordered record of what happened during a test, for asserting the order of teardown steps.
/// Safe to write from any thread, including from deinit and notification callbacks.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func record(_ event: String) {
        lock.withLock { items.append(event) }
    }

    var events: [String] {
        lock.withLock { items }
    }
}

/// Thrown when a claim that the test needs is refused.
struct Refused: Error {}

/// Unwraps `value`, failing the test when it is nil. Used instead of `#require`, which warns on
/// claims whose Optional result it cannot prove nil.
func require<T>(_ value: T?) throws -> T {
    guard let value else { throw Refused() }
    return value
}

/// Sets `value` to nil and reads it back as an inout argument, so the test's intent to release it
/// is explicit and the compiler does not report the variable as written but never read.
func drop<T>(_ value: inout T?) {
    value = nil
}
