# Monitor rotation (beta)

Each dock monitor can be set to 0°, 90°, 180° or 270° from its card in the menu-bar panel. The angle is how far the monitor itself is turned clockwise. The setting is stored per monitor and applies at once.

**Status: beta, not hardware-verified.** The rules, the frame checks, the cursor routing and the app integration are built and tested without a dock. Nothing here has run against a physical DisplayLink monitor. Treat the feature as unverified until the checklist at the end passes on hardware, and say so in any release notes.

## What was verified, and how

| Check | Result | Command |
|---|---|---|
| Pure rotation rules, frame rotation, frame checks, cursor routing, duplicate identities, migration, and the head controller's lifecycle (`LinkLiteRotationTests`), including the composed runtime tests (`HeadRuntimeCompositeTests`, `HeadRuntimeTests`) that run the real controller, HeadRuntime, StreamLifecycle and identity allocator, and `DisplayLedgerTests` | Part of the whole-package count below | `swift test` and `swift test -c release -Xswiftc -enable-testing` |
| Identity (`LinkLiteCoreTests`) | Pass, unchanged by this change | same |
| Whole package (adds the 5 DLProbe tests) | 282 tests pass in debug and release, no warnings (227 before the rotation change; 32 added then: the ported `DisplayLedger` and early-frame and permission controller tests, the mode and permission composite tests, and one stream-restart overlap test; 23 added by the review fixes: a late mode answer during a stalled stop, rebuilding heads listed and their stops reported, grant epochs for running streams, refused creations retried with backoff, and launch and activation permission checks in `RaceRegressionTests`, `HeadControllerTests` and `ScreenRecordingAccessTests`) | same |
| Fault injection on a scratch copy (one fault at a time): twin port records not written, no first-frame deadline, no mode gate, no mode retry, no cursor publish, a late start not stopped, a usable frame not cancelling its deadline | Each fault fails 3–20 tests | Applied to a scratch copy only |
| Mutation check on the pure rules (scratch copy, not the repo) | Seven deliberate faults each fail 4–8 tests: cursor hide sent always, lone change clearing every port record, missing pixel-format check, orientation ignoring a missing display, unusable-frame run never reset, gate reopening after close, first-target forgetting disabled | Applied to a scratch copy |
| App compile and link against the real Sparkle 2.10.1 framework, debug and release | Compiles and links, no warnings | See "Building for the tests" |
| Engine (not changed by this work) | Not re-run: no `cargo` on the verification machine. Last recorded: crate 22/22, `vino-chimera` 35/35, `vino-driver` 8/8 | `cargo test --locked --manifest-path engine/Cargo.toml` |
| USB descriptor regressions | Pass (ASan/UBSan, native) | `scripts/test-usb-descriptors.sh` |
| Dock, monitor, ScreenCaptureKit with a real display, cursor, sleep/wake, reconnect, the menu's "Live" state | **Not run.** No dock, no display changes, no Screen Recording permission, no app launch | — |

The rotated frame copy was measured earlier, not in this work, at 4.9 ms per 3840×2160 frame at 90° and 2.0 ms at 180°, single-threaded, release build, on the arm64 Air used for this work. That figure is for the copy alone.

Parts of the app that need the OS or hardware are compiled but not exercised: `DisplayHost`, `VirtualDisplay`, `DisplayCapture`'s ScreenCaptureKit path, `CursorTracker`'s event monitors, and the panel. The pure helpers those parts call are tested.

## Performance

**There is no frame-rate promise for a rotated monitor.** A rotated head sends every captured frame whole, and the frame is copied and rotated on each one, because ScreenCaptureKit's damage rectangles are not yet mapped to the rotated raster. So:

- The copy costs about 2–5 ms of CPU per 4K frame on the test Mac (see above), more under motion. It runs on top of the engine's own per-frame work.
- Nothing has been measured against the 100 MB/s video budget, end to end, on a dock. Full-frame updates during motion (window drags, scrolling, Exposé) may reach a lower frame rate on a rotated monitor than on an unrotated one. The actual rate is unknown.
- The pointer on a rotated head is part of the video, so pointer movement there sends video, not a few bytes of control traffic. Its latency and smoothness are unmeasured.

Measure on hardware before describing any rotated monitor's speed to users.

## How it works

