// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Screen Recording access as the app uses it: one explicit request at launch, and a check whenever the app becomes
/// active again (the user returns from System Settings) or the panel opens. The CoreGraphics calls are injected, so
/// DisplayHost and the tests share this one implementation and the tests never prompt or change system state.
///
/// A grant is reported only when a check confirms it. The request's own result is not trusted on its own, and a
/// request that is answered later is confirmed by the next check, never claimed early. Only the launch request can
/// show the system prompt; a check never does. Every check confirms again, not only after a denial: the OS may have
/// revoked and regranted access while a stream's denial is still in flight, and the controller counts each confirmed
/// grant so that the older denial is recognised as stale.
@MainActor
public final class ScreenRecordingAccess {
    /// The platform calls. DisplayHost passes CGPreflightScreenCaptureAccess and CGRequestScreenCaptureAccess.
    public struct Platform {
        /// Whether access is granted now. Never prompts.
        public var isGranted: @MainActor () -> Bool
        /// The explicit request, which may show the system prompt. Its result is only what the OS reported at once.
        public var requestAccess: @MainActor () -> Bool

        public init(isGranted: @escaping @MainActor () -> Bool,
                    requestAccess: @escaping @MainActor () -> Bool) {
            self.isGranted = isGranted
            self.requestAccess = requestAccess
        }
    }

    private let platform: Platform
    /// Sends the grant or denial to the head runtime (permissionChanged).
    private let report: @MainActor (Bool) -> Void

    public init(platform: Platform, report: @escaping @MainActor (Bool) -> Void) {
        self.platform = platform
        self.report = report
    }

    /// At launch. When access is missing, reports it denied, makes the one explicit request, then checks again: a grant
    /// is reported only if that check confirms it. Otherwise the denial stands until an activation confirms a grant.
    public func checkAtLaunch() {
        guard !platform.isGranted() else { return }
        report(false)
        _ = platform.requestAccess()
        if platform.isGranted() {
            report(true)
        }
    }

    /// When the app becomes active or the panel opens. Runs the platform check every time, and never prompts. Reports a
    /// grant on every check that confirms it, whether or not the controller is denied. Reports nothing when access is not
    /// confirmed: a denial is reported by the stream the OS stops, so a check alone changes no state.
    public func recheck() {
        guard platform.isGranted() else { return }
        report(true)
    }
}
