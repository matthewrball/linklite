// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A stream could not be confirmed stopped, so no new stream may start on its key. Shown to the user as
/// the head's problem; the full reason goes to the log.
public struct StreamStopNotConfirmed: LocalizedError, CustomStringConvertible, Sendable {
    /// Why the stop was not confirmed, for the log.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    /// Short enough for one line of the panel.
    public var errorDescription: String? {
        "Previous capture did not confirm it stopped; retrying"
    }

    public var description: String {
        "StreamStopNotConfirmed(\(reason))"
    }
}

/// The wait before each retry of a stop that failed. The first retry comes after 1 s, doubling to a 30 s cap.
public enum StreamRetry {
    public static func interval(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(max(failures, 1) - 1, 5)))
    }
}

/// Orders the start and stop of capture streams, per key, so that two streams never run under one key
/// at once. The key must name the physical socket, not the display: a socket's display can be replaced
/// by one with a different display ID while the old stream is still running on the same socket, and
/// keying by display ID would let the two overlap. DisplayHost keys by head for this reason.
///
/// Every operation for a key runs only after every earlier operation for that key has finished,
/// including one still in flight. A stop is therefore always queued behind the start it stops, and a
/// start queued behind a stop begins only once that stop has completed. Ordering is by awaiting, not
/// by timing.
///
/// Each start is an attempt with its own identity. A cancelled attempt is never kept: if its stream
/// starts after the cancel, the start operation stops it itself before the operation ends.
///
/// Fail closed. `stopStream` may throw, meaning the stream's state is unknown. Such a stream is kept on
/// its key, and no later start on that key runs its `make` until every such stream is confirmed stopped:
/// each start first retries those stops, and fails with `StreamStopNotConfirmed` if one still fails.
/// A stop that failed never counts as a stop that succeeded.
///
/// Retried without a start. A failed stop also starts one retry task for its key, whether or not any
/// start or replacement follows. It retries the oldest unconfirmed stream after a bounded backoff (see
/// `StreamRetry`), and keeps going until none is left, so a head with no replacement still gets its stream
/// confirmed stopped. There is at most one retry task per key. `confirmedStopped` waits for the unconfirmed
/// streams that exist when it is called, so whatever the streams on a key capture can be released only after
/// those are confirmed. It does not wait for stops queued after it, which a later start may hold.
/// Clearing the last unconfirmed stream ends the key's retry task at once, even while it sleeps: a
/// foreground start may confirm the stream first. A retry that wakes after being ended does nothing.
public final class StreamLifecycle<Key: Hashable & Sendable, Stream: Sendable>: @unchecked Sendable {
    /// Identifies one start attempt.
    public struct Attempt: Hashable, Sendable {
        private let id: UUID

        fileprivate init() {
            id = UUID()
        }
    }

    /// What a start attempt ended with.
    public enum Outcome: Sendable {
        /// The stream is running. The lifecycle owns it until the attempt is cancelled.
        case started(Stream)
        /// The attempt was cancelled before its stream was kept. Nothing is running for it.
        case cancelled
    }

    private struct Record {
        let key: Key
        var wanted = true
        var stream: Stream?
    }

    private struct Tail {
        let id: UUID
        let done: Task<Void, Never>
    }

    /// A stream whose stop threw, identified so a waiter can tell it apart from streams stopped later.
    private struct Unconfirmed {
        let id: UInt64
        let stream: Stream
    }

    /// A caller of `confirmedStopped` waiting for the streams it covers to be confirmed. `covered` is the set
    /// of unconfirmed streams present when it was called. nil, the fallback if that set could not be read,
    /// waits for every stream on the key.
    private struct ClearWaiter {
        let covered: Set<UInt64>?
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var records: [Attempt: Record] = [:]
    private var tails: [Key: Tail] = [:]
    /// Streams whose stop threw, per key, oldest first. Appended under `lock` by operations queued for the key.
    private var unconfirmed: [Key: [Unconfirmed]] = [:]
    /// The identity of the next stream to become unconfirmed. Guarded by `lock`.
    private var nextUnconfirmedID: UInt64 = 0
    /// The one retry task per key, present while a stop on the key is unconfirmed, identified by its
    /// token. Guarded by `lock`. A retry task whose token is no longer here has been ended and stops.
    private var retriers: [Key: UUID] = [:]
    /// Callers of `confirmedStopped` waiting for their covered streams on a key to clear. Guarded by `lock`.
    private var clearWaiters: [Key: [ClearWaiter]] = [:]
    private let stopStream: @Sendable (Stream) async throws -> Void
    private let retryDelay: @Sendable (Int) async -> Void
    private let unconfirmedChanged: @Sendable (Key) -> Void

