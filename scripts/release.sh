#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Official packaging requires an explicit channel, Developer ID Application identity,
# and notarytool keychain profile. Local development builds remain build-app.sh's job.
#
#   LINKLITE_SIGN_IDENTITY=<identity> LINKLITE_NOTARY_PROFILE=<profile> \
#     scripts/release.sh --channel public
#   LINKLITE_SIGN_IDENTITY=<identity> LINKLITE_NOTARY_PROFILE=<profile> \
#     scripts/release.sh --channel candidate --candidate-base-url https://<staging-directory>
#
# Public packaging appends to appcast.xml after all signing/verification succeeds.
# Candidates write only their DMG, checksum and separate appcast.xml under dist/candidates.
# Upload candidate assets and feed to the specified staging directory yourself; neither
# channel publishes anything or changes the app's normal SUFeedURL. A GitHub prerelease
# alone does not isolate Sparkle updates. Source archives use release-sources.py separately.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
    echo "Usage: scripts/release.sh --channel public|candidate [--candidate-base-url https://<staging-directory>]" >&2
}
channel=""
candidate_base_url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)
            [[ $# -ge 2 && -z "$channel" ]] || { usage; exit 1; }
            channel="$2"
            shift 2
            ;;
        --candidate-base-url)
            [[ $# -ge 2 && -z "$candidate_base_url" ]] || { usage; exit 1; }
            candidate_base_url="$2"
            shift 2
            ;;
        *) usage; exit 1 ;;
    esac
done
case "$channel" in
    public)
        [[ -z "$candidate_base_url" ]] || { usage; exit 1; }
        output_dir="dist"
        feed="appcast.xml"
        ;;
    candidate)
        python3 - "$candidate_base_url" <<'PY'
import sys
from urllib.parse import urlsplit
url = urlsplit(sys.argv[1])
if (url.scheme != "https" or not url.hostname or url.username or url.password
        or url.query or url.fragment or any(c.isspace() for c in sys.argv[1])):
    sys.exit("Candidates require --candidate-base-url with an HTTPS staging directory (no query or fragment).")
PY
        candidate_base_url="${candidate_base_url%/}"
        output_dir="dist/candidates"
        feed="$output_dir/appcast.xml"
        ;;
    *) usage; exit 1 ;;
esac
if [[ -z "${LINKLITE_SIGN_IDENTITY:-}" || -z "${LINKLITE_NOTARY_PROFILE:-}" ]]; then
    echo "Official packaging requires explicit LINKLITE_SIGN_IDENTITY and LINKLITE_NOTARY_PROFILE." >&2
    exit 1
fi
export LINKLITE_SIGN_IDENTITY LINKLITE_NOTARY_PROFILE

build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ -z "$version" || "$version" == *[!a-zA-Z0-9.+_-]* ]]; then
    echo "The app version is not a safe release filename." >&2
    exit 1
fi
marker='<!-- release.sh inserts new <item> elements directly below this line. -->'
check_public_feed() {
    python3 - "$build" "$version" "$marker" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET
build, version, marker = sys.argv[1:]
url = "https://github.com/matthewrball/linklite/releases/download/v" + version + "/LinkLite-" + version + ".dmg"
text = pathlib.Path("appcast.xml").read_text()
root = ET.fromstring(text)
if text.count(marker) != 1 or len(root.findall("channel")) != 1:
    sys.exit("appcast.xml must contain one channel and exactly one release marker.")
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for item in root.findall("./channel/item"):
    if (item.findtext(sparkle + "version") == build
            or item.findtext(sparkle + "shortVersionString") == version
            or any(enclosure.get("url") == url for enclosure in item.findall("enclosure"))):
        sys.exit("appcast.xml already lists this build, short version, or artifact URL: "
                 "use new CFBundleVersion and CFBundleShortVersionString values before packaging.")
PY
}
if [[ "$channel" == public ]]; then
    check_public_feed
fi

# Stage outputs on the destination filesystem; publish the feed last. Build,
# signing and notarization failures leave existing feeds and packages untouched.
mkdir -p "$output_dir"
workdir="$(mktemp -d "$output_dir/.release.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

scripts/build-app.sh
app="dist/LinkLite.app"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" != "$build" ||
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" != "$version" ]]; then
    echo "The built app version changed during packaging." >&2
    exit 1
fi
dmg="$workdir/LinkLite-$version.dmg"

