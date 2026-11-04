# Security Policy

## Reporting a vulnerability

Please report security issues **privately** rather than opening a public issue.

Use GitHub's private vulnerability reporting on this repository: go to the **Security** tab › **Report a vulnerability**. That opens a private advisory visible only to the maintainers.

Please include enough detail to reproduce: LinkLite version, macOS version, Mac model, dock model, and steps. We'll acknowledge your report and keep you updated on a fix.

## Scope

LinkLite is a local menu-bar app. It talks only to the USB dock it drives: it has no backend, makes no network connections, and collects no data. See [PRIVACY.md](PRIVACY.md).

Areas of particular interest:

- **Screen capture.** LinkLite holds the Screen Recording permission and uses ScreenCaptureKit to read the virtual displays it creates for the dock's monitors. Any path that captures another display or window, or sends captured pixels anywhere other than the dock, is in scope.
- **Private display API.** Virtual displays are created with CoreGraphics' private `CGVirtualDisplay` classes, declared locally in `Sources/CDLLite/`. Misuse that could leave macOS with stray displays or an unusable display arrangement is in scope.
- **USB and protocol handling.** The engine (`engine/`) and the vendored Vino core (`vendor/vino/`) parse data from the dock, including monitor EDIDs, and run the HDCP 2.2 authentication and encrypted control session. Memory-safety or parsing bugs reachable from a malicious or malfunctioning USB device are in scope.
- **Release integrity.** Release archives on GitHub are signed with the maintainer's Developer ID, notarized by Apple, and published with a SHA-256 checksum. Report anything that lets a modified build pass as an official one.

Out of scope: the dock's own firmware, and the DisplayLink protocol design itself. Issues in upstream Vino that are not specific to LinkLite are best reported to [Vino](https://github.com/cameron1729/Vino) as well.

## Supported versions

Only the latest public release is supported for security fixes.
