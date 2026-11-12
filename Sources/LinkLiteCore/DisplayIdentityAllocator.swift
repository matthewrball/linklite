// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The result of claiming an identity: the identity to create the display with, and the lease that
/// keeps the identity claimed for as long as the display exists.
public struct IdentityClaim {
    public let identity: DisplayIdentity
    public let lease: IdentityLease
}

/// Holds an identity for as long as the display made with it exists. Attach it to the display with
/// `DisplayLease.attach`, so the identity is released only when the display has been deallocated,
/// never while macOS may still be tearing it down.
public final class IdentityLease: @unchecked Sendable {
    private let allocator: DisplayIdentityAllocator
    private let id: UUID

    fileprivate init(allocator: DisplayIdentityAllocator, id: UUID) {
        self.allocator = allocator
        self.id = id
    }

    deinit {
        allocator.released(id)
    }
}

/// A monitor that is attached right now on another socket, as the allocator needs to see it: what
/// its EDID reports (physical identity) and, if its virtual display exists, the identity macOS
/// knows that display by. The two are kept apart on purpose: a generated identity is never taken
/// for a physical monitor.
public struct AttachedMonitor: Sendable {
    public let reported: DisplayIdentity
    /// The identity of the monitor's virtual display, nil while that display is not yet created.
    public let identity: DisplayIdentity?
    public let head: UInt8

    public init(reported: DisplayIdentity, identity: DisplayIdentity?, head: UInt8) {
        self.reported = reported
        self.identity = identity
        self.head = head
    }
}

/// Decides which identity each monitor's virtual display is created with, so that identical
/// monitors (same vendor, product and placeholder serial) never collide inside macOS.
///
/// Rules for a monitor reporting `reported` on socket `head`, given the monitors attached on the
/// other sockets:
/// 1. If another socket has a monitor reporting the same identity, the two are identical monitors:
///    the pair is recorded as twins.
/// 2. A twin is given the reported identity only on the socket that owns it. Any other socket gets a
///    derived identity, which is stored for that socket and reserved, so it is the same on every
///    launch and reconnect, whichever order the monitors start in.
/// 3. A reservation is held even while its display is not live: no other monitor is given it. So a
///    monitor whose reported identity equals a reservation owned by another socket is a different
///    physical monitor, not a twin. It gets its own stable derived identity on its socket, and the
///    reservation's socket keeps its identity when it returns.
/// 4. Otherwise it gets the reported identity, and this socket becomes the owner. A single monitor
///    therefore keeps its identity and macOS settings, as in 0.3.15.
///
/// A derived identity avoids every identity in use or reserved, every reported identity ever seen,
/// and the configured monitor keys the caller passes, so it never names another monitor's settings.
///
/// A claim is refused (nil) while the chosen identity is still held by any live lease, including a
/// display retained for a reconnect on another socket: a moved monitor waits for its own identity
/// rather than taking a new one. The caller retries when `identityReleasedNotification` is posted.
/// A reservation is never held by another live lease, so a reserved socket waits only for its own
/// retained display, which is released within the caller's grace period.
///
/// Scope: monitors whose EDIDs differ in some byte but parse to the same vendor, product and serial.
/// Byte-identical EDIDs are not covered: the engine refuses the second head before any claim, because
/// the dock's shared EDID handler can echo the first monitor's EDID back. That guard is kept.
///
/// Known, unavoidable ambiguity: a parsed identity cannot tell two such monitors apart, only the
/// socket can. After a pair has been seen, a lone monitor that moves to another socket gets the derived
/// identity, and once two identical monitors have started on swapped cables their settings follow
/// the sockets, not the monitors.
///
/// Records written before these rules may hold a reservation that equals another monitor's reported
/// identity. `DisplayIdentityRecords.reconciled()` settles those when the records are loaded.
public final class DisplayIdentityAllocator: @unchecked Sendable {
    /// Posted on the thread that released a lease, after the display has been deallocated.
    public static let identityReleasedNotification = Notification.Name("com.ball.linklite.identityReleased")

    /// A display that is alive: attached, or retained for a reconnect.
    private struct Live {
        let identity: DisplayIdentity
        let head: UInt8
    }

    private let lock = NSLock()
    private var live: [UUID: Live] = [:]
    private var state: DisplayIdentityRecords
    private let persist: (@Sendable (DisplayIdentityRecords) -> Void)?

