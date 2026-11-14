# Distribution

This document covers how Toy Box for Apple is signed, packaged, updated and distributed. The Mac
app ships from tagged GitHub releases and updates itself in place with Sparkle. The iPhone app
ships through TestFlight on its own tags. Product behavior lives in the [spec](../../../../docs/spec.md).

## Mac releases

Releases are Developer ID signed, notarized and stapled, then published with their SHA-256 checksum
and Sparkle appcast by `.github/workflows/build-and-release.yml` on an approved `vX.Y.Z` tag.
A manual run on `main` performs the same signing, notarization and appcast generation but keeps them
as artifacts, without publishing.
Local builds use Command Line Tools. CI uses its selected Xcode 27 toolchain on the `xcode-27` runner.
Checks run for pull requests and pushes to `main`, not standalone branch pushes. A newer revision
cancels unfinished checks for the same pull request or ref. Release tags and manual dry runs retain
their serialized, non-cancellable publication group. Tooling typechecking and workflow linting run
on Linux. Native bundling, Siri metadata and signing checks run in the Mac release job.
The Mac gate emits unbuffered test progress. Its twelve-minute watchdog samples only its own
SwiftPM and XCTest descendants, prints their stacks and uploads diagnostics before failing.
The job has a twenty-minute limit. It runs ToyBoxClient with
`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` before the full suite, so test gates must suspend rather than
block a cooperative worker.
The iOS gate stops a suite that prints nothing for three minutes, well inside its 25-minute job. It
prints the call graph of that suite's own `xctest` process and the suites and tests that started
without finishing, then ends the process before the simulator shuts down. It never retries.

Every normal bundle embeds `Contents/PlugIns/ToyBoxDesktopShare.appex`, a SwiftPM executable linked with
`_NSExtensionMain` for `com.apple.share-services`. Its activation rules accept text, URLs, images
and files. It performs no networking and presents no editor. It loads the explicit items into a
uniquely named `dev.toybox.desktop.share.<UUID>` pasteboard, then opens
`toybox-desktop://quick-send?pasteboard=<name>`. Quick Send imports and clears that pasteboard,
preserving drafts and requiring an explicit send. Image bytes are loaded before the extension
completes so a provider's temporary URL cannot expire underneath the host.
Only in-place non-image files are passed as paths. Temporary/provider-only non-image files and
sandbox-container paths are rejected explicitly, rather than giving an agent an expired or
inaccessible path. Arbitrary files are never uploaded.

The extension has only App Sandbox, with hardened runtime and a secure timestamp in releases.
Its ID is the containing app's ID plus `.share`, and its version and build match the app.
Inside-out signing verifies the extension before signing the container, without `--deep`.
Validation checks its architecture, SDK stamp, extension point, metadata, signature and entitlements.
Isolated validation/benchmark bundles and snapshots remove Share, Services, URL-scheme and document
registrations so they cannot take over the user's integrations.

The app's bundle identity is `dev.toybox.desktop`. Agent validation uses `dev.toybox.desktop.test`,
and the benchmark uses `dev.toybox.desktop.benchmark`, keeping their preferences and permissions
isolated from the user's app.

Only the certificate owner runs the one-time setup:

```sh
bun run setup-secrets SHA1 APPLE_ID TEAM_ID
```

It uses an Apple ID and an app-specific password from account.apple.com. Its silent prompt reads
the password without echoing or logging it, and accepts piped stdin with or without a trailing
newline. Never pass the password as a script argument. The command optionally accepts `OWNER/REPO`
as the final argument and configures the local
`toy-box-channels-notary` keychain profile plus GitHub's `MACOS_SIGNING_CERTIFICATE`,
`MACOS_SIGNING_PASSWORD` and `NOTARY_APP_PASSWORD` secrets, plus the Sparkle archive-signing key
described below. Setup exports only the pinned
certificate's identity into a temporary encrypted file, then removes it on exit.

