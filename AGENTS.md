# Toy Box

Toy Box is a native SwiftUI client for Toy Box Channels. [docs/spec.md](docs/spec.md) is
the source of truth for parity, protocol and design. Read its Design section before changing any
view.

## Tech stack

- SwiftUI, with AppKit where SwiftUI falls short. Swift 6.4 and SwiftPM, with no Xcode project.
  macOS 27 on Apple Silicon only.
- `ChannelKit` is the domain: Codable models, the reducer, transcript grouping, attention, tasks
  and cron. `ChannelClient` is transport: HTTP commands, SSE, reconnect and observable stores.
  `ChannelIntelligence` is on-device Foundation Models. `ToyBoxDesktop` is the app.
- It talks to the same `/api/v1` HTTP and SSE routes as the Minecraft client. The conformance
  fixtures are copied unchanged from that client.

## Build and run

- Tooling uses Bun 1.4.4. Run `bun install --frozen-lockfile` once, then use the root `package.json`
  commands. `scripts/dev/` owns local development, `scripts/release/` owns packaging and release
  checks, and `scripts/fixtures/` owns demo servers and fixture generation. Use Bun's native
  `bun check` directly, without installing TypeScript. `bun run test:release` and
  `bun run lint:workflows` cover release behavior and workflows.
- Use `bun run test` for Swift tests. Bare `bun test` only runs the TypeScript tooling tests.
- Build only with Command Line Tools. Never use `xcodebuild`. `bun run app` runs Xcode's `appintentsmetadataprocessor` directly for
  Siri and Shortcuts, which needs Xcode installed but not its license.
- Target macOS 27 or later on Apple Silicon with Swift tools 6.4 or later. `bun run app` stamps the real SDK
  version before signing. Use its bundle for native visual checks, not SwiftPM's unstamped
  executable. `bun run validate` rejects bundles whose recorded SDK is below macOS 27.
- Use your own scratch path so parallel builds never share `.build`:
  - `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path /tmp/tbm-<you>`
  - `SCRATCH_PATH=/tmp/tbm-<you> bun run test` runs the suite with the Command Line Tools
    Testing macro plugin path, which a bare `swift test` can't find. It also fails when a test
    run stops before printing its summary, which a bare `swift test` can report as success.
  - `SCRATCH_PATH=/tmp/tbm-<you> bun run app` builds, bundles and opens a new app instance.
- Point the app at a server with `TOY_BOX_SERVER_URL` or Settings. Use our Minecraft demo wrapper
  (`bun run demo` in this repository, port 3210) for write tests. It serves the required
  catalog lead profile without modifying the reference. The live server
  on port 3100 hosts real channels: read it freely, but never post or mutate there without the
  lead's approval of a specific scratch channel.
  Leave its current process running.
- `bun run history-demo` imports that reference factory read-only and serves `history-demo`
  on 3211 with 480 messages, canonical 100-message older pages and isolated read receipts. Use it
  for paging and key-window read checks without disturbing the shared 3210 screenshot baseline.
- Integration tests are opt-in: `TOY_BOX_DEMO_URL=http://127.0.0.1:3210 bun run test`, and
  `TOY_BOX_HISTORY_DEMO_URL=http://127.0.0.1:3211 bun run test --filter HistoryFixtureTests`
  against a freshly started history demo.
- `TOY_BOX_REAL_DICTATION_TESTS=1 bun run test --filter ComposerTests/theRealTranscriberHearsARecordingThroughTheAudioSourceProtocol`
  opts into the real transcriber check. It needs the on-device English dictation model and uses
  synthesized audio, not microphone access. The normal suite never queries speech-model assets.
- `TOY_BOX_TEST_TRANSCRIPT_TIMING=1 SCRATCH_PATH=/tmp/tbm-you bun run test --filter 'Transcript|ImageViewer'`
  opts into native Transcript frame-timing and VisionKit selection-layer checks. Run these locally
  before changes to landing, paging, following arrivals or native image text selection.
- `TOY_BOX_TEST_LIVE_TEXT_INTERACTION=1 SCRATCH_PATH=/tmp/tbm-<you> bun run test --filter pressesOnTextReachLiveTextAndEverythingElseReachesTheViewer`
  opts into native Live Text press/drag routing in an ordered off-screen window. WindowServer
  events can stop the test runner's outer run loop. VisionKit analysis and deterministic geometry
  and routing-policy checks remain in the default suite.