    /// `stopStream` stops one running stream. It throws if the stream could not be confirmed stopped.
    /// `retryDelay` waits before a retry; its argument counts the failed attempts so far, from 1. The
    /// default follows `StreamRetry`. `unconfirmedChanged` is called, off the lock, whenever the unconfirmed
    /// streams on a key change, so an observer can show it.
    public init(stopStream: @escaping @Sendable (Stream) async throws -> Void,
                retryDelay: @escaping @Sendable (Int) async -> Void = { failures in
                    try? await Task.sleep(for: StreamRetry.interval(afterFailures: failures))
                },
                unconfirmedChanged: @escaping @Sendable (Key) -> Void = { _ in }) {
        self.stopStream = stopStream
        self.retryDelay = retryDelay
        self.unconfirmedChanged = unconfirmedChanged
    }

    /// Starts an attempt on `key`. `make` runs once every earlier operation for `key` has finished,
    /// and only if the attempt has not been cancelled by then and every earlier stop on `key` is
    /// confirmed. The attempt is checked again after each wait, and immediately before `make`. The
    /// returned task finishes with the outcome, or throws what `make` threw, or
    /// `StreamStopNotConfirmed` when an earlier stream is not known to have stopped.
    public func start(_ key: Key, make: @escaping @Sendable () async throws -> Stream)
        -> (attempt: Attempt, outcome: Task<Outcome, Error>) {
        let attempt = Attempt()
        lock.withLock { records[attempt] = Record(key: key) }
        let outcome = enqueue(key) { [self] () async throws -> Outcome in
            guard isWanted(attempt) else {
                forget(attempt)
                return .cancelled
            }
            do {
                try await confirmEarlierStreamsStopped(key)
            } catch {
                // A cancelled attempt ends as cancelled, whatever the stop did; it never starts.
                let cancelled = !isWanted(attempt)
                forget(attempt)
                if cancelled { return .cancelled }
                throw error
            }
            // Cancelled while an earlier stop was being retried. Nothing may start.
            guard isWanted(attempt) else {
                forget(attempt)
                return .cancelled
            }
            let stream: Stream
            do {
                stream = try await make()
            } catch {
                forget(attempt)
                throw error
            }
            guard adopt(stream, for: attempt) else {
                // Cancelled while it was starting: stop it here, before any later operation runs.
                await stopOrRecord(stream, on: key)
                forget(attempt)
                return .cancelled
            }
            return .started(stream)
        }
        return (attempt, outcome)
    }

    /// Cancels `attempt`. Its stream, if it has one, is stopped by an operation queued for `key`
    /// behind everything already queued, so the stop has finished before a later start on `key`
    /// begins. The returned task finishes when that stop has. A stop that fails is kept and retried
    /// before the next start on `key`, and by the key's retry task.
    @discardableResult
    public func cancel(_ attempt: Attempt, on key: Key) -> Task<Void, Never> {
        lock.withLock {
            records[attempt]?.wanted = false
        }
        let stop = enqueue(key) { [self] () async throws in
            if let stream = takeStream(for: attempt) {
                await stopOrRecord(stream, on: key)
            }
            forget(attempt)
        }
        return Task { _ = try? await stop.value }
    }

    /// A task that finishes once every operation queued for `key` so far has finished: the starts and
    /// stops already queued, not any queued afterwards. A stop that failed is not waited for: see
    /// `confirmedStopped` for that. The task finishes even when a stop on `key` was not confirmed.
    public func settled(_ key: Key) -> Task<Void, Never> {
        guard let tail = lock.withLock({ tails[key]?.done }) else { return Task {} }
        return Task { await tail.value }
    }

