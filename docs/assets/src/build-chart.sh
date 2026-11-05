#!/bin/zsh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Renders the README benchmark and optimization graphics from the checked-in measurements.
# Usage: docs/assets/src/build-chart.sh (no installed applications or attached dock needed)
set -euo pipefail
here="${0:A:h}"
assets="${here:h}"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
profile="$(mktemp -d -t linklite-charts)"
trap 'rm -rf "$profile"' EXIT

for graphic in benchmark optimizations; do
  height=500
  [[ "$graphic" == optimizations ]] && height=456
  for theme in light dark; do
    "$chrome" --headless=new --disable-gpu --hide-scrollbars \
      --user-data-dir="$profile/chrome" --allow-file-access-from-files \
      --force-device-scale-factor=2 --virtual-time-budget=2000 \
      --window-size="880,$height" --screenshot="$profile/$graphic-$theme.png" --dump-dom \
      "file://$here/benchmark.html?view=$graphic&theme=$theme" \
      > "$profile/$graphic-$theme.html" 2> "$profile/$graphic-$theme.log"
    if ! grep -q 'data-rendered="true"' "$profile/$graphic-$theme.html"; then
      echo "Chart data did not render: $graphic ($theme)" >&2
      cat "$profile/$graphic-$theme.log" >&2
      exit 1
    fi
  done
done
mv "$profile"/{benchmark,optimizations}-{light,dark}.png "$assets/"
print "Rendered light and dark benchmark and optimization graphics"