- `SCRATCH_PATH=/tmp/tbm-<you> bun run benchmark [--summaries] [launch|switch|messages|paging|key|idle ...]` is the
  performance regression benchmark. It builds a release bundle as `dev.toybox.desktop.benchmark`,
  runs each scenario against a fresh `bun run perf-demo` fixture on 3292 (`TOY_BOX_PERF_PORT`),
  prints each result beside its budget and exits 1 when one is over. The spec's Performance budgets
  section defines the budgets and how busy time, saturated spans and frame gaps differ. Leave its
  window uncovered. `key` runs only when named, because it takes focus for about 45 seconds to
  measure CPU in a key window with 4 and then 20 working agents, where a continuous animation shows
  up. Warn the user before running it.
  Catch-up summaries stay off so the card can't land mid-measurement. `--summaries` leaves them on.
  Only one benchmark runs at a time on this Mac. Others wait for it, so never poll for one yourself.
  Compare actual main-thread CPU work when the Mac is loaded: scroll reports CPU ms per 1,000
  native points and paging reports CPU ms per older page, both informational. Judge wall-clock
  hitches only on a quiet machine, since run-loop busy time includes scheduling delays.
- `bun run generate-cron-fixtures ../toy-box` regenerates the cron fixtures from the
  reference without touching it.
- Quit the instances you launch when you are done.
- Attach channel images from your own session `files/` folder, never `/tmp`. Toy Box serves
  attachments from their original paths, so a cleaned scratch folder breaks earlier posts.

## Test reliability

- A test that fails on main without an identified code cause must be quarantined behind an
  explicit opt-in the same day. Do not leave it in the merge gate while rerunning CI or patching
  timing races in place. Record the failed run, test case and diagnostics, with an owner and
  follow-up task. Quarantine changes gating, not responsibility for the failure.
- CI should protect decisions with deterministic tests over inputs such as measured frames.
  Native window tests in CI may assert settled end states, never per-frame timing. Frame-timing
  and WindowServer-event checks remain opt-in and must run locally before changes to their behavior.
- Restore a quarantined test to CI only after identifying the cause and adding deterministic
  regression coverage. Do not loosen assertions or add retries to turn an unexplained failure green.

## Validating the running app

- Snapshots: `SCRATCH_PATH=/tmp/tbm-<you> bun run snapshot --server http://127.0.0.1:3210
  --channel studio-demo --appearance light|dark --size 1280x840 --snapshot <file.png>
  [--state <name>]`. Snapshot mode never marks read, saves settings or posts notifications.
  It opens the normal SwiftUI scene, disables restoration only in the process's volatile
  argument domain, and refuses application-state saving/restoration. Attached native sheets
  render their own layer trees into the parent PNG. These static renders do not prove native
  interaction or capture WindowServer shadows and corner masks.
  With the real 27+ SDK stamp, they also misrender Liquid Glass and sidebar selection. Use
  them for layout evidence only. Verify materials, selection and scroll-edge effects in a real window.
