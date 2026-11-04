#!/bin/zsh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Renders the README benchmark chart (light and dark) from docs/benchmark/results.json.
# usage: build-chart.sh <LinkLite.app> <DisplayLink Manager.app>   (app sizes for the size panel)
set -euo pipefail
here="${0:A:h}"
assets="${here:h}"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mb() { print -r -- "$(du -sk "$1" | cut -f1) / 1024" | bc -l; }

{
  print -r -- "window.RESULTS = $(cat "$assets/../benchmark/results.json");"
  print -r -- "window.SIZES = { linklite_mb: $(mb "$1"), dlm_mb: $(mb "$2") };"
} > "$here/chart-data.js"

for theme in light dark; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=880,592 --screenshot="$assets/benchmark-$theme.png" \
    "file://$here/benchmark.html?theme=$theme" 2>/dev/null
done
rm -f "$here/chart-data.js"
print "Rendered $assets/benchmark-light.png and benchmark-dark.png"
