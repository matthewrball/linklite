// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import CDLLite
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

private let log = Logger(subsystem: "com.ball.linklite", category: "host")

/// Ties the engine to macOS: one virtual display plus one capture stream per attached dock head.
@MainActor
final class DisplayHost {
    struct Head {
        var monitor: MonitorInfo
        var display: VirtualDisplay?
        var capture: DisplayCapture?
        /// Identifies the current capture attempt so stale async results are discarded.
        var captureToken = UUID()
        var startTask: Task<Void, Never>?
        var problem: String?
        var rebuiltAfterTermination = false
        /// A scheduled restart after the stream stopped or failed to start, and how many in a row.
        var retryTask: Task<Void, Never>?
        var retryAttempt = 0
    }

    private(set) var engineState: DLLState?
    private(set) var engineMessage = "Starting…"
    private(set) var heads: [UInt8: Head] = [:]
    private(set) var screenRecordingDenied = false
    /// Called after any change the menu shows.
    var onChange: (() -> Void)?

    private let engine = EngineHandle()
    private lazy var cursor = CursorTracker(engine: engine)
    private var displayReconfigured: NSObjectProtocol?
    private static let configuredMonitorsKey = "ConfiguredMonitors"

    /// A detached head's virtual display, kept briefly for a reconnect.
    private struct Retained {
        var display: VirtualDisplay
        var monitor: MonitorInfo
        var release: Task<Void, Never>
    }
    private var retained: [UInt8: Retained] = [:]
    /// Long enough to ride out a dock reset (about 7 s measured) or a quick cable replug.
    private static let reconnectGrace: Duration = .seconds(20)

