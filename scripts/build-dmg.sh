#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Packages a built LinkLite.app into a drag-to-Applications disk image with the branded window,
# and signs the image with the app's own Developer ID (ad-hoc builds leave it unsigned).
# Usage: scripts/build-dmg.sh dist/LinkLite.app dist/LinkLite-<version>.dmg
# Needs dmgbuild (`pipx install dmgbuild`).
set -euo pipefail

cd "$(dirname "$0")/.."
app="${1:?usage: build-dmg.sh <LinkLite.app> <output.dmg>}"
dmg="${2:?usage: build-dmg.sh <LinkLite.app> <output.dmg>}"
# Pass paths rather than option-like relative names to rm, codesign, and dmgbuild.
[[ "$app" = /* ]] || app="$PWD/$app"
[[ "$dmg" = /* ]] || dmg="$PWD/$dmg"
command -v dmgbuild >/dev/null || { echo "dmgbuild not found: pipx install dmgbuild" >&2; exit 1; }
codesign --verify --deep --strict "$app"

assets="$(mktemp -d -t linklite-dmg)"
trap 'rm -rf "$assets"' EXIT
swift scripts/dmg/render-background.swift docs/assets/logo-512.png "$assets"

rm -f "$dmg"
dmgbuild -s scripts/dmg/settings.py -D "app=$app" -D "assets=$assets" "LinkLite" "$dmg"

identity="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)"
if [[ -n "$identity" ]]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
fi
hdiutil verify "$dmg" >/dev/null
echo "Built $dmg"
