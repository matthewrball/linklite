#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Sample per-process GPU time, CPU, memory and energy impact once a second.

Usage: sampler.py OUT_DIR

Writes CSV rows to OUT_DIR/samples.csv until the file OUT_DIR/stop exists. The current phase label
is read from OUT_DIR/phase ("driver,phase"), which run.sh updates. GPU time comes from the AGX
driver's per-client AppUsage counters (the source Activity Monitor uses), CPU/memory/energy from
Apple's `top`.
"""
import csv, os, plistlib, re, subprocess, sys, threading, time

# LinkLite, DisplayLink Manager's two processes, and the window server, which composites the
# virtual displays for either driver.
PROCS = {"LinkLite", "DisplayLinkUserAgent", "DisplayLinkXpcService", "WindowServer"}

def canonical(name):
    """Map a process name, possibly truncated (top cuts names to 16 characters), to a tracked one."""
    if name in PROCS:
        return name
    # Only long prefixes count as truncations, so short unrelated names cannot match.
    if len(name) < 12:
        return None
    return next((p for p in PROCS if p.startswith(name) or name.startswith(p)), None)

out_dir = sys.argv[1]
stop_file = os.path.join(out_dir, "stop")
phase_file = os.path.join(out_dir, "phase")

out = open(os.path.join(out_dir, "samples.csv"), "w", newline="")
w = csv.writer(out)
w.writerow(["t", "driver", "phase", "process", "cpu_pct", "mem_mb", "energy", "gpu_ms_per_s", "gpu_util_pct"])

def phase():
    try:
        return open(phase_file).read().strip().split(",", 1)
    except OSError:
        return ["", ""]

def gpu_times():
    """Accumulated GPU nanoseconds per process name, summed over that process's clients."""
    raw = subprocess.run(["ioreg", "-r", "-c", "AGXDeviceUserClient", "-a"], capture_output=True).stdout
    totals = {}
    for entry in plistlib.loads(raw) if raw else []:
        m = re.match(r"pid (\d+), (.+)", entry.get("IOUserClientCreator", ""))
        name = canonical(m.group(2)) if m else None
        if not name:
            continue
        ns = sum(u.get("accumulatedGPUTime", 0) for u in entry.get("AppUsage", []) or [])
        totals[name] = totals.get(name, 0) + ns
    return totals

def device_util():
    """Whole-GPU utilisation, as reported by the accelerator's PerformanceStatistics."""
    raw = subprocess.run(["ioreg", "-r", "-c", "IOAccelerator", "-w0", "-l"], capture_output=True, text=True).stdout
    m = re.search(r'"Device Utilization %"=(\d+)', raw)
    return int(m.group(1)) if m else -1

def parse_mem(s):
    m = re.match(r"([\d.]+)([BKMG])", s)
    if not m:
        return 0.0
    return float(m.group(1)) * {"B": 1 / 1048576, "K": 1 / 1024, "M": 1, "G": 1024}[m.group(2)]

latest = {}  # process -> (cpu, mem_mb, energy) from the newest top sample
lock = threading.Lock()

def top_reader():
    p = subprocess.Popen(["/usr/bin/top", "-l", "0", "-s", "1", "-stats", "command,cpu,mem,power"],
                         stdout=subprocess.PIPE, text=True)
    sample = {}
    for line in p.stdout:
        if line.startswith("Processes:"):
            with lock:
                latest.clear()
                latest.update(sample)
            sample = {}
            continue
        parts = line.split()
        if len(parts) >= 4 and canonical(parts[0]):
            try:
                sample[canonical(parts[0])] = (float(parts[-3]), parse_mem(parts[-2]), float(parts[-1]))
            except ValueError:
                pass

threading.Thread(target=top_reader, daemon=True).start()
prev, prev_t = gpu_times(), time.monotonic()
start = prev_t
while not os.path.exists(stop_file):
    time.sleep(1)
    now_t = time.monotonic()
    cur = gpu_times()
    util = device_util()
    driver, ph = phase()
    with lock:
        snap = dict(latest)
    for proc in sorted(PROCS):
        if proc not in cur and proc not in snap:
            continue
        gpu = max(0, cur.get(proc, 0) - prev.get(proc, 0)) / 1e6 / (now_t - prev_t)
        cpu, mem, energy = snap.get(proc, (0.0, 0.0, 0.0))
        w.writerow([round(now_t - start, 1), driver, ph, proc, cpu, round(mem, 1), energy, round(gpu, 3), util])
    out.flush()
    prev, prev_t = cur, now_t
