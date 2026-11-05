# Development notes

The engineering gate log for LinkLite: the hardware and safety gates the replacement had to pass, with the measured status of each.

The target is intentionally narrow: keep the Humanscale M/Connect 2 (`0x17e9:0x600f`) and replace only the macOS DisplayLink user-space display pipeline with a smaller local implementation.

This cannot turn M/Connect 2 into a native Thunderbolt or DisplayPort Alt Mode dock. Humanscale documents its display path as DisplayLink-dependent. A replacement must still create displays in macOS, capture their pixels, compress changes, and speak the dock's proprietary DL-6xxx USB protocol.

## Hard gates

### Gate 0: USB 3.x transport

Run:

```sh
swift run dlprobe
```

The result must be `PASS` at 5 Gbps or faster. Do not try to compensate for a USB 2.0 link with more aggressive host compression; that works against the lightweight goal.

Status 2026-11-03: **PASS** at 5000 Mbps on the current desk. An earlier setup reported 480 Mbps; if that returns, check the upstream full-feature USB-C cable, adapters, port connection, and macOS accessory authorization, and re-run `dlprobe` after each physical change.

### Gate 1: protocol identity

Independently confirm that product `0x600f` uses the same DL3 control and video endpoint layout documented for the DL-6000 family. This gate is read-only: descriptors and known-safe device queries only.

Licensing: the Vino sources carry per-file `SPDX-License-Identifier: GPL-2.0` / `GPL-2.0-or-later` headers (and `revdi/LICENSES/`), so they are vendored under those terms in `vendor/vino/` and this project is GPL-2.0-or-later.

Status 2026-11-03: **layout matches DL-6xxx "Ridge"** (`swift run dlprobe --descriptors`, `bcdDevice 0x3104`):

| Interface | Class | Endpoints | Ridge reference (Dell D6000 `17e9:6006`) |
|---|---|---|---|
| 0 alt 0 | `ff/00/03` vendor | bulk `0x02` OUT, `0x84` IN, `0x08` `0x0a` `0x0b` `0x0c` OUT, all 1024 B | control `0x02`/`0x84`, per-head video bulk-OUT incl. `0x08`, `0x0b` |
| 0 alt 1 | `ff/00/04` vendor | bulk `0x08` OUT | not documented |
| 1 | `fe/01/01` DFU | none | firmware update path; never touch |
| 2-4 | USB audio | iso/int | n/a |
| 5-6 | CDC NCM ethernet | int + bulk | n/a |

Public observations (Vino `docs/protocol/generations.md`, `docs/ridge.md`): Ridge's control plane is plaintext init, then an HDCP 2.2 AKE, then AES-CTR + CMAC-sealed records; video is a vendor wavelet codec per head; the dock has one EDID handler shared between heads. Open in Gate 1: read the running firmware version (a vendor descriptor, not `bcdDevice`) only once a standard-request path for it is confirmed.

### Gate 2: control-plane engagement

Use a spare dock or a deliberate maintenance window. DisplayLink Manager must release its exclusive USB ownership before another process can claim the interface, so the attached DisplayLink screens will go dark during this test.

Success means:

- claim and release the correct USB interface cleanly
- complete the required session and encrypted control-plane setup
- read monitor identity and state
- leave the dock operational after process exit

No video endpoint writes are allowed at this gate.

Status 2026-11-03: **PASS** on the live dock. HDCP 2.2 AKE and the sealed control session complete on macOS over libusb; both monitors read as `HPN HP Z27k G3`, 3840x2160@60 (once the monitors were powered on, and after the local EDID readiness patch in `vendor/vino/UPSTREAM.md`); quitting the app releases the dock.

### Gate 3: one-head video proof

On a spare dock, send one known-safe solid frame to one output after a valid mode set. Incorrect DL-6xxx video writes can reset the dock or destabilize the live desktop, so this is not a first test on the user's only active dock.

Success means one monitor exits standby, shows the expected frame, and the dock survives repeated start/stop cycles.

Status 2026-11-03: **PASS**. Both heads lit at 3840x2160@60 with a solid test colour each, then with the desktop. Codec checked offline against Vino's decoder on a real screenshot: 49.7 dB PSNR, max error 8/255, no decode failures.

### Gate 4: macOS display pipeline

Only after the hardware proof:

- create one macOS virtual display
- capture dirty regions instead of full frames when possible
- reuse a bounded IOSurface/buffer pool
- encode and send one head, then add the second
- handle hotplug, sleep/wake, resolution changes, and orderly shutdown

macOS does not expose a supported public API for a general USB-backed display. DisplayLink Manager itself imports private virtual-display APIs, so a same-dock replacement will be OS-version-sensitive and unsuitable for the Mac App Store.

Status 2026-11-03: **working on both heads**: CGVirtualDisplay + ScreenCaptureKit with SCK dirty rects (only changed areas are converted and hashed), dock hardware cursor, settle pass and three-slot delivery (no stale boxes or flicker, confirmed on the monitors), 100 MB/s video rate limit (no dock resets under App Exposé), reuse of a virtual display across a dock reset, display sleep/wake mapped to sink power, slow probing of empty sockets for monitors switched on later. Measured idle: ~135 MB footprint, under 1 s of CPU per minute.

## Acceptance criteria

- two HP Z27k G3 displays at 3840x2160 and 60 Hz
- the external displays remain usable with DisplayLink Manager stopped
- bounded memory after an eight-hour run, with no upward trend
- materially lower memory and CPU than an A/B run of DisplayLink Manager on the same 5 Gbps link and workload
- repeatable hotplug and sleep/wake without a process crash, dock reset, logout, or reboot
- DisplayLink Manager remains installed until all criteria pass

Status 2026-11-03: criteria 1 and 2 met on the monitors. Not yet measured: the eight-hour memory run, an A/B against DisplayLink Manager, and repeated sleep/wake and hotplug cycles.

Protected-content playback is out of scope for the first implementation.

## Engineering hardening — 2026-11-04 (v0.3.7 prerelease)

These changes ship in v0.3.7. LinkLite remains beta software; this prerelease does not close the outstanding hardware gates or establish 1.0 readiness.

The C ABI and wire encoding are unchanged. Capture damage is converted lazily at the ABI boundary, frame spans are checked before constructing Rust slices, and cursor/damage/candidate storage is reused. Cached encoded strips are borrowed during packing, and USB chunks are filled without an intermediate full-frame stream. Byte-equivalence regressions cover the affected encoding paths. See [BENCHMARK.md](BENCHMARK.md#hardware-free-optimization-checks--2026-11-04) for the limited measurements and their method.

The native dependency is pinned in `vendor/libusb1-sys/` with documented upstream descriptor-parser backports. The USB receive queue now has a hard capacity and fails closed on overflow. Teardown waits for all submitted transfer callbacks before releasing memory; if libusb never completes cancellation, shutdown can wait indefinitely. Do not replace that wait with a timeout that frees live callback state.

Hardware-free regressions and signed application builds pass. Two-monitor rendering, physical unplug/replug, sleep/wake, the receive-queue high-water mark, and an eight-hour memory run still need live-hardware validation for these changes. These checks do not supersede the acceptance criteria above.


## Safety boundaries

- Never terminate `WindowServer` or `kernel_task`.
- Never send undocumented vendor or video writes to the live dock.
- Never uninstall DisplayLink Manager before the replacement passes Gate 4.
- Treat a dock reset, USB stall, forced logout, or macOS crash as a failed test.

## Reference implementations and documentation

- [Humanscale M/Connect 2 user guide](https://humanscale.getbynder.com/m/49d81af0b0b26c05/original/hs-technology-tool-m-connect2-user-guide.pdf)
- [Synaptics DL-6000 series](https://drivers.synaptics.com/products/displaylink-graphics/integrated-chipsets/dl-6000)
- [FireBurn/Vino clean-room research](https://lwn.net/Articles/1090989/) (drm/vino v3 cover letter; drives DL-6xxx on Linux)
- [Vino protocol notes](https://github.com/cameron1729/Vino/tree/main/docs) (the `revdi/` sources LinkLite builds on are vendored in `vendor/vino/` under their per-file GPL-2.0 / GPL-2.0-or-later SPDX headers; see `vendor/vino/UPSTREAM.md`)
- [DisplayLink Manager 16.2 release notes](https://drivers.synaptics.com/sites/default/files/release_notes/2026-07/DisplayLink%20Manager%20Graphics%20Connectivity16.2-Release%20Notes.txt)
