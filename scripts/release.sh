#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds, signs, and packages LinkLite for release: dist/LinkLite-<version>.zip plus its SHA-256,
# and adds the update to appcast.xml, the feed the app's updater reads.
#
# Notarization: set LINKLITE_NOTARY_PROFILE to a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Without a profile the zip is signed but not notarized, and macOS blocks it until the user picks
# "Open Anyway" in System Settings › Privacy & Security.
#
# Updates: the zip is signed with the EdDSA key stored in the login keychain under the Sparkle
# account "linklite" (created once with `generate_keys --account linklite`; its public half is
# SUPublicEDKey in Resources/Info.plist).
#
# Run this from Terminal: notarytool and sign_update read their keys from the login keychain of the
# session. Afterwards, publish the zip as release v<version>, then commit and push appcast.xml;
# installed copies update once the pushed feed lists the new version.
set -euo pipefail

cd "$(dirname "$0")/.."

build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
if grep -q "<sparkle:version>$build</sparkle:version>" appcast.xml; then
    echo "appcast.xml already lists $build: bump the version in Resources/Info.plist first." >&2
    exit 1
fi

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

# The feed entry. sign_update prints: sparkle:edSignature="…" length="…"
signature="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account linklite "$zip")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
item="$(cat <<EOF
    <item>
      <title>LinkLite $version</title>
      <link>https://github.com/matthewrball/linklite/releases/tag/v$version</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/matthewrball/linklite/releases/download/v$version/$(basename "$zip")"
                 type="application/octet-stream"
                 $signature />
    </item>
EOF
)"
marker='<!-- release.sh inserts new <item> elements directly below this line. -->'
ITEM="$item" MARKER="$marker" perl -0pi -e 's/\Q$ENV{MARKER}\E/$ENV{MARKER}\n$ENV{ITEM}/' appcast.xml
echo "Added LinkLite $version to appcast.xml"
