#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the Rust engine and the Swift host, then assembles and signs "dist/LinkLite.app".
#
# Signing: uses the first Developer ID Application, then Apple Development, identity in the
# keychain (override with LINKLITE_SIGN_IDENTITY). A stable identity keeps the Screen Recording grant
# across rebuilds. Without one the bundle is signed ad hoc, and macOS treats every rebuild as a new
# app, so the Screen Recording grant has to be given again after each build.
set -euo pipefail

cd "$(dirname "$0")/.."

# Match the app's deployment target so the C parts of the engine (libusb) do not default to the SDK
# version. Prefer rustup's toolchain: its standard library targets macOS 11, while Homebrew's Rust
# ships one built for the host OS, which would make the app refuse to run on older macOS.
cargo=(cargo)
if command -v rustup >/dev/null && rustup run stable cargo --version >/dev/null 2>&1; then
    cargo=(rustup run stable cargo)
    # Cargo otherwise finds rustc on PATH, which may still be Homebrew's macOS-only build.
    export RUSTC="${RUSTC:-$(rustup which --toolchain stable rustc)}"
fi
MACOSX_DEPLOYMENT_TARGET=14.0 "${cargo[@]}" build --locked --release --manifest-path engine/Cargo.toml
swift build --force-resolved-versions -c release --product LinkLite
bin_dir="$(swift build --force-resolved-versions -c release --show-bin-path)"

app="dist/LinkLite.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin_dir/LinkLite" "$app/Contents/MacOS/LinkLite"
printf 'APPL????' > "$app/Contents/PkgInfo"

# Sparkle, the updater. LinkLite is not sandboxed, so Sparkle's XPC services are not needed
# (https://sparkle-project.org/documentation/sandboxing/).
sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto "$bin_dir/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
# LinkLite runs on Apple silicon only: keep Sparkle's arm64 code and drop its build-time headers.
rm -rf "$sparkle/Versions/B/"{Headers,PrivateHeaders,Modules} "$sparkle/"{Headers,PrivateHeaders,Modules}
for binary in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater; do
    lipo "$sparkle/Versions/B/$binary" -thin arm64 -output "$sparkle/Versions/B/$binary"
done
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"

identity="${LINKLITE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identities="$(security find-identity -v -p codesigning)"
    for kind in "Developer ID Application" "Apple Development"; do
        identity="$(printf '%s\n' "$identities" | awk -v kind="$kind" 'index($0, "\"" kind ":") { print $2; exit }')"
        [[ -n "$identity" ]] && break
    done
fi

# Sign inside out: Sparkle's helpers, the framework, then the app.
sign() {
    if [[ -n "$identity" ]]; then
        # Hardened runtime is fine here: the private CGVirtualDisplay classes are ordinary
        # Objective-C classes in CoreGraphics, and the engine is linked statically, so no library
        # validation or JIT exceptions are needed. Notarization requires a secure timestamp.
        codesign --force --options runtime --timestamp --sign "$identity" "$@"
    else
        codesign --force --options runtime --sign - "$@"
    fi
}

if [[ -n "$identity" ]]; then
    echo "Signing with $identity"
else
    echo "No code-signing identity found; signing ad hoc."
    echo "macOS will ask for Screen Recording permission again after every rebuild."
fi
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$app"

codesign --verify --deep --strict --verbose=2 "$app"
echo "Built $app"
