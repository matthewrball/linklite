#!/bin/sh
# Regenerates the LinkLite brand assets from the HTML/SVG sources in this directory.
#
#   docs/assets/logo.png            1024 px app icon (macOS grid, transparent)
#   docs/assets/logo-512.png        512 px copy
#   docs/assets/social-preview.png  1280x640 GitHub social preview
#   Resources/AppIcon.icns          app icon for the bundle
#
# Needs Google Chrome (headless), plus sips and iconutil from macOS.
# Usage: docs/assets/src/build.sh
set -eu

src=$(cd "$(dirname "$0")" && pwd)
assets=$(dirname "$src")
repo=$(cd "$assets/../.." && pwd)
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# render <page> <out.png> <width> <height>
# Always at device scale 1: the icon's weave seam is aligned to whole pixels at 1024 px.
render() {
	"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
		--default-background-color=00000000 --window-size="$3,$4" \
		--screenshot="$2" "file://$src/$1" >/dev/null 2>&1
	[ -s "$2" ] || { echo "render failed: $1" >&2; exit 1; }
}

# scale <in.png> <size> <out.png>
scale() { sips -z "$2" "$2" "$1" --out "$3" >/dev/null; }

render icon.html "$assets/logo.png" 1024 1024
render "icon.html?small=1" "$work/small.png" 1024 1024
scale "$assets/logo.png" 512 "$assets/logo-512.png"

# 16 and 32 px come from the small master (chunkier bezels, no rivets); 64 px and up from the full one.
set="$work/AppIcon.iconset"
mkdir "$set"
scale "$work/small.png" 16 "$set/icon_16x16.png"
scale "$work/small.png" 32 "$set/icon_16x16@2x.png"
scale "$work/small.png" 32 "$set/icon_32x32.png"
scale "$assets/logo.png" 64 "$set/icon_32x32@2x.png"
scale "$assets/logo.png" 128 "$set/icon_128x128.png"
scale "$assets/logo.png" 256 "$set/icon_128x128@2x.png"
scale "$assets/logo.png" 256 "$set/icon_256x256.png"
scale "$assets/logo.png" 512 "$set/icon_256x256@2x.png"
scale "$assets/logo.png" 512 "$set/icon_512x512.png"
cp "$assets/logo.png" "$set/icon_512x512@2x.png"
iconutil -c icns -o "$repo/Resources/AppIcon.icns" "$set"

render social-preview.html "$assets/social-preview.png" 1280 640

echo "Wrote logo.png, logo-512.png, social-preview.png and Resources/AppIcon.icns"
