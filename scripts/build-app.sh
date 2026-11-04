#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the Rust engine and the Swift host, then assembles and signs "dist/DisplayLink Lite.app".
#
# Signing: uses the first Developer ID Application, then Apple Development, identity in the
# keychain (override with DLL_SIGN_IDENTITY). A stable identity keeps the Screen Recording grant
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
fi
MACOSX_DEPLOYMENT_TARGET=14.0 "${cargo[@]}" build --release --manifest-path engine/Cargo.toml
swift build -c release --product DisplayLinkLite
bin_dir="$(swift build -c release --show-bin-path)"

app="dist/DisplayLink Lite.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$bin_dir/DisplayLinkLite" "$app/Contents/MacOS/DisplayLinkLite"
printf 'APPL????' > "$app/Contents/PkgInfo"

identity="${DLL_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identities="$(security find-identity -v -p codesigning)"
    for kind in "Developer ID Application" "Apple Development"; do
        identity="$(printf '%s\n' "$identities" | awk -v kind="$kind" 'index($0, "\"" kind ":") { print $2; exit }')"
        [[ -n "$identity" ]] && break
    done
fi

if [[ -n "$identity" ]]; then
    echo "Signing with $identity"
    # Hardened runtime is fine here: the private CGVirtualDisplay classes are ordinary Objective-C
    # classes in CoreGraphics, and the engine is linked statically, so no library validation or
    # JIT exceptions are needed. Notarization requires a secure timestamp.
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
else
    echo "No code-signing identity found; signing ad hoc."
    echo "macOS will ask for Screen Recording permission again after every rebuild."
    codesign --force --options runtime --sign - "$app"
fi

codesign --verify --strict --verbose=2 "$app"
echo "Built $app"