    func start() {
        if !CGPreflightScreenCaptureAccess() {
            screenRecordingDenied = true
            // Shows the system prompt once and lists the app under Screen & System Audio Recording.
            CGRequestScreenCaptureAccess()
        }
        if !engine.start(onEvent: { [weak self] event in self?.handle(event) }) {
            engineMessage = "The dock engine could not start"
            log.error("dll_engine_start returned NULL")
        }
        // Display arrangement changes move the virtual displays' bounds.
        displayReconfigured = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCursorTargets() }
        }
        onChange?()
    }

    /// Blanks the monitors and releases the dock. Blocks until the engine thread has exited.
    func stop() {
        engine.stop()
    }

    func setDisplayPower(on: Bool) {
        for head in heads.keys.sorted() {
            engine.setDisplayPower(head: head, on: on)
        }
    }

    /// Re-checks Screen Recording access and restarts capture for heads that were waiting on it.
    func refreshScreenRecordingAccess() {
        guard screenRecordingDenied, CGPreflightScreenCaptureAccess() else { return }
        screenRecordingDenied = false
        resumeCapture()
        onChange?()
    }

    /// Restarts capture now for every head whose stream is down, e.g. after the Mac wakes or
    /// unlocks. ScreenCaptureKit stops all streams when the screen locks or the displays sleep
    /// (SCStreamError -3815); until a new stream starts, the dock keeps showing the last frame.
    func resumeCapture() {
        guard !screenRecordingDenied else { return }
        for (head, state) in heads where state.display != nil && state.capture == nil && state.startTask == nil {
            heads[head]?.retryTask?.cancel()
            heads[head]?.retryTask = nil
            heads[head]?.retryAttempt = 0
            log.info("Resuming capture for head \(head)")
            startCapture(head: head)
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .attached(let monitor):
            log.info("Head \(monitor.head) attached: \(monitor.name, privacy: .public) \(monitor.width)x\(monitor.height)@\(monitor.refreshHz)")
            attach(monitor)
        case .detached(let head):
            log.info("Head \(head) detached")
            detach(head: head)
        case .stateChanged(let state, let message):
            if state != engineState || message != engineMessage {
                log.info("Engine state \(state.rawValue): \(message, privacy: .public)")
            }
            engineState = state
            engineMessage = message
        }
        updateCursorTargets()
        onChange?()
    }

    /// Points the hardware cursor at every head whose dock draws the pointer itself.
    private func updateCursorTargets() {
        cursor.setTargets(heads.values.compactMap { head in
            guard head.monitor.hardwareCursor, let display = head.display else { return nil }
            return CursorTracker.Target(head: head.monitor.head, displayID: display.displayID,
                                        width: head.monitor.width, height: head.monitor.height)
        })
    }

    private func attach(_ monitor: MonitorInfo, rebuiltAfterTermination: Bool = false) {
        if heads[monitor.head] != nil {
            detach(head: monitor.head)
        }
        var head = Head(monitor: monitor, rebuiltAfterTermination: rebuiltAfterTermination)
        // The same monitor coming back on the same socket within the grace period (a dock reset or
        // a replugged cable) gets its virtual display back, so macOS does not rearrange windows.
        if let kept = retained.removeValue(forKey: monitor.head) {
            kept.release.cancel()
            if kept.monitor.sameDisplay(as: monitor) {
                head.display = kept.display
                heads[monitor.head] = head
                log.info("Head \(monitor.head) reattached to its existing virtual display")
                startCapture(head: monitor.head)
                return
            }
        }
        do {
            head.display = try VirtualDisplay(monitor: monitor) { [weak self] in
                self?.displayTerminated(head: monitor.head)
            }
        } catch {
            head.problem = "\(error)"
            log.error("\(String(describing: error), privacy: .public)")
        }
        heads[monitor.head] = head
        if head.display != nil {
            startCapture(head: monitor.head, configuringModes: true)
        }
    }

    /// Stops a head. Its virtual display is kept for `reconnectGrace` so a quick reconnect can
    /// reuse it, unless `keepDisplay` is false.
    private func detach(head: UInt8, keepDisplay: Bool = true) {
        guard let state = heads.removeValue(forKey: head) else { return }
        state.startTask?.cancel()
        state.retryTask?.cancel()
        let capture = state.capture
        if keepDisplay, let display = state.display {
            let release = Task { [weak self] in
                try? await Task.sleep(for: Self.reconnectGrace)
                guard !Task.isCancelled, let self, self.retained[head]?.display === display else { return }
                self.retained.removeValue(forKey: head)
                log.info("Head \(head) did not come back; virtual display released")
            }
            retained[head] = Retained(display: display, monitor: state.monitor, release: release)
            Task { await capture?.stop() }
            return
        }
        let display = state.display
        // Stop the stream before the display it captures disappears.
        Task {
            await capture?.stop()
            withExtendedLifetime(display) {}
            log.info("Head \(head) torn down")
        }
    }

    private func displayTerminated(head: UInt8) {
        guard let state = heads[head] else { return }
        log.error("Window server removed the virtual display for head \(head)")
        detach(head: head, keepDisplay: false)
        if state.rebuiltAfterTermination {
            var lost = Head(monitor: state.monitor)
            lost.problem = "macOS removed the virtual display"
            heads[head] = lost
        } else {
            attach(state.monitor, rebuiltAfterTermination: true)
        }
        onChange?()
    }

    /// Starts capture for `head`. With `configuringModes`, first waits for the new display's mode
    /// list (the window server fills it in asynchronously) and applies the default mode.
    private func startCapture(head: UInt8, configuringModes: Bool = false) {
        guard var state = heads[head], let display = state.display else { return }
        let token = UUID()
        let monitor = state.monitor
        let engine = self.engine
        state.captureToken = token
        state.problem = nil
        let onStop: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.captureStopped(head: head, token: token, error: error) }
        }
        state.startTask = Task { [weak self] in
            do {
                if configuringModes {
                    try await self?.configureModes(of: display, for: monitor)
                }
                let capture = try await DisplayCapture.start(displayID: display.displayID, monitor: monitor,
                                                             engine: engine, onStop: onStop)
                guard let self, self.heads[head]?.captureToken == token else {
                    await capture.stop()
                    return
                }
                self.heads[head]?.capture = capture
                self.heads[head]?.startTask = nil
                if self.heads[head]?.retryAttempt ?? 0 > 0 {
                    log.info("Capture for head \(head) restarted")
                }
                self.heads[head]?.retryAttempt = 0
            } catch {
                guard let self, self.heads[head]?.captureToken == token else { return }
                self.heads[head]?.startTask = nil
                self.recordCaptureFailure(head: head, error: error)
                self.scheduleCaptureRetry(head: head)
            }
            self?.onChange?()
        }
        heads[head] = state
    }

    private func captureStopped(head: UInt8, token: UUID, error: Error) {
        guard heads[head]?.captureToken == token else { return }
        heads[head]?.capture = nil
        recordCaptureFailure(head: head, error: error)
        scheduleCaptureRetry(head: head)
        onChange?()
    }

    /// Retries capture after 1, 2, 4… seconds (capped at 30) until it runs again or the head goes
    /// away. A wake or unlock restarts it immediately through `resumeCapture()`.
    private func scheduleCaptureRetry(head: UInt8) {
        guard !screenRecordingDenied, let state = heads[head], state.display != nil else { return }
        state.retryTask?.cancel()
        let delay = min(30, 1 << min(state.retryAttempt, 5))
        heads[head]?.retryAttempt = state.retryAttempt + 1
        heads[head]?.retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let state = self.heads[head],
                  state.capture == nil, state.startTask == nil, !self.screenRecordingDenied else { return }
            self.heads[head]?.retryTask = nil
            log.info("Retrying capture for head \(head) (attempt \(state.retryAttempt))")
            self.startCapture(head: head)
        }
    }

    private func recordCaptureFailure(head: UInt8, error: Error) {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            screenRecordingDenied = true
            heads[head]?.problem = "Screen Recording permission is required"
        } else {
            heads[head]?.problem = (error as? DisplayCapture.CaptureError)?.description ?? error.localizedDescription
        }
        log.error("Capture for head \(head) failed: \(String(describing: error), privacy: .public)")
    }

    /// Waits for the new display's mode list, logs it, and applies the default mode the first time
    /// a given monitor shows up. macOS itself would pick the largest HiDPI mode ("looks like"
    /// 2560x1440 on a 4K panel); after the first time, whatever the user chose in System Settings
    /// wins, since macOS restores it by vendor, product and serial.
    private func configureModes(of display: VirtualDisplay, for monitor: MonitorInfo) async throws {
        let native = (width: monitor.width, height: monitor.height)
        var defaultMode = display.defaultMode(nativeWidth: native.width, nativeHeight: native.height)
        for _ in 0..<50 where defaultMode == nil {
            try await Task.sleep(for: .milliseconds(100))
            defaultMode = display.defaultMode(nativeWidth: native.width, nativeHeight: native.height)
        }

        let modes = display.availableModes()
            .filter { $0.isUsableForDesktopGUI() }
            .map { mode in
                mode.pixelWidth == mode.width
                    ? "\(mode.width)x\(mode.height)"
                    : "\(mode.width)x\(mode.height)@\(mode.pixelWidth)x\(mode.pixelHeight)"
            }
        log.info("Display \(display.displayID) modes: \(modes.joined(separator: ", "), privacy: .public)")

        guard let defaultMode else {
            log.error("No HiDPI mode backed by \(native.width)x\(native.height) on display \(display.displayID)")
            return
        }
        let identity = String(format: "%04x-%04x-%08x", monitor.vendorID, monitor.productCode, monitor.serial)
        let defaults = UserDefaults.standard
        var configured = defaults.stringArray(forKey: Self.configuredMonitorsKey) ?? []
        guard !configured.contains(identity) else { return }
        if display.setMode(defaultMode) {
            configured.append(identity)
            defaults.set(configured, forKey: Self.configuredMonitorsKey)
            log.info("Display \(display.displayID) set to looks-like \(defaultMode.width)x\(defaultMode.height)")
        }
    }
}