Setup writes the selected public certificate SHA-1 to `MACOS_SIGNING_IDENTITY`; the workflow reads
that variable, not a hard-coded fingerprint. Apple ID (`joncart@outlook.com`) and Team ID
(`RHFNBL7EG4`) are public account settings. Setup also exports the verified public issuer chain
to `MACOS_SIGNING_CERTIFICATE_CHAIN`, alongside the encrypted identity, allowing issuer renewal
through setup without a workflow edit. CI stores the notarization login in a temporary keychain
profile. Missing or rejected credentials fail the release explicitly.

Agents never run setup with real credentials or read signing keys and passwords.
For a local release, set `SIGNING_IDENTITY=SHA1`,
`BUILD_NUMBER=N` and `NOTARY_PROFILE=toy-box-channels-notary` when invoking `bun run release vX.Y.Z`.
Without a notary profile, the archive is named `SIGNED-UNNOTARIZED` and is never published.
The release script uses Bun's native JSON parser for notarization responses and requires a
string status before accepting one.

### In-place updates

Sparkle 2.10.0 is an exact SwiftPM dependency of the app target. Every bundle includes the framework,
`Autoupdate` installer and `Updater.app`, thinned to arm64, with symlinks and license notices
preserved. Headers, modules and sandbox-only XPC services are omitted. The framework adds about
1.3 MB installed, or 0.5 MB compressed. Signing proceeds from installer to updater to framework to
app, verifying each component strictly and never using `--deep`. Developer ID releases use hardened
runtime and secure timestamps throughout. Ad-hoc development signing does not enable hardened
runtime, because library validation cannot match Team IDs between ad-hoc-signed binaries.

Only `bun run release` adds the production `SUFeedURL` and `SUPublicEDKey`. The stable feed is
`https://github.com/lostintangent/toy-box-apple/releases/latest/download/appcast.xml`, and every
enclosure points at that version's GitHub release asset URL. Development, validation,
snapshot and test bundles have no feed or verification key and never start an updater. Release
bundles enable automatic checking without Sparkle's permission prompt, but leave automatic
installation off by default. Both choices remain user-configurable through Sparkle.

The same `bun run setup-secrets` command makes Sparkle generate or reuse the
app-specific `dev.toybox.desktop` Keychain account, without touching its global default key.
Setup uploads the exported key as `SPARKLE_ED_PRIVATE_KEY`, configures `SPARKLE_ED_PUBLIC_KEY` as a
public repository variable, and removes the temporary export. The archive key is independent of
Apple, but disposable: a new Mac creates a replacement if the old Keychain account is unavailable.
Sparkle authorizes that replacement when the update satisfies the installed app's Developer ID
signing requirement and its archive matches the new embedded key. Keep the bundle ID and Apple
team unchanged. Agents never run this setup with real credentials or read that key.

The active Sparkle Keychain account is `dev.toybox.desktop`. Computer Use needs approval for
`dev.toybox.desktop.test`.

After notarization and stapling, the workflow's `scripts/desktop/release/appcast.ts` helper uses Sparkle's checksum-pinned tools to
sign the finished archive with Ed25519. It reads the private key on stdin from
`SPARKLE_ED_PRIVATE_KEY`, or from an explicit `SPARKLE_ED_KEY_FILE` in isolated tests, and never
from the default Keychain. The archive signature, length, URL,
machine and human-readable versions, and minimum macOS version are checked before publishing.
The archive signature is verified with `sign_update`. The feed and release notes are not separately
signed, and `SUVerifyUpdateBeforeExtraction` / `SURequireSignedFeed` stay absent. This trades the
extra pre-extraction/feed checks for normal Sparkle key rotation through Apple code signing.
The matching `## Mac X.Y.Z` changelog entry supplies
both Sparkle and GitHub Release notes. There is no tag-annotation or commit-message fallback.
Deltas are intentionally omitted
for these small apps.
Both the feed and zip are attached to every release and retained by dry runs.

`CFBundleVersion` is `github.run_number.github.run_attempt`. Release workflows are serialized, and
the new numeric build must exceed every version in the latest published appcast. Missing or
malformed prior metadata fails the release instead of allowing a downgrade. The first Sparkle
release bootstraps from 0.1.0, which has no feed and must be upgraded manually. Local releases can
set `PREVIOUS_APPCAST` to apply the same monotonicity guard.

