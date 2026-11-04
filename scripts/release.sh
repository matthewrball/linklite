#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds, signs, and packages LinkLite for release: dist/LinkLite-<version>.zip plus its SHA-256.
#
# Notarization: set LINKLITE_NOTARY_PROFILE to a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Run this from Terminal: notarytool reads the profile from the login keychain of the session.
# Without a profile the zip is signed but not notarized, and macOS blocks it until the user picks
# "Open Anyway" in System Settings › Privacy & Security.
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/build-app.sh

app="dist/LinkLite.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
zip="dist/LinkLite-$version.zip"
rm -f "$zip" "$zip.sha256"

if [[ -n "${LINKLITE_NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$LINKLITE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
    echo "Notarized and stapled."
else
    echo "LINKLITE_NOTARY_PROFILE not set: packaging without notarization."
fi

ditto -c -k --keepParent "$app" "$zip"
(cd dist && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
echo "Packaged $zip"
cat "$zip.sha256"
