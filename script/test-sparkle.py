#!/usr/bin/env python3
"""Credential-free tests for Sparkle packaging and release automation."""

import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
FAKE_COMMAND = r"""
import json
import base64
import os
from pathlib import Path
import shutil
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
payload = sys.stdin.read() if command == "gh" and args[:2] == ["secret", "set"] else ""
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"command": command, "args": args, "input": payload}) + "\n")
if command == "ditto":
    shutil.copytree(args[0], args[1], symlinks=True)
elif command == "xcrun":
    if args[:2] == ["lipo", "-archs"]:
        print("arm64 x86_64")
    elif args[0] == "lipo":
        shutil.copyfile(args[1], args[-1])
    else:
        sys.exit("Unexpected xcrun command")
elif command == "codesign":
    if os.environ.get("FAIL_SIGN") == "1" and "--verify" not in args:
        sys.exit(23)
elif command == "gh":
    if args[:2] == ["repo", "view"]:
        print("example/fake-repository")
    elif args[:2] == ["release", "view"]:
        print(os.environ.get("PREVIOUS_FEED_URL", "") if args[args.index("--json") + 1] == "assets"
              else os.environ.get("LATEST_TAG", "v0.1.0"))
    elif args[:2] == ["secret", "set"] and os.environ.get("FAIL_SECRET") == "1":
        sys.exit(24)
elif command == "curl":
    shutil.copyfile(os.environ["FAKE_PREVIOUS_FEED"], args[args.index("-o") + 1])
elif command == "generate_keys":
    if os.environ.get("FAIL_KEY") == "1":
        sys.exit(25)
    if "-x" in args:
        Path(args[args.index("-x") + 1]).write_text("fake-sparkle-private-key")
    elif "-p" in args:
        print(base64.b64encode(b"p" * 32).decode())
elif command == "generate_appcast":
    import xml.etree.ElementTree as ET
    output = Path(args[args.index("-o") + 1])
    archive = next(output.parent.glob("*.zip"))
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    root = ET.Element("rss")
    item = ET.SubElement(ET.SubElement(root, "channel"), "item")
    for key, value in (("version", "200.1"), ("shortVersionString", "0.2.0"),
                       ("minimumSystemVersion", "27.0"), ("hardwareRequirements", "arm64")):
        ET.SubElement(item, ns + key).text = value
    ET.SubElement(item, "enclosure", {
        "url": args[args.index("--download-url-prefix") + 1] + archive.name,
        "length": str(archive.stat().st_size),
        ns + "edSignature": "" if os.environ.get("UNSIGNED_FEED") == "1" else base64.b64encode(b"s" * 64).decode(),
    })
    ET.ElementTree(root).write(output)
elif command == "sign_update":
    if os.environ.get("FAIL_VERIFY") == "1":
        sys.exit(26)
else:
    sys.exit("Unexpected fake command")
"""


class FakeCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="toy-box-sparkle-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        binary = self.directory / "bin"
        binary.mkdir()
        for command in ("ditto", "xcrun", "codesign", "gh", "curl", "generate_keys",
                        "generate_appcast", "sign_update"):
            path = binary / command
            path.write_text(f"#!{sys.executable}\n" + FAKE_COMMAND)
            path.chmod(0o700)
        self.log = self.directory / "commands.jsonl"
        self.environment = {
            "PATH": f"{binary}:/usr/bin:/bin", "HOME": str(self.directory),
            "FAKE_LOG": str(self.log), "TMPDIR": str(self.directory),
            "SPARKLE_TOOLS_DIR": str(self.directory),
        }

    def run_script(self, script, *arguments, extra=None):
        return subprocess.run(
            ["/bin/bash", str(ROOT / "script" / script), *map(str, arguments)],
            env={**self.environment, **(extra or {})}, capture_output=True, text=True, timeout=15)

    def calls(self, command):
        if not self.log.exists():
            return []
        return [call for line in self.log.read_text().splitlines()
                if (call := json.loads(line))["command"] == command]


