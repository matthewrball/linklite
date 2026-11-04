#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds, signs, and packages "DisplayLink Lite" for testers: dist/DisplayLink-Lite-<version>.zip
# plus its SHA-256.
#
# Notarization: set DLL_NOTARY_PROFILE to a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific>
# Without it the zip is signed but not notarized, and testers must approve the app in
# System Settings › Privacy & Security › "Open Anyway" on first launch.
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/build-app.sh

app="dist/DisplayLink Lite.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
zip="dist/DisplayLink-Lite-$version.zip"
rm -f "$zip" "$zip.sha256"

if [[ -n "${DLL_NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$DLL_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
    echo "Notarized and stapled."
else
    echo "DLL_NOTARY_PROFILE not set: packaging without notarization."
fi

ditto -c -k --keepParent "$app" "$zip"
(cd dist && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
echo "Packaged $zip"
cat "$zip.sha256"
