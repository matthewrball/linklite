# Changelog

All notable changes to LinkLite are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.13] - 2026-11-06

### Changed

- Smoother App Exposé, Mission Control and desktop swipes on dock monitors. Full-screen motion used to send every frame as a complete image three times over; it now sends each frame once and lets the remaining copies follow, as for any other change. Measured on two 4K monitors during Exposé and swipes, the busier monitor went from about 17 to 44 frames per second and the other from 22 to 29, while using less USB bandwidth.
- Both monitors now get an equal turn when they are busy at the same time; the first monitor previously went first three times out of four.
- Optional performance logging for diagnosing smoothness: `defaults write com.ball.linklite PerformanceLogging -bool true` (off by default).

## [0.3.12] - 2026-11-06

### Fixed

- After the displays sleep or the Mac locks, the dock monitors work again when you return. macOS stops all screen capture at display sleep, and LinkLite never restarted it, so the monitors kept showing the last frame and ignored clicks and typing ("Failed to find any displays or windows to capture"). LinkLite now restarts capture as soon as the Mac wakes or unlocks, and keeps retrying if capture stops for any other reason.

### Changed

- With Reduce Motion on, the menu-bar panel now opens and closes instantly instead of fading.
- The Automatic updates rows fade in and out with the panel's resize when update support changes, instead of snapping.

## [0.3.11] - 2026-11-06

### Changed

- LinkLite uses less power while displays sleep: it stops checking the pointer until they wake, then immediately puts the dock's pointer back where it belongs.
- The menu-bar panel moves more calmly. Settings fade in below the status card instead of sliding under it, monitors and status details fade in and out while the panel resizes smoothly around them, and the panel's window is trimmed only after a collapse has finished. With Reduce Motion on, these changes happen instantly.

## [0.3.10] - 2026-11-06

### Fixed

- During screenshot selection (⇧⌘4, ⇧⌘5) the pointer on dock monitors no longer freezes, and the crosshair now appears. macOS stops delivering pointer events to other apps while it holds the pointer, so LinkLite now also polls the pointer and follows it at display rate whenever events go quiet. The same polling picks up pointer shape changes that happen without movement.

## [0.3.9] - 2026-11-05

### Fixed

- Expanding settings no longer pushes the menu-bar panel's header down for a moment. The panel's content stays pinned to its top edge and the glass grows downward from it, including during rapid reversals.

## [0.3.8] - 2026-11-05

### Changed

- Require an explicit public or candidate release channel, Developer ID signing, accepted notarization, and a Sparkle signing key that matches the built app. Candidate packages and feeds are isolated from public artifacts.
- Reject public packages that reuse a published build number, short version, or DMG URL, so a build-only version bump cannot replace already released bytes.
- Exercise release failure handling and app-bundle/license packaging in CI, with a stable required-check name and a Node 24 checkout action.
- Add release/recovery procedures and measurable pre-1.0 hardware, upgrade, compatibility, and performance gates. Separate the historically tested dock from unqualified device families and OS versions.
- Smooth the settings disclosure with matching chevron and native-window easing. Keep the panel's top edge anchored while expanding or collapsing, including rapid reversals, and honor Reduce Motion.

## [0.3.7] - 2026-11-04

### Changed

- Quieter menu-bar controls: Quit is an icon, settings expand with an animated chevron, and Check for Updates sits beneath Automatic updates in a beveled strip. Keyboard shortcuts and update behavior are unchanged.
- Release the panel's SwiftUI view tree after dismissal so its status pulse does not continue consuming CPU while hidden.
- Reuse capture damage, strip-candidate, and cursor-image buffers; pack cached video strips and USB transfers without redundant full-body copies.
- Build with locked dependency versions and select the rustup compiler consistently, avoiding Homebrew standard-library deployment-target mismatches.
- The README leads with the measured memory saving versus DisplayLink Manager, with updated light/dark graphics and a separate component-optimization section.
- Bundle project and third-party license notices in the app and publish a separate, commit-pinned source archive with locked dependency sources.

### Fixed

- CI selects Xcode 26.2 instead of the macOS 15 runner's default Xcode 16.4, which cannot compile the Liquid Glass APIs. The app's macOS 14 deployment target is unchanged.
- Keep cancelled USB transfers alive until their callbacks finish, instead of freeing callback-owned memory after a timeout.
- Bound queued USB replies and fail the session on overflow instead of allowing unbounded memory growth.
- Backport native libusb descriptor fixes for CVE-2026-23679 and CVE-2026-47104, with sanitizer regressions.
- Check frame-buffer arithmetic and descriptor lengths before reading memory; preserve the distinction between unknown and empty capture damage.
- Reject unsuccessful notarization and malformed update feeds; stage feed changes atomically. CI actions are pinned and checkout credentials are not retained.

