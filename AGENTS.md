# Toy Box

Toy Box is a native SwiftUI client for Toy Box Channels. [docs/spec.md](docs/spec.md) is
the source of truth for parity, protocol and design. Read its Design section before changing any
view.

## Tech stack

- SwiftUI, with AppKit where SwiftUI falls short. Swift 6.4 and SwiftPM, with no Xcode project.
  macOS 27 on Apple Silicon, plus the iOS 27 iPhone companion in `Sources/ToyBoxMobile`.
- `ChannelKit` is the domain: Codable models, the reducer, transcript grouping, attention, tasks
  and cron. `ChannelClient` is transport: HTTP commands, SSE, reconnect and observable stores.
  `ChannelIntelligence` is on-device Foundation Models. `ToyBoxUI` is shared SwiftUI presentation
  without AppKit or UIKit. `ToyBoxDesktop` and `ToyBoxMobile` own native platform integration.
- It talks to the same `/api/v1` HTTP and SSE routes as the Minecraft client. The conformance
  fixtures are copied unchanged from that client.

## Build and run

- Use Bun 1.4.4 and root `package.json` commands after `bun install --frozen-lockfile`.
  `scripts/desktop/` and `scripts/mobile/` own their platform tooling, `scripts/shared/` their
  common commands, and `scripts/demo/` local servers. Each folder's top level contains only
  commands named for what they do. See [scripts/README.md](scripts/README.md) for the command table.
  Helpers live in `bundle/`, Mac `release/`, mobile `drive/` and shared `support/`.
  Platform folders never import each other. Use native `bun check`, without installing TypeScript.
  `bun test scripts` keeps release/signing contracts, not development-tool or workflow-text tests.
  `bun run lint:workflows` validates workflows.
  Workflow shell checks gate warnings and errors, not style hints.
- Use `bun run test` for Swift tests. Bare `bun test` only runs the TypeScript tooling tests.
- Mac builds use only Command Line Tools. iOS uses Xcode's toolchain/SDK through SwiftPM,
  not `xcodebuild`. `bun run build` invokes Xcode's `appintentsmetadataprocessor` for Siri/Shortcuts,
  requiring Xcode installed but not its license.
- Target macOS 27+ on Apple Silicon with Swift tools 6.4+. `bun run build` stamps the real SDK
  before signing. Use that bundle for native visual checks, not SwiftPM's unstamped executable.
  `bun run validate` rejects recorded SDKs below macOS 27.
- Use your own scratch path so parallel builds never share `.build`:
  - `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path /tmp/tbm-<you>`
  - `SCRATCH_PATH=/tmp/tbm-<you> bun run test` supplies the Command Line Tools Testing macro plugin
    path and rejects runs without a summary, unlike bare `swift test`.
  - `SCRATCH_PATH=/tmp/tbm-<you> bun run build` builds, bundles and opens a new app instance.
- Set the server with `TOY_BOX_SERVER_URL` or Settings. Write tests use `bun run demo` on 3210,
  the Minecraft wrapper serving the required catalog lead profile without modifying the reference.
  Read live 3100 freely, but never post or mutate there without the lead's approval of a specific
  scratch channel. Leave its current process running.
- `bun run demo:history` imports the reference factory read-only: `history-demo` on 3211,
  480 messages, canonical 100-message older pages and isolated read receipts. Use it for paging
  and key-window read checks without disturbing the shared 3210 screenshot baseline.
- Integration tests are opt-in: `TOY_BOX_DEMO_URL=http://127.0.0.1:3210 bun run test`, and
  `TOY_BOX_HISTORY_DEMO_URL=http://127.0.0.1:3211 bun run test --filter HistoryFixtureTests`
  against a freshly started history demo.
- `TOY_BOX_REAL_DICTATION_TESTS=1 bun run test --filter ComposerTests/theRealTranscriberHearsARecordingThroughTheAudioSourceProtocol`
  needs the on-device English dictation model and synthesized audio, not microphone access.
  The normal suite never queries speech-model assets.
- `TOY_BOX_TEST_TRANSCRIPT_TIMING=1 SCRATCH_PATH=/tmp/tbm-you bun run test --filter 'Transcript|ImageViewer'`
  opts into native Transcript frame-timing and VisionKit selection-layer checks. Run these locally
  before changes to landing, paging, following arrivals or native image text selection.
- `TOY_BOX_TEST_IMAGE_STRIP_SCROLLING=1 SCRATCH_PATH=/tmp/tbm-<you> bun run test --filter ComposerTests/imageStripOverflowRespondsToWheelInput`
  opts into native image-strip wheel input. Keep the Mac awake and unlocked. Equal height, hidden scrollers,
  overflow and synchronous native clip scrolling remain in the default suite.
