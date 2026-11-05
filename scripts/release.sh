#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds, signs, and packages LinkLite for release: dist/LinkLite-<version>.dmg (the branded
# drag-to-Applications installer, built by scripts/build-dmg.sh) plus its SHA-256, and adds the
# update to appcast.xml, the feed the app's updater reads. The same disk image serves first installs
# and updates.
#
# Notarization: set LINKLITE_NOTARY_PROFILE to a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# The app is notarized and stapled first, so it stays valid once copied out of the disk image; then
# the disk image itself. Without a profile both are signed but not notarized, and macOS blocks the
# app until the user picks "Open Anyway" in System Settings › Privacy & Security.
#
# Updates: the disk image is signed with the EdDSA key stored in the login keychain under the
# Sparkle account "linklite" (created once with `generate_keys --account linklite`; its public half
# is SUPublicEDKey in Resources/Info.plist).
#
# Run this from Terminal: notarytool and sign_update read their keys from the login keychain of the
# session. Afterwards, publish the disk image as release v<version>, then commit and push
# appcast.xml; installed copies update once the pushed feed lists the new version.
set -euo pipefail

cd "$(dirname "$0")/.."

build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
if grep -Fq "<sparkle:version>$build</sparkle:version>" appcast.xml; then
    echo "appcast.xml already lists $build: bump the version in Resources/Info.plist first." >&2
    exit 1
fi

# Fail before building if the feed cannot receive exactly one new entry.
marker='<!-- release.sh inserts new <item> elements directly below this line. -->'
MARKER="$marker" perl -0ne '
    $count = () = /\Q$ENV{MARKER}\E/g;
    die "appcast.xml must contain exactly one release marker\n" unless $count == 1;
' appcast.xml

# Keep the staged feed on the same filesystem for an atomic final rename, and remove
# notarization uploads on both success and failure.
workdir="$(mktemp -d .release.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT

scripts/build-app.sh

app="dist/LinkLite.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="dist/LinkLite-$version.dmg"
rm -f "$dmg" "$dmg.sha256"

notarize() {
    local result="$workdir/notarization.plist"
    xcrun notarytool submit "$1" --keychain-profile "$LINKLITE_NOTARY_PROFILE" --wait \
        --output-format plist > "$result"
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$result")" != "Accepted" ]]; then
        cat "$result" >&2
        echo "Notarization was not accepted for $1." >&2
        return 1
    fi
}

if [[ -n "${LINKLITE_NOTARY_PROFILE:-}" ]]; then
    upload="$workdir/LinkLite.zip"
    ditto -c -k --keepParent "$app" "$upload"
    notarize "$upload"
    rm -f "$upload"
    xcrun stapler staple "$app"
else
    echo "LINKLITE_NOTARY_PROFILE not set: packaging without notarization."
fi

scripts/build-dmg.sh "$app" "$dmg"
if [[ -n "${LINKLITE_NOTARY_PROFILE:-}" ]]; then
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    echo "Notarized and stapled."
fi

(cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "Packaged $dmg"
cat "$dmg.sha256"

# The feed entry. sign_update prints: sparkle:edSignature="…" length="…"
signature="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account linklite "$dmg")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
item="$(cat <<EOF
    <item>
      <title>LinkLite $version</title>
      <link>https://github.com/matthewrball/linklite/releases/tag/v$version</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/matthewrball/linklite/releases/download/v$version/$(basename "$dmg")"
                 type="application/octet-stream"
                 $signature />
    </item>
EOF
)"
# Do not truncate the live feed if generation fails or the marker changed during the build.
cp -p appcast.xml "$workdir/appcast.xml"
ITEM="$item" MARKER="$marker" perl -0pi -e '
    $count = s/\Q$ENV{MARKER}\E/$ENV{MARKER}\n$ENV{ITEM}/g;
    die "appcast.xml must contain exactly one release marker\n" unless $count == 1;
' "$workdir/appcast.xml"
mv -f "$workdir/appcast.xml" appcast.xml
echo "Added LinkLite $version to appcast.xml"
