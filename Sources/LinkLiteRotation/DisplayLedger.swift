// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// The platform's record of live displays and the default-mode operations running on them. Generic over the display
// type and free of AppKit and CoreGraphics: DisplayHost holds the real VirtualDisplay values, and the tests hold fakes.
//
// A display is let go only after its outstanding operation has been cancelled and has returned. Until then the ledger
// holds the display, so a replacement with the same identity cannot be created while the old display still exists,
// and a cancelled operation cannot change a display that has been released. A cancelled operation reports nothing:
// the controller has already moved on.

/// The result of asking for a default-mode operation.
public enum ModeStart: Equatable, Sendable {
    case started
    /// An operation is still outstanding for this display. Its report will answer the controller.
    case alreadyRunning
    /// No display is registered under the generation, or it is being released.
    case unknownDisplay
}

@MainActor
public final class DisplayLedger<Display: AnyObject> {
    private var displays: [UInt64: Display] = [:]
    private var operations: [UInt64: Task<Void, Never>] = [:]
    /// Operations cancelled by a release request. The release waits for each to return before it drops the display.
    private var cancelled: [UInt64: Task<Void, Never>] = [:]
    /// Generations whose release has been requested and not yet acknowledged. Nothing new starts on them.
    private var retiring: Set<UInt64> = []

    public init() {}

    public subscript(generation: UInt64) -> Display? { displays[generation] }

    public func register(_ display: Display, generation: UInt64) {
        displays[generation] = display
    }

    /// Runs `operation` on the display, then reports its outcome unless the operation was cancelled first.
    public func start(_ generation: UInt64,
                      operation: @escaping @MainActor (Display) async -> ModeOutcome,
                      report: @escaping @MainActor (ModeOutcome) -> Void) -> ModeStart {
        guard !retiring.contains(generation), let display = displays[generation] else { return .unknownDisplay }
        guard operations[generation] == nil else { return .alreadyRunning }
        operations[generation] = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let outcome = await operation(display)
            // release() is waiting for this task and has already dropped its entry; a cancelled result is not reported.
            guard !Task.isCancelled else { return }
            self?.operations[generation] = nil
            report(outcome)
        }
        return .started
    }

    /// Requests the release of `generation`. Synchronous, so from this call on nothing new starts on the display, and
    /// its outstanding operation is cancelled at once: its result is never reported, even if the call was already
    /// inside the platform. The display itself stays held until `release` completes, so its identity stays held too.
    public func beginRelease(_ generation: UInt64) {
        retiring.insert(generation)
        if let operation = operations.removeValue(forKey: generation) {
            operation.cancel()
            cancelled[generation] = operation
        }
    }

    /// Requests the release (see `beginRelease`), waits until the cancelled operation has returned, then forgets the
    /// display and runs `acknowledge`. Nothing for the display runs after `acknowledge`.
    public func release(_ generation: UInt64, acknowledge: @MainActor () -> Void) async {
        beginRelease(generation)
        if let operation = cancelled.removeValue(forKey: generation) {
            await operation.value
        }
        displays[generation] = nil
        retiring.remove(generation)
        acknowledge()
    }
}

/// Probes for a value a few times, with a pause between probes. The probe runs on the main actor, where the platform
/// lookup must run. Cancellation ends the wait at once; the value is not looked for after that.
public enum PollWait {
    @MainActor
    public static func firstValue<T>(retries: Int, interval: Duration, _ probe: @MainActor () -> T?) async -> T? {
        if let value = probe() { return value }
        for _ in 0..<retries {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return nil
            }
            if Task.isCancelled { return nil }
            if let value = probe() { return value }
        }
        return nil
    }
}
