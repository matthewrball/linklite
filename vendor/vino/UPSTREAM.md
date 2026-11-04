# Vendored Vino userspace core

Source: https://github.com/cameron1729/Vino, commit `490aa8e13488c9dbf0c88cb80aa4676d525a50ef` (2026-09-21), directory `revdi/`.

| Directory | Upstream | Licence |
|---|---|---|
| `chimera/` | `revdi/chimera` | GPL-2.0-or-later |
| `kernel-shim/` | `revdi/kernel-shim` | GPL-2.0-or-later |
| `vino-driver/` | `revdi/vino-driver` | GPL-2.0-or-later |
| `LICENSES/` | `revdi/LICENSES` | licence texts |

Copied unmodified except for the local patches below. `chimera/vino/` holds the literal DL3 protocol, HDCP 2.2 AKE, encrypted control plane, dock profiles, and video codec from the in-kernel `drm/vino` driver; chimera compiles it in userspace over libusb.

## Local patches

All were found or measured on a Humanscale M/Connect 2 (`17e9:600f`, Ridge firmware 12.2.25) with two HP Z27k G3 monitors.

1. **Parallel encode** — `chimera/src/scanout.rs`: `strip_hashes` and the fresh-body pass of `HeadScanout::encode` run across cores through `par_for_each_mut` (scoped threads; passes under 64 strips stay on the calling thread). Upstream's only SIMD path is x86-64, so on Apple Silicon a serial 4K keyframe took 96 ms; parallel it takes 12 ms. Output is byte-identical to serial `encode_strip` + `frame_records` across all 8100 strips of a 4K frame.
2. **EDID readiness gate** — `chimera/src/edid_fetch.rs`: before the dock reports its downstream read complete, only the dock's own `NVT` placeholder EDID is discarded (`is_dock_placeholder`). This dock never sets the readiness bit, so upstream discarded both monitors' real `HPN` EDIDs and lit nothing.
3. **Downstream-change notice** — `chimera/src/session.rs`: replies read by `send_control` and `send_control_echoing` go through `ControlSession::receive`, which records the dock's `id=0x03 sub=0x82` push; `take_downstream_change()` exposes it. The engine probes lit heads only after this notice on shared-EDID-handler docks, because probing them once a second kept both monitors in standby.
4. **Settle pass** — `chimera/src/scanout.rs` (`HeadScanout::settle`, `touched`) and `chimera/src/session.rs` (`ControlSession::settle`): every strip changed since the last settle is owed another `damage_frames` round once the surface has been still for 100 ms. The engine paces those retransmissions one refresh apart. A transmission the dock missed or placed in the other buffer while things moved can therefore not leave a stale box behind.
5. **Video bytes returned** — `ControlSession::present_rgb` returns the bytes it submitted so the engine can hold all heads together to 100 MB/s (Vino's measured DLM rate on this family). Unthrottled full-screen motion on two 4K heads reset the dock off the bus within minutes.
6. **Three ring slots** — `chimera/vino/profile.rs`: Ridge `dock_buffers: 3` and `FrameDelivery::new(3, 1, 3)` (upstream 2 and `(2, 1, 3)`); the pinned assertion in `api.rs` follows. Ridge's frame trailer already cycles three phases (`ring_phase`, `seq % 3`), and Vino's notes record the vendor filling slots 0/2/4 in equal thirds. Two keyframe presentations left one slot stale, seen as patches flickering on a still screen.
7. **Dirty hint** — `chimera/src/scanout.rs` (`HeadScanout::plan_dirty`, `strip_hashes_within`, `strip_hash`) and `chimera/src/session.rs` (`ControlSession::present_rgb_dirty`): when the caller knows which areas changed (ScreenCaptureKit's dirty rects), only strips meeting them are hashed. Full-surface hashing of a 4K frame for a ticking menu-bar item was the largest steady CPU cost. `plan` and `present_rgb` keep upstream behaviour.

Tried and reverted (measured worse on this dock): a zero-length packet after full-packet frames (did not stop resets), presenting each delta twice (`FrameDelivery::new(2, 2, 3)`; doubled bandwidth and reset the dock without the rate limit).

To refresh, re-copy those directories from a newer upstream commit, re-apply the patches, update the commit above, and re-run `cargo test -p vino-chimera` in `engine/`. The vendored crate cannot build standalone because its optional Linux `revdi` dependency is not vendored; build it through `engine/`.