- Computer Use approves apps by bundle ID. A path is refused. The user's copy is
  `dev.toybox.desktop`. Agents test as `dev.toybox.desktop.test` ("Toy Box
  Test" in `.build/agents`), which `bun run validate` builds and launches. Instances that share a
  bundle ID can be read but not clicked, so the separate ID is what lets you interact while the
  user's app is open. Until the user approves the test ID, `bun run validate` falls back to the
  shared bundle and says so. It unregisters pre-rename `Toy Box Desktop Test.app` copies of
  the test identity before registering `Toy Box Test.app`, without deleting those bundles or
  changing the user's app registration.
- Launch your own build in the background against the demo:
  `open -n -g "/tmp/tbm-<you>/Toy Box.app" --args --server http://127.0.0.1:3210 -ApplePersistenceIgnoreState YES`.
  `-g` keeps it from taking the user's focus. A `--server` or `TOY_BOX_SERVER_URL` launch is
  session-only and never replaces the server the user saved in Settings.
  `-ApplePersistenceIgnoreState YES` keeps test instances from restoring or overwriting the
  saved window state they share with the user's app. Keep it for validation isolation even
  though the normal launch fallback now handles a restored zero-window state.
- A Computer Use session binds to the first bundle path it inspects and then rejects windows from
  other paths ("no longer belongs to the approved app"). Keep using that one path. Run
  `SCRATCH_PATH=/tmp/tbm-<you> bun run validate`, which always builds with `CONFIGURATION=release`,
  swaps that optimized build into both bundles without disturbing running instances, and launches
  the test bundle in the background against the demo. Judge feel with these optimized bundles.
  Quick `bun run app` loops still default to debug.
- Clicks only work while one instance has the test ID. If a click fails with "no perception
  baseline for this pid", another agent's test instance is running, so wait for it to quit.
  Reads still work, so call `list_apps` and pass your own `window`. Before acting, confirm the
  window shows the demo server's `studio-demo`. Never act in a window that lists live channels,
  because it may be the user's own app.
- Quit your instance with `kill <pid>` when you finish.

## Swift conventions

- The macOS 27 CLT SDK exports an unusable `@State` macro. Use `@ViewState`, which aliases
  `SwiftUI.State`.
- `ChannelKit` owns domain semantics and `ChannelClient` owns transport and stores. Views never
  reimplement reducer, audience, task, attention or transcript-grouping rules. Ask Core for a
  domain or store change instead of working around it in a view.
- `TranscriptView` is ChannelKit's message filter enum, so SwiftUI views use other names.

## Client rules

- Management writes are never retried. A 422 is a rejection, but a 500 may have committed, so
  call `reconcileManagementWrite(channelId:)` before offering another attempt.
- A send makes one attempt with a caller-owned UUID, kept in a per-channel outbox until confirmed.
  Send Again reuses that UUID, so the server can't deliver it twice.
- Reading never answers a request. Reconnects resume from the last applied revision.
- The catalog's `lead` profile is required. Treat a missing one as a protocol error, and never
  substitute client art.

## Releases

- Workflow actions stay pinned to full commit hashes with readable version comments. Dependabot
  checks them weekly. The Release checks job validates workflows and credential-free release tools.
- Push a `vX.Y.Z` tag, only with the user's approval. Actions tests the tag, then signs,
  notarizes, staples and publishes the zip, its checksum and a signed `appcast.xml`. Running the
  workflow by hand on `main` is a dry run that keeps all three as artifacts.
- One-time setup, by the certificate owner only:
  `bun run setup-release-secrets SHA1 APPLE_ID TEAM_ID`, using an Apple ID app-specific password
  entered at the silent prompt or piped on stdin, never as a script argument. This configures the
  local `toy-box-channels-notary` profile and three GitHub secrets: `MACOS_SIGNING_CERTIFICATE`,
  `MACOS_SIGNING_PASSWORD` and `NOTARY_APP_PASSWORD`. The workflow pins the public certificate SHA-1,
  Apple ID and Team ID directly. Keep them in sync with the setup arguments when rotating identities.
  Agents never run setup with real credentials, create
  secrets or read keys and passwords. `bun run test:release` uses fake commands only unless the
  native checks are explicitly enabled. The only shell helper is `read-password.sh`, whose
  `read -rs` handles terminal echo and piped input without a custom terminal implementation.
- Update signing setup, by the user only: `bun run setup-update-secrets [OWNER/REPO]`. It reuses
  or creates the `dev.toybox.desktop` Sparkle Keychain account, uploads `SPARKLE_ED_PRIVATE_KEY`
  as a secret and `SPARKLE_ED_PUBLIC_KEY` as a public repository variable, then deletes its temporary
  export. Back up that Keychain key. Do not replace it casually, since existing installs trust it.
  Agents never run this setup or read the real key. The opt-in native appcast check in
  `scripts/release/tests/native.test.ts` uses a throwaway CryptoKit key file, never a Keychain item.
  Run it with `TOY_BOX_BUNDLE=<app> SPARKLE_TOOLS_DIR=<tools> bun test scripts/release/tests/native.test.ts`.
- The update signing key uses the `dev.toybox.desktop` Sparkle Keychain account.
- Locally: `SPARKLE_ED_PUBLIC_KEY=... SIGNING_IDENTITY=SHA1 BUILD_NUMBER=N NOTARY_PROFILE=toy-box-channels-notary
  bun run release vX.Y.Z`. Without `NOTARY_PROFILE` the zip is named `SIGNED-UNNOTARIZED` and
  is never published. `PREVIOUS_APPCAST=path` enforces an increasing build number locally. CI always
  compares against the latest published feed and serializes release workflows. Its build number is
  `github.run_number.github.run_attempt`, so reruns advance too.
- Hardened runtime and a secure timestamp throughout. The app has only audio-input permission.
  `Contents/PlugIns/ToyBoxShare.appex` has only App Sandbox, no network or file-access entitlement.
  Its identity is the app's ID plus `.share`, with matching version/build, signed before the app.
  Never `--deep`. Validation checks its arm64 architecture, SDK stamp, signature and sandbox.
  Local builds use Command Line Tools, and CI uses the runner's selected Xcode 27 on `xcode-27`.
- The Share extension is built by SwiftPM with `_NSExtensionMain`, without Xcode or a storyboard.
  It loads only explicitly shared items, writes `dev.toybox.desktop.share.<UUID>` pasteboards,
  and opens `toybox-desktop://quick-send?pasteboard=...`. The host imports and clears that board.
  It never sends automatically or connects to a server. Test/validation/benchmark clones and
  snapshots omit the extension, Services, URL schemes and document handlers to avoid taking over
  the user's integrations. To check registration, use `pluginkit -m -v -i dev.toybox.desktop.share`
  on a normal built bundle, not an isolated validation clone.
- Sparkle is pinned to 2.10.0 in SwiftPM. Every bundle embeds its arm64-only framework, installer
  and updater, without sandbox XPC services or development headers. `bun run sign-app` signs those
  components inside out before signing the app. Keep Sparkle's license in the bundle.
- Only release bundles receive `SUFeedURL` and `SUPublicEDKey`. All other bundles have no updater,
  even if the user previously enabled it in preferences. The release feed is
  `https://github.com/lostintangent/toy-box-apple/releases/latest/download/appcast.xml`.
  Automatic checking defaults on without a permission prompt. Installation remains opt-in.
  `bun run generate-appcast` runs after notarization and verifies both the archive and feed signatures.
  It accepts the private key on stdin from `SPARKLE_ED_PRIVATE_KEY`, or an explicit
  `SPARKLE_ED_KEY_FILE` for isolated testing. It never falls back to a default Keychain key.
- The Developer ID certificate and its G1 intermediate expire February 1, 2027. Before then, move
  to a G2 certificate, rerun the setup, and update the workflow's intermediate URL and SHA-256.
- The app icon's only source is `Resources/AppIcon.icon` (Designer). After changing it, run
  `bun run icon` and commit it with `Resources/AppIcon.icns` and `Resources/Assets.car`. Generation
  needs Icon Composer and Xcode's `actool`. Builds only copy these outputs, so CLT builds and CI
  need neither tool. `CFBundleIconName` selects the layered dark, clear and tinted appearances;
  the `.icns` stays the fallback.
- Never alter the user's installed validation bundle or microphone permission state to test a
  release.

## Source ownership

| Path | Owner |
| --- | --- |
| `Sources/ChannelKit/`, `Sources/ChannelClient/`, `Tests/` (except below), `scripts/`, `Package.swift`, `package.json` | Core |
| `Sources/ToyBoxDesktop/App`, `Shell`, `Sidebar`, `Settings`, `Shared`, `Channel/ChannelDetailView.swift` | Shell |
| `Sources/ToyBoxDesktop/Transcript`, `Tests/ToyBoxDesktopTests/TranscriptTests.swift` | Transcript |
| `Sources/ToyBoxDesktop/Composer` (composer and tray), `Tests/ToyBoxDesktopTests/ComposerTests.swift` | Composer |
| `Sources/ToyBoxDesktop/Overview`, `Management` | Overview |
| `Sources/ChannelIntelligence/`, `Tests/ChannelIntelligenceTests/` | Intelligence |

UI engineers may add one `Tests/ToyBoxDesktopTests/<Surface>Tests.swift` file for their own surface.

Edit only files you own. Ask the owner for anything else in the channel.

## Seams between surfaces

- `AppModel` (environment): server URL, `ChannelCatalogStore` and its `ChannelAPI`.
- `ChannelStore` (passed in): one per channel, shared by every window that shows the channel.
- `ChannelInteraction` (environment, one per channel window) carries cross-surface intents:
  Reply, Focus Composer, Reveal message, Jump to Latest, the Message View filter and inspector
  visibility. Any owner may add a narrowly scoped intent here. Announce it in the channel.
- `ManagementPresenter` (environment, one per window): `present(_:)` opens any management flow.
  Overview implements the flows behind it. Every other surface only calls `present`.
- `AgentAvatarView` (Shared) renders agent identity exactly like the pane's `AgentAvatar`.
