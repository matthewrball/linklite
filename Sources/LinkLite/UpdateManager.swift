// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import os
import Sparkle

private let log = Logger(subsystem: "com.ball.linklite", category: "updates")

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

/// Sparkle calls these on the main thread.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
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

    /// With automatic downloads on, Sparkle downloads silently and installs when the app quits.
    /// LinkLite rarely quits, so ask once the download is ready. Answer Sparkle first and show
    /// the alert a turn later, outside Sparkle's callback.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
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
            The update is already downloaded. Installing restarts LinkLite, so your dock's \
            monitors go dark for a few seconds. If you choose Later, it installs the next time \
            LinkLite quits.
            """
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            install()
        }
    }
}