class BundleTests(FakeCommandTests):
    def setUp(self):
        super().setUp()
        self.app = self.directory / "Toy Box Desktop.app"
        self.framework = self.app / "Contents/Frameworks/Sparkle.framework"
        source = self.directory / "source.framework"
        self.version = source / "Versions/B"
        self.version.mkdir(parents=True)
        (source / "Versions/Current").symlink_to("B")
        for component in ("Headers", "PrivateHeaders", "Modules", "XPCServices"):
            (self.version / component).mkdir()
            (source / component).symlink_to(f"Versions/Current/{component}")
        for executable in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater"):
            path = self.version / executable
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fake universal executable")
        (source / "Sparkle").symlink_to("Versions/Current/Sparkle")
        self.source = source
        self.license = self.directory / "LICENSE"
        self.license.write_text("Upstream license notices")

    def test_embedding_preserves_symlinks_trims_and_thins_all_three_executables(self):
        for _ in range(2):
            result = self.run_script("embed-sparkle", self.source, self.app, self.license)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.framework / "Versions/Current").is_symlink())
        self.assertTrue((self.framework / "Sparkle").is_symlink())
        for component in ("Headers", "PrivateHeaders", "Modules", "XPCServices"):
            self.assertFalse(os.path.lexists(self.framework / component))
            self.assertFalse((self.framework / "Versions/B" / component).exists())
        thinned = [call for call in self.calls("xcrun") if "-thin" in call["args"]]
        self.assertEqual(len(thinned), 6)
        self.assertTrue(all(call["args"][2:4] == ["-thin", "arm64"] for call in thinned))
        self.assertEqual((self.app / "Contents/Resources/Sparkle-LICENSE").read_text(),
                         self.license.read_text())

    def test_signing_is_inside_out_with_entitlements_only_on_the_app(self):
        options = ["--force", "--options", "runtime", "--timestamp", "--sign", "FAKE_IDENTITY"]
        result = self.run_script("sign-app", self.app, *options)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls("codesign")
        signed = [call["args"] for call in calls if "--verify" not in call["args"]]
        self.assertEqual([args[-1] for args in signed], [
            str(self.framework / "Versions/Current/Autoupdate"),
            str(self.framework / "Versions/Current/Updater.app"),
            str(self.framework), str(self.app)])
        self.assertTrue(all(args[:len(options)] == options for args in signed))
        self.assertTrue(all("--entitlements" not in args for args in signed[:-1]))
        self.assertIn("--entitlements", signed[-1])
        self.assertEqual(len([call for call in calls if "--strict" in call["args"]]), 4)
        self.assertFalse(any("--deep" in call["args"] for call in calls))

    def test_ad_hoc_signing_and_errors(self):
        result = self.run_script("sign-app", self.app)
        self.assertEqual(result.returncode, 0, result.stderr)
        first = self.calls("codesign")[0]["args"]
        self.assertIn("--timestamp=none", first)
        self.assertEqual(first[first.index("--sign") + 1], "-")
        self.log.unlink()
        result = self.run_script("sign-app", self.app, extra={"FAIL_SIGN": "1"})
        self.assertEqual(result.returncode, 23)
        self.assertEqual(len(self.calls("codesign")), 1)


