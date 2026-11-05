#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Isolated release transaction regressions: python3 scripts/test-release.py.

Requires macOS's PlistBuddy and csreq. The real release script runs
inside disposable repositories; signing/notary/build fixtures never use a keychain,
network, physical image, or the working repository's dist/feed. These fixtures
model artifacts and failure transitions, not the platform's cryptographic trust.
Real Developer ID/notarization acceptance remains a separate release smoke test.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


RELEASE = Path(__file__).with_name("release.sh")
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MARKER = "<!-- release.sh inserts new <item> elements directly below this line. -->"
FIXTURE = r'''#!/usr/bin/env python3
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
failure = os.environ.get("FAIL_AT", "")

def fail(stage):
    if failure == stage:
        sys.exit("fixture failure: " + stage)

def load(path):
    path = Path(path)
    return json.loads((path / "signature.json" if path.is_dir() else path).read_text())

def save(path, data):
    path = Path(path)
    (path / "signature.json" if path.is_dir() else path).write_text(json.dumps(data, sort_keys=True))

def kind(path):
    return "app" if Path(path).is_dir() or str(path).endswith(".zip") else "dmg"

if command == "build-app.sh":
    Path("build-started").touch()
    app = Path("dist/LinkLite.app")
    (app / "Contents").mkdir(parents=True, exist_ok=True)
    shutil.copyfile("Resources/Info.plist", app / "Contents/Info.plist")
    save(app, {"identity": os.environ.get("APP_IDENTITY", "Developer ID Application"), "ticket": False})
elif command == "build-dmg.sh":
    fail("build-dmg")
    save(args[1], {"identity": "Developer ID Application", "ticket": False, "app": load(args[0])})
elif command == "codesign":
    path = args[-1]
    fail(kind(path) + "-signature")
    data = load(path)
    # Ad hoc/development signatures can pass ordinary codesign verification,
    # but cannot satisfy the release's Developer ID designated requirement.
    if "-R" in args:
        subprocess.run(["/usr/bin/csreq", "-r", args[args.index("-R") + 1]], check=True)
        if data["identity"] != "Developer ID Application":
            sys.exit("signature does not satisfy Developer ID requirement")
elif command == "ditto":
    shutil.copyfile(Path(args[-2]) / "signature.json", args[-1])
elif command == "xcrun":
    if args[0] == "notarytool":
        path = args[2]
        stage = kind(path) + "-notary"
        fail(stage + "-command")
        status = "Invalid" if failure == stage else "Accepted"
        sys.stdout.buffer.write(plistlib.dumps({"status": status}))
    elif args[0] == "stapler":
        action, path = args[1:]
        fail(kind(path) + "-" + action)
        data = load(path)
        if action == "staple":
            data["ticket"] = True
            save(path, data)
        elif action == "validate":
            if not data["ticket"]:
                sys.exit("no stapled ticket")
        else:
            sys.exit("unexpected stapler action")
    else:
        sys.exit("unexpected xcrun command")
elif command == "hdiutil":
    fail("hdiutil")
    data = load(args[-1])
    if not data["ticket"] or not data["app"]["ticket"]:
        sys.exit("image or embedded app missing stapled ticket")
elif command == "generate_keys":
    fail("read-update-key")
    print(base64.b64encode(b"fixture public key".ljust(32, b"\0")).decode())
elif command == "sign_update":
    if "--verify" in args:
        fail("verify-update")
        path, signature = args[-2:]
        expected = base64.b64encode(hashlib.sha512(Path(path).read_bytes()).digest()).decode()
        if expected != signature:
            sys.exit("signature mismatch")
    else:
        fail("sign-update")
        path = Path(args[-1])
        signature = base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode()
        if failure == "malformed-signature":
            signature = "not-base64"
        length = path.stat().st_size + (1 if failure == "wrong-length" else 0)
        print('sparkle:edSignature="' + signature + '" length="' + str(length) + '"')
else:
    sys.exit("unexpected fixture command: " + command)
'''


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="linklite-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("scripts", "Resources", "bin", "dist/candidates", ".build/artifacts/sparkle/Sparkle/bin"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(RELEASE, self.root / "scripts/release.sh")
        for command in ("scripts/build-app.sh", "scripts/build-dmg.sh", "bin/codesign",
                        "bin/ditto", "bin/xcrun", "bin/hdiutil",
                        ".build/artifacts/sparkle/Sparkle/bin/sign_update",
                        ".build/artifacts/sparkle/Sparkle/bin/generate_keys"):
            path = self.root / command
            path.write_text(FIXTURE)
            path.chmod(0o755)
        with (self.root / "Resources/Info.plist").open("wb") as target:
            plistlib.dump({"CFBundleVersion": "0.3.7", "CFBundleShortVersionString": "0.3.7",
                          "LSMinimumSystemVersion": "14.0",
                          "SUPublicEDKey": base64.b64encode(b"fixture public key".ljust(32, b"\0")).decode()}, target)
        self.set_feed("0.3.6")
        self.public_assets = {
            "dist/LinkLite-0.3.7.dmg": b"existing public disk image",
            "dist/LinkLite-0.3.7.dmg.sha256": b"existing public checksum",
        }
        self.candidate_assets = {
            "dist/candidates/LinkLite-0.3.7.dmg": b"existing candidate disk image",
            "dist/candidates/LinkLite-0.3.7.dmg.sha256": b"existing candidate checksum",
            "dist/candidates/appcast.xml": b"existing candidate feed",
        }
        for name, content in {**self.public_assets, **self.candidate_assets}.items():
            (self.root / name).write_bytes(content)
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("LINKLITE_") and key not in ("FAIL_AT", "APP_IDENTITY")}
        self.environment.update({"PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                                 "LINKLITE_SIGN_IDENTITY": "fixture-identity",
                                 "LINKLITE_NOTARY_PROFILE": "fixture-profile"})

    def set_feed(self, version, include_short_version=True, artifact_extension="dmg"):
        self.original_feed = ('<?xml version="1.0"?>\n<rss version="2.0" '
                              'xmlns:sparkle="' + SPARKLE[1:-1] + '"><channel>\n'
                              '<title>LinkLite</title>\n' + MARKER + '\n'
                              '<item><title>Existing entry</title><sparkle:version>' + version +
                              '</sparkle:version>' +
                              ('<sparkle:shortVersionString>' + version + '</sparkle:shortVersionString>'
                               if include_short_version else '') +
                              '<enclosure url="https://github.com/matthewrball/linklite/releases/download/v' +
                              version + '/LinkLite-' + version + '.' + artifact_extension +
                              '"/></item>\n</channel></rss>\n').encode()
        (self.root / "appcast.xml").write_bytes(self.original_feed)

    def run_release(self, channel="public", extra=(), overrides=None, omit=()):
        environment = dict(self.environment)
        environment.update(overrides or {})
        for key in omit:
            environment.pop(key, None)
        arguments = [] if channel is None else ["--channel", channel]
        if channel == "candidate":
            arguments += ["--candidate-base-url", "https://staging.example.test/linklite/v0.3.7-rc.1"]
        result = subprocess.run(["/bin/bash", "scripts/release.sh", *arguments, *extra],
                                cwd=self.root, env=environment, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return result

    def assert_preserved(self, assets):
        self.assertEqual((self.root / "appcast.xml").read_bytes(), self.original_feed)
        for name, content in assets.items():
            self.assertEqual((self.root / name).read_bytes(), content, name)
        self.assertEqual(list((self.root / "dist").rglob(".release.*")), [])

    def assert_package(self, directory, feed_path):
        dmg = self.root / directory / "LinkLite-0.3.7.dmg"
        contents = dmg.read_bytes()
        data = json.loads(contents)
        self.assertTrue(data["ticket"])
        self.assertTrue(data["app"]["ticket"])
        expected_checksum = hashlib.sha256(contents).hexdigest() + "  " + dmg.name + "\n"
        self.assertEqual(Path(str(dmg) + ".sha256").read_text(), expected_checksum)
        items = ET.parse(self.root / feed_path).findall("./channel/item")
        entry = items[0]
        self.assertEqual(entry.findtext(SPARKLE + "version"), "0.3.7")
        self.assertEqual(entry.findtext(SPARKLE + "shortVersionString"), "0.3.7")
        enclosure = entry.find("enclosure")
        self.assertEqual(enclosure.get("length"), str(len(contents)))
        self.assertEqual(enclosure.get(SPARKLE + "edSignature"),
                         base64.b64encode(hashlib.sha512(contents).digest()).decode())
        return items, enclosure

    def test_explicit_channel_and_credentials_before_build(self):
        cases = [(None, (), ()), ("unknown", (), ()),
                 ("public", (), ("LINKLITE_SIGN_IDENTITY",)),
                 ("public", (), ("LINKLITE_NOTARY_PROFILE",)),
                 ("candidate", (), ("LINKLITE_SIGN_IDENTITY",)),
                 ("candidate", (), ("LINKLITE_NOTARY_PROFILE",)),
                 ("public", ("--channel", "candidate"), ())]
        for channel, extra, omit in cases:
            with self.subTest(channel=channel, extra=extra, omit=omit):
                result = self.run_release(channel, extra, omit=omit)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "build-started").exists())
                self.assert_preserved({**self.public_assets, **self.candidate_assets})

    def test_candidate_requires_explicit_staging_url(self):
        for url in (None, "http://staging.example.test", "https://staging.example.test/?x=1"):
            with self.subTest(url=url):
                extra = ["--channel", "candidate"]
                if url is not None:
                    extra += ["--candidate-base-url", url]
                result = self.run_release(None, extra)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "build-started").exists())
                self.assert_preserved({**self.public_assets, **self.candidate_assets})

    def test_public_duplicate_is_rejected_before_build(self):
        self.set_feed("0.3.7")
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "build-started").exists())
        self.assert_preserved({**self.public_assets, **self.candidate_assets})

    def test_public_version_and_url_reuse_are_rejected_before_build(self):
        info_path = self.root / "Resources/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleVersion"] = "0.3.8"
        info_path.write_bytes(plistlib.dumps(info))
        for include_short_version, extension in ((True, "zip"), (False, "dmg")):
            with self.subTest(include_short_version=include_short_version, extension=extension):
                self.set_feed("0.3.7", include_short_version, extension)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "build-started").exists())
                self.assert_preserved({**self.public_assets, **self.candidate_assets})

    def test_public_success_appends_one_entry(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout)
        items, enclosure = self.assert_package("dist", "appcast.xml")
        self.assertEqual(len(items), 2)
        self.assertEqual(items[1].findtext("title"), "Existing entry")
        self.assertEqual(items[1].findtext(SPARKLE + "version"), "0.3.6")
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/matthewrball/linklite/releases/download/v0.3.7/LinkLite-0.3.7.dmg")
        for name, content in self.candidate_assets.items():
            self.assertEqual((self.root / name).read_bytes(), content)
        updated_feed = (self.root / "appcast.xml").read_bytes()
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.root / "appcast.xml").read_bytes(), updated_feed)

    def test_candidate_same_published_version_is_isolated(self):
        self.set_feed("0.3.7")
        result = self.run_release("candidate")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_preserved(self.public_assets)
        items, enclosure = self.assert_package("dist/candidates", "dist/candidates/appcast.xml")
        self.assertEqual(len(items), 1)
        self.assertEqual(enclosure.get("url"),
                         "https://staging.example.test/linklite/v0.3.7-rc.1/LinkLite-0.3.7.dmg")

    def test_rejected_app_signing_identity_preserves_publication(self):
        for channel in ("public", "candidate"):
            for identity in ("adhoc", "Apple Development"):
                with self.subTest(channel=channel, identity=identity):
                    result = self.run_release(channel, overrides={"APP_IDENTITY": identity})
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assert_preserved({**self.public_assets, **self.candidate_assets})

    def test_missing_or_mismatched_update_key_preserves_publication(self):
        for channel in ("public", "candidate"):
            for public_key in (None, base64.b64encode(b"different key".ljust(32, b"\0")).decode()):
                with self.subTest(channel=channel, public_key=public_key):
                    info_path = self.root / "Resources/Info.plist"
                    info = plistlib.loads(info_path.read_bytes())
                    if public_key is None:
                        info.pop("SUPublicEDKey", None)
                    else:
                        info["SUPublicEDKey"] = public_key
                    info_path.write_bytes(plistlib.dumps(info))
                    result = self.run_release(channel)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assert_preserved({**self.public_assets, **self.candidate_assets})

    def test_failure_transitions_preserve_feeds_and_artifacts(self):
        stages = ("app-signature", "dmg-signature", "app-notary", "dmg-notary",
                  "app-notary-command", "dmg-notary-command", "app-staple", "dmg-staple",
                  "app-validate", "dmg-validate", "build-dmg", "hdiutil", "sign-update",
                  "malformed-signature", "wrong-length", "verify-update", "read-update-key")
        for channel in ("public", "candidate"):
            for stage in stages:
                with self.subTest(channel=channel, stage=stage):
                    result = self.run_release(channel, overrides={"FAIL_AT": stage})
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assert_preserved({**self.public_assets, **self.candidate_assets})

    def test_invalid_public_feed_fails_before_build(self):
        for marker in ("", MARKER + MARKER):
            with self.subTest(marker=marker):
                self.set_feed("0.3.6")
                self.original_feed = self.original_feed.replace(MARKER.encode(), marker.encode())
                (self.root / "appcast.xml").write_bytes(self.original_feed)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "build-started").exists())
                self.assert_preserved({**self.public_assets, **self.candidate_assets})


if __name__ == "__main__":
    unittest.main(verbosity=2)
