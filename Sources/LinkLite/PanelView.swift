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
    @Published var isSettingsExpanded = false

    var toggleOpenAtLogin: () -> Void = {}
    var toggleAutomaticUpdates: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var openScreenRecordingSettings: () -> Void = {}
    var quit: () -> Void = {}
}

/// The brand mint, from the icon.
private let mint = Color(red: 0.18, green: 0.65, blue: 0.48)

/// Shared by SwiftUI and the native panel, which clips its window only after a collapse finishes.
@MainActor
enum DisclosureMotion {
    static let duration = 0.14
    static let animation = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: duration)
    /// Content appearing below other cards fades in and settles from 97% scale at its own top edge,
    /// so it never slides over the cards above it. Leaving is a plain fade.
    static let reveal = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
        removal: .opacity
    )
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    let onSizeChange: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            StatusCard(model: model)
            if !model.monitors.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.monitors) { MonitorCard(monitor: $0).transition(DisclosureMotion.reveal) }
                }
                .transition(DisclosureMotion.reveal)
            }
            if model.isSettingsExpanded {
                settings.transition(DisclosureMotion.reveal)
            }
            Divider().padding(.horizontal, 4).opacity(0.5)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .overlay(alignment: .bottomTrailing) {
            Button {
                withAnimation(disclosureAnimation) {
                    model.isSettingsExpanded.toggle()
                }
            } label: {
                Color.clear.frame(width: 104, height: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.isSettingsExpanded ? "Hide settings" : "Show settings")
            .accessibilityLabel(model.isSettingsExpanded ? "Hide settings" : "Show settings")
        }
        .animation(disclosureAnimation, value: model.isSettingsExpanded)
        .tint(mint)
        // Leaving cards keep their old place while the glass shrinks; keep them inside it.
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassPanel(cornerRadius: 24)
        // The window is transparent and shadowless; this shadow follows the rounded glass, and the
        // margin keeps it from being clipped. StatusPanelController offsets the window by the margin.
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        // Status and monitor changes arrive without a transaction. Animate them here, outside the
        // glass, so the glass and its shadow resize on the same curve as the cards inside.
        .animation(disclosureAnimation, value: model.status)
        .animation(disclosureAnimation, value: model.message)
        .animation(disclosureAnimation, value: model.monitors)
        .animation(disclosureAnimation, value: model.loginNeedsApproval)
        .animation(disclosureAnimation, value: model.updatesAvailable)
        .padding(Self.shadowMargin)
        .fixedSize()
        // The window grows to the final size at once and shrinks on the disclosure curve. Keep the
        // content top-aligned so the glass animates downward from a fixed top edge.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static let shadowMargin: CGFloat = 28

    /// Abendrot's disclosure timing: motion.dur-base and ease-warm.
    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : DisclosureMotion.animation
    }

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
                VStack(spacing: 0) {
                    Divider().padding(.leading, 40).opacity(0.5)
                    SettingRow(
                        symbol: "arrow.down.circle",
                        title: "Automatic updates",
                        subtitle: nil,
                        isOn: model.automaticUpdates,
                        action: model.toggleAutomaticUpdates
                    )
                    UpdateRibbonButton(action: model.checkForUpdates)
                        .disabled(!model.canCheckForUpdates)
                        .padding(.leading, 40)
                        .padding(.trailing, 10)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                }
                .transition(DisclosureMotion.reveal)
            }
        }
        .padding(.vertical, 4)
        .card()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            FooterIconButton(title: "Quit LinkLite", symbol: "escape", action: model.quit)
                .keyboardShortcut("q", modifiers: .command)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(model.isSettingsExpanded ? 180 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
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
                // Fades with the light's breath; its size stays put.
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.8 + 0.2 * breath)
                    // Status changes reach the breath without animation, as the light's do.
                    .animation(nil, value: model.status)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            if model.status == .needsPermission {
                Button("Allow", action: model.openScreenRecordingSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .transition(.opacity)
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
        // The panel animates status changes, but the breath must keep taking them instantly so a
        // repeat-forever breath starts and stops cleanly. The colour changes whenever pulsing does.
        .animation(nil, value: color)
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
                        .transition(.opacity)
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

private struct UpdateRibbonButton: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 3, bottomLeadingRadius: 8,
            bottomTrailingRadius: 8, topTrailingRadius: 3
        )
        Button(action: action) {
            Text("Check for Updates…")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(isEnabled ? (hovered ? 0.95 : 0.72) : 0.3))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [.primary.opacity(hovered && isEnabled ? 0.11 : 0.07),
                                 .primary.opacity(0.025)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    in: shape
                )
                .overlay(shape.strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
                .overlay(alignment: .top) {
                    Rectangle().fill(.primary.opacity(0.12))
                        .frame(height: 0.5)
                        .padding(.horizontal, 4)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct FooterIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(isEnabled ? (hovered ? 0.85 : 0.55) : 0.22))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(hovered && isEnabled ? 0.08 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
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