    /// A task that finishes once every operation queued for `key` before this call has finished, and every
    /// stream on `key` that was unconfirmed at this call is confirmed stopped. The operations and streams are
    /// fixed when this is called, not when the task runs: a start queued afterwards is not waited for, however
    /// long it is held. A stop that fails is retried until it is confirmed, however long that takes, so this
    /// task may wait for as long as such a stop keeps failing. Cancelling it does not end the wait: the
    /// streams it waits for have not stopped yet.
    public func confirmedStopped(_ key: Key) -> Task<Void, Never> {
        // Queued now, so it runs after everything queued before this call and before anything queued later.
        // It only reads the unconfirmed streams and waits for nothing itself, so a later operation waits for
        // it only as long as the earlier ones take.
        let snapshot = enqueue(key) { [self] () async throws -> Set<UInt64> in
            lock.withLock { Set(unconfirmed[key]?.map(\.id) ?? []) }
        }
        return Task { [self] in
            // The snapshot cannot throw. If it ever did, wait for every stream on the key: the safe side.
            let covered = try? await snapshot.value
            await waitUntilCleared(key, covered: covered)
        }
    }

    /// Returns at once if none of `covered` is unconfirmed on `key`, otherwise when the last of them is
    /// confirmed. Not woken by cancellation: the streams it waits for have not stopped.
    private func waitUntilCleared(_ key: Key, covered: Set<UInt64>?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                guard !isClearedLocked(key, covered) else { return true }
                clearWaiters[key, default: []].append(ClearWaiter(covered: covered, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Whether none of `covered` is unconfirmed on `key`. nil covers every stream on the key. Call with `lock` held.
    private func isClearedLocked(_ key: Key, _ covered: Set<UInt64>?) -> Bool {
        let pending = unconfirmed[key] ?? []
        guard let covered else { return pending.isEmpty }
        return !pending.contains { covered.contains($0.id) }
    }

    /// Removes and returns the continuations of the waiters that are now cleared, to resume after unlocking.
    /// Call with `lock` held, after any change to the unconfirmed streams on `key`.
    private func takeClearedWaitersLocked(_ key: Key) -> [CheckedContinuation<Void, Never>] {
        var cleared: [CheckedContinuation<Void, Never>] = []
        var waiting: [ClearWaiter] = []
        for waiter in clearWaiters.removeValue(forKey: key) ?? [] {
            if isClearedLocked(key, waiter.covered) {
                cleared.append(waiter.continuation)
            } else {
                waiting.append(waiter)
            }
        }
        if !waiting.isEmpty { clearWaiters[key] = waiting }
        return cleared
    }

    /// How many streams on `key` are not known to have stopped. Zero once every stop is confirmed.
    public func unconfirmedCount(_ key: Key) -> Int {
        lock.withLock { unconfirmed[key]?.count ?? 0 }
    }

    /// The number of retry tasks running. Never more than one per key.
    var retrierCount: Int {
        lock.withLock { retriers.count }
    }

    private func isWanted(_ attempt: Attempt) -> Bool {
        lock.withLock { records[attempt]?.wanted ?? false }
    }

    /// Keeps `stream` for a wanted attempt. False if the attempt was cancelled meanwhile.
    private func adopt(_ stream: Stream, for attempt: Attempt) -> Bool {
        lock.withLock {
            guard records[attempt]?.wanted == true else { return false }
            records[attempt]?.stream = stream
            return true
        }
    }

    private func takeStream(for attempt: Attempt) -> Stream? {
        lock.withLock {
            let stream = records[attempt]?.stream
            records[attempt]?.stream = nil
            return stream
        }
    }

    private func forget(_ attempt: Attempt) {
        _ = lock.withLock { records.removeValue(forKey: attempt) }
    }

    /// Stops `stream`. If the stop throws, the stream is kept on `key` as not confirmed stopped, and is
    /// retried before any later start on `key` and by the key's retry task. Runs only inside an operation
    /// queued for `key`.
    private func stopOrRecord(_ stream: Stream, on key: Key) async {
        do {
            try await stopStream(stream)
        } catch {
            lock.withLock {
                nextUnconfirmedID += 1
                unconfirmed[key, default: []].append(Unconfirmed(id: nextUnconfirmedID, stream: stream))
                ensureRetrierLocked(key)
            }
            unconfirmedChanged(key)
        }
    }

    /// Retries the stops that failed earlier on `key`, oldest first. Throws, and so lets no new stream
    /// start, as soon as one is still not confirmed stopped. Runs only inside an operation queued for `key`.
    private func confirmEarlierStreamsStopped(_ key: Key) async throws {
        while try await retryOldestUnconfirmed(key) {}
    }

    /// Retries the oldest stream whose stop failed on `key`. False if none is left. Throws if it is still
    /// not confirmed stopped. Runs only inside an operation queued for `key`.
    private func retryOldestUnconfirmed(_ key: Key) async throws -> Bool {
        guard let stream = lock.withLock({ unconfirmed[key]?.first?.stream }) else { return false }
        do {
            try await stopStream(stream)
        } catch {
            throw StreamStopNotConfirmed(reason: String(describing: error))
        }
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            unconfirmed[key]?.removeFirst()
            if unconfirmed[key]?.isEmpty == true {
                // Nothing is left unconfirmed: end the key's retry task, so one still sleeping stops nothing
                // when it wakes.
                unconfirmed[key] = nil
                retriers[key] = nil
            }
            return takeClearedWaitersLocked(key)
        }
        for waiter in waiters { waiter.resume() }
        unconfirmedChanged(key)
        return true
    }

    /// Starts the retry task for `key`, unless one is running. Call with `lock` held. Its first retry
    /// waits, so a stop that fails in an operation is not retried in the same instant.
    private func ensureRetrierLocked(_ key: Key) {
        guard retriers[key] == nil else { return }
        let id = UUID()
        retriers[key] = id
        Task { [self] in
            await retryUnconfirmed(key, id: id)
        }
    }

    /// Whether the retry task `id` is still the one for `key`. False once it has been ended by a clear, or
    /// replaced by a newer task.
    private func isCurrentRetrier(_ key: Key, _ id: UUID) -> Bool {
        lock.withLock { retriers[key] == id }
    }

    /// The retry task `id` for `key`. Each retry is one queued operation, so it runs in order with the starts
    /// and stops on the key. It backs off after each failure. It ends when it is no longer current, which
    /// happens once no stream on the key is unconfirmed, whether a retry or a foreground start cleared them.
    /// A stop that fails later starts a new task.
    private func retryUnconfirmed(_ key: Key, id: UUID) async {
        var attempt = 1
        while isCurrentRetrier(key, id) {
            await retryDelay(attempt)
            // The wait may have ended because the key was cleared, or a newer task took over. Stop nothing.
            guard isCurrentRetrier(key, id) else { return }
            do {
                // Checked again when the retry runs: a clear queued ahead of it ends this task, and a stop
                // must not be tried for a task that has ended.
                _ = try await enqueue(key) { [self] () async throws -> Bool in
                    guard isCurrentRetrier(key, id) else { return false }
                    return try await retryOldestUnconfirmed(key)
                }.value
                attempt = 1
            } catch {
                attempt += 1
            }
        }
    }

    /// Queues `operation` behind the last operation for `key`. The tail is set under the lock, so
    /// operations run in the order they were queued.
    private func enqueue<T: Sendable>(_ key: Key, _ operation: @escaping @Sendable () async throws -> T)
        -> Task<T, Error> {
        let id = UUID()
        return lock.withLock {
            let previous = tails[key]?.done
            let task = Task<T, Error> {
                await previous?.value
                return try await operation()
            }
            let done = Task<Void, Never> {
                _ = await task.result
                self.finish(key, id: id)
            }
            tails[key] = Tail(id: id, done: done)
            return task
        }
    }

    private func finish(_ key: Key, id: UUID) {
        lock.withLock {
            if tails[key]?.id == id {
                tails[key] = nil
            }
        }
    }
}