## [0.3.6] - 2026-11-04

### Changed

- The status title's fade is a little deeper, so it reads as breathing with the light.

## [0.3.5] - 2026-11-04

### Changed

- The status title fades gently with the light instead of also changing size.

## [0.3.4] - 2026-11-04

### Changed

- A calmer status light: while LinkLite looks for the dock, the light and its title breathe more slowly and more subtly.

## [0.3.3] - 2026-11-04

### Fixed

- The status light and its title now breathe in step while LinkLite looks for the dock: both shrink and dim together, then swell back.

## [0.3.2] - 2026-11-04

### Changed

- The menu-bar menu is now a Liquid Glass panel (a translucent material before macOS 26): a status light that breathes with its title while LinkLite looks for the dock, a card for each monitor with its resolution and refresh rate, switches for Open at login and Automatic updates, and Check for Updates and Quit (⌘Q). Esc or a click elsewhere closes it.

## [0.3.1] - 2026-11-04

### Changed

- LinkLite now ships as a disk image: open it and drag LinkLite into Applications. Updates arrive as the same signed, notarized disk image.

## [0.3.0] - 2026-11-03

### Added

- Automatic updates. LinkLite checks this repository's releases when it starts and once a day, downloads new versions in the background, verifies their signature, and asks before installing; if you choose Later, the update installs the next time LinkLite quits. **Check for Updates…** and **Download Updates Automatically** are in the menu-bar menu. Updates use [Sparkle](https://sparkle-project.org); see [PRIVACY.md](PRIVACY.md) for what the update check sends.

### Changed

- The app is 3.9 MB, up from 2.6 MB, for the updater.

## [0.2.0] - 2026-11-03

### Changed

- Renamed to **LinkLite**. The app is now `LinkLite.app` with the bundle identifier `com.ball.linklite`, so macOS treats it as a new app: grant Screen & System Audio Recording again, turn **Open at Login** back on, and delete the old **DisplayLink Lite** from Applications.
- Much lower CPU and GPU use on an everyday desktop. macOS often reports a much larger changed area than really changed (a whole terminal window for a blinking cursor); LinkLite now checks each 64x16 strip's pixels and converts and sends only the strips that actually changed. Measured on two 4K monitors: CPU on a live desktop down from about 116% to about 50%, and the GPU now about half as busy as with DisplayLink Manager under heavy motion. See [docs/BENCHMARK.md](docs/BENCHMARK.md).

### Added

- App icon.
- Published benchmark against DisplayLink Manager, with the scripts and raw data to reproduce it.

## [0.1.0] - 2026-11-03

First tester build, released as **DisplayLink Lite**.

### Added

- Drives both monitors on a DL-6xxx ("Ridge") dock at their native resolution: tested with two 3840x2160 @ 60 Hz monitors on a Humanscale M/Connect 2.
- Menu-bar app showing dock status and the attached monitors, with a shortcut to the Screen Recording settings and **Open at Login**.
- Hardware cursor: the dock draws the mouse pointer itself, so moving it sends a few bytes instead of redrawing the screen.
- Sends only the parts of the screen that change, using the changed areas macOS reports; a still desktop sends nothing.
- New monitors default to a sharp HiDPI "looks like" resolution (1920x1080 on a 4K panel) the first time they are seen. Resolutions you choose afterwards are kept.
- Monitors switched on after the app starts are detected and lit.
- Rides out a dock reset without moving your windows: the same monitor coming back reuses its virtual display.
- Display sleep and wake turn the dock's monitors off and on with your Mac's displays.
- A still screen stays clean, with no stale boxes or flickering patches: changed areas get a follow-up pass once the screen settles, and frames cycle through all three of the dock's buffers.
- Heavy motion (for example App Exposé on two 4K monitors) does not reset the dock: video across both monitors is held to 100 MB/s.

[Unreleased]: https://github.com/matthewrball/linklite/compare/v0.3.13...HEAD
[0.3.13]: https://github.com/matthewrball/linklite/compare/v0.3.12...v0.3.13
[0.3.12]: https://github.com/matthewrball/linklite/compare/v0.3.11...v0.3.12
[0.3.11]: https://github.com/matthewrball/linklite/compare/v0.3.10...v0.3.11
[0.3.10]: https://github.com/matthewrball/linklite/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/matthewrball/linklite/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/matthewrball/linklite/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/matthewrball/linklite/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/matthewrball/linklite/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/matthewrball/linklite/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/matthewrball/linklite/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/matthewrball/linklite/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/matthewrball/linklite/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/matthewrball/linklite/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/matthewrball/linklite/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/matthewrball/linklite/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/matthewrball/linklite/releases/tag/v0.1.0
