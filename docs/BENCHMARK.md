# Benchmark

How LinkLite's resource use is measured against DisplayLink Manager on the same dock, monitors, and workload. The scripts are in [`benchmark/`](benchmark/).

## Method

### Hardware

- MacBook Pro, Apple M5 Pro, 64 GB, macOS 26.6.
- Humanscale M/Connect 2 dock (DL-6xxx "Ridge", USB `17e9:600f`) on a 5 Gbps USB link (checked with `swift run dlprobe`).
- Two HP Z27k G3 monitors, 3840x2160 @ 60 Hz, both set to "looks like" 1920x1080 (HiDPI).

### Runs

Each benchmark is an **A/B/A** sequence on one boot, driven by [`benchmark/run.sh`](benchmark/run.sh):

1. LinkLite (`lite1`)
2. DisplayLink Manager (`dlm`)
3. LinkLite again (`lite2`)

Repeating LinkLite after DisplayLink Manager shows how much of any difference is drift (thermal state, background activity) rather than the driver. Between runs the script quits one driver, opens the other, and waits until both external screens are back.

Each run has three phases:

| Phase | Length | Workload |
|---|---|---|
| `settle` | 15 s | Nothing; lets the displays come up and the driver reach steady state. Not scored. |
| `desktop` | 45 s | The live desktop as it is: menu-bar clock, idle windows. |
| `animation` | 45 s | [`benchmark/motion.html`](benchmark/motion.html), a deterministic 60 fps canvas animation (scrolling gradient, drifting cards, a frame counter) in a 1600x900 Chrome window on the right-most external screen. It changes most of the window every frame, like scrolling a web page. Chrome runs with an isolated, temporary profile so extensions and other tabs do not interfere. |

### Metrics

[`benchmark/sampler.py`](benchmark/sampler.py) samples once a second for the driver's processes (`LinkLite`; `DisplayLinkUserAgent` and `DisplayLinkXpcService` for DisplayLink Manager) and for `WindowServer`, which composites the virtual displays for either driver:

| Metric | Source |
|---|---|
| Per-process GPU time (ms of GPU per second) | The AGX driver's per-client `AppUsage` › `accumulatedGPUTime` counters, read with `ioreg -r -c AGXDeviceUserClient`, summed per process and differenced between samples. This is the counter Activity Monitor's GPU column uses. |
| Whole-GPU utilisation (%) | `Device Utilization %` in the `IOAccelerator` performance statistics (`ioreg -r -c IOAccelerator`). |
| CPU (%), memory (MB), energy impact | `/usr/bin/top -l 0 -s 1 -stats command,cpu,mem,power`. |

Each phase is summarised per driver from its one-second samples. WindowServer is reported alongside the driver, because work a driver pushes onto the compositor still costs the user.

### Running it

Install LinkLite and DisplayLink Manager, attach the dock with both monitors, and start with LinkLite driving the dock and DisplayLink Manager quit. Then:

```sh
docs/benchmark/run.sh
```

The run takes about six minutes. Leave the Mac alone while it runs. `run.log` and `samples.csv` are written to `$TMPDIR/linklite-bench` (override with `BENCH_OUT`); set `LINKLITE_APP` if LinkLite is not in `/Applications`.

## Results

Run on 2026-11-03: LinkLite 0.2.0 (pre-release build), DisplayLink Manager 16.1.25, macOS 26.6. Both drivers rendered each monitor at 1920x1080 points, 2x (3840x2160 pixels), checked in [`run-2026-11-03.log`](benchmark/run-2026-11-03.log). Raw samples: [`samples-2026-11-03.csv`](benchmark/samples-2026-11-03.csv); summary: [`results.json`](benchmark/results.json), produced by [`summarize.py`](benchmark/summarize.py).

### Summary (LinkLite runs averaged)

| Driver | Phase | Whole GPU busy | GPU time: driver + WindowServer | Driver CPU | Driver memory |
|---|---|---|---|---|---|
| LinkLite | Live desktop | 12% | 162 ms/s (0 + 162) | 55% | 133 MB |
| LinkLite | 60 fps animation | **15%** | **250 ms/s (0 + 250)** | 338% | **135 MB** |
| DisplayLink Manager | Live desktop | **2%** | **76 ms/s (9 + 67)** | **2%** | 512 MB |
| DisplayLink Manager | 60 fps animation | 33% | 323 ms/s (168 + 155) | **20%** | 513 MB |

### Per run