- **Geometry** (`Sources/LinkLiteRotation/RotationGeometry.swift`). The physical raster is the dock's programmed mode. The logical raster is what the viewer sees upright, and it is what macOS draws into and ScreenCaptureKit captures. For a portrait head the logical size is the physical size with width and height exchanged.
- **Virtual display** (`VirtualDisplay.swift`). A portrait head gets a portrait CGVirtualDisplay: its mode list, `maxPixels*` and millimetres are exchanged. Standard heads take exactly the old code path.
- **Default mode.** The default HiDPI mode is looked up at the logical size. Portrait has its own `ConfiguredMonitors` entry (`<identity>-portrait`), so a landscape entry does not suppress it.
- **Capture** (`DisplayCapture.swift`). A rotated head captures the logical size and each complete frame is rotated into a persistent physical buffer. An unrotated head keeps ScreenCaptureKit damage exactly as before.
  - Every complete frame is checked before any byte is read: pixel format must be BGRA, the size must be the configured size, and the stride and byte span must be representable without overflow. A frame that fails any check is dropped and counted.
  - Idle and incomplete frames are normal and are not counted.
  - Frames are read only while the stream is open: from just before it starts until stop or failure (`CaptureGate`). A stopped stream never reopens.
  - After 30 unusable complete frames in a row (`FrameHealth`), the stream is stopped once, the card shows the reason, and capture is retried with the usual backoff.
- **Live state.** The card says "Starting" until the capture has delivered its first usable frame, then "Live". Nothing is shown as live before a picture has arrived. A stream that never delivers one within 10 s is stopped and retried, and the card gives the reason.
- **Pointer.** A rotated head has no dock hardware cursor. Its pointer is drawn into its frames by ScreenCaptureKit, and it is excluded from the dock cursor targets. This avoids the engine's edge handling, which clamps a negative cursor origin instead of cropping it, and it has no rotated cursor image or hotspot.
- **Dock cursor routing** (`DockCursorRouter.swift`, used by `CursorTracker`). The dock keeps the last position it was given, so the router tracks what the dock is believed to show and sends only changes.
  - Removing the last dock-cursor head hides the dock cursor before the tracker stops, so the cursor does not stay on a rotated head.
  - Removing one of several dock heads does not hide the cursor while the pointer is on a head that remains.
  - A failed send leaves the state unknown, and the next report sends again.
- **Head controller** (`HeadController.swift`, pure, in `LinkLiteRotation`). It owns every per-head decision. `apply(_:)` takes one event and returns commands. `HeadDriver` runs the commands against `HeadEffects`. `DisplayHost` is the production effects: it creates displays, starts and stops streams, sets modes, schedules timers and writes defaults. Tests use fake effects and a fake clock, so the real transitions run without sleeps.
  - Change within a shape (0°↔180°, 90°↔270°): stop the capture, and start again once the display's first mode attempt has resolved. The virtual display stays.
  - Change between landscape and portrait: the old display is released after its capture stops. Only then is a new one created, and the cursor target follows the new display as soon as it exists. Windows on that display may move.
  - Choosing an orientation for a head with no display (its creation failed earlier) creates the display again, even if the choice is the one already shown. A failed head is retried by choosing an orientation. A refused creation also retries by itself, after 1, 2, 4, 8, 16 and then every 30 s, and at once on wake; the refusal stays shown until a display exists. Screen Recording does not hold these retries back.
  - A new display's default mode is attempted before its first capture starts, and a failed attempt does not block that capture. Later attempts retry on a backoff (1, 2, 4, 8, 16 s). After six failures the mode is reported as unavailable on the card, and retries stop. A reconnect starts a fresh set of attempts. Retries never stop a running capture.
  - A capture that has not delivered a usable frame within 10 s of starting is stopped and retried. Only a usable frame resets the retry backoff (1, 2, 4, 8, 16, then 30 s). Idle and unusable frames are not reported and cannot move the deadline.
  - Reconnect within the 20 s grace period: the old display is reused only if its shape matches. A portrait display is never handed to a landscape head, or the reverse.
  - Results from an earlier attempt, display or timer are ignored. A late successful start is stopped, never installed.
  - Sleep, wake and screen-lock restarts use the head's stored orientation.
  - Detaching a head cancels its pending rebuild, retry and deadline.

## Storage and identity

Settings are stored in user defaults under `MonitorOrientations`. The format is the single-monitor format: a key is either a monitor's identity (vendor, product, serial) or identity plus head (`…-headN`). Installs that never rotated a monitor have no such key and read every monitor as 0°. Returning every monitor to 0° removes the key, unless a twin pair has recorded zeros (see below). No migration is needed: the rules below read the same records as before. One exception: the first time two identical panels both have a display, each is recorded (zero for standard), so the key can appear for a pair that was never rotated. This is the only new write that does not follow a user's choice.

