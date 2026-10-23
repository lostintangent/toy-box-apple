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
        self.environment = {
            "PATH": f"{binary}:/usr/bin:/bin",
            "HOME": str(self.directory),
            "TMPDIR": str(self.directory),
            "FAKE_LOG": str(self.log),
            "RUNNER_TEMP": str(self.directory),
            "GITHUB_ENV": str(self.directory / "github-env"),
            "NOTARY_PROFILE": "fake-ci-profile",
            **dict.fromkeys(APPLE, ""),
        }
        self.arguments = [IDENTITY, APPLE["NOTARY_APPLE_ID"], APPLE["NOTARY_TEAM_ID"]]

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

    def test_setup_stores_profile_and_all_six_secrets(self):
        result = self.setup([*self.arguments, "example/explicit-repo"], APPLE_PASSWORD + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release secrets configured for example/explicit-repo", result.stdout)
        self.assertEqual(self.calls("xcrun")[-1]["args"],
                         ["notarytool", "store-credentials", "toy-box-channels-notary",
                          "--apple-id", APPLE["NOTARY_APPLE_ID"], "--team-id", APPLE["NOTARY_TEAM_ID"],
                          "--password", APPLE_PASSWORD])
        secrets = {call["args"][2]: call["input"] for call in self.calls("gh")
                   if call["args"][:2] == ["secret", "set"]}
        self.assertEqual(len(secrets), 6)
        self.assertEqual(secrets["MACOS_SIGNING_IDENTITY"], IDENTITY)
        self.assertEqual(secrets["MACOS_SIGNING_PASSWORD"], "fake-generated-password")
        self.assertEqual(base64.b64decode(secrets["MACOS_SIGNING_CERTIFICATE"]), b"fake encrypted identity")
        self.assertEqual({name: secrets[name] for name in APPLE}, APPLE)
        for call in self.calls("gh"):
            if call["args"][:2] == ["secret", "set"]:
                self.assertEqual(call["args"][3:], ["--repo", "example/explicit-repo"])

    def test_setup_resolves_default_repository(self):
        result = self.setup(self.arguments, APPLE_PASSWORD + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("example/fake-repository", result.stdout)

    def test_setup_disables_tracing_before_reading_password(self):
        result = self.run_bash(["-x", str(ROOT / "script/setup-release-secrets"), *self.arguments],
                              APPLE_PASSWORD + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--password", result.stderr)

    def test_piped_password_needs_no_trailing_newline(self):
        result = self.setup(self.arguments, APPLE_PASSWORD)
        self.assertEqual(result.returncode, 0, result.stderr)
        secrets = {call["args"][2]: call["input"] for call in self.calls("gh")
                   if call["args"][:2] == ["secret", "set"]}
        self.assertEqual(secrets["NOTARY_APP_PASSWORD"], APPLE_PASSWORD)

    def test_empty_or_missing_password_does_not_export_or_upload(self):
        for password in ("", "\n"):
            with self.subTest(password=repr(password)):
                result = self.setup(self.arguments, password)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls("xcrun"), [])
                self.assertFalse(any(call["args"][:2] == ["secret", "set"] for call in self.calls("gh")))

    def test_rejected_notary_credentials_never_upload_secrets(self):
        result = self.setup(self.arguments, APPLE_PASSWORD + "\n", {"FAIL_NOTARY": "1"})
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertNotIn("Release secrets configured", result.stdout)
        self.assertFalse(any(call["args"][:2] == ["secret", "set"] for call in self.calls("gh")))

    def test_failed_upload_is_not_reported_as_success(self):
        result = self.setup(self.arguments, APPLE_PASSWORD + "\n", {"FAIL_SECRET": "NOTARY_APP_PASSWORD"})
        self.assertEqual(result.returncode, 24, result.stderr)
        self.assertNotIn("Release secrets configured", result.stdout)

    def test_invalid_arguments_fail_before_external_commands(self):
        for arguments in ([], [IDENTITY, "", "team"], [IDENTITY, "email", ""],
                          ["invalid", "email", "team"], [*self.arguments, "repo", "extra"]):
            with self.subTest(arguments=arguments):
                self.assertNotEqual(self.setup(arguments).returncode, 0)
                self.assertFalse(self.log.exists())

    def test_workflow_stores_apple_id_in_the_temporary_keychain(self):
        result = self.run_bash(["-c", workflow_import()], extra={**SIGNING, **APPLE})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("xcrun")[-1]["args"],
                         ["notarytool", "store-credentials", "fake-ci-profile",
                          "--keychain", str(self.directory / "toy-box-release.keychain-db"),
                          "--apple-id", APPLE["NOTARY_APPLE_ID"], "--team-id", APPLE["NOTARY_TEAM_ID"],
                          "--password", APPLE_PASSWORD])

    def test_workflow_rejects_missing_credentials_before_keychain_access(self):
        for missing in (*APPLE, *SIGNING):
            with self.subTest(missing=missing):
                result = self.run_bash(["-c", workflow_import()], extra={**SIGNING, **APPLE, missing: ""})
                self.assertNotEqual(result.returncode, 0)
                name = {"CERTIFICATE": "MACOS_SIGNING_CERTIFICATE",
                        "CERTIFICATE_PASSWORD": "MACOS_SIGNING_PASSWORD"}.get(missing, missing)
                self.assertIn(f"Missing {name}", result.stderr)
                self.assertFalse(self.log.exists())

    def test_workflow_reports_notary_rejection(self):
        result = self.run_bash(["-c", workflow_import()], extra={**SIGNING, **APPLE, "FAIL_NOTARY": "1"})
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(self.calls("xcrun")), 1)


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS system plutil")
class NotaryResponseTests(unittest.TestCase):
    def parse_response(self, response):
        source = (ROOT / "script/release").read_text()
        validation = source.split('    cat "$TEMP/result.json"\n', 1)[1].split(
            '    if [[ "$STATUS" != Accepted', 1)[0]
        with tempfile.TemporaryDirectory(prefix="toy-box-notary-response-") as temporary:
            (Path(temporary) / "result.json").write_text(response)
            return subprocess.run(
                ["/bin/bash", "-eu", "-c", validation + '\nprintf "%s" "$STATUS"\n'],
                env={"PATH": "/usr/bin:/bin", "TEMP": temporary, "SUBMISSION_STATUS": "0"},
                text=True, capture_output=True, timeout=5)

    def test_real_notarytool_json_is_accepted_by_system_plutil(self):
        response = '{"id":"01234567-89ab-cdef-0123-456789abcdef","message":"Processing complete","status":"Accepted"}'
        result = self.parse_response(response)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Accepted")

    def test_rejected_response_preserves_its_status(self):
        result = self.parse_response(json.dumps({"id": "fake-submission", "status": "Invalid"}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Invalid")

    def test_malformed_or_missing_status_fails_explicitly(self):
        for response in ("", "{", '{"id":"fake-submission"}'):
            with self.subTest(response=response):
                result = self.parse_response(response)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("without a valid submission response", result.stderr)


if __name__ == "__main__":
    unittest.main()
