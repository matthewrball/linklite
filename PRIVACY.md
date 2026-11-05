# Privacy Policy

_Last updated: November 3, 2026 · Applies to the LinkLite macOS application._

LinkLite is a free, open-source macOS app. It has no account system, analytics SDK, advertising, crash reporter, or telemetry. Its only network connections are update checks against its GitHub repository. It does not send your settings, display information, usage statistics, or screen contents to its maintainer or to anyone else.

## Network access

Only for updates. LinkLite uses [Sparkle](https://sparkle-project.org) to check for new versions when it starts and once a day after that:

- It downloads the update feed, `https://raw.githubusercontent.com/matthewrball/linklite/main/appcast.xml`, from GitHub.
- When the feed lists a newer version, it downloads that release's disk image from GitHub Releases, checks its EdDSA signature against the key built into the app, and asks before installing it.

These are plain HTTPS requests. Like any web request they reveal your IP address to GitHub, and they identify the app as LinkLite and its version and the Sparkle version in the `User-Agent` header. LinkLite does not send Sparkle's optional system profile (Mac model, macOS version, CPU), and the maintainer receives nothing: GitHub serves the files, under [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).

To turn update checks off, switch off **Automatic updates** in the menu-bar panel; **Check for Updates…** still works on demand.

Many docks also contain an Ethernet adapter. LinkLite sends no traffic through it.

## Screen Recording permission

macOS has no public way for an app to provide a display, so LinkLite creates a virtual display for each monitor on the dock and reads its pixels back with ScreenCaptureKit, which macOS gates behind the Screen Recording permission. DisplayLink Manager works the same way.

LinkLite uses that permission only to capture the virtual displays it created for the dock. It asks macOS for the list of displays only to find its own, and never captures your built-in screen, other monitors, or individual windows. Captured pixels are compressed in memory and sent to the dock over USB. They are never written to disk or sent anywhere else.

## Data kept on your Mac

LinkLite stores its settings in its preferences (`UserDefaults`, domain `com.ball.linklite`):

- `ConfiguredMonitors`: a list of monitor identities, each made of the monitor's vendor ID, product code, and serial number as reported in its EDID (or a hash of the serial text, for monitors that report their serial only as text). LinkLite applies its default "looks like" resolution to a monitor the first time it sees it and records the monitor here, so a resolution you choose later in System Settings is not overwritten.
- Sparkle's update state, under keys starting with `SU`: when it last checked, whether updates download automatically, and a random number Sparkle uses locally to stagger phased rollouts. None of it is sent anywhere.

Downloaded updates are kept in `~/Library/Caches/com.ball.linklite` until they are installed.

Like any connected monitor, the virtual displays carry their monitor's name, vendor, product, and serial number, so macOS can remember their arrangement and resolution in its own display preferences.

If you turn on **Open at Login**, macOS records LinkLite as a login item. You can review it in System Settings › General › Login Items.

## Logs

LinkLite writes diagnostic messages to the macOS unified log under the subsystem `com.ball.linklite`: dock and engine status, monitor model names and resolutions, display IDs, and errors. These logs stay on your Mac, are managed by macOS, and are only shared if you choose to attach them to a bug report. To view them:

```sh
log show --predicate 'subsystem == "com.ball.linklite"' --last 10m
```

## Removing local data

Quit LinkLite and move it to the Trash. To also remove its settings, run:

```sh
defaults delete com.ball.linklite
```

Builds released as "DisplayLink Lite" (0.1.0) used the domain `com.ball.displaylink-lite` instead. To withdraw the Screen Recording permission, remove LinkLite in System Settings › Privacy & Security › Screen & System Audio Recording.

## Changes and contact

Material changes to data handling will be documented here before release. Questions can be opened as an issue on [GitHub](https://github.com/matthewrball/linklite). Sensitive privacy concerns can use GitHub's private vulnerability reporting under the repository's Security tab.