- `TOY_BOX_TEST_LIVE_TEXT_INTERACTION=1 SCRATCH_PATH=/tmp/tbm-<you> bun run test --filter pressesOnTextReachLiveTextAndEverythingElseReachesTheViewer`
  opts into native Live Text press/drag routing in an ordered off-screen window. WindowServer
  events can stop the runner's outer run loop. Deterministic geometry/routing-policy checks remain
  in the default suite. VisionKit analysis is quarantined under Test reliability.
- `SCRATCH_PATH=/tmp/tbm-<you> bun run benchmark [--summaries] [launch|switch|messages|paging|key|idle ...]`
  builds release `dev.toybox.desktop.benchmark`, runs each scenario on a fresh `bun run demo:perf`
  at 3292 (`TOY_BOX_PERF_PORT`), prints result/budget and exits 1 if over. See the spec's Performance
  budgets for busy time, saturated spans and frame gaps. Leave the window uncovered.
  `key` runs only when named, takes focus for about 45 seconds, and measures key-window CPU with
  4 then 20 working agents to expose continuous animation. Warn the user first.
  Catch-up summaries stay off unless `--summaries`. Only one benchmark runs at a time on this Mac.
  Others wait for it, so never poll for one yourself. Under load, compare main-thread CPU:
  scroll's CPU ms per 1,000 native points and paging's CPU ms per older page are informational.
  Judge wall-clock hitches only on a quiet machine, since busy time includes scheduling delays.
- `bun run cron-fixtures ../toy-box` regenerates the cron fixtures from the
  reference without touching it.
- Quit the instances you launch when you are done.
- Attach channel images from your own session `files/` folder, never `/tmp`. Original paths stay
  live, so cleaning scratch would break earlier posts.

### iPhone development

- **Simulator:** `SCRATCH_PATH=/tmp/tbm-<you> bun run simulator` builds, bundles, installs and launches
  `dev.toybox.mobile` on shared **Toy Box Mobile** iPhone Duo. It never opens/focuses Device Hub
  (`com.apple.dt.Devices`). Select that device there and use its native hinge-posture slider.
- **Lease:** one agent at a time. Every simulator command takes a machine-wide `flock`, waits,
  and prints the holder's PID, command and worktree. `bun run simulator --hold` retains it for manual
  checks. Ctrl-C or the 15-minute expiry shuts down and releases it. Never boot another simulator
  or run `simctl` by hand. `MOBILE_SIMULATOR=<UDID>` selects an agreed shared device, not one per agent.
- **Server:** launches explicitly pass `--server`, defaulting to `TOY_BOX_SERVER_URL` or
  `http://127.0.0.1:3210`. `bun run simulator --server <URL>` wins over stale launch environment
  without saving Settings.
- **Capture:** `bun run simulator --screenshot <file.png>` uses the same lock.
  `--hold --screenshot <file.png>` captures the current pose at lease end, before shutdown.
  `--displays` lists native IDs, and `--display <ID>` selects a screenshot display, including Duo's
  secondary display. Wait for visible drawing before ending the lease, not merely a launch PID.
- **Content size:** `--content-size <category>` uses UIKit's process-only preferred-category argument:
  `extraSmall`, `small`, `medium`, `large`, `extraLarge`, `extraExtraLarge`, `extraExtraExtraLarge`,
  `accessibilityMedium`, `accessibilityLarge`, `accessibilityExtraLarge`,
  `accessibilityExtraExtraLarge`, `accessibilityExtraExtraExtraLarge`.
- **Appearance:** `--appearance light|dark` passes `-appearance` in the app's process-only
  argument domain, ahead of saved Settings. It changes neither saved appearance nor the simulator
  preference, so nothing needs restoring. This is app-only, not Home/Lock Screen or widget-host
  appearance. A drive still verifies effective native traits before captures/completion.
  Build-only, capture-only, display-list-only and shutdown-only commands reject launch options.
- **Shutdown:** `bun run simulator --shutdown`.

**Driver.** `--drive <steps.json>` runs a DEBUG-only accessibility script under the lease,
then shuts down on completion/failure. Release builds have neither startup hook nor driver.
No script runs without the explicit per-launch environment. This drives accessibility activation,
native control primary actions and text insertion, not finger touch. Reruns repeat sends:
use demo servers only for write scripts. Never skip or retry actions.

