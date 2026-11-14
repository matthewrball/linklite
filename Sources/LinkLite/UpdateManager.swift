// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import os
import Sparkle

private let log = Logger(subsystem: "com.ball.linklite", category: "updates")

/// What an automatic update is allowed to fetch. The feed URL is compiled in so a defaults
/// write or configuration profile cannot redirect it. Enclosure URLs are allowlisted as well:
/// Sparkle's Developer ID fallback can accept an archive whose EdDSA signature does not match,
/// and that archive must still be an official GitHub release of this repository.
enum UpdatePolicy {
    static let feedURL = "https://raw.githubusercontent.com/matthewrball/linklite/main/appcast.xml"
    /// Larger than any published DMG, smaller than a disk-filling download.
    static let maxDownloadBytes: UInt64 = 64 * 1024 * 1024

    static func acceptsDownload(_ url: URL, length: UInt64) -> Bool {
        guard length > 0, length <= maxDownloadBytes else { return false }
        guard isGitHubHTTPS(url) else { return false }
        let prefix = "/matthewrball/linklite/releases/download/"
        guard url.path.hasPrefix(prefix), !url.path.contains("..") else { return false }
        let rest = url.path.dropFirst(prefix.count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let tag = parts[0]
        let file = parts[1]
        return isReleaseToken(tag) && file.hasPrefix("LinkLite-") && file.hasSuffix(".dmg")
            && isReleaseToken(file.dropFirst("LinkLite-".count).dropLast(".dmg".count))
    }

    static func acceptsInfo(_ url: URL) -> Bool {
        guard isGitHubHTTPS(url), !url.path.contains("..") else { return false }
        return url.path == "/matthewrball/linklite" || url.path.hasPrefix("/matthewrball/linklite/")
    }

    static func accepts(_ item: SUAppcastItem) -> Bool {
        guard let fileURL = item.fileURL, acceptsDownload(fileURL, length: item.contentLength) else {
            return false
        }
        if let info = item.infoURL, !acceptsInfo(info) { return false }
        if let notes = item.releaseNotesURL, !acceptsInfo(notes) { return false }
        if let deltas = item.deltaUpdates {
            for delta in deltas.values {
                guard let url = delta.fileURL, acceptsDownload(url, length: delta.contentLength) else {
                    return false
                }
            }
        }
        return true
    }

    /// The install prompt shows this string. It comes from the appcast, which is not itself signed.
    static func promptVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.count <= 32 && trimmed.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || ".-_".contains(character))
        }
        return safe ? trimmed : "a new version"
    }

    private static func isGitHubHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && url.query == nil
            && url.fragment == nil
    }

    private static func isReleaseToken<S: StringProtocol>(_ token: S) -> Bool {
        !token.isEmpty && token.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || ".-_".contains(character))
        }
    }
}

/// Keeps LinkLite current from the GitHub releases feed (`SUFeedURL`, EdDSA-signed with
/// `SUPublicEDKey`). Checking and downloading are on by default (`SUEnableAutomaticChecks`,
/// `SUAutomaticallyUpdate` in Info.plist); the user is asked before an install, because installing
/// relaunches LinkLite and the dock's monitors go dark for a few seconds.
@MainActor
final class UpdateManager {
    private let controller: SPUStandardUpdaterController?
    // Sparkle holds its delegates weakly.
    private let delegate = UpdaterDelegate()

    init() {
        guard Self.isConfigured else {
            log.info("Updates are off: this build has no update feed or signing key")
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    var isAvailable: Bool { controller != nil }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Checking and downloading in the background, which the menu shows as one setting.
    var automaticallyDownloadsUpdates: Bool {
        guard let updater = controller?.updater else { return false }
        return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Local and ad-hoc builds ship without a key; Sparkle would refuse every update anyway.
    private static var isConfigured: Bool {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        return !key.trimmingCharacters(in: .whitespaces).isEmpty
            && !feed.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Sparkle calls these on the main thread. Internal so tests can confirm the security hooks
/// are the ObjC selectors Sparkle actually invokes.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private var didForceLaunchCheck = false

    /// Sparkle checks at most once per `SUScheduledCheckInterval` and keeps the last check time
    /// across launches, so a relaunch alone checks nothing. This callback is Sparkle deciding to
    /// wait; force one background check per launch instead. The latch matters: Sparkle calls this
    /// again after every completed check.
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        guard !didForceLaunchCheck else { return }
        didForceLaunchCheck = true
        DispatchQueue.main.async { updater.checkForUpdatesInBackground() }
    }

    /// Ignore `SUFeedURL` in user defaults. A configuration profile must not redirect updates.
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdatePolicy.feedURL
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard UpdatePolicy.accepts(updateItem) else {
            throw NSError(
                domain: "com.ball.linklite.updates",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The update is not an official LinkLite release."]
            )
        }
    }

    /// Release notes are an unsigned URL in the feed. Do not fetch or render them.
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }

    /// With automatic downloads on, Sparkle downloads silently and installs when the app quits.
    /// LinkLite rarely quits, so ask once the download is ready. Answer Sparkle first and show
    /// the alert a turn later, outside Sparkle's callback.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = UpdatePolicy.promptVersion(item.displayVersionString)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Self.askToInstall(version: version, install: immediateInstallHandler)
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
    }

    @MainActor
    private static func askToInstall(version: String, install: @escaping () -> Void) {
        log.info("LinkLite \(version, privacy: .public) is downloaded and ready to install")
        let alert = NSAlert()
        alert.messageText = "LinkLite \(version) is ready to install"
        alert.informativeText = """
            This is a signed release from the LinkLite GitHub releases page. Installing \
            restarts LinkLite, so your dock's monitors go dark for a few seconds. If you \
            choose Later, it installs the next time LinkLite quits.
            """
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            install()
        }
    }
}

enum UpdateSecurityHooks {
    static func installed(on delegate: SPUUpdaterDelegate) -> Bool {
        let object = delegate as AnyObject
        return [
            "feedURLStringForUpdater:",
            "updater:shouldProceedWithUpdate:updateCheck:error:",
            "updater:shouldDownloadReleaseNotesForUpdate:",
        ].allSatisfy { object.responds(to: Selector($0)) }
    }
}
