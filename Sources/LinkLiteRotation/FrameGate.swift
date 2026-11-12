// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The frame gate of one capture stream, shared by the stream and the runtime that owns it.
///
/// The runtime creates the gate before the stream starts and closes it the moment the stream is retired, even
/// while its start is still running or its stop is stalled. A stream reads frames only inside `whileOpen`, so
/// `close()` returns only after any frame in progress has been submitted, and no frame reaches the engine after
/// it. A closed gate never reopens, so a late start cannot revive a retired stream.
public final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = CaptureGate()

    public init() {}

    /// True once the stream may deliver frames. Opening happens once, when the stream is about to start.
    public var isOpen: Bool { lock.withLock { gate.accepts } }

    /// Opens the gate. Has no effect once it is closed.
    public func open() {
        lock.withLock { gate.open() }
    }

    /// Closes the gate for good. Returns true only if it was open, so the caller can tell a first close from a
    /// repeated one. Returns after any `whileOpen` body in progress has finished.
    @discardableResult
    public func close() -> Bool {
        lock.withLock {
            let wasOpen = gate.accepts
            gate.close()
            return wasOpen
        }
    }

    /// Runs `body` only while the gate is open, and returns its result; nil if the gate is closed. The gate cannot
    /// close while `body` runs, so `body` must not call back into this gate.
    public func whileOpen<Result>(_ body: () -> Result) -> Result? {
        lock.withLock { gate.accepts ? body() : nil }
    }
}