Tooling is grouped by platform under `scripts/desktop/` and `scripts/mobile/`. Each contains
one-time `setup-secrets.ts`, Swift `test.ts`, `bundle/` for building and signing, `dogfood/` for
running and measuring development builds, and release tooling. Commands with helpers use their
folder's `index.ts`. Mac distribution uses `desktop/release/index.ts`; the phone's standalone
TestFlight command is `mobile/release.ts`. The phone's `dogfood/boot.ts` owns simulator preparation,
`drive.ts` runs scripted taps and captures, and `drives/` contains those scripts.
Mirrored filenames across platforms are intentional, with no ambiguous duplicates within a platform.

`scripts/demo-server/` serves sample channels for either app's development, screenshots and
write tests without touching real channels. Its `channels/` helpers supply the sample content
and push routes. Common commands live in `scripts/shared/`, with helpers in `lib/`.
[scripts/README.md](../../../../scripts/README.md) lists every package command, its file, purpose and operator.
Platform folders never import each other. CI calls release-only helpers by path rather than exposing
unused package commands.

There are no script tests. CI keeps `bun check` and
`bun run lint:workflows`. Any change to bundle or release tooling requires both real release
dry runs to pass. Bun 1.4.4 is pinned in the package metadata and CI, and setup-bun is commit-pinned
on both runner platforms. Every workflow action is pinned to a full commit hash with a readable version
comment, and Dependabot checks them weekly. Scripts use TypeScript, Bun Shell and native file and XML APIs.
The sole `.sh` helper uses Bash's silent `read -rs` for the
user-only credential prompt. Native Swift helpers handle Security-framework identity export and
AppKit icon rendering.

## iPhone TestFlight

Before the first signed build, the **user** confirms an active Apple Developer team, accepts
pending agreements, registers the explicit App ID `dev.toybox.mobile` and creates its App Store
Connect app. TestFlight also needs an Apple Distribution certificate, App Store Connect profiles,
required metadata, privacy and export-compliance answers and tester access, plus beta review for
external testers.

`bun run testflight` is independent of the Mac release. It builds optimized arm64 with
the selected Xcode 27+ iPhoneOS SDK through SwiftPM, without an Xcode project or Simulator.
`--version X.Y.Z` / `MOBILE_VERSION` sets the marketing version. `--build-number N` / `BUILD_NUMBER`
sets the build and is required for validate/upload. Choose an unused number; App Store Connect
rejects reused numbers, including uploads from other machines. Build-only may use the source
plist's build. There is no local counter or TestFlight lease; use your own scratch path.

The user supplies an Apple Distribution identity and four explicit, unexpired App Store Connect
profiles through the `MOBILE_PROVISIONING_PROFILE`, `MOBILE_WIDGET_PROVISIONING_PROFILE`,
`MOBILE_NOTIFICATION_PROVISIONING_PROFILE` and `MOBILE_SHARE_PROVISIONING_PROFILE` selectors.
They must share a team/certificate, grant
the App Group capability, and grant production Push on
the host. Development, ad-hoc, enterprise and wildcard profiles are rejected. Extensions embed
their own profiles and sign before the host, whose actual signed entitlements are verified.
There is no `get-task-allow`, bundled server address, DEBUG driver or proof fixture. First launch
asks the tester for a server.

The phone selects its server from `--server`, then `TOY_BOX_SERVER_URL`, then saved Settings,
in that order. Launch overrides are session-only and never overwrite saved Settings. With none
configured, it shows Connect to Toy Box. There is no bundle fallback.