| Step syntax | Contract |
| --- | --- |
| `{"tap":"exact label or identifier"}` | Exact label/identifier, or exact accessibility value for an unlabeled element such as native Search |
| `{"type":"text"}` | Text insertion |
| `{"wait":"label or value fragment"}` | `absent: true` waits for disappearance |
| `{"screenshot":"name","display":1}` | Capture only after settled accessibility/layout |
| `{"back":true}` | Native Back, then public window accessibility escape only if activation is unhandled. Disabled Back never falls through. `ifPresent: true` allows an explicitly optional initial return from restored navigation. Wait for the channel name, then optional Back before tapping its row |
| `{"action":"Reply","on":"message-12"}` | Named accessibility custom action on one exact label or identifier |
| `{"posture":"unfolded","timeout":60}` | Wait for the measured scene, not hinge movement |
| `{"menuAction":"Edit Channel"}` | Visible-menu action dispatch, not a tap. See below |
| `{"scroll":"down","on":"scrollable-list"}` | One public accessibility scroll on that exact unique identifier. Directions: `up`, `down`, `left`, `right`. Missing targets wait within the step deadline. Ambiguous/unhandled actions fail without retries or direct content-offset changes. The target must handle the action. Some SwiftUI Forms decline this, so it is not finger scrolling |
| `{"drag":"up","on":"conversation-transcript"}` | Move the unique UIScrollView's content offset across 80% of its visible size over 24 frames, clamped to content, between delegate begin/end-dragging callbacks. Geometry/scroll phases drive older paging, but there is no pan gesture, deceleration or rubber-banding |

- Each step's timeout is in seconds: default 12, maximum 60. Cancellation/deadline stops drag
  offsets but balances started end callbacks, never reporting completion. Captures wait for settled layout.
- Host acknowledgement requires a settled app accessibility/layout snapshot and both
  `<name>.png` and `<name>.json` under `SCRATCH_PATH/mobile-drive/`, containing its step, state,
  labels and viewport. Later `status.json` cannot erase it. Capture/control children share the step deadline
  and interruption signal. Cancellation kills the exact child and awaits exit before shutdown/release.
- DEBUG status reports loaded-content `traits.contentSizeCategory` / `traits.interfaceStyle`, or
  `traitsError`. Active presented content takes priority, and visible controllers must agree.
  Never force view loading or substitute screen/requested launch traits for measured content.
- Menu dispatch requires one active menu in the current scene and one enabled, visible matching
  leaf. Tag its public accessibility identifier in UIKit's returned copy, require the exact fresh
  tag on a measured native candidate, and restore the original identifier before dispatch/on failure.
  Same-title background controls do not establish ownership. Missing tags fail. Exclude hidden items
  and unopened submenus. Dismiss through UIKit, wait for dismissal/settled layout within the same
  deadline, then perform the retained leaf through public `UIMenuLeaf`. Missing, dismissed, ambiguous
  or changed-scene menus fail explicitly. This proves neither finger selection, menu accessibility
  nor hardware-key delivery.
- Posture requires Computer Use on Device Hub while the driver owns the lease. Confirm its window
  and selected device identify the leased simulator before using native posture controls.
  The SDK 27.1 fixture waits for settled **466x678-point folded** / **669x951-point unfolded** proof
  scenes, not general device/hinge detection. Timeouts report expected and measured scenes and
  stop without retrying. `scripts/mobile/drive/posture.json` checks folded/unfolded/folded
  without sending or editing a draft.
- Observed: native Open then Rotate Right reached unfolded. Displays **1** = folded LCD
  (1398x2034), **3** = unfolded LCD (2007x2853), both 3x. **2** is TVOut, not unfolded.
  Re-enumerate after runtime/device changes, never infer IDs from posture. Slider **0** was folded.
  Unfolded value remains unverified: Computer Use refused setting and advertised increment.
  A requested value is not a measured result. Legacy `{"fold":false}` fails with native diagnostics.
  Never use display-power: it did not change the scene and can crash SpringBoard.
- `scripts/mobile/drive/demo.json` performs a real reply/send and both display captures,
  requires message-row identifiers and baseline request sequence 15, and sends on every run.
  It requires the same live Device Hub posture actions.
- **Build only:** `bun run simulator --build-only` makes the Simulator bundle without booting.
  `bun run testflight --build-only` makes an **unsigned** release arm64 bundle without reading signing
  identities/profiles. Simulator tests always debug, Simulator
  apps default debug. Use `CONFIGURATION=release` for native performance comparisons.
  Output states configuration/optimization.
- **Bundle contract:** before signing, stamp/verify the selected iOS SDK in `LC_BUILD_VERSION`,
  preserving plist deployment minimum and device/Simulator platform. `DTSDKName` alone is insufficient.
  Compile shared `Resources/AppIcon.icon` with the selected platform's `actool`, embedding layered
  appearances, PNG fallbacks and generated metadata. No separate phone artwork/iOS asset catalog.
  Embed `PlugIns/ToyBoxMobileWidget.appex` (`dev.toybox.mobile.widget`) and
  `PlugIns/ToyBoxMobileNotification.appex` (`dev.toybox.mobile.notification`) with SwiftPM
  application-extension safety. Both enter through verified `_NSExtensionMain`, establishing context
  before WidgetKit's generated Swift main/the service. Verify every executable's real SDK stamp.
  Simulator capabilities link into `__TEXT,__entitlements` / `__TEXT,__ents_der`, including all three
  bundles' `group.dev.toybox.mobile`. Ad-hoc signatures have no restricted device entitlements.
  Sign Simulator extensions before host, without device profiles/credentials.
