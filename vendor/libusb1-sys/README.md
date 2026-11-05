# Libusb Rust Bindings

The `libusb1-sys` crate provides declarations and linkage for the `libusb` C library. Following the
`*-sys` package conventions, the `libusb1-sys` crate does not define higher-level abstractions over
the native `libusb` library functions.

## LinkLite's pinned copy

Imported from the crates.io `libusb1-sys` **0.7.0** archive, SHA-256
`da050ade7ac4ff1ba5379af847a10a10a8e284181e060105bf8d86960ce9ce0f`.
The bundled native library remains **libusb 1.0.27**, with local safety backports;
this is not an unmodified 1.0.27 or a full 1.0.30 upgrade. `engine/Cargo.toml`
patches the dependency for both direct callers and `rusb`, and enables static vendoring.

`libusb/libusb/descriptor.c` backports
[upstream descriptor fixes](https://github.com/libusb/libusb/commit/bc0886173ea15b8cc9bba2918f58a97a7f185231)
for **CVE-2026-23679** and **CVE-2026-47104**:

- An incomplete interface cannot advertise endpoints when its endpoint array is NULL.
- Both IAD passes require a complete header; lengths are bounded by remaining bytes.
- The older IAD implementation also rejects undersized association records before reading their fields, and uses a non-wrapping array index.

`tests/descriptor-safety.c` exercises the actual native parsers without opening a USB device.
Run `scripts/test-usb-descriptors.sh` from the repository root. The endpoint invariant failed
and ASan caught the one-byte IAD overread before the patch; the corrected parsers pass
ASan/UBSan with both malformed and valid descriptors. Keep these regressions when refreshing
this dependency. Native parser fixes are required in addition to Rust advisory checks.

Binding sources and build backend are otherwise unchanged. Upstream MIT and LGPL licence
texts are retained in `LICENSE` and `libusb/COPYING`.

## Dependencies
In order to use the `libusb1-sys` crate, you must have the `libusb` library installed where it can be
found by `pkg-config`.

All systems supported by `libusb` are also supported by the `libusb1-sys` crate. It's been tested on
Linux, OS X, and Windows.

### Cross-Compiling
To link to a cross-compiled version of the native `libusb` library, it's necessary to set several
environment variables to configure `pkg-config` to work with a cross-compiler's sysroot. [Autotools
Mythbuster](https://autotools.io/) has a good explanation of [supporting
cross-compilation](https://autotools.io/pkgconfig/cross-compiling.html) with `pkg-config`.

However, Rust's [`pkg-config` build helper](https://github.com/alexcrichton/pkg-config-rs) doesn't
support calling a `$CHOST`-prefixed `pkg-config`. It will always call `pkg-config` without a prefix.
To cross-compile `libusb1-sys` with the `pkg-config` build helper, one must define the environment
variables `PKG_CONFIG_DIR`, `PKG_CONFIG_LIBDIR`, and `PKG_CONFIG_SYSROOT_DIR` for the *default*
`pkg-config`. It's also necessary to set `PKG_CONFIG_ALLOW_CROSS` to tell Rust's `pkg-config` helper
that it's okay to proceed with a cross-compile.

To adapt the `pkg-config` wrapper in the Autotools Mythbuster guide so that it works with Rust, one
will end up with a script similar to the following:

```sh
#!/bin/sh

SYSROOT=/build/root

export PKG_CONFIG_DIR=
export PKG_CONFIG_LIBDIR=${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=${SYSROOT}
export PKG_CONFIG_ALLOW_CROSS=1

cargo build
```

## Usage
Add `libusb1-sys` as a dependency in `Cargo.toml`:

```toml
[dependencies]
libusb1-sys = "0.6"
```

Import the `libusb1_sys` crate and use the functions as they're defined in the native `libusb`
library. See the [`libusb` 1.0 API documention](http://libusb.sourceforge.net/api-1.0/) for more
usage information.

```rust
extern crate libusb1_sys as ffi;

fn main() {
  let version = unsafe { ffi::libusb_get_version() };

  println!("libusb v{}.{}.{}.{}", version.major, version.minor, version.micro, version.nano);
}
```

### Native dependencies

`libusb1-sys` exports [metadata] so that dependent crates can find the correct `libusb.h` header
and compile native code that depends on `libusb`. If a crate has a direct dependency on `libusb1-sys`,
its build script has access to the following environment variables:

* `DEP_USB_1.0_INCLUDE` contains the include path with the correct `libusb.h`
* `DEP_USB_1.0_VENDORED` is set with a value of `1` if `libusb1-sys` compiled and linked to
its vendored copy of `libusb`
* `DEP_USB_1.0_STATIC`  is set with a value of `1` if static linkage has been used instead of
dynamic.

[metadata]: https://doc.rust-lang.org/cargo/reference/build-scripts.html#the-links-manifest-key

### Finding Help
Since `libusb1-sys` is no more than a wrapper around the native `libusb` library, the best source for
help is the information already available for `libusb`:

* [Home Page](http://libusb.info/)
* [API Documentation](http://libusb.sourceforge.net/api-1.0/)
* [Source](https://github.com/libusb/libusb)


## License
Distributed under the [MIT License](LICENSE).

### License note.
If you link native `libusb` library statically then you must follow [GNU LGPL](https://github.com/libusb/libusb/blob/master/COPYING) from libusb.