    /// `records` are reconciled first (see `DisplayIdentityRecords.reconciled()`). If that changes
    /// them, the reconciled records are persisted at once, so the migration happens once.
    public init(records: DisplayIdentityRecords = DisplayIdentityRecords(),
                persist: (@Sendable (DisplayIdentityRecords) -> Void)? = nil) {
        let reconciled = records.reconciled()
        state = reconciled
        self.persist = persist
        if reconciled != records {
            persist?(reconciled)
        }
    }

    public var records: DisplayIdentityRecords {
        lock.withLock { state }
    }

    /// Claims an identity for the monitor on `head`. `attached` are the monitors attached on the
    /// other sockets right now; the caller excludes `head` itself. `configured` are the identities
    /// that already have per-display settings in macOS; a derived identity avoids them.
    ///
    /// What is recorded differs by outcome. Twin recognition and a socket's derived serial describe
    /// the monitors on the bus, so they are kept even when the claim is refused: the refused socket
    /// then waits for the same serial it will get. Ownership is a claim, so it is recorded only once
    /// the identity is actually held. A refused attempt must never move an owner, or a later restart
    /// would hand the identities out in a different order.
    public func claim(reported: DisplayIdentity, head: UInt8, attached: [AttachedMonitor],
                      configured: Set<DisplayIdentity> = []) -> IdentityClaim? {
        let key = reported.configurationKey
        let others = attached.filter { $0.head != head }
        let (claim, saved) = lock.withLock { () -> (IdentityClaim?, DisplayIdentityRecords?) in
            let before = state

            state.reported.insert(key)
            if others.contains(where: { $0.reported == reported }) {
                state.twins.insert(key)
            }
            let ownedElsewhere = state.owners[key].map { $0 != head } ?? false
            let generatedElsewhere = others.contains { $0.identity == reported }
            // A reservation is never this socket's own reported identity (see assignedIdentity), so any
            // reservation equal to `reported` belongs to a different monitor.
            let reservedElsewhere = state.assignments.values.contains(key)
            let wantsReported = !generatedElsewhere && !reservedElsewhere
                && !(state.twins.contains(key) && ownedElsewhere)

            let identity = wantsReported
                ? reported
                : assignedIdentity(for: reported, head: head, attached: others, configured: configured)
            guard !live.values.contains(where: { $0.identity == identity }) else {
                // Refused: only the observations and the reserved serial above may have changed.
                return (nil, state != before ? state : nil)
            }
            if wantsReported {
                state.owners[key] = head
            }
            let id = UUID()
            live[id] = Live(identity: identity, head: head)
            let claim = IdentityClaim(identity: identity,
                                      lease: IdentityLease(allocator: self, id: id))
            return (claim, state != before ? state : nil)
        }
        if let saved { persist?(saved) }
        return claim
    }

    /// The derived identity for `reported` on `head`: the one reserved for this socket if there is one,
    /// otherwise a new one that avoids every identity in use, reserved or known. Called under the lock.
    private func assignedIdentity(for reported: DisplayIdentity, head: UInt8,
                                  attached: [AttachedMonitor], configured: Set<DisplayIdentity>) -> DisplayIdentity {
        let slot = DisplayIdentityRecords.assignmentKey(for: reported, head: head)
        if let stored = state.assignments[slot].flatMap(DisplayIdentity.init(configurationKey:)),
           stored.vendorID == reported.vendorID, stored.productCode == reported.productCode,
           stored != reported, stored.serial != 0 {
            return stored
        }
        var avoid = Set(live.values.map(\.identity))
        avoid.formUnion(attached.map(\.reported))
        avoid.formUnion(attached.compactMap(\.identity))
        avoid.formUnion(configured)
        for (other, value) in state.assignments where other != slot {
            if let reserved = DisplayIdentity(configurationKey: value) {
                avoid.insert(reserved)
            }
        }
        // Every reported identity seen before, and every owner and twin, is a physical monitor's.
        for key in state.reported.union(state.owners.keys).union(state.twins) {
            if let known = DisplayIdentity(configurationKey: key) {
                avoid.insert(known)
            }
        }
        let identity = DisplayIdentity.derived(from: reported, head: head, avoiding: avoid)
        state.assignments[slot] = identity.configurationKey
        return identity
    }

    fileprivate func released(_ id: UUID) {
        lock.withLock { _ = live.removeValue(forKey: id) }
        NotificationCenter.default.post(name: Self.identityReleasedNotification, object: self)
    }
}