class UpdateSecretsTests(FakeCommandTests):
    def test_setup_uses_app_account_and_uploads_private_key_only_over_stdin(self):
        result = self.run_script("setup-update-secrets", "example/explicit-repository")
        self.assertEqual(result.returncode, 0, result.stderr)
        keys = self.calls("generate_keys")
        self.assertEqual(len(keys), 3)
        self.assertTrue(all(call["args"][:2] == ["--account", "dev.toybox.channels.mac"]
                            for call in keys))
        gh = self.calls("gh")
        secret = next(call for call in gh if call["args"][:2] == ["secret", "set"])
        self.assertEqual(secret["args"], ["secret", "set", "SPARKLE_ED_PRIVATE_KEY",
                                         "--repo", "example/explicit-repository"])
        self.assertEqual(secret["input"], "fake-sparkle-private-key")
        variable = next(call for call in gh if call["args"][:2] == ["variable", "set"])
        self.assertEqual(variable["args"][2], "SPARKLE_ED_PUBLIC_KEY")
        self.assertNotIn("fake-sparkle-private-key", result.stdout + result.stderr)
        self.assertFalse(list(self.directory.glob("toy-box-update-secrets.*")))

    def test_setup_resolves_repository_and_propagates_key_or_upload_errors(self):
        for extra, code in (({}, 0), ({"FAIL_KEY": "1"}, 25), ({"FAIL_SECRET": "1"}, 24)):
            with self.subTest(extra=extra):
                result = self.run_script("setup-update-secrets", extra=extra)
                self.assertEqual(result.returncode, code, result.stderr)
                if code:
                    self.assertNotIn("Update signing configured", result.stdout)
                self.assertFalse(list(self.directory.glob("toy-box-update-secrets.*")))

    def test_setup_disables_tracing(self):
        result = subprocess.run(
            ["/bin/bash", "-x", str(ROOT / "script/setup-update-secrets")],
            env=self.environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("fake-sparkle-private-key", result.stdout + result.stderr)
        self.assertNotIn("gh secret", result.stderr)


class AppcastTests(FakeCommandTests):
    def setUp(self):
        super().setUp()
        self.output = self.directory / "release"
        self.output.mkdir()
        (self.output / "ToyBoxDesktop-0.2.0-arm64.zip").write_bytes(b"fake archive")
        self.environment.update({
            "OUTPUT_DIR": str(self.output), "BUILD_NUMBER": "200.1",
            "SPARKLE_ED_PRIVATE_KEY": "fake-sparkle-private-key",
        })

    def test_generates_and_verifies_archive_and_feed_without_keychain_access(self):
        result = self.run_script("generate-appcast", "v0.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        generated = self.calls("generate_appcast")[0]["args"]
        self.assertEqual(generated[:2], ["--ed-key-file", "-"])
        self.assertIn("--embed-release-notes", generated)
        self.assertIn("--maximum-deltas", generated)
        verified = self.calls("sign_update")
        self.assertEqual(len(verified), 2)
        self.assertTrue(all(call["args"][:3] == ["--ed-key-file", "-", "--verify"]
                            for call in verified))
        self.assertNotIn("fake-sparkle-private-key", result.stdout + result.stderr)

    def test_missing_key_unsigned_feed_and_verification_failure_are_not_success(self):
        for extra in ({"SPARKLE_ED_PRIVATE_KEY": ""}, {"UNSIGNED_FEED": "1"},
                      {"FAIL_VERIFY": "1"}, {"BUILD_NUMBER": "199.1"}):
            with self.subTest(extra=extra):
                result = self.run_script("generate-appcast", "v0.2.0", extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Signed update feed:", result.stdout)

    def test_explicit_throwaway_file_never_falls_back_to_a_keychain(self):
        key = self.directory / "throwaway-key"
        key.write_text("fake-key")
        result = self.run_script("generate-appcast", "v0.2.0",
                                 extra={"SPARKLE_ED_PRIVATE_KEY": "", "SPARKLE_ED_KEY_FILE": str(key)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(call["args"][:2] == ["--ed-key-file", str(key)]
                            for call in self.calls("generate_appcast") + self.calls("sign_update")))

    def test_workflow_only_bootstraps_the_known_release_and_rejects_older_builds(self):
        lines = (ROOT / ".github/workflows/build-and-release.yml").read_text().splitlines()
        start = lines.index("      - name: Check update signing configuration and build number")
        run = lines.index("        run: |", start) + 1
        body = []
        for line in lines[run:]:
            if line and not line.startswith("          "):
                break
            body.append(line[10:])
        previous = self.directory / "source-appcast.xml"
        previous.write_text("""<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item><s:version>200.1</s:version></item></channel></rss>""")
        environment = {
            **self.environment, "SPARKLE_ED_PUBLIC_KEY": "fake-public-key",
            "RUNNER_TEMP": str(self.directory), "GITHUB_ENV": str(self.directory / "github-env"),
            "GITHUB_REPOSITORY": "example/fake-repository", "FAKE_PREVIOUS_FEED": str(previous),
        }
        for extra, succeeds in (({}, True), ({"LATEST_TAG": "v0.2.0"}, False),
                                ({"PREVIOUS_FEED_URL": "https://example.invalid/appcast.xml",
                                  "BUILD_NUMBER": "200.2"}, True),
                                ({"PREVIOUS_FEED_URL": "https://example.invalid/appcast.xml"}, False)):
            with self.subTest(extra=extra):
                result = subprocess.run(["/bin/bash", "-c", "\n".join(body)],
                                        env={**environment, **extra}, cwd=ROOT,
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)


class UpdateVersionTests(unittest.TestCase):
    def test_build_comparison_is_numeric_strict_and_checks_every_published_item(self):
        check = runpy.run_path(str(ROOT / "script/check-update-version.py"))["check"]
        with tempfile.TemporaryDirectory(prefix="toy-box-version-test-") as directory:
            feed = Path(directory) / "previous.xml"
            feed.write_text("""<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><item><s:version>199.10</s:version></item>
              <item><enclosure s:version="200.1"/></item></channel></rss>""")
            check("200.2", feed)
            check("201", feed)
            for rejected in ("200.1", "200.1.0", "200", "199.99", "1", "invalid", "10000.1"):
                with self.subTest(build=rejected), self.assertRaises(ValueError):
                    check(rejected, feed)
            feed.write_text("<rss><channel><item/></channel></rss>")
            with self.assertRaises(ValueError):
                check("201", feed)
            feed.write_text("<rss><channel/></rss>")
            with self.assertRaises(ValueError):
                check("201", feed)


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("TOY_BOX_BUNDLE"),
                     "Requires a built macOS bundle")
class NativeBundleTests(unittest.TestCase):
    def test_framework_is_arm64_signed_and_development_updates_are_disabled(self):
        app = Path(os.environ["TOY_BOX_BUNDLE"])
        framework = app / "Contents/Frameworks/Sparkle.framework"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertNotIn("SUFeedURL", info)
        self.assertNotIn("SUPublicEDKey", info)
        self.assertTrue((framework / "Versions/Current").is_symlink())
        self.assertTrue((app / "Contents/Resources/Sparkle-LICENSE").is_file())
        for component in ("Headers", "PrivateHeaders", "Modules", "XPCServices"):
            self.assertFalse(os.path.lexists(framework / component))
            self.assertFalse((framework / "Versions/Current" / component).exists())
        for executable in (app / "Contents/MacOS/ToyBoxDesktop", framework / "Sparkle",
                           framework / "Autoupdate",
                           framework / "Updater.app/Contents/MacOS/Updater"):
            result = subprocess.run(["xcrun", "lipo", "-archs", str(executable)],
                                    check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "arm64")
        for component in (framework / "Autoupdate", framework / "Updater.app", framework, app):
            subprocess.run(["codesign", "--verify", "--strict", str(component)], check=True)


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("TOY_BOX_BUNDLE") and
                     os.environ.get("SPARKLE_TOOLS_DIR"), "Requires a bundle and Sparkle tools")
class NativeAppcastTests(unittest.TestCase):
    def test_real_tools_sign_feed_and_archive_using_only_a_throwaway_file_key(self):
        with tempfile.TemporaryDirectory(prefix="toy-box-native-appcast-") as directory:
            temporary = Path(directory)
            key = temporary / "throwaway-key"
            public = subprocess.run(
                ["xcrun", "swift", "-e", """
                import CryptoKit
                import Foundation
                let key = Curve25519.Signing.PrivateKey()
                try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
                print(key.publicKey.rawRepresentation.base64EncodedString())
                """, str(key)], check=True, capture_output=True, text=True).stdout.strip()
            app = temporary / "Toy Box Desktop.app"
            shutil.copytree(os.environ["TOY_BOX_BUNDLE"], app, symlinks=True)
            info_path = app / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info.update({
                "CFBundleVersion": "200.1", "CFBundleShortVersionString": "0.2.0",
                "SUFeedURL": "http://127.0.0.1:3298/appcast.xml", "SUPublicEDKey": public,
                "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
            })
            info_path.write_bytes(plistlib.dumps(info))
            subprocess.run([str(ROOT / "script/sign-app"), str(app)], check=True,
                           capture_output=True)
            output = temporary / "dist"
            output.mkdir()
            archive = output / "ToyBoxDesktop-0.2.0-arm64.zip"
            subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
            environment = {
                **os.environ, "HOME": directory, "CFFIXED_USER_HOME": directory,
                "SPARKLE_ED_KEY_FILE": str(key), "SPARKLE_ED_PRIVATE_KEY": "",
                "OUTPUT_DIR": str(output), "BUILD_NUMBER": "200.1",
                "DOWNLOAD_URL_PREFIX": "http://127.0.0.1:3298/",
            }
            result = subprocess.run([str(ROOT / "script/generate-appcast"), "v0.2.0"],
                                    env=environment, capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            feed = ET.parse(output / "appcast.xml")
            ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
            signature = feed.find("./channel/item/enclosure").get(ns + "edSignature")
            with archive.open("ab") as file:
                file.write(b"tampered")
            result = subprocess.run(
                [str(Path(os.environ["SPARKLE_TOOLS_DIR"]) / "bin/sign_update"),
                 "--ed-key-file", str(key), "--verify", str(archive), signature],
                env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            feed_path = output / "appcast.xml"
            original = feed_path.read_bytes()
            tampered = original.replace(b"0.2.0", b"9.2.0")
            self.assertNotEqual(original, tampered)
            feed_path.write_bytes(tampered)
            result = subprocess.run(
                [str(Path(os.environ["SPARKLE_TOOLS_DIR"]) / "bin/sign_update"),
                 "--ed-key-file", str(key), "--verify", str(output / "appcast.xml")],
                env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
