// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu-bar agent: no Dock icon even when run outside the bundle (the bundle sets LSUIElement).
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