- **On-phone checks:** install through TestFlight. Direct local device installs are retired,
  so development never replaces the user's TestFlight app or data.
  There is no bundled server or Bonjour default. Never save launch overrides in Settings.
  Both apps accept user-selected HTTP/HTTPS, including fully qualified Tailscale names.
  ATS uses `NSAllowsArbitraryLoads` alone, not `NSAllowsLocalNetworking` (which defeats the opt-out).
  Local-network permission is separate. HTTPS retains normal certificate validation.
- **TestFlight:** `bun run testflight [--version X.Y.Z] [--build-number N]` builds release
  arm64, signs the three bundles with matching Apple Distribution/App Store profiles, packages an
  IPA, validates and uploads. A zero altool exit means Apple accepted the upload, not that
  processing or tester availability is complete. Print its output without parsing it as one
  JSON document or polling. `--validate-only` never uploads.
  `--build-only` is unsigned and needs no profiles or credentials. All modes omit a bundled server,
  DEBUG proof code and fixtures. Use `mobile-testflight` under your own `SCRATCH_PATH`.
- **TestFlight setup:** the user creates the App Store Connect app and three explicit App Store
  profiles, with the same App Group capability and production Push on the app.
  Select them with the same `MOBILE_*_PROVISIONING_PROFILE` variables. Set
  `APP_STORE_CONNECT_USERNAME` and numeric `APP_STORE_CONNECT_APP_ID`. Apple tools read the password
  only through `@env:NOTARY_APP_PASSWORD`, locally and in CI. Never pass a password as a shell argument.
  Only the user supplies it. For a local validation from the repo root:
  `NOTARY_APP_PASSWORD="$(bash scripts/shared/support/read-password.sh 'App-specific password: ')" bun run testflight --validate-only --build-number N`
- **TestFlight bundle:** actual Xcode/SDK `DT*` metadata, matching version/build on every component,
  `ITSAppUsesNonExemptEncryption=false`, production push and no `get-task-allow`. Validate/upload require
  `--build-number` / `BUILD_NUMBER`; choose an unused App Store build. Build-only may use the plist's
  build. `MOBILE_VERSION` sets the version. There is no local counter or TestFlight lease. Each
  executable carries its audited `PrivacyInfo.xcprivacy`. TestFlight shows the build after Apple processing.
- `SCRATCH_PATH=/tmp/tbm-<you> bun run test:mobile` builds the iOS tests and runs
  ChannelClient, ToyBoxUI, ToyBoxMobileIntegrations, ToyBoxMobileWidget and ToyBoxMobile
  tests on iOS Simulator via Apple's `xctest` host. ChannelKit/mocked Intelligence execute on Mac
  only but compile in the iOS build. Reject interrupted, failed and empty Swift Testing runs.
  Existing opt-ins stay off. Shut down the simulator only if this command booted it.
- Mobile commands default to `/Applications/Xcode.app/Contents/Developer`. Set `DEVELOPER_DIR`
  to another installed Xcode if needed. Require Swift 6.4 and an iOS 27+ SDK, a Duo runtime for
  the app, or another iPhone's installed 27+ runtime for tests. Never download runtimes.
- These commands set `TOY_BOX_MOBILE=1` for the package's mobile graph and use
  `mobile-simulator` / `mobile-testflight` under `SCRATCH_PATH`. Each links the same manifest,
  sources/tests into a dependency-free workspace. Leave the default graph, Mac build/tests and
  Sparkle lockfile unchanged. Do not export the flag globally, run that graph in the repository
  root or share scratch paths across builds.
- Main/PR CI builds mobile app, extensions and shared modules for Simulator, verifies extension
  signatures, and runs suites only with an installed iOS 27+ runtime, otherwise explicitly skipping.
  Tags/manual release dry runs skip iOS. Mac runs ChannelClient once under the strict cooperative pool,
  then remaining suites. Bundle, Siri and native Sparkle checks run only in the release job.
- The phone widget fetches its saved server through the app's snapshot publisher on every
  timeline refresh, with a ten-second total network deadline. Failed refreshes preserve cached
  requests/last-success time. The notification service requests reload before returning each routed
  alert to iOS. WidgetKit schedules it. Simulator injection never invokes the service: prove real
  APNs-to-service wake on device. Successful Mac catalog polls feed the existing fifteen-minute
  heartbeat even when unchanged. Offline polls never advance last-success time.
- Mobile views use SwiftUI's safe areas, layout margins, size classes and adaptive navigation.
  Never hard-code a safe-area inset, device size or Duo fold width. The layout adapts to the
  scene the system provides. Mockup canvas measurements are not implementation constants.

