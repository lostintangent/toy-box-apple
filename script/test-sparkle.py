#!/usr/bin/env python3
"""Credential-free tests for Sparkle packaging and release automation."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
FAKE_COMMAND = r"""
import json
import os
from pathlib import Path
import shutil
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"command": command, "args": args}) + "\n")
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
else:
    sys.exit("Unexpected fake command")
"""


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="toy-box-sparkle-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        binary = self.directory / "bin"
        binary.mkdir()
        for command in ("ditto", "xcrun", "codesign"):
            path = binary / command
            path.write_text(f"#!{sys.executable}\n" + FAKE_COMMAND)
            path.chmod(0o700)
        self.log = self.directory / "commands.jsonl"
        self.environment = {
            "PATH": f"{binary}:/usr/bin:/bin", "HOME": str(self.directory),
            "FAKE_LOG": str(self.log),
        }
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

    def run_script(self, script, *arguments, extra=None):
        return subprocess.run(
            ["/bin/bash", str(ROOT / "script" / script), *map(str, arguments)],
            env={**self.environment, **(extra or {})}, capture_output=True, text=True, timeout=15)

    def calls(self, command):
        return [call for line in self.log.read_text().splitlines()
                if (call := json.loads(line))["command"] == command]

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


if __name__ == "__main__":
    unittest.main()
