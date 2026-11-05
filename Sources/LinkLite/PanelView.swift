// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import SwiftUI

/// What the menu-bar panel shows. AppDelegate refreshes it from DisplayHost, SMAppService and
/// UpdateManager, and supplies the actions.
@MainActor
final class PanelModel: ObservableObject {
    enum Status: Equatable {
        case starting, searching, connected, retrying, needsPermission
    }

    struct Monitor: Identifiable, Equatable {
        let id: UInt8
        let name: String
        let detail: String
        let problem: String?
    }

    @Published var status: Status = .starting
    @Published var message = ""
    @Published var monitors: [Monitor] = []
    @Published var openAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var updatesAvailable = false
    @Published var automaticUpdates = false
    @Published var canCheckForUpdates = false

    var toggleOpenAtLogin: () -> Void = {}
    var toggleAutomaticUpdates: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var openScreenRecordingSettings: () -> Void = {}
    var quit: () -> Void = {}
}

/// The brand mint, from the icon.
private let mint = Color(red: 0.18, green: 0.65, blue: 0.48)

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            StatusCard(model: model)
            if !model.monitors.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.monitors) { MonitorCard(monitor: $0) }
                }
            }
            settings
            footer
        }
        .padding(14)
        .frame(width: 320)
        .tint(mint)
        .glassPanel(cornerRadius: 24)
        // The window is transparent and shadowless; this shadow follows the rounded glass, and the
        // margin keeps it from being clipped. StatusPanelController offsets the window by the margin.
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(Self.shadowMargin)
    }

    static let shadowMargin: CGFloat = 28

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            Text("LinkLite")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var settings: some View {
        VStack(spacing: 0) {
            SettingRow(
                symbol: "power",
                title: "Open at login",
                subtitle: model.loginNeedsApproval ? "Approve LinkLite in Login Items" : nil,
                isOn: model.openAtLogin,
                action: model.toggleOpenAtLogin
            )
            if model.updatesAvailable {
                Divider().padding(.leading, 40).opacity(0.5)
                SettingRow(
                    symbol: "arrow.down.circle",
                    title: "Automatic updates",
                    subtitle: nil,
                    isOn: model.automaticUpdates,
                    action: model.toggleAutomaticUpdates
                )
            }
        }
        .padding(.vertical, 4)
        .card()
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if model.updatesAvailable {
                FooterButton(title: "Check for Updates…", action: model.checkForUpdates)
                    .disabled(!model.canCheckForUpdates)
            }
            Spacer()
            FooterButton(title: "Quit", shortcut: "⌘Q", action: model.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Status

private struct StatusCard: View {
    @ObservedObject var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One breath drives both the light and the title, so they rise and fall together.
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(color: color, breath: breath)
            VStack(alignment: .leading, spacing: 2) {
                // Breathes with the light: smaller and dimmer as it shrinks, full as it swells.
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .scaleEffect(1 - 0.01 * (1 - breath), anchor: .leading)
                    .opacity(0.92 + 0.08 * breath)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if model.status == .needsPermission {
                Button("Allow", action: model.openScreenRecordingSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .card()
        .onAppear { animate() }
        .onChange(of: pulsing) { animate() }
    }

    private func animate() {
        breathe = false
        guard pulsing, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
    }

    private var title: String {
        switch model.status {
        case .starting: "Starting"
        case .searching: "Looking for your dock"
        case .connected: "Connected"
        case .retrying: "Reconnecting"
        case .needsPermission: "Screen Recording needed"
        }
    }

    /// Only when there is something to say beyond the title.
    private var subtitle: String? {
        switch model.status {
        case .connected:
            let count = model.monitors.count
            return count == 0 ? "No monitors on the dock yet"
                : "\(count) monitor\(count == 1 ? "" : "s") on your DisplayLink dock"
        case .needsPermission:
            return "LinkLite captures only the displays it creates for your dock."
        case .starting:
            return nil
        case .searching where model.message.isEmpty || model.message.hasPrefix("Looking for"):
            return nil
        case .searching, .retrying:
            // The engine's own words for anything unusual, such as the dock being in use elsewhere.
            return model.message.isEmpty ? nil : model.message
        }
    }

    private var color: Color {
        switch model.status {
        case .connected: mint
        case .needsPermission: .red
        case .starting, .searching, .retrying: .orange
        }
    }

    private var pulsing: Bool { model.status != .connected && model.status != .needsPermission }

    /// 1 at the top of the breath (and whenever the light is steady), 0 at the bottom.
    private var breath: Double { pulsing && !breathe ? 0 : 1 }
}

/// A glowing status light. While LinkLite looks for the dock it breathes: the light and its halo
/// shrink and dim together, then swell back.
private struct StatusOrb: View {
    let color: Color
    /// 0 (exhaled) to 1 (full).
    let breath: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 30, height: 30)
                .scaleEffect(0.88 + 0.12 * breath)
                .opacity(0.65 + 0.35 * breath)
            Circle()
                .fill(color.gradient)
                .frame(width: 11, height: 11)
                .scaleEffect(0.94 + 0.06 * breath)
                .shadow(color: color.opacity(0.45 + 0.25 * breath), radius: 5)
        }
        .frame(width: 32, height: 32)
    }
}

// MARK: - Monitors

private struct MonitorCard: View {
    let monitor: PanelModel.Monitor

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.42),
                                                  Color(red: 0.09, green: 0.11, blue: 0.27)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "display")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0.62, green: 0.90, blue: 0.77))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(monitor.problem ?? monitor.detail)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(monitor.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if monitor.problem == nil {
                Text("Live")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(mint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(mint.opacity(0.14), in: Capsule())
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .card()
    }
}

// MARK: - Settings rows

private struct SettingRow: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct FooterButton: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(hovered && isEnabled ? 0.08 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Surfaces

private extension View {
    /// An inset card on the glass.
    func card() -> some View {
        background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }

    /// Liquid Glass on macOS 26; the translucent popover material before that, and a solid surface
    /// when Reduce Transparency is on.
    func glassPanel(cornerRadius: CGFloat) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

private struct GlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(VisualEffectBackground().clipShape(shape))
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