Before signed TestFlight builds, the **user** must confirm an active Apple Developer team,
accept pending agreements, register explicit App ID `dev.toybox.mobile` and create its App Store Connect
app. TestFlight needs an Apple Distribution certificate, App Store Connect
profile, required metadata, privacy/export-compliance answers and tester access, plus beta review for
external testers.
Agents never create these accounts, accept agreements, read private keys or set up credentials.

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
- Test gates and hooks suspend, never block a cooperative worker. CI runs ChannelClient with
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` to enforce this.
- Client readiness waits use Observation and explicit per-mock request, held-response and stop
  signals, not polling or an elapsed-time assertion. Their suites have a one-minute Swift Testing
  hang limit. Keep actual heartbeat/backoff checks unchanged.
- Read failure diagnostics only after the readiness wait fails, outside Observation tracking.
  Record callback submissions, final phase, applied revision, presence and transport counters before
  disconnecting. Submitted callbacks do not prove URLSession/event consumption. Keep the internal
  per-API trace unset in ordinary clients, and never let recording send mock readiness notifications.

Current opt-ins and restoration conditions follow. Full failed runs, deadlines, logs, causal
comparisons and retained regression contracts are in [docs/test-history.md](docs/test-history.md).

| Test | Opt-in | Owner / condition for restoring merge-gate coverage |
| --- | --- | --- |
| `ToyBoxMobileTests/ComposerTests.audienceCapsuleIsSeparateFromIts44PointRowAndGrowsWithText` | `TOY_BOX_TEST_MOBILE_AUDIENCE_RENDERING=1` | Core, t465 `mobile-audience-capsule-rendering`: identify the transparent center-column render cause and add deterministic regression coverage before restoring |
| `ImageViewerLiveTextTests.onlyTheSettledCurrentImageIsAnalyzedAndTheWindowRemembersIt` | `TOY_BOX_TEST_LIVE_TEXT_ANALYSIS=1` | Transcript: identify cause and add deterministic analysis-gating coverage |
| `imageStripOverflowRespondsToWheelInput` | `TOY_BOX_TEST_IMAGE_STRIP_SCROLLING=1` | Composer: native wheel animation requires awake/unlocked Mac, so keep per-frame/WindowServer checks opt-in |
| Three `MainActorTurnTests` occupancy probes | `TOY_BOX_TEST_MAIN_ACTOR_TIMING=1 bun run test --filter MainActorTurnTests` | Core, t340 (`client-test-actor-isolation`): isolate probes and replace timing-dependent readiness with controlled events. Run locally before changing launch network work |
| `ChannelArtifactSessionTests.switchingScopeDiscardsTheVisitAndCancelsItsPendingLoad` | `TOY_BOX_TEST_ARTIFACT_SCOPE_TIMING=1` | Core, t340 `artifact-scope-readiness`: capture stalled stage, identify cause, add deterministic scope-replacement coverage |
| `ChannelArtifactSessionTests.removingAnArtifactDuringLoadingRetainsItsIdentityWithoutPublishingTheResponse` | `TOY_BOX_TEST_ARTIFACT_SCOPE_TIMING=1` | Core, t340 `artifact-removal-readiness`: capture stalled stage, identify cause, add deterministic removal-during-load coverage |

`TransportTests.storeReconnectsFromAppliedRevisionZero` and `recoverySnapshotReplacesCachedHistory`
are restored to the default gate with immediate/held-response delivery, not
`TOY_BOX_TEST_RECONNECT_TIMING=1`. The actor probes remain opt-in. Image-strip CI still covers both
scroller styles, equal height, overflow, native clip scrolling and trailing-edge visibility through
`imageStripKeepsOneHeightWhenItsImagesOverflowAndStillScrolls`. Wheel failure diagnostics include
geometry, window visibility, display sleep and session lock state. Live Text timeouts record
analysis errors/completion/text detection and load.

## Validating the running app

- Snapshots: `SCRATCH_PATH=/tmp/tbm-<you> bun run snapshot --server http://127.0.0.1:3210
  --channel studio-demo --appearance light|dark --size 1280x840 --snapshot <file.png>
  [--state <name>]`. Snapshot mode never marks read, saves settings or posts notifications.
  It uses the normal SwiftUI scene, disables restoration only in the volatile argument domain,
  refuses application-state saving/restoration, and renders attached sheets' layers into the PNG.
  Layout evidence only: no native interaction, WindowServer shadows/corner masks, or correct
  27+ Liquid Glass/sidebar selection. Verify materials, selection and scroll-edge effects in a real window.
- Computer Use accepts bundle IDs, not paths. User: `dev.toybox.desktop`. Agents:
  `dev.toybox.desktop.test` ("Toy Box Test", `.build/agents`), built/launched by `bun run validate`.
  Shared IDs permit reads, not clicks. Validation builds and registers only the isolated test copy,
  never a shared-bundle fallback. Computer Use approval is still required by the tool.
- Launch your own build in the background against the demo:
  `open -n -g "/tmp/tbm-<you>/Toy Box.app" --args --server http://127.0.0.1:3210 -ApplePersistenceIgnoreState YES`.
  `-g` avoids focus. `--server` / `TOY_BOX_SERVER_URL` is session-only, never replacing saved Settings.
  Keep `-ApplePersistenceIgnoreState YES` for isolation even with restored-zero-window fallback:
  test instances must neither restore nor overwrite shared saved window state.
