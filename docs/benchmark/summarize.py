#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Summarize a run.sh benchmark: per-driver, per-phase means.

usage: summarize.py <samples.csv> <results.json>

LinkLite's two runs (lite1, lite2) are averaged together. "Driver" means the driver's own
processes: LinkLite, or DisplayLinkUserAgent + DisplayLinkXpcService for DisplayLink Manager.
GPU figures: the driver's own GPU time, WindowServer's GPU time (compositing and capture), and the
whole GPU's busy percentage.
"""
import csv, json, statistics as st, sys

rows = list(csv.DictReader(open(sys.argv[1])))
DRIVERS = {
    "LinkLite": (["lite1", "lite2"], ["LinkLite"]),
    "DisplayLink Manager": (["dlm"], ["DisplayLinkUserAgent", "DisplayLinkXpcService"]),
}


def per_second(runs, phase, procs, key):
    """Mean over seconds of the per-second sum across `procs`."""
    sums = {}
    for r in rows:
        if r["driver"] in runs and r["phase"] == phase and r["process"] in procs:
            k = (r["driver"], r["t"])
            sums[k] = sums.get(k, 0.0) + float(r[key])
    return st.mean(sums.values()) if sums else None


def gpu_util(runs, phase):
    seen = {(r["driver"], r["t"]): float(r["gpu_util_pct"]) for r in rows if r["driver"] in runs and r["phase"] == phase}
    return st.mean(seen.values()) if seen else None


results = {}
for name, (runs, procs) in DRIVERS.items():
    results[name] = {}
    for phase in ("desktop", "animation"):
        driver_gpu = per_second(runs, phase, procs, "gpu_ms_per_s")
        ws_gpu = per_second(runs, phase, ["WindowServer"], "gpu_ms_per_s")
        results[name][phase] = {
            "gpu_util_pct": gpu_util(runs, phase),
            "driver_gpu_ms_per_s": driver_gpu,
            "windowserver_gpu_ms_per_s": ws_gpu,
            "gpu_ms_per_s_total": (driver_gpu or 0) + (ws_gpu or 0),
            "driver_cpu_pct": per_second(runs, phase, procs, "cpu_pct"),
            "driver_mem_mb": per_second(runs, phase, procs, "mem_mb"),
        }

# Per run, so run-to-run spread (background activity on the Mac) is visible.
results["runs"] = {}
for name, (runs, procs) in DRIVERS.items():
    for run in runs:
        results["runs"][run] = {
            phase: {
                "gpu_util_pct": gpu_util([run], phase),
                "driver_gpu_ms_per_s": per_second([run], phase, procs, "gpu_ms_per_s"),
                "windowserver_gpu_ms_per_s": per_second([run], phase, ["WindowServer"], "gpu_ms_per_s"),
                "driver_cpu_pct": per_second([run], phase, procs, "cpu_pct"),
                "driver_mem_mb": per_second([run], phase, procs, "mem_mb"),
            }
            for phase in ("desktop", "animation")
        }

json.dump(results, open(sys.argv[2], "w"), indent=2)

fmt = lambda v, d=0: "n/a" if v is None else f"{v:.{d}f}"
print("| | Phase | GPU busy | GPU time (driver + WindowServer) | Driver CPU | Driver memory |")
print("|---|---|---|---|---|---|")
for name in DRIVERS:
    for phase, m in results[name].items():
        label = "Live desktop" if phase == "desktop" else "60 fps animation"
        print(f"| {name} | {label} | {fmt(m['gpu_util_pct'])}% | {fmt(m['gpu_ms_per_s_total'])} ms/s "
              f"({fmt(m['driver_gpu_ms_per_s'])} + {fmt(m['windowserver_gpu_ms_per_s'])}) | "
              f"{fmt(m['driver_cpu_pct'])}% | {fmt(m['driver_mem_mb'])} MB |")
print()
print("| Run | Phase | GPU busy | Driver GPU | WindowServer GPU | Driver CPU | Driver memory |")
print("|---|---|---|---|---|---|---|")
for run, phases in results["runs"].items():
    for phase, m in phases.items():
        print(f"| {run} | {phase} | {fmt(m['gpu_util_pct'], 1)}% | {fmt(m['driver_gpu_ms_per_s'])} ms/s | "
              f"{fmt(m['windowserver_gpu_ms_per_s'])} ms/s | {fmt(m['driver_cpu_pct'])}% | {fmt(m['driver_mem_mb'])} MB |")