| Run | Phase | Whole GPU busy | Driver GPU | WindowServer GPU | Driver CPU | Driver memory |
|---|---|---|---|---|---|---|
| lite1 | desktop | 3.8% | 0 ms/s | 123 ms/s | 53% | 136 MB |
| lite1 | animation | 9.7% | 0 ms/s | 216 ms/s | 336% | 135 MB |
| dlm | desktop | 2.4% | 9 ms/s | 67 ms/s | 2% | 512 MB |
| dlm | animation | 33.0% | 168 ms/s | 155 ms/s | 20% | 513 MB |
| lite2 | desktop | 19.8% | 0 ms/s | 200 ms/s | 58% | 131 MB |
| lite2 | animation | 20.9% | 0 ms/s | 285 ms/s | 339% | 134 MB |

### Reading the results

- **Under load LinkLite keeps the GPU about half as busy** (15% vs 33%, lower in both LinkLite runs). DisplayLink Manager compresses video on the GPU (168 ms of GPU per second in its own process); LinkLite's own process uses no GPU at all.
- **Memory: 3.8x less** (134 MB vs 513 MB), steady in every phase. App size: 3.9 MB vs 20.6 MB (LinkLite was 2.6 MB in the measured 0.2.0 build; 0.3.0 adds the updater, and its memory use is unchanged at about 135 MB).
- **On a quiet desktop both drivers barely touch the GPU.** The second LinkLite desktop phase (19.8%) caught background activity on the Mac; a 20-second spot check right after, with LinkLite still driving both monitors, read 4.3%, in line with the first run (3.8%). Whole-GPU and WindowServer figures include every app, so treat the desktop phase as noisy.
- **CPU is where DisplayLink Manager wins.** LinkLite encodes on the CPU: about half a core on a live desktop, and about 3.4 cores under full-window 60 fps motion, against 2% and 20% for DisplayLink Manager. Moving LinkLite's encoder to the GPU is the main item on the roadmap.

### Capture path

LinkLite captures with ScreenCaptureKit. The older `CGDisplayStream`, which DisplayLink Manager also links, was measured as an alternative on the same animation: one extra capture of a 4K display cost WindowServer about 25 ms/s of GPU with ScreenCaptureKit and about 17 ms/s with `CGDisplayStream`. The difference is small, and `CGDisplayStream` is obsoleted in the macOS 15 SDK, so LinkLite stays on ScreenCaptureKit.

## Hardware-free optimization checks — 2026-11-04

These are local, narrowly scoped measurements of the unreleased engineering changes, not a rerun of the two-monitor A/B benchmark above.

| Scenario | Before | After |
|---|---:|---:|
| Hidden searching panel: process CPU over six seconds | 9.54% | 0.18% |
| Pack 50 identical cached 3840×2160 Ridge frames, optimized Rust build | 204.1 ms | 119.2 ms |

The panel measurement launched the production SwiftUI panel and controller in a temporary native host, showed it, dismissed it, waited one second for the fade to finish, then sampled process CPU time with `getrusage`. Both versions used the same searching state. Releasing the hidden view tree stops its repeating status animation. This measures panel overhead, not the USB engine or an attached-display workload.

The packing comparison exercised the former double-copy path and the borrowed-body path against the same patterned RGB frame and cached encoded strips. The new path avoids 16,200 strip-body allocations and 41,988,360 copied body bytes per such full frame; this is allocation/copy traffic, not retained memory. The byte-equivalence regression remains in `vendor/vino`; the temporary timing harness was removed.

Capture smoke checks exercised initial/full, partial, empty, and scaled damage through the actual Swift callback. Cursor checks compared reused-buffer output byte-for-byte and checked hotspots at 1× and 2×. No full-application RSS reduction, USB throughput gain, eight-hour stability result, hotplug result, or older-macOS compatibility result is claimed by these checks.

## README graphics

The lead graphic uses the saved real-dock results in [`benchmark/results.json`](benchmark/results.json), not the unreleased component checks. The memory headline compares each driver's mean memory across desktop and animation: `100 × (1 − 134.0549 / 512.8444) = 73.86%`, rounded to **74% less memory**. The supporting whole-GPU-busy figure under motion is `100 × (1 − 15.2308 / 32.9556) = 53.78%`, rounded to **54% lower**. Neither is a new measurement of the optimized build.

The separate optimization graphic reads [`benchmark/optimizations-2026-11-04.json`](benchmark/optimizations-2026-11-04.json), which records the rounded measurements and structural counts described above. Its CPU reduction applies only to the hidden-panel host; its packing-time reduction is not an increase in display frame rate. The copied-byte count is for the synthetic full-frame case, not retained RAM.

Regenerate both graphics in light and dark with:

```sh
docs/assets/src/build-chart.sh
```

The renderer uses Google Chrome and a temporary browser profile. It needs neither installed driver applications nor a connected dock, and it publishes the four PNGs only after their measurement data has rendered.
