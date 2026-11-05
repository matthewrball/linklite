// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import SwiftUI

/// The borderless glass panel that drops down from the menu-bar icon. It takes keyboard focus
/// without activating the app (so Esc and ⌘Q work) and closes on a click anywhere else.
@MainActor
final class StatusPanelController {
    private let panel: Panel
    private let hosting: NSHostingController<PanelView>
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    var onShow: (() -> Void)?

    var isShown: Bool { panel.isVisible }

    init(model: PanelModel) {
        hosting = NSHostingController(rootView: PanelView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel = Panel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear

        // The content grows and shrinks (monitors come and go): keep the top edge pinned under the icon.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    func toggle(from button: NSStatusBarButton) {
        isShown ? hide() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        onShow?()
        panel.setContentSize(hosting.view.fittingSize)
        place()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        button.highlight(true)

        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
        monitors = [outside, escape].compactMap { $0 }
    }

    func hide() {
        guard isShown else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        anchor?.highlight(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    /// The glass centred under the icon, 6 pt below the menu bar, kept inside the screen. The window
    /// extends past the glass by the shadow margin on every side.
    private func place() {
        guard let button = anchor, let window = button.window else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let margin = PanelView.shadowMargin
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = icon.midX - size.width / 2
        x = min(max(x, visible.minX + 8 - margin), visible.maxX - size.width - 8 + margin)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: (icon.minY - 6 + margin - size.height).rounded()))
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}
