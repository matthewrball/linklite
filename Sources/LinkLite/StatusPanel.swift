// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import SwiftUI

/// The borderless glass panel that drops down from the menu-bar icon. It takes keyboard focus
/// without activating the app (so Esc and ⌘Q work) and closes on a click anywhere else.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: PanelModel
    private let panel: Panel
    private let hosting: NSHostingController<PanelView?>
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    var onShow: (() -> Void)?

    private(set) var isShown = false
    private var presentationID: UInt64 = 0

    init(model: PanelModel) {
        self.model = model
        // A hidden SwiftUI view can keep repeat-forever animations running. Build the view tree
        // only while presented, and release it after the closing fade finishes.
        hosting = NSHostingController(rootView: nil)
        hosting.sizingOptions = [.preferredContentSize]
        panel = Panel(contentViewController: hosting)
        super.init()
        panel.delegate = self
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

    }

    func windowDidResize(_ notification: Notification) {
        // Monitor attachment changes the content's size; keep its top edge under the icon.
        place()
    }

    func toggle(from button: NSStatusBarButton) {
        isShown ? hide() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        guard !isShown else { return }
        isShown = true
        presentationID &+= 1
        anchor = button
        onShow?()
        hosting.rootView = PanelView(model: model)
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
        isShown = false
        presentationID &+= 1
        let closingPresentation = presentationID
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        anchor?.highlight(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentationID == closingPresentation else { return }
                self.panel.orderOut(nil)
                self.hosting.rootView = nil
            }
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