Two kinds of record:

- The **identity record** is the setting of a panel that is alone with its identity.
- A **port record** (`…-headN`) is the setting of a panel on head N while an identical panel, or a panel with serial 0, was attached.

**Reads.** A monitor reads its port record first, then its identity record. A panel with serial 0 never reads an identity record, so two identical serial-0 panels cannot share a setting.

**Writes.**
- A change made while the panel is alone writes the identity record and removes only that head's port record, which would otherwise shadow the new setting. Other heads' port records are kept: they belong to identical panels that may be plugged back in.
- A change made with an identical panel attached (or for serial 0) writes only that head's port record.
- When a twin first has a display alongside its identical panel, every such twin's current rotation is written to its port record. A twin that was standard is written as an explicit 0, so an identity record set later while it is absent cannot reach it. Nothing is written for a failed display creation, or for serial 0.

So an absent identical panel keeps its rotation on its port. A returning twin gets its own port's rotation back, not the value chosen while it was away, or the value the other panel was later given.

**Identity dependency.** EDID has no unique ID. Two identical panels can report the same nonzero serial, and some report serial 0. The rules treat a monitor as "alone" only when its serial is nonzero and no other attached monitor has the same identity.

Unavoidable limits, which no software can remove:

- **A lone panel moved onto a port that holds an identical twin's record reads that record.** The panel cannot be told apart from the twin that left the record. A change made there replaces that record. The identity setting it chose elsewhere is untouched.
- **Identical panels that swap ports swap their rotations.** The rotation stays with the port. The panel's note says so.
- **A twin whose display could not be created is not recorded.** Nothing is written for a failed creation. If that panel is unplugged before a display is made, and its twin's setting then changes while it is alone, it reads the new setting when it returns. This is the one case where a twin's rotation is not kept, and it needs a failed display and then an unplug.
- **Serial-0 panels keep their rotation per port.** Moving one to another port changes its rotation.

The card shows a note for each of these cases (`PanelView.swift`, `MonitorCard`). A monitor that is alone with a nonzero serial shows no note.

Tests: `Tests/LinkLiteRotationTests/DisplayLedgerTests.swift` covers `DisplayLedger` with real tasks and cancellation: a release waits for a default-mode call stuck in a system call, drops the display, and only then acknowledges; a cancelled setup never sets the mode or reports; and the controller routed through the ledger. `Tests/LinkLiteRotationTests/MonitorSettingsTests.swift` covers twins unplugged and reconnected in both orders, a change made while the other twin is absent (its port record is kept), start order, serial 0, a different unit of the same model, the parked-record case, the explicit standard of a twin, the first sighting of a twin with a legacy identity record in either order, a failed display creation that records nothing, and materialization that touches no other identity. `Tests/LinkLiteRotationTests/HeadControllerTests.swift` runs the real controller through `HeadDriver` with fake effects and a fake clock. It covers the twin scenario end to end (with the reconnect grace running out and not), cursor targets through a portrait-to-standard rebuild (including a cancelled rebuild and a reattach during the release), the first-usable-frame deadline (idle and bad frames, stale results, a failed start, a detach, the retry backoff, and permission), and the default mode (a failed attempt that does not stop capture, permanent unavailability, detach and reattach, a late result for a released display, and no second setter in flight).

## Capture lifecycle (merged with StreamLifecycle)

The controller in `Sources/LinkLiteRotation/HeadController.swift` decides what a head should do. `HeadRuntime` (`Sources/LinkLiteRotation/HeadRuntime.swift`) performs those decisions, and it is the only owner of a head's capture lifetime. Every start, cancel and stop goes through the head's `StreamLifecycle` from `LinkLiteCore`, keyed by head. `DisplayHost` supplies only the platform operations (display creation with an identity claim, `DisplayCapture`, mode setup, cursor targets, defaults).

