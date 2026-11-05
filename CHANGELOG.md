# Changelog

All notable changes to LinkLite are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

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

[0.3.4]: https://github.com/matthewrball/linklite/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/matthewrball/linklite/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/matthewrball/linklite/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/matthewrball/linklite/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/matthewrball/linklite/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/matthewrball/linklite/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/matthewrball/linklite/releases/tag/v0.1.0