- Keep the first bundle path a Computer Use session inspects, or it rejects other paths
  ("no longer belongs to the approved app"). `SCRATCH_PATH=/tmp/tbm-<you> bun run validate` always uses
  `CONFIGURATION=release`, swaps an optimized build into the isolated bundle without disturbing running
  instances, and launches the test bundle against the demo in background. Judge feel there,
  not quick `bun run build` debug builds.
- Only one instance may have the test ID for clicks. On "no perception baseline for this pid",
  wait for the other agent's instance to quit. Reads still work: `list_apps` with your own `window`.
  Confirm `studio-demo` before acting. Never act in a window listing live channels.
- Quit your instance with `kill <pid>` when you finish.

## Swift conventions

- The macOS 27 CLT SDK exports an unusable `@State` macro. Use `@ViewState`, which aliases
  `SwiftUI.State`.
- `ChannelKit` owns domain semantics and `ChannelClient` owns transport and stores. Views never
  reimplement reducer, audience, task, attention or transcript-grouping rules. Ask Core for a
  domain or store change instead of working around it in a view.
- `TranscriptView` is ChannelKit's message filter enum, so SwiftUI views use other names.
- `ToyBoxUI.TranscriptMarkdown` owns portable Markdown, mention styling and find decorations.
  Hosts inject text scale, resolved mention ink and Copy Code, keeping native bubble geometry,
  font preferences, system-color resolution and clipboard access in the platform target. The shared
  `TranscriptMentionContrast` accepts composited sRGB backgrounds. Transcript landing, reveal,
  viewport coordinates and accessible message/divider labels live beside the renderer.
  Portable assertions run in `ToyBoxUITests` on both platforms. Native selection, window,
  system-color and rendering assertions remain in `ToyBoxDesktopTests`.

## Client rules

- Management writes are never retried. A 422 is a rejection, but a 500, timeout or lost connection
  may have committed, so call `reconcileManagementWrite(channelId:)` before offering another attempt.
  Can't connect, offline and bad-host failures remain ordinary retryable errors.
- A send makes one attempt with a caller-owned UUID, kept in a per-channel outbox until confirmed.
  Send Again reuses that UUID, so the server can't deliver it twice.
- Reading never answers a request. Reconnects resume from the last applied revision.
- The catalog's `lead` profile is required. Treat a missing one as a protocol error, and never
  substitute client art.

## Releases

- Workflow actions stay pinned to full commit hashes with readable version comments. Dependabot
  checks them weekly. The Release checks job validates workflows and credential-free release tools.
- Push a `vX.Y.Z` tag, only with the user's approval. Actions tests the tag, then signs,
  notarizes, staples and publishes the signed zip, its checksum and `appcast.xml`. Running the
  workflow by hand on `main` is a dry run that keeps all three as artifacts.
- iPhone releases are independent `mobile-vX.Y.Z` tags in `mobile-release.yml`. They upload to
  TestFlight, never GitHub Releases. Manual `main` runs use `--validate-only`, never upload.
  The phone workflow's `github.run_number.github.run_attempt` is its build. Use `1` for the first
  local upload, below the first CI build `1.1`. No Simulator runtime is needed.
- `CHANGELOG.md` is the release-note source: `## Mac X.Y.Z` / `## iPhone X.Y.Z`. Missing, duplicate
  or empty entries fail before release builds. `bun run release-notes TAG [OUTPUT.md]` extracts one.
  Mac GitHub/Sparkle notes use the Mac entry. Phone notes are retained in the job summary/artifact;
  per-build “What to Test” stays manual until a password-authenticated Apple tool path is proven.
- User only: `bun run setup-secrets:mobile SHA1 APP_STORE_CONNECT_APP_ID [OWNER/REPO]`.
  It selects the same three App Store profiles as `testflight`, reads an export password
  silently or from piped stdin, exports only that Apple Distribution identity and deletes its
  temporary encrypted export. It sets `MOBILE_SIGNING_CERTIFICATE`, `MOBILE_SIGNING_PASSWORD`,
  the three `MOBILE_*_PROVISIONING_PROFILE` secrets, and public `MOBILE_SIGNING_IDENTITY` /
  `MOBILE_SIGNING_CERTIFICATE_CHAIN` / `APP_STORE_CONNECT_APP_ID` variables. It never reads or replaces
  `NOTARY_APP_PASSWORD`.
  Actions imports the identity with its verified issuer chain and the profiles only
  into job-temporary storage, then restores the keychain search list and removes the material.
  Agents never run real setup or read the exported identity/password.
