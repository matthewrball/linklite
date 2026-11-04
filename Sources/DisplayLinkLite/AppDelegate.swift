// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import CDLLite
import os
import ServiceManagement

private let log = Logger(subsystem: "com.ball.displaylink-lite", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let host = DisplayHost()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "DisplayLink Lite") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "DL"
        }
        item.button?.toolTip = "DisplayLink Lite"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        observeSleepAndWake()
        host.onChange = { [weak self] in self?.rebuildMenu() }
        host.start()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.stop()
    }

    // MARK: Sleep and wake

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        let power: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, false),
            (NSWorkspace.willSleepNotification, false),
            (NSWorkspace.screensDidWakeNotification, true),
            (NSWorkspace.didWakeNotification, true)
        ]
        for (name, on) in power {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    log.info("\(name.rawValue, privacy: .public): display power \(on ? "on" : "off")")
                    self?.host.setDisplayPower(on: on)
                }
            })
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        host.refreshScreenRecordingAccess()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(disabledItem(engineStatusText()))

        let heads = host.heads.values.sorted { $0.monitor.head < $1.monitor.head }
        if !heads.isEmpty {
            menu.addItem(.separator())
            for head in heads {
                let monitor = head.monitor
                let item = disabledItem("\(monitor.name) — \(monitor.width)×\(monitor.height) @ \(monitor.effectiveRefreshHz) Hz")
                if let problem = head.problem {
                    item.toolTip = problem
                    menu.addItem(item)
                    menu.addItem(disabledItem("    \(problem)"))
                } else {
                    menu.addItem(item)
                }
            }
        }

        if host.screenRecordingDenied {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Screen Recording permission is required"))
            menu.addItem(actionItem("Open Screen Recording Settings…", #selector(openScreenRecordingSettings)))
        }

        menu.addItem(.separator())
        let login = actionItem("Open at Login", #selector(toggleOpenAtLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = actionItem("Quit DisplayLink Lite", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// Engine messages describe their own state ("Looking for the DisplayLink dock…",
    /// "Dock connected: 2 monitors"), so they are shown as they are.
    private func engineStatusText() -> String {
        host.engineMessage.isEmpty ? "Starting…" : host.engineMessage
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
            }
        } catch {
            log.error("Open at Login: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change Open at Login"
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() {
        host.stop()
        NSApp.terminate(nil)
    }
}
