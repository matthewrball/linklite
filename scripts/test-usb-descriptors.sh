#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs native parser regressions with ASan/UBSan; no USB device is opened.
set -euo pipefail
cd "$(dirname "$0")/.."
workdir="$(mktemp -d -t linklite-usb-tests)"
trap 'rm -rf "$workdir"' EXIT
: > "$workdir/config.h"
clang -std=c11 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DPLATFORM_POSIX=1 -DHAVE_SYS_TIME_H=1 -DHAVE_NFDS_T=1 -DDEFAULT_VISIBILITY= \
    -I "$workdir" -I vendor/libusb1-sys/libusb/libusb \
    vendor/libusb1-sys/tests/descriptor-safety.c -o "$workdir/descriptor-safety"
"$workdir/descriptor-safety" "$@"
