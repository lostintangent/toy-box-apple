#!/usr/bin/env python3
"""Exercise setup and the workflow's credential step without Apple, GitHub or a keychain."""

import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parent.parent
IDENTITY = "0123456789ABCDEF0123456789ABCDEF01234567"
APPLE_PASSWORD = r"fake-app-password\with a space"
SIGNING = {"CERTIFICATE": base64.b64encode(b"fake identity").decode(),
           "CERTIFICATE_PASSWORD": "fake-p12-password"}
API = {"NOTARY_KEY": "fake API key", "NOTARY_KEY_ID": "FAKEKEY123",
       "NOTARY_ISSUER_ID": "fake-issuer"}
APPLE = {"NOTARY_APPLE_ID": "owner@example.invalid", "NOTARY_TEAM_ID": "FAKETEAM12",
         "NOTARY_APP_PASSWORD": APPLE_PASSWORD}

FAKE_COMMAND = r"""
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
payload = sys.stdin.read() if command == "shasum" or (command == "gh" and args[:2] == ["secret", "set"]) else ""
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"command": command, "args": args, "input": payload}) + "\n")
if command == "gh":
    if args[:2] == ["repo", "view"]:
        print("example/fake-repository")
    elif args[:2] == ["secret", "set"] and args[2] == os.environ.get("FAIL_SECRET"):
        sys.exit(24)
elif command == "openssl":
    print("fake-generated-password")
elif command == "xcrun":
    if args[0] == "swift":
        Path(args[-1]).write_text("fake encrypted identity")
    elif args[:2] == ["notarytool", "store-credentials"]:
        if os.environ.get("FAIL_NOTARY") == "1":
            print("Fake notarization rejection", file=sys.stderr)
            sys.exit(23)
    else:
        sys.exit("Unexpected xcrun command")
elif command == "curl":
    Path(args[args.index("-o") + 1]).write_text("fake intermediate certificate")
elif command == "security":
    if args[:2] == ["list-keychains", "-d"] and "-s" not in args:
        print('    "/fake/login.keychain-db"')
elif command != "shasum":
    sys.exit("Unexpected fake command")
"""


def workflow_import():
    lines = (ROOT / ".github/workflows/build-and-release.yml").read_text().splitlines()
    start = lines.index("      - name: Import the signing identity and notarization credentials")
    run = lines.index("        run: |", start) + 1
    body = []
    for line in lines[run:]:
        if line and not line.startswith("          "):
            break
        body.append(line[10:])
    return "\n".join(body) + "\n"


class ReleaseSecretsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="toy-box-fake-release-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        binary = self.directory / "bin"
        binary.mkdir()
        for command in ("gh", "openssl", "xcrun", "security", "curl", "shasum"):
            path = binary / command
            path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(FAKE_COMMAND))
            path.chmod(0o700)
        self.log = self.directory / "commands.jsonl"
        self.key = self.directory / "AuthKey.p8"
        self.key.write_text("fake API key")
        self.environment = {
            "PATH": f"{binary}:/usr/bin:/bin",
            "HOME": str(self.directory),
            "TMPDIR": str(self.directory),
            "FAKE_LOG": str(self.log),
            "RUNNER_TEMP": str(self.directory),
            "GITHUB_ENV": str(self.directory / "github-env"),
            "NOTARY_PROFILE": "fake-ci-profile",
            **dict.fromkeys((*API, *APPLE), ""),
        }

    def calls(self, command):
        if not self.log.exists():
            return []
        return [call for line in self.log.read_text().splitlines()
                if (call := json.loads(line))["command"] == command]

    def run_bash(self, arguments, password="", extra=None):
        result = subprocess.run(["/bin/bash", *arguments], input=password, text=True,
                                capture_output=True, env={**self.environment, **(extra or {})},
                                cwd=ROOT, timeout=15)
        self.assertNotIn(APPLE_PASSWORD, result.stdout + result.stderr)
        self.assertEqual(list(self.directory.glob("toy-box-release-secrets.*")), [])
        return result

    def setup(self, arguments, password="", extra=None):
        return self.run_bash([str(ROOT / "script/setup-release-secrets"), *arguments],
                             password, extra)

    def test_setup_keeps_api_key_and_apple_id_modes(self):
        for apple_id in (False, True):
            with self.subTest(apple_id=apple_id):
                self.log.unlink(missing_ok=True)
                arguments = (["--apple-id", APPLE["NOTARY_APPLE_ID"], APPLE["NOTARY_TEAM_ID"]]
                             if apple_id else [str(self.key), API["NOTARY_KEY_ID"], API["NOTARY_ISSUER_ID"]])
                result = self.setup([IDENTITY, *arguments, "example/explicit-repo"],
                                    APPLE_PASSWORD + "\n" if apple_id else "",
                                    {"APPLE_ID": "ambient-value-must-not-select-the-mode"})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Release secrets configured for example/explicit-repo", result.stdout)
                notary = self.calls("xcrun")[-1]["args"]
                self.assertEqual(notary[:3], ["notarytool", "store-credentials", "toy-box-channels-notary"])
                secrets = {call["args"][2]: call["input"] for call in self.calls("gh")
                           if call["args"][:2] == ["secret", "set"]}
                self.assertEqual(len(secrets), 6)
                self.assertEqual(secrets["MACOS_SIGNING_IDENTITY"], IDENTITY)
                self.assertEqual(secrets["MACOS_SIGNING_PASSWORD"], "fake-generated-password")
                self.assertEqual(base64.b64decode(secrets["MACOS_SIGNING_CERTIFICATE"]),
                                 b"fake encrypted identity")
                for call in self.calls("gh"):
                    if call["args"][:2] == ["secret", "set"]:
                        self.assertEqual(call["args"][3:], ["--repo", "example/explicit-repo"])
                if apple_id:
                    self.assertEqual(notary[3:], ["--apple-id", APPLE["NOTARY_APPLE_ID"],
                                                 "--team-id", APPLE["NOTARY_TEAM_ID"],
                                                 "--password", APPLE_PASSWORD])
                    self.assertEqual({name: secrets[name] for name in APPLE}, APPLE)
                else:
                    self.assertEqual(notary[3:], ["--key", str(self.key), "--key-id", API["NOTARY_KEY_ID"],
                                                 "--issuer", API["NOTARY_ISSUER_ID"]])
                    self.assertEqual(secrets["APP_STORE_CONNECT_PRIVATE_KEY"], self.key.read_text())
                    self.assertEqual(secrets["APP_STORE_CONNECT_KEY_ID"], API["NOTARY_KEY_ID"])
                    self.assertEqual(secrets["APP_STORE_CONNECT_ISSUER_ID"], API["NOTARY_ISSUER_ID"])

    def test_setup_disables_tracing_before_reading_password(self):
        result = self.run_bash(["-x", str(ROOT / "script/setup-release-secrets"), IDENTITY,
                               "--apple-id", APPLE["NOTARY_APPLE_ID"], APPLE["NOTARY_TEAM_ID"]],
                              APPLE_PASSWORD + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--password", result.stderr)

    def test_piped_password_needs_no_trailing_newline(self):
        result = self.setup([IDENTITY, "--apple-id", APPLE["NOTARY_APPLE_ID"],
                             APPLE["NOTARY_TEAM_ID"]], APPLE_PASSWORD)
        self.assertEqual(result.returncode, 0, result.stderr)
        secrets = {call["args"][2]: call["input"] for call in self.calls("gh")
                   if call["args"][:2] == ["secret", "set"]}
        self.assertEqual(secrets["NOTARY_APP_PASSWORD"], APPLE_PASSWORD)

    def test_setup_resolves_default_repository(self):
        result = self.setup([IDENTITY, str(self.key), API["NOTARY_KEY_ID"], API["NOTARY_ISSUER_ID"]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("example/fake-repository", result.stdout)

    def test_empty_or_missing_password_does_not_export_or_upload(self):
        for password in ("", "\n"):
            with self.subTest(password=repr(password)):
                result = self.setup([IDENTITY, "--apple-id", APPLE["NOTARY_APPLE_ID"],
                                     APPLE["NOTARY_TEAM_ID"]], password)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls("xcrun"), [])
                self.assertFalse(any(call["args"][:2] == ["secret", "set"] for call in self.calls("gh")))

    def test_rejected_notary_credentials_never_upload_secrets(self):
        result = self.setup([IDENTITY, "--apple-id", APPLE["NOTARY_APPLE_ID"],
                             APPLE["NOTARY_TEAM_ID"]], APPLE_PASSWORD + "\n", {"FAIL_NOTARY": "1"})
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertNotIn("Release secrets configured", result.stdout)
        self.assertFalse(any(call["args"][:2] == ["secret", "set"] for call in self.calls("gh")))

    def test_failed_upload_is_not_reported_as_success(self):
        result = self.setup([IDENTITY, "--apple-id", APPLE["NOTARY_APPLE_ID"],
                             APPLE["NOTARY_TEAM_ID"]], APPLE_PASSWORD + "\n",
                            {"FAIL_SECRET": "NOTARY_APP_PASSWORD"})
        self.assertEqual(result.returncode, 24, result.stderr)
        self.assertNotIn("Release secrets configured", result.stdout)

    def test_invalid_arguments_fail_before_external_commands(self):
        for arguments in ([], [IDENTITY, "--apple-id", "", "team"],
                          ["invalid", "--apple-id", "email", "team"],
                          [IDENTITY, "/missing/fake-key.p8", "key", "issuer"],
                          [IDENTITY, "--apple-id", "email", "team", "repo", "extra"]):
            with self.subTest(arguments=arguments):
                self.assertNotEqual(self.setup(arguments).returncode, 0)
                self.assertFalse(self.log.exists())

    def test_workflow_prefers_complete_api_set_then_apple_id(self):
        for credentials, expects_key in ((API, True), (APPLE, False), ({**API, **APPLE}, True),
                                         ({**APPLE, "NOTARY_KEY_ID": "incomplete API set"}, False)):
            with self.subTest(expects_key=expects_key, fields=list(credentials)):
                self.log.unlink(missing_ok=True)
                key_file = self.directory / "toy-box-signing/AuthKey.p8"
                key_file.unlink(missing_ok=True)
                result = self.run_bash(["-c", workflow_import()], extra={**SIGNING, **credentials})
                self.assertEqual(result.returncode, 0, result.stderr)
                notary = self.calls("xcrun")[-1]["args"]
                self.assertIn("--keychain", notary)
                self.assertEqual("--key" in notary, expects_key)
                self.assertEqual("--apple-id" in notary, not expects_key)
                self.assertEqual(key_file.exists(), expects_key)
                if expects_key:
                    self.assertEqual(key_file.read_text(), API["NOTARY_KEY"])
                else:
                    self.assertEqual(notary[notary.index("--password") + 1], APPLE_PASSWORD)

    def test_workflow_rejects_missing_or_partial_credentials_before_keychain_access(self):
        for credentials in ({}, {"NOTARY_KEY_ID": "partial"}, {"NOTARY_APPLE_ID": "partial"}):
            with self.subTest(fields=list(credentials)):
                result = self.run_bash(["-c", workflow_import()], extra={**SIGNING, **credentials})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("APP_STORE_CONNECT_PRIVATE_KEY", result.stderr)
                self.assertIn("NOTARY_APP_PASSWORD", result.stderr)
                self.assertFalse(self.log.exists())

    def test_workflow_does_not_fall_back_after_an_api_rejection(self):
        result = self.run_bash(["-c", workflow_import()],
                               extra={**SIGNING, **API, **APPLE, "FAIL_NOTARY": "1"})
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(self.calls("xcrun")), 1)
        self.assertIn("--key", self.calls("xcrun")[0]["args"])


if __name__ == "__main__":
    unittest.main()