- **One owner.** A controller `CaptureAttempt` maps to one lifecycle attempt. `.stopCapture` cancels that attempt, and cancelling is idempotent. The stop is queued behind every earlier operation on the head, so a stop is never raced by a second stop, and no two streams run on one head.
- **Frame gate.** The runtime creates a `FrameGate` for each attempt, before its stream starts. `.stopCapture` and `.releaseDisplay` close it immediately, even while the start is still running or the stop is stalled. A stream submits a frame only inside `whileOpen`, so no frame reaches the engine after the close returns.
- **Start.** `.startCapture` is answered by `.captureStarted` only once the lifecycle keeps the stream. A cancelled start sends nothing and its stream is stopped. `.captureStartFailed` carries a stop that could not be confirmed.
- **Usable frame.** `.captureUsableFrame` may arrive before `.captureStarted`. It is kept for that start, so the first frame is never lost, and no first-frame deadline is armed for it.
- **Stop failure.** A stop that throws is not a stop. The stream stays on its head, is retried with backoff, and nothing else starts on the head until it is confirmed. The panel shows "Previous capture did not confirm it stopped; retrying".
- **Display release.** `.releaseDisplay` cancels the display's default-mode operation at once, when the release is requested, and nothing new starts on the display from then on. The display is dropped only after the head's streams are confirmed stopped and the cancelled operation has returned (`DisplayLedger`). The display's identity lease is attached to the display, so the identity is free only after that. `.displayReleased` is then sent. A result from a cancelled mode operation is never reported or recorded. A call that is already inside the system cannot be undone, so its effect on the retired display is possible, but the controller never accepts its answer.
- **Permission.** Nothing starts while Screen Recording is denied: not on attach, rotation, retry or resume. A grant restarts the waiting heads, and a confirmed grant is counted even when no denial is known yet, so a denial still in flight from a stream started before it is stale. Each capture keeps the grant count it was issued under from its start until it stops, so a denial from a stream issued before the latest grant does not block or show as a problem, whether that stream was still starting or already running. A failure that is not a permission failure never changes the permission state.
- **Launch and activation.** `ScreenRecordingAccess` (`Sources/LinkLiteRotation/ScreenRecordingAccess.swift`) is the only place that asks. At launch, a missing grant is reported denied, the one explicit request is made, and access is checked again; a grant is reported only if that check confirms it. Each time the app becomes active (the user returns from System Settings) and when the panel opens, access is checked again without prompting, whether or not a denial is known. Every check that confirms access reports a grant, and the controller counts each one; a check that does not confirm access reports nothing, and never stops a running capture. A request that is answered later is confirmed by the next check, never claimed early.
- **Rebuilding heads.** A head whose display is being replaced stays listed, as waiting, with its latest rotation selected. A rotation chosen meanwhile is applied to the replacement. A stop that fails is shown on its head as unconfirmed until a retry confirms it.
- **Identity.** A display is created by claiming an identity from `DisplayIdentityAllocator`. If the identity is still held, the head waits (`.displayCreationWaiting`), retries on its backoff timer, and is woken by `.identityMayBeFree` when an identity is released. The default-mode record is keyed by the identity the display actually has.
- **Rotation during a rebuild.** A rotation that arrives while the old display is still being released is stored, and the replacement is made with the last choice.
- **Default mode.** A failed mode attempt is retried on its own timer and never stops or restarts a running capture. A detach cancels a pending retry.
- **Cursor.** Cursor targets are published whenever the set changes. A head that turns off the dock cursor is withdrawn, which hides the dock cursor, and it returns when the head is upright again.

The composed behaviour is tested in `Tests/LinkLiteRotationTests/HeadRuntimeTests.swift` and `HeadRuntimeCompositeTests.swift`, which run the real controller, `HeadRuntime`, `StreamLifecycle` and identity allocator against fake platform hooks, with every race decided by a test-owned gate. They cover a release that waits for a stuck default-mode call and a stalled stop, a late mode answer that sets nothing, rapid rotations that never overlap two setups, a usable frame before the start returns, nothing starting while denied, a revoked stream restarting once on a grant, and a stale denial after a regrant.

## Hardware beta limitations

These are limits of the current implementation, not only of the hardware:

1. **Unverified on hardware.** Every path that needs a dock, a virtual display or Screen Recording is untested: display creation, mode restore, capture of the portrait display, pointer position, sleep and wake, reconnect, and the "Live" state.
2. **macOS display identity.** The portrait virtual display uses the same vendor, product and serial as the landscape one. macOS may restore an old display arrangement or mode for that identity. This is untested. Changing the serial for portrait would be the fallback, with its own trade-offs.
3. **Windows move on a landscape↔portrait change.** The display is rebuilt, so windows on it may be rearranged.
4. **No dock pointer on a rotated head.** See Performance above.
5. **Full frames on rotated heads.** Every frame is copied and sent whole. See Performance above. Not measured on a dock.
6. **No dock cursor edge handling for rotated heads.** Not needed while the pointer is in frames, but a future switch back to the dock cursor needs the crop-not-clamp fix in `engine/src/host.rs` (`sync_cursor`) first.
7. **Identical panels.** A setting follows the port, not the panel (see above). Two identical panels with the same serial can be mixed up by macOS itself.
8. **macOS rotation control.** It is not known whether macOS offers its own rotation control for a CGVirtualDisplay. If it does, it may conflict with this feature. It was not checked, because it would require changing display settings.
9. **Screen Recording.** Capture still needs Screen Recording permission, as before.
10. **A start that never returns holds its head.** A stream start that neither succeeds nor fails blocks the head's later starts, and its display is not released, because the release waits for that start to finish. There is no start timeout. The panel shows no separate message for it.
11. **The first-usable-frame deadline (10 s) and the mode backoff (1–16 s, six attempts) are estimates.** They have not been measured on a dock. A mode retry that succeeds while the stream is running may change how macOS scales the display. That has not been observed.

## Release notes (beta draft, not published)

Draft for the beta. Edit before any release. Nothing here is a release decision.

> **Monitor rotation (beta).** Turn each dock monitor to 0°, 90°, 180° or 270° from its card in the menu-bar panel.
>
> This is a beta. Rotation is tested in software only. It has not yet been run on a DisplayLink dock, so please report anything that looks wrong and say which monitor, cable and macOS version you used.
>
> - **Speed.** A rotated monitor sends every frame whole and rotates each one. No frame rate is promised for a rotated monitor, and its speed during motion has not been measured on hardware. Unrotated monitors are unchanged.
> - **Windows may move** when a monitor switches between landscape and portrait, because its display is rebuilt.
> - **Pointer.** On a rotated monitor the pointer is drawn into the picture, not by the dock.
> - **Identical monitors** keep their rotation per port, so if two identical monitors swap ports their rotations swap too.
> - **Status.** A rotated monitor shows "Starting" until its first picture arrives, then "Live". A monitor that stops delivering pictures shows the reason and is retried.

## Hardware checklist (owner, on a spare dock)

For each orientation (90°, 180°, 270°) on each head:

- A corner marker appears in the right corner, and the picture is upright on the monitor.
- The pointer's tip is at the clicked pixel at all four edges and corners, and is visible throughout.
- Text selection and window dragging update the picture with no stale regions.
- Measure and record the frame rate and CPU use during a window drag and a scroll, rotated and unrotated.
- 0°↔180° and 90°↔270° switches keep the display and its window layout.
- Landscape↔portrait switches rebuild the display; windows return sensibly.
- Choosing an orientation after a failed display creation creates the display.
- Unplug and replug within 20 s reuses or rebuilds the display correctly, for both attachment orders.
- Two identical panels: each keeps its rotation through unplug and replug, a change made with one alone leaves the other's rotation on its port, and the note appears.
- Sleep and wake, and screen lock and unlock, resume capture in the stored orientation.
- Two monitors with different rotations, with the pointer crossing between them.
- The card shows "Starting" before the first picture and "Live" after it.
- Unrotated monitors are byte-identical to the previous release.

Record the exact app build, macOS version, monitor model, cable, and the outcome of each step, following the logging rules in `docs/DEVELOPMENT.md`.

## Building for the tests

The package resolves Sparkle from GitHub. Where that download is not possible, the Sparkle zip can be used as a local binary target in a scratch copy of the package. The manifest is the only change: `.package(url: …, exact: "2.10.1")` becomes a path to a wrapper package whose target is the extracted `Sparkle.xcframework`. Verify the zip's SHA-256 first (`4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a` for Sparkle 2.10.1). Never commit that change.

Otherwise:

```sh
swift test                                       # debug
swift test -c release -Xswiftc -enable-testing   # release
```

With Command Line Tools only (no Xcode), Swift Testing needs explicit search paths:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F \
  -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

### Building without Sparkle

A typecheck-only stand-in for Sparkle 2.10.1 can replace the download in a scratch copy of the package, for example to typecheck the app where GitHub is unreachable. The stand-in declares only the API that `UpdateManager.swift` uses. Nothing built this way is shipped, and it does not establish that the real framework behaves the same. With the stand-in and the Command Line Tools' Swift 6.3 compiler, the unmodified `UpdateManager.swift` reported data-race errors at its install-handler call. The scratch copy wrapped that handler in `nonisolated(unsafe)` to get past it. The real framework built without that change in this work. Never commit either change.