- Certificate-owner-only setup:
  `bun run setup-secrets SHA1 APPLE_ID TEAM_ID`, using an Apple ID app-specific password
  entered silently or piped on stdin, never as an argument. It configures `toy-box-channels-notary`
  and GitHub secrets `MACOS_SIGNING_CERTIFICATE`, `MACOS_SIGNING_PASSWORD`, `NOTARY_APP_PASSWORD`,
  plus public `MACOS_SIGNING_IDENTITY` / `MACOS_SIGNING_CERTIFICATE_CHAIN` variables.
  Setup exports its verified public chain alongside the encrypted identity,
  so certificate renewal needs setup again, not a workflow fingerprint/intermediate edit.
  Agents never run setup with real credentials, create secrets or read keys/passwords.
  `bun test scripts` uses fake commands unless native checks are explicitly enabled.
  The only shell helper is `read-password.sh`, using `read -rs` for echo/piped-input handling.
- The same Mac setup also reuses
  or creates the `dev.toybox.desktop` Sparkle Keychain account, uploads `SPARKLE_ED_PRIVATE_KEY`
  as a secret and `SPARKLE_ED_PUBLIC_KEY` as a public repository variable, then deletes the temporary
  export. No key backup is required: on a new Mac it creates a replacement, authorized by the same
  app's Developer ID signing requirement. Keep the bundle ID and Apple team unchanged.
  Agents never run setup or read the key.
  Opt-in `scripts/desktop/bundle/native.test.ts` uses a throwaway CryptoKit file, never Keychain.
  Run it with `TOY_BOX_BUNDLE=<app> SPARKLE_TOOLS_DIR=<tools> bun test scripts/desktop/bundle/native.test.ts`.
- Locally: `SPARKLE_ED_PUBLIC_KEY=... SIGNING_IDENTITY=SHA1 BUILD_NUMBER=N NOTARY_PROFILE=toy-box-channels-notary
  bun run release vX.Y.Z`. Without `NOTARY_PROFILE` the zip is named `SIGNED-UNNOTARIZED` and
  is never published. `PREVIOUS_APPCAST=path` enforces increasing local build numbers. CI compares the
  latest feed, serializes workflows and uses `github.run_number.github.run_attempt` to advance reruns.
- Hardened runtime and a secure timestamp throughout. The app has audio-input permission and,
  when Developer ID signed with its widget, the `RHFNBL7EG4.dev.toybox.desktop` app group.
  `Contents/PlugIns/ToyBoxShare.appex` has only App Sandbox, no network or file-access entitlement.
  Its identity is the app's ID plus `.share`, with matching version/build, signed before the app.
  Never `--deep`. Validation checks its arm64 architecture, SDK stamp, signature and sandbox.
- `Contents/PlugIns/ToyBoxWidget.appex`: App Sandbox, same Team-ID-prefixed group, no networking,
  app ID plus `.widget`, matching version/build. Ad-hoc builds have no group entitlement or snapshot
  publishing. Isolated validation/snapshot/benchmark copies remove widget/group metadata.
  Register the containing app with LaunchServices before probing WidgetKit registration.
  Quick Send/Needs You controls share this extension. Both executables include foreground intents
  from `ToyBoxControlIntents` through `AppIntentsPackage`. `bun run build` extracts package metadata,
  merges into host/extension, then signs. Controls open host routes, never send from the extension.
  Local builds use Command Line Tools, CI the runner's Xcode 27 on `xcode-27`.
- Share builds via SwiftPM/`_NSExtensionMain`, without Xcode/storyboard. Load only explicitly shared
  items, write `dev.toybox.desktop.share.<UUID>` pasteboards, open
  `toybox-desktop://quick-send?pasteboard=...`, then let the host import/clear the board.
  Never auto-send or connect to a server. Test/validation/benchmark clones and snapshots omit Share,
  Services, URL schemes and document handlers. Check `pluginkit -m -v -i dev.toybox.desktop.share`
  on a normal bundle, not an isolated clone.
- Sparkle is pinned to 2.10.0 in SwiftPM. Every bundle embeds its arm64-only framework, installer
  and updater, without sandbox XPC services or development headers. `desktop/bundle/sign-app.ts` signs those
  components inside out before signing the app. Keep Sparkle's license in the bundle.
- Only release bundles get `SUFeedURL` / `SUPublicEDKey`. Others have no updater regardless of saved
  preferences. Feed:
  `https://github.com/lostintangent/toy-box-apple/releases/latest/download/appcast.xml`.
  Automatic checks default on without prompting. Installation is opt-in. After notarization,
  `desktop/release/appcast.ts` verifies the archive signature, accepting key stdin from
  `SPARKLE_ED_PRIVATE_KEY` or explicit `SPARKLE_ED_KEY_FILE` for isolated tests. Never default Keychain.
