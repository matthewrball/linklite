#!/bin/zsh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# A/B/A benchmark: LinkLite, DisplayLink Manager, LinkLite. See docs/BENCHMARK.md.
# Each run: 15 s settle, 45 s live desktop, 45 s of a 60 fps canvas animation in an isolated Chrome
# window on the right-most external screen.
#
# Needs both LinkLite and DisplayLink Manager installed, Google Chrome, and two monitors on the dock.
# Start with LinkLite driving the dock and DisplayLink Manager quit. Settings:
#   LINKLITE_APP  path to LinkLite.app (default /Applications/LinkLite.app)
#   BENCH_OUT     output directory for run.log and samples.csv (default $TMPDIR/linklite-bench)
#   BENCH_ONLY    "lite" to measure LinkLite alone (one run, no DisplayLink Manager)
here="${0:A:h}"
app="${LINKLITE_APP:-/Applications/LinkLite.app}"
out="${BENCH_OUT:-${TMPDIR:-/tmp}/linklite-bench}"
chrome_profile="$out/chrome-profile"
mkdir -p "$out"
rm -f "$out/stop" "$out/run.log" "$out/samples.csv"

log() { print -r -- "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }

externals() {  # prints "count x y w h" for the right-most external screen, in CG (top-left) coordinates
  osascript -l JavaScript -e '
    ObjC.import("AppKit");
    const s = $.NSScreen.screens, main = s.objectAtIndex(0).frame;
    let n = 0, best = null;
    for (let i = 1; i < s.count; i++) { const f = s.objectAtIndex(i).frame; n++;
      if (!best || f.origin.x > best.origin.x) best = f; }
    best ? `${n} ${best.origin.x} ${main.size.height - best.origin.y - best.size.height} ${best.size.width} ${best.size.height}` : "0 0 0 0 0";'
}

modes() {  # each external screen's "looks like" size and the pixels macOS actually renders
  osascript -l JavaScript -e '
    ObjC.import("AppKit");
    const s = $.NSScreen.screens, out = [];
    for (let i = 1; i < s.count; i++) { const sc = s.objectAtIndex(i), f = sc.frame, k = sc.backingScaleFactor;
      out.push(`${f.size.width}x${f.size.height}pt@${k}x=${f.size.width * k}x${f.size.height * k}px`); }
    out.join(" ");'
}

wait_for_two() {
  for i in {1..60}; do
    [[ "$(externals | cut -d' ' -f1)" == 2 ]] && return 0
    sleep 1
  done
  log "WARN: two external screens did not appear"; return 1
}

phase() { print -r -- "$1,$2" > "$out/phase"; log "phase $1 $2"; }

run_driver() {  # $1 = label
  wait_for_two
  log "$1 screens: $(externals); modes: $(modes)"
  phase $1 settle; sleep 15
  phase $1 desktop; sleep 45
  read n x y w h <<< "$(externals)"
  open -na "Google Chrome" --args "--user-data-dir=$chrome_profile" --no-first-run --no-default-browser-check \
    --window-position=$(( ${x%.*} + 80 )),$(( ${y%.*} + 80 )) --window-size=1600,900 "--app=file://$here/motion.html"
  sleep 3
  phase $1 animation; sleep 45
  pkill -f -- "--user-data-dir=$chrome_profile"; sleep 2
}

quit_lite() { osascript -e 'quit app "LinkLite"'; for i in {1..30}; do pgrep -xq LinkLite || return; sleep 1; done; }
quit_dlm() { osascript -e 'quit app "DisplayLink Manager"'; for i in {1..30}; do pgrep -q DisplayLinkUserAgent || return; sleep 1; done; }

phase none start
python3 "$here/sampler.py" "$out" &
sampler=$!

pgrep -xq LinkLite || open "$app"
run_driver lite1
if [[ "${BENCH_ONLY:-}" != lite ]]; then
  quit_lite; phase none switch; open -a "DisplayLink Manager"
  run_driver dlm
  quit_dlm; phase none switch; open "$app"
  run_driver lite2
fi

touch "$out/stop"; wait $sampler; rm -rf "$chrome_profile"
log "DONE: results in $out"