Every component declares the `arm64` required device capability and has the same version/build,
`ITSAppUsesNonExemptEncryption=false` and real Xcode,
SDK, platform and build-machine metadata. The privacy manifests declare host-local UserDefaults
(`CA92.1`), cache file timestamps (`C617.1`) and elapsed animation timing (`35F9.1`); the three
extensions declare only the timing API present in their linked shared presentation code.
App Group state uses files, not shared UserDefaults. No disk-space API is used. See Apple's
[required-reason policy](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

`APP_STORE_CONNECT_USERNAME` and numeric `APP_STORE_CONNECT_APP_ID` identify the account/app.
Apple tools use only `@env:NOTARY_APP_PASSWORD`, locally and in CI. The user supplies the
app-specific password. After setting the account/app identifiers, a local validation from the
repo root prompts silently and passes only an environment reference to Apple's tool:

```sh
NOTARY_APP_PASSWORD="$(bash scripts/shared/lib/read-password.sh 'App-specific password: ')" bun run testflight --validate-only --build-number N
```

Omit `--validate-only` to upload. No password is passed as a shell argument or stored by the
release tools. Apple's tool performs authentication. Agents never create accounts, profiles or credentials,
accept agreements, read keys/passwords or run real credential setup.

The IPA contains `Payload/Toy Box.app`, whose `Metadata.appintents` lets Siri see the phone's
App Intents when it declares any. `altool --validate-app` must pass before upload.
`--validate-only` signs/packages and validates without uploading; `--build-only` creates an
unsigned App Store-form bundle without profiles or credentials. `altool --upload-package` succeeds
when its command exits zero. Print its output unchanged, without assuming it is one JSON document.
Do not pass `--wait` or poll for processing. Upload acceptance and Apple processing are separate:
finish with "Uploaded. Apple is processing it, and TestFlight shows it when that's done."
A failed or interrupted command must not trigger another upload before checking App Store Connect.
Keep the signed IPA and notes even if delivery fails. Upload success does not claim that a tester
group has access.

After local qualification, `.github/workflows/mobile-release.yml` handles only `mobile-vX.Y.Z` tags,
independently of the Mac's `vX.Y.Z` release line. Both require one nonempty matching
`## Mac X.Y.Z` / `## iPhone X.Y.Z` entry in root `CHANGELOG.md` before release building or credential
access. `MOBILE_VERSION` must match the phone tag. The mobile workflow serializes its own publishes,
uses Xcode 27's device SDK without a Simulator and calls the same `testflight` command.
Manual dispatch on `main` adds `--validate-only`, so it never uploads. CI uses
`github.run_number.github.run_attempt`; use build `1` for the first local upload so it precedes the
first CI build `1.1`.

The user runs `bun run setup-secrets:mobile SHA1 APP_STORE_CONNECT_APP_ID [OWNER/REPO]`.
The shared signing selector validates the four App Store profiles and chosen Apple Distribution
identity before export. The setup generates a random export encryption password, which is not the
Apple Account password, and stores it as the `MOBILE_SIGNING_PASSWORD` secret. Six secrets hold the
encrypted certificate, its password and the four profiles. Public variables hold the certificate
fingerprint, verified issuer chain and numeric app ID. The existing `NOTARY_APP_PASSWORD` is reused
for uploads without reading or replacing it during setup.
Temporary export files are removed even on a failed secret upload.

The mobile job imports its identity and exported verified issuer chain into an isolated
temporary keychain and uses profile files only under the runner's temporary directory. Cleanup
restores the original keychain search list and removes signing material, including failures.
No iPhone GitHub Release is created, so the Mac's latest-release feed remains untouched.
The iPhone changelog entry is retained as a workflow summary/artifact. Apple's documented per-build
notes endpoint uses API-key authentication; the installed `altool --beta-app-store-text` exposes
marketing-version metadata but no verified per-build password path. “What to Test” remains manual
until that path is proven. No API key is required or read by the release tools.

## Recovery without laptop-held backups

Actions holds the working signing material, so publishing does not use this Mac. If the laptop or
repository secrets are lost, sign in to the same Apple account/team on another Mac, make new
Developer ID and Apple Distribution certificates and matching App Store profiles, then rerun
`setup-secrets` and `setup-secrets:mobile`. They update
their public fingerprint/issuer-chain variables and encrypted identity exports. No workflow edit
or private-key backup is required. Apple account access and the app/team identities must be retained.

The Mac setup also recreates the Sparkle key when its Keychain account is unavailable. Sparkle 2.10's normal update
validator allows that rotation through the installed app's Apple signing requirement, while still
requiring the new archive signature to match its embedded public key. Current v0.1.8 installs have
the stricter feed/pre-extraction policy and need a one-time manual installation of this replacement.
No actual key rotation or credential setup is performed by agents.

The current Developer ID certificate expires February 1, 2027. Renew it and rerun setup before then.