- Recovery from a lost Mac: sign in to the same Apple account/team, create replacement Developer ID
  and Apple Distribution certificates/profiles, then rerun `setup-secrets`
  and `setup-secrets:mobile`. Neither workflow pins an issuing intermediate.
  The current Developer ID expires February 1, 2027. Renew and rerun setup before then.
  Sparkle's archive key stays required, but the feed is unsigned and both strict flags stay absent.
  Existing v0.1.8 has the strict policy: install the first replacement manually once.
- Icon source: `Resources/AppIcon.icon` (Designer). After changes, `bun run icon`, then commit it with
  `Resources/AppIcon.icns` / `Resources/Assets.car`. Generation needs Icon Composer/Xcode `actool`.
  Mac builds only copy outputs, so CLT/Mac CI need neither. Mobile uses Xcode `actool` for the
  selected platform. `CFBundleIconName` selects layered dark/clear/tinted appearances.
  Mac `.icns` and generated phone PNGs remain fallbacks.
- Never alter the user's installed validation bundle or microphone permission state to test a
  release.

## Source ownership

| Path | Owner |
| --- | --- |
| `Sources/ChannelKit/`, `Sources/ChannelClient/`, `Sources/ToyBoxControlIntents/`, `Tests/` (except below), `scripts/`, `Package.swift`, `package.json` | Core |
| `Sources/ToyBoxUI/` shared presentation, identity and interaction models | Core, with the originating UI owner |
| `Sources/ToyBoxDesktop/App`, `Shell`, `Sidebar`, `Settings`, `Shared`, `Channel/ChannelDetailView.swift` | Shell |
| `Sources/ToyBoxDesktop/Transcript`, `Tests/ToyBoxDesktopTests/TranscriptTests.swift` | Transcript |
| `Sources/ToyBoxDesktop/Composer` (composer and tray), `Tests/ToyBoxDesktopTests/ComposerTests.swift` | Composer |
| `Sources/ToyBoxDesktop/Overview`, `Management` | Overview |
| `Sources/ChannelIntelligence/`, `Tests/ChannelIntelligenceTests/` | Intelligence |
| `Sources/ToyBoxMobile/App`, `Shell`, `Sidebar`, `Settings`, `Shared`, `Channel` | Shell |
| `Sources/ToyBoxMobile/Transcript` | Transcript |
| `Sources/ToyBoxMobile/Composer` (composer and tray) | Composer |
| `Sources/ToyBoxMobile/Overview`, `Management` | Overview |
| `Sources/ToyBoxMobileIntegrations/`, `Sources/ToyBoxMobileNotification/`, `Resources/Mobile/` | Core |
| `Sources/ToyBoxWidgetViews/`, `Sources/ToyBoxMobileWidget/`, `Tests/ToyBoxMobileWidgetTests/` | Overview |

UI engineers may add one `Tests/ToyBoxDesktopTests/<Surface>Tests.swift` file for their own surface.

Edit only files you own. Ask the owner for anything else in the channel.

## Seams between surfaces

- `AppModel` (environment): server URL, `ChannelCatalogStore` and its `ChannelAPI`.
- `ChannelStore` (passed in): one per channel, shared by every window that shows the channel.
- `ChannelInteraction` (ToyBoxUI, environment, one per channel window) carries cross-surface intents:
  Reply, Focus Composer, Reveal message, Jump to Latest, the Message View filter and inspector
  visibility. Any owner may add a narrowly scoped intent here. Announce it in the channel.
- `ManagementPresenter` (ToyBoxUI, environment, one per window): `present(_:)` opens any management flow.
  Overview implements the flows behind it. Every other surface only calls `present`.
- `AgentAvatarView`, `AgentAvatarStack`, `ChannelMark`, `ChannelTaskColors`, `ChannelColors`,
  `ChannelAttentionStyle` and `TranscriptSurface` (ToyBoxUI) preserve the Mac's identity and colors.
  Typography, navigation and layout stay platform-native.
- `ComposerDraft`, `ComposerImage`, `ConnectGrace` and `ChannelConnections` live in ChannelClient.
  Supply a native image-readability check to the shared draft. Mac uses its existing lazy NSImage
  validation and iPhone uses UIImage. Keep persistence keys and send-attempt identity unchanged.
- `channelMatchesQuery` (ChannelKit) matches name, purpose and directory. Callers retain their
  existing query normalization and ordering. `ChannelAPI.channelURL(channelID:files:)` builds
  browser routes, preserving deployment prefixes. `SidebarConnection` (ToyBoxUI) projects the
  shared footer connection state and server label.
- `ChannelSidebarProjection` (ChannelClient) takes the catalog and the host's current
  `openChannelIDs`. Its `channel`, `attention`, `agents`, `working` and `catalogAgents` methods
  preserve the Mac's live-versus-catalog rules and granular observation. `RequestedCatalogRefresh`
  tracks user-requested work separately from polling and joins refreshes already in flight.
