# Release and recovery runbook

This is an operator procedure, not permission to publish or a claim of 1.0 readiness. Signing credentials and publication remain owner-controlled. Hardware qualification is tracked in [DEVELOPMENT.md](DEVELOPMENT.md#pre-10-qualification-matrix); build, test and corresponding-source instructions are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Current evidence

v0.3.15 is the latest public release and the default appcast is live. Its source commit is `3376cac6fb29d7231fe4beac956e5a3df7309213`; it cuts CPU during full-screen motion (about 41 → 14–15 ms CPU per 4K frame in an offline scrolling benchmark) with byte-identical wire output, verified by an old-vs-new encoder differential over 52,200 strips (vendored patches 14 and 15). It was published without running on a dock. Earlier 0.3.x releases: v0.3.14 (`cd3cc96a7a3572849a8db16ed69e41d30487eab7`, gamma tables applied to the dock picture and pointer), v0.3.13 (`67fbd175c65e189a99e109a161451c65122683a6`, scattered full-screen change sent once as a coarse delta, fair head rotation, opt-in performance logging), v0.3.12 (`f4c40b8bacfca4bfdad86ee52349f390db517b7d`, capture restarts after display sleep and screen lock), v0.3.11 (`5bbdadddbbb09b4b03d6b2a534da502361181dc9`, calmer panel motion, pointer polling paused during display sleep), v0.3.10 (`c8d861d480cf9bc70bfbfc6271345540baefc5bc`, dock pointer and crosshair during screenshot selection), v0.3.9 (`e52a3822b40b9b14bb81549da04f884ca903669d`, header no longer drops on expand), v0.3.8 (`c390e17edb460662ffa798c78231b60855f29810`, smoother settings disclosure) and v0.3.7 (`e5b9023b8b9b46eafd6c7c91c01807eaf3614f9a`). Do not replace any released assets or reuse a released version for new bytes.

v0.3.8 through v0.3.15 were each published through a PR with the required "Build and test" CI, Developer ID signing, accepted notarization, stapling, Gatekeeper acceptance, a byte-identical re-download, Ed25519 verification, and then a separate feed PR. On the owner's M/Connect 2 with two 4K monitors: the 0.3.12 fix was verified with `pmset displaysleepnow` (both capture streams stopped with SCStreamError -3815 at display sleep; capture resumed 120 ms after wake), and the 0.3.13 change was measured with the engine's performance counters during App Exposé and desktop swipes (busy-second medians: head 0 17 → 44 presents/s, head 1 22 → 29, total 66.5 → 47.6 MB/s, no dock reset) and judged smoother with no leftover patches by the owner. Updater-driven installs were observed for 0.3.10 and 0.3.11; the update flow itself was not watched.

### v0.3.7 evidence (historical)

Recorded release checks: 54 Rust/Swift tests, native ASan/UBSan checks, independent source/security and release-contract reviews, [GitHub CI](https://github.com/matthewrball/linklite/actions/runs/41985290639), Developer ID signing, accepted notarization, stapling, Gatekeeper assessment, and Ed25519 verification against the public key in the shipped app. The source archive was deterministic across system Python 3.9.6 and current Python; Rust rebuilt offline with an empty CARGO_HOME, and Swift rebuilt with the pinned cached Sparkle binary. These are packaging/source receipts, not live-dock qualification.

On 2026-11-05, the normal updater offered v0.3.7 to the installed v0.3.6 on macOS 26.6 (`25G72`), downloaded it, installed it and relaunched successfully. The installed version and unchanged designated signing requirement were verified; Gatekeeper accepted it as Notarized Developer ID. Open at login remained off, automatic updates remained on, and the app returned to its permission-ready dock-search state without resetting privacy settings. The live icon footer, settings expansion/collapse and update ribbon were exercised. This was an existing-profile, no-dock upgrade, not a fresh-consent or active-display test.

The post-release packaging safeguards passed ten local release-contract regressions, including Apple's real requirement parser, and a real candidate build. Apple accepted app notarization `16b2821c-4652-42f7-9d75-5047cc0b906b` and DMG notarization `4b60cf2e-9e91-473f-8e4b-90578861805e`; stapling, Developer ID requirements and Ed25519 verification passed. The public feed and all four published v0.3.7 assets remained byte-identical after both a failed and successful candidate attempt. The candidate validation files were local only; no candidate feed or extra release was published.

Pending: candidate-to-newer-version updates with a live dock, fresh-profile consent/login, the remaining supported-OS GUI/hardware matrix (including macOS 14), eight-hour memory and physical lifecycle tests, owner signing-key backup/recovery verification, settings disclosure with the system Reduce Motion setting on, and the hidden-pointer limitation (see [Hardware cursor](DEVELOPMENT.md#hardware-cursor)). Repository protection is an external control: inspect GitHub's effective policy before each publication rather than inferring it from a green CI run.

## Prepare a release

1. Choose a new version/build number for new bytes. Review the [qualification gates](DEVELOPMENT.md#stable-10-decision), known risks and precise compatibility scope; beta publication is not gate closure.
2. Submit source changes through review. Verify that GitHub requires pull requests and an up-to-date, successful GitHub Actions `Build and test` check for `main`, enforces protection for administrators, and blocks force pushes and deletion. With one maintainer, the required additional approval count is zero; independent review remains part of this procedure. Check the effective repository policy and record any bypass rather than assuming this document configures GitHub.
3. Run the [contributor checks](../CONTRIBUTING.md#running-the-tests) and release-contract regression `python3 scripts/test-release.py` on the final source. Retain CI URL, commit SHA and native check receipts. Run hardware/GUI gates separately; hardware-free CI cannot close them.
4. Commit the exact release source and generate the [corresponding source archive](../CONTRIBUTING.md#release-source-archives) from its full SHA. Inspect provenance, license notices and pinned dependencies. Rebuild from the extracted archive with an empty Cargo cache and offline Rust dependencies; distinguish the pinned cached Swift/Sparkle binary prerequisite from a fully offline Swift toolchain.
5. Confirm the owner has the intended Developer ID identity, notarization keychain profile and Sparkle signing key available. Never paste private keys into chat, logs, CI output or release notes.

## Explicit release channels

There is no implicit release channel. Both commands require an explicit Developer ID Application signing identity and notarization profile, and must verify Developer ID signing and accepted notarization. Development/ad-hoc signing is not a release fallback.

```sh
export LINKLITE_SIGN_IDENTITY='<Developer ID fingerprint>'
export LINKLITE_NOTARY_PROFILE='<keychain profile>'

# Stage and qualify a candidate first; replace with the real staging directory URL.
scripts/release.sh --channel candidate \
  --candidate-base-url https://example.invalid/linklite/candidates/BUILD

# Public publication preparation, only after approval:
scripts/release.sh --channel public
```

The example identity/profile/URL are placeholders to replace, not usable credentials or a deployed service. Do not run both commands blindly as a single qualification step. Candidate output is `dist/candidates/LinkLite-<version>.dmg`, its matching `.sha256`, and `dist/candidates/appcast.xml`; it must not modify root `appcast.xml` or overwrite public DMG/checksum outputs. Public mode uses the public outputs and appends the signed entry to root `appcast.xml`. It rejects reuse of an existing build number, short version or DMG enclosure URL; bump both version fields in `Resources/Info.plist` for a new public release. A collision is a stop condition, not a reason to remove the existing entry.

### Candidate staging

Upload the candidate DMG and matching checksum to the exact directory supplied in `--candidate-base-url`; place its corresponding-source archive there as well. Generate that archive under `dist/candidates/` using the contributor instructions, so candidate preparation does not overwrite public source artifacts. Only after verifying the hosted assets should the separate candidate `appcast.xml` be staged. This staging destination is chosen by the owner; no new update service is required.

A GitHub prerelease alone does **not** isolate Sparkle updates. Isolation comes from the separate feed and enclosure URLs: never merge the candidate entry into root `appcast.xml`. Candidate mode leaves the app's `SUFeedURL` unchanged and adds no channel preference. Normal installations see entries explicitly published to the public feed, including current prereleases.

Use a disposable, owner-approved test installation/account and an explicitly candidate-configured test harness or build to exercise the candidate feed; do not redirect the user's normal installation or claim candidate mode does this automatically. Record how the test feed was selected. Test an older signed candidate updating to a strictly newer signed candidate and record offer, download, user-approved restart, installed build and dock recovery. If the isolated updater setup is unavailable, leave that exercise pending. Never downgrade a version or weaken signature checks to force an offer.

## Validate before publishing the feed

For the exact staged bytes:

- Check the DMG SHA-256 against its published checksum, then independently compute and retain the source archive SHA-256. Fetch the hosted assets again and compare hashes, not only local filenames.
- Mount the DMG read-only and inspect the actual contained application: `codesign --verify --deep --strict --verbose=2 /path/to/LinkLite.app`, `codesign -dv --verbose=4 /path/to/LinkLite.app`, and `spctl --assess --type execute --verbose=4 /path/to/LinkLite.app`. Confirm the expected Developer ID/team, bundle version and minimum OS. Validate stapling with `xcrun stapler validate /path/to/LinkLite.app` and `xcrun stapler validate /path/to/LinkLite-<version>.dmg`; retain the accepted notary submission receipt. Gatekeeper verification must not be replaced by clearing quarantine or disabling assessment.
- Verify the appcast enclosure's Ed25519 signature over the exact downloaded DMG using the pinned Sparkle tools and the public key embedded in that app. Verify enclosure length, version/build, HTTPS asset URL, minimum OS and release notes. A SHA-256 file alone does not authenticate a release.
- Inspect the downloaded source archive's `SOURCE-RELEASE.txt`, matching commit, dependencies and licenses; retain reproduction commands/results. The DMG, checksum, source and feed must all identify the same release.

**Publish assets before the feed.** Stage the DMG, checksum and corresponding source on the release host, validate their final download URLs and bytes, and only then publish/merge the public appcast change through the required review/CI path. The appcast is the switch that exposes an update to existing users. Keep an evidence record with source SHA, feed commit, release URL, hashes, signing/notary receipts and updater result. Do not republish a released version to test this procedure.

### Post-publication verification

After the public feed change is merged, confirm the intended entry is reachable through the default feed and the actual updater offers and installs it on the approved test installation. Record this separately from cryptographic verification; until exercised it remains pending. This default-feed check cannot run before the new entry is published. Qualify the isolated candidate updater before promotion instead.

## Download statistics

`python3 scripts/download-stats.py` prints each release's download counts (the DMG or zip, and the source archive) and, with the owner's `gh` login, the last 14 days of repository views and clones. Counts are GitHub's all-time totals per release asset. They include automatic updates, because Sparkle downloads the same release DMG, and manual re-downloads such as the hash checks in [Validate before publishing the feed](#validate-before-publishing-the-feed), about one per asset per release. Update-feed checks are not counted: the appcast is served from `raw.githubusercontent.com`, which reports nothing.

The `Download stats` workflow runs daily (and on demand from the Actions tab) and records a snapshot on the `stats` branch: `downloads.csv` (one row per asset per day) and `traffic.csv` (one row per day). GitHub keeps traffic for 14 days only, so the daily record is the history. Traffic needs push-level access: add a fine-grained token with read-only **Administration** permission for this repository as the `STATS_TOKEN` Actions secret to record it; without it the workflow records downloads only.

## Safe recovery and forward fixes

If validation fails before feed publication, stop: leave the public feed unchanged, correct the source and produce a new uniquely versioned candidate. Do not upload a replacement over already public signed bytes.

If a published update is faulty, preserve the released assets and evidence. Stop further promotion and notify users through existing release notes/support channels. The owner may remove only the faulty feed entry through a reviewed feed-only change to stop new offers; preserve other entries and record the before/after feed commits. This cannot retract cached offers/downloads or downgrade installations already updated. Do not rely on deleting an asset URL as rollback, and do not reuse the bad version for corrected bytes.

Ship a higher-version forward fix through the same candidate, signing, notarization, source and validation gates. For an affected user, recommend normal Quit and DisplayLink Manager as the installed fallback only after LinkLite has released USB ownership. During a cancellation hang, follow the [shutdown safety procedure](DEVELOPMENT.md#shutdown-safety-and-recovery); never launch competing owners or kill system display services. If an owner-approved manual reinstall is necessary, use a previously verified signed release and explain that the updater will not automatically downgrade. Keep local logs private as appropriate; use the existing [security policy](../SECURITY.md) for suspected compromise.

## Owner-only key recovery gate

Before 1.0 the owner must record completion of all items below, without storing secrets in the repository:

- An encrypted, off-device backup of the **Sparkle Ed25519 private key** and the **Developer ID certificate plus its private key**; the public certificate alone is insufficient. Record backup location/custodian and encryption/recovery method without revealing secrets. No backup is claimed to exist today.
- Access verification for the backup and its decryption/recovery material, with at least one controlled restore/recovery exercise on an owner-managed isolated system. Verify that the restored Sparkle key matches the shipped public key and that the Developer ID identity can sign and obtain accepted notarization. Retain non-secret verification receipts and date.
- Documented Apple Developer/notarization account recovery, authorized maintainers, access revocation and key-loss/compromise response. Keep recovery material separate from the device and from the encrypted backup where appropriate.

Only the owner performs exports/restores; this runbook does not authorize an agent to read or export private keys. Loss or compromise of the Sparkle key cannot be solved by silently replacing the public key in an unsigned feed: existing installations trust the old key. Stop publication and plan a verified migration/manual-install advisory under the security policy. Treat Developer ID revocation/replacement similarly, with fresh signing/notarization validation and explicit user guidance.
