// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import ObjectiveC

/// Ties an identity lease to the lifetime of the display object it was claimed for.
///
/// The lease is attached to the display itself as an associated object, so it is released by the
/// Objective-C runtime when the display is deallocated: after the display's own `deinit` has run,
/// and only if no other strong reference to the display remains. This does not depend on the order
/// in which a holder's stored properties are released, which Swift leaves unspecified and which
/// optimized builds do not keep in declaration order. Any extra strong reference to the display
/// (a callback, a stored copy) keeps its identity claimed for as long as the display exists, which
/// is the conservative choice: macOS may still be tearing down a display that is still referenced.
public enum DisplayLease {
    /// The association key is the address of this object. The object is immutable, is never
    /// released (it is held by `key` for the life of the process) and is `Sendable`, so no
    /// unsafe global state is needed to make the key concurrency-safe.
    private final class Key: Sendable {}
    private static let key = Key()

    private static var keyAddress: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(key).toOpaque())
    }

    /// Keeps `lease` claimed for exactly as long as `display` is alive. Call once per display, as
    /// soon as the display exists, so that a display which fails later in its setup still releases
    /// the identity when it is deallocated.
    ///
    /// Attaching a second lease to the same display would release the first one at once, so that is
    /// a programming error and traps.
    public static func attach(_ lease: IdentityLease, to display: AnyObject) {
        precondition(objc_getAssociatedObject(display, keyAddress) == nil,
                     "A display can carry only one identity lease")
        objc_setAssociatedObject(display, keyAddress, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