# Require the actual assembled signature to chain to Apple's Developer ID CA and
# carry the Developer ID Application leaf extension, not merely a named identity.
developer_id='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
verify_signature() {
    codesign --verify --deep --strict --verbose=2 -R "=$developer_id" "$1"
}
notarize() {
    local result="$workdir/notarization.plist"
    xcrun notarytool submit "$1" --keychain-profile "$LINKLITE_NOTARY_PROFILE" --wait \
        --output-format plist > "$result"
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$result")" != "Accepted" ]]; then
        cat "$result" >&2
        echo "Notarization was not accepted for $1." >&2
        return 1
    fi
    cat "$result"
    rm -f "$result"
}
staple_and_verify() {
    xcrun stapler staple "$1"
    xcrun stapler validate "$1"
    verify_signature "$1"
}

verify_signature "$app"
sparkle_bin=".build/artifacts/sparkle/Sparkle/bin"
# -p only reads the existing public key; it never generates or exports a private key.
public_key="$("$sparkle_bin/generate_keys" --account linklite -p)"
bundled_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
if [[ -z "$public_key" || "$public_key" != "$bundled_key" ]]; then
    echo "The Sparkle signing key does not match SUPublicEDKey in the built app." >&2
    exit 1
fi
upload="$workdir/LinkLite.zip"
ditto -c -k --keepParent "$app" "$upload"
notarize "$upload"
rm -f "$upload"
staple_and_verify "$app"

scripts/build-dmg.sh "$app" "$dmg"
verify_signature "$dmg"
notarize "$dmg"
staple_and_verify "$dmg"
hdiutil verify "$dmg" >/dev/null

(cd "$workdir" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
# sign_update reads the Sparkle EdDSA key from the login keychain, account linklite.
sign_update="$sparkle_bin/sign_update"
signature="$("$sign_update" --account linklite "$dmg")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
if [[ "$channel" == public ]]; then
    check_public_feed
    base_url="https://github.com/matthewrball/linklite/releases/download/v$version"
    release_url="https://github.com/matthewrball/linklite/releases/tag/v$version"
else
    base_url="$candidate_base_url"
    release_url="$candidate_base_url/appcast.xml"
fi
# Parse the signing tool's output as attributes, reject malformed signatures/lengths,
# and escape metadata/URLs before inserting the entry into a staged feed.
SIGNATURE="$signature" python3 - "$channel" "$build" "$version" "$minimum" "$dmg" \
    "$base_url" "$release_url" "$marker" "$workdir/appcast.xml" "$workdir/signature" <<'PY'
import base64
import datetime
import email.utils
import os
import pathlib
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

channel, build, version, minimum, dmg, base_url, release_url, marker, output, sigfile = sys.argv[1:]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
attributes = ET.fromstring('<enclosure xmlns:sparkle="' + sparkle + '" ' + os.environ["SIGNATURE"] + '/>').attrib
signature = attributes.get("{" + sparkle + "}edSignature", "")
if (set(attributes) != {"{" + sparkle + "}edSignature", "length"}
        or len(base64.b64decode(signature, validate=True)) != 64
        or attributes["length"] != str(pathlib.Path(dmg).stat().st_size)):
    sys.exit("sign_update returned an invalid EdDSA signature or artifact length.")
pathlib.Path(sigfile).write_text(signature)
item = ET.Element("item")
for tag, value in (
    ("title", "LinkLite " + version), ("link", release_url),
    ("pubDate", email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))),
    ("{" + sparkle + "}version", build),
    ("{" + sparkle + "}shortVersionString", version),
    ("{" + sparkle + "}minimumSystemVersion", minimum),
):
    ET.SubElement(item, tag).text = value
ET.SubElement(item, "enclosure", {
    "url": base_url + "/" + pathlib.Path(dmg).name,
    "type": "application/octet-stream", **attributes,
})
ET.indent(item, space="  ", level=2)
entry = ET.tostring(item, encoding="unicode")
if channel == "public":
    text = pathlib.Path("appcast.xml").read_text()
    if text.count(marker) != 1:
        sys.exit("The public feed marker changed during packaging.")
else:
    text = ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="' + sparkle + '">\n  <channel>\n'
            '    <title>LinkLite candidates</title>\n    <link>' + escape(release_url) + '</link>\n'
            '    <description>Isolated LinkLite candidate feed.</description>\n'
            '    <language>en</language>\n    ' + marker + '\n  </channel>\n</rss>\n')
text = text.replace(marker, marker + "\n    " + entry)
ET.fromstring(text)
pathlib.Path(output).write_text(text)
PY
"$sign_update" --account linklite --verify "$dmg" "$(cat "$workdir/signature")"

mv -f "$dmg" "$output_dir/$(basename "$dmg")"
mv -f "$dmg.sha256" "$output_dir/$(basename "$dmg").sha256"
mv -f "$workdir/appcast.xml" "$feed"
echo "Notarized, stapled and verified $output_dir/$(basename "$dmg")"
cat "$output_dir/$(basename "$dmg").sha256"
echo "Added LinkLite $version to $feed ($channel; not published)"
