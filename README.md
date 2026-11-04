# DisplayLink Lite

A lightweight replacement for DisplayLink Manager on macOS. Built and tested on a Humanscale M/Connect 2 dock (DisplayLink DL-6xxx "Ridge", USB `17e9:600f`) driving two HP Z27k G3 monitors at 3840×2160 @ 60 Hz.

**DisplayLink Lite** is a menu-bar app. For each monitor on the dock it creates a macOS virtual display, captures only the parts of it that change, and sends the changed 64×16 strips to the dock. The mouse pointer is drawn by the dock itself, so moving it costs a few bytes rather than a redraw. A still desktop puts nothing on the wire.

## For testers

1. Download `DisplayLink-Lite-<version>.zip` from the release, unzip it, and move **DisplayLink Lite** to Applications.
2. Quit DisplayLink Manager (menu-bar icon › Quit). Only one program can drive the dock.
3. Open DisplayLink Lite. Grant **Screen & System Audio Recording** when asked (System Settings › Privacy & Security), then quit and reopen it from its menu-bar icon.
4. Your monitors should light up within a few seconds. Turn on **Open at Login** from the menu-bar icon to keep using it.

Requirements: macOS 14 or later on Apple Silicon, and a USB 3 (5 Gbps) link to the dock.

Supported docks: DL-6xxx (Ridge) is tested. DL-3xxx (Ella) and DL-7400 (Navarro) docks are recognised by the Vino core but untested on macOS. Please report the dock model, `swift run dlprobe` output, and what you saw.

### Why Screen Recording permission?

macOS has no public way for a third-party program to provide a display. Apple offers no display driver framework (DriverKit has none, and display kexts no longer work on Apple Silicon), so every USB display product, DisplayLink Manager included, creates a virtual display and reads its pixels back with ScreenCaptureKit, which macOS gates behind Screen Recording. DisplayLink Lite captures only the virtual displays it created for the dock, never your built-in screen, and the pixels go nowhere but the USB dock.

Going back to DisplayLink Manager: quit DisplayLink Lite and open DisplayLink Manager.

## How it is built

| Part | Where | What it does |
|---|---|---|
| Dock engine (Rust) | `engine/` | USB transport, HDCP 2.2 authentication, encrypted control plane, mode setting, video codec, hardware cursor, rate limiting; C ABI in `engine/include/dllite.h` |
| Vendored protocol core | `vendor/vino/` | Vino/chimera userspace DL3 implementation, GPL-2.0-or-later; local patches listed in `vendor/vino/UPSTREAM.md` |
| Display host (Swift) | `Sources/DisplayLinkLite/` | Virtual displays, capture, pointer tracking, menu bar, display sleep/wake |
| Preflight probe | `Sources/dlprobe/` | Read-only USB link and descriptor check |

Licence: GPL-2.0-or-later (`LICENSE`), because the engine links the GPL Vino core.

## Build and install

Requires Xcode command-line tools and a Rust toolchain (rustup recommended; Homebrew's Rust builds an app that runs only on the macOS it was built on).

```sh
scripts/build-app.sh
cp -R "dist/DisplayLink Lite.app" /Applications/
open "/Applications/DisplayLink Lite.app"
```

The build signs with your Developer ID or Apple Development identity if the keychain has one; otherwise it signs ad hoc, and macOS will ask for Screen Recording permission again after every rebuild.

### Release package

```sh
xcrun notarytool store-credentials dllite --apple-id <apple-id> --team-id <team-id>   # once
DLL_NOTARY_PROFILE=dllite scripts/release.sh
```

This produces `dist/DisplayLink-Lite-<version>.zip` and its `.sha256`, signed with the Developer ID and, with a notary profile, notarized and stapled so testers can open it without a Gatekeeper warning. Without `DLL_NOTARY_PROFILE` the zip is signed but not notarized; testers then approve it once under System Settings › Privacy & Security › Open Anyway.

On first launch, grant **Screen & System Audio Recording** to DisplayLink Lite (System Settings › Privacy & Security). Turn on **Open at Login** from the menu-bar item.

## Using it instead of DisplayLink Manager

Only one program can drive the dock. Quit DisplayLink Manager before opening DisplayLink Lite; while DisplayLink Manager holds the dock, the menu shows that the dock is in use.

Monitors use their EDID preferred mode (3840×2160 at 60 Hz for the HP Z27k G3). macOS offers "looks like" scaled resolutions; the first time a monitor is seen it defaults to "looks like 1920×1080", which is drawn at exactly the panel's native 3840×2160.

## Diagnostics

```sh
swift run dlprobe                  # USB link speed and current owner of the dock
swift run dlprobe --descriptors    # interface and endpoint layout (read-only)
cargo run --release --manifest-path engine/Cargo.toml --bin dllite-probe
                                   # engage the dock and list each connector's monitor
```

`dllite-probe` needs the dock to itself: quit DisplayLink Lite and DisplayLink Manager first.

A 480 Mbps USB 2.0 link is too slow for two 4K monitors; `dlprobe` reports it as `FAIL`. Fix the cable or port until it reports 5000 Mbps or faster.

## Tests

```sh
cargo test --manifest-path engine/Cargo.toml        # engine
(cd engine && cargo test -p vino-chimera)           # vendored protocol core
swift test                                          # dlprobe core
```

`swift build` links the engine archive, so build the engine first (`cargo build --release --manifest-path engine/Cargo.toml`).

See [ROADMAP.md](ROADMAP.md) for the gates this replacement had to pass.
