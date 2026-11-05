# Development

How to build, test, run and validate both apps in detail. [AGENTS.md](../AGENTS.md) has the rules
every change follows, and [scripts/README.md](../scripts/README.md) lists every command. Release
signing, notarization, updates and TestFlight are in [releases.md](releases.md).

## Toolchains

| | Mac | iPhone |
| --- | --- | --- |
| Toolchain | Command Line Tools only | Xcode's toolchain and SDK through SwiftPM, never `xcodebuild` |
| Requires | Swift tools 6.4+ and the macOS 27+ SDK on Apple Silicon | Swift 6.4, an iOS 27+ SDK, and a Duo runtime for the app or another iPhone's 27+ runtime for tests |
| Developer dir | `/Library/Developer/CommandLineTools` | `/Applications/Xcode.app/Contents/Developer`, or set `DEVELOPER_DIR` to another installed Xcode |

- Use native `bun check` for the TypeScript tooling, without installing TypeScript. Platform
  script folders never import each other.
- `bun run build` invokes Xcode's `appintentsmetadataprocessor` for Siri and Shortcuts, so Xcode
  must be installed, though its license needn't be accepted.
- `bun run build` stamps the real SDK before signing. Use that bundle for native visual checks,
  not SwiftPM's unstamped executable. `bun run validate` rejects recorded SDKs below macOS 27.
- Mobile commands set `TOY_BOX_MOBILE=1` for the package's mobile graph and build in
  `mobile-simulator` or `mobile-testflight` under `SCRATCH_PATH`. Each links the same manifest,
  sources and tests into a dependency-free workspace. Leave the default graph, the Mac build and
  tests and the Sparkle lockfile unchanged. Never export the flag globally, run that graph in the
  repository root or share scratch paths across builds.
- Never download simulator runtimes.

### Scratch paths

| To | Run |
| --- | --- |
| Build only | `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path /tmp/tbm-<you>` |
| Test | `SCRATCH_PATH=/tmp/tbm-<you> bun run test`, which supplies the Command Line Tools Testing macro plugin path and rejects runs without a summary, unlike bare `swift test` |
| Build, bundle and open a new instance | `SCRATCH_PATH=/tmp/tbm-<you> bun run build` |

## Servers

Set the server with `TOY_BOX_SERVER_URL` or Settings. Launch overrides are session-only and never
replace saved Settings.

| Server | Port | Use it for |
| --- | --- | --- |
| `bun run demo` | 3210 | `studio-demo`, the isolated fixture server with the required catalog lead profile. Write tests and the shared screenshot baseline |
| `bun run demo:history` | 3211 | `history-demo`: 480 messages, canonical 100-message older pages and isolated read receipts. Paging and key-window read checks, without disturbing 3210 |
| `bun run demo:perf` | 3292 | The benchmark fixture, started fresh by `bun run benchmark`. `TOY_BOX_PERF_PORT` changes it |
| Live Toy Box | 3100 | Reading only. Posting or mutating needs the Lead's approval of a specific scratch channel. Leave its process running |

## Tests

### Opt-in suites

The default suite never needs these. Each runs with `SCRATCH_PATH=/tmp/tbm-<you> bun run test`
and the setting shown.

| Suite | Setting and filter | Notes |
| --- | --- | --- |
| Demo integration | `TOY_BOX_DEMO_URL=http://127.0.0.1:3210` | Against `bun run demo` |
| History integration | `TOY_BOX_HISTORY_DEMO_URL=http://127.0.0.1:3211`, `--filter HistoryFixtureTests` | Against a freshly started history demo |
| Real dictation | `TOY_BOX_REAL_DICTATION_TESTS=1`, `--filter ComposerTests/theRealTranscriberHearsARecordingThroughTheAudioSourceProtocol` | Needs the on-device English dictation model and synthesized audio, not microphone access. The normal suite never queries speech-model assets |
| Transcript timing | `TOY_BOX_TEST_TRANSCRIPT_TIMING=1`, `--filter 'Transcript\|ImageViewer'` | Native Transcript frame-timing and VisionKit selection-layer checks. Run locally before changes to landing, paging, following arrivals or native image text selection |
| Image-strip wheel | `TOY_BOX_TEST_IMAGE_STRIP_SCROLLING=1`, `--filter ComposerTests/imageStripOverflowRespondsToWheelInput` | Keep the Mac awake and unlocked. Equal height, hidden scrollers, overflow and synchronous native clip scrolling stay in the default suite |
| Live Text interaction | `TOY_BOX_TEST_LIVE_TEXT_INTERACTION=1`, `--filter pressesOnTextReachLiveTextAndEverythingElseReachesTheViewer` | Native press and drag routing in an ordered off-screen window. WindowServer events can stop the runner's outer run loop. Geometry and routing-policy checks and VisionKit analysis gating stay in the default suite |
| HTML origin probe | `TOY_BOX_TEST_ARTIFACT_HTML_ORIGIN_PROBE=1` | Quarantined. See AGENTS.md |

### iPhone tests

`SCRATCH_PATH=/tmp/tbm-<you> bun run test:mobile` builds the iOS tests and runs the ChannelClient,
ToyBoxUI, ToyBoxMobileIntegrations, ToyBoxMobileWidget and ToyBoxMobile suites on the iOS Simulator
through Apple's `xctest` host. ChannelKit and mocked Intelligence run on the Mac only, but compile
in the iOS build.

- It rejects interrupted, failed and empty Swift Testing runs.
- A suite silent for three minutes is sampled, stopped and fails, naming the tests that never
  finished.
- Existing opt-ins stay off.
- It shuts down the simulator only if it booted it.

### CI

- Main and pull-request CI builds the phone app, its extensions and the shared modules for the
  Simulator and verifies the extensions' signatures. It runs the iOS suites only with an installed
  iOS 27+ runtime, and otherwise skips them explicitly.
- Tags and manual release dry runs skip iOS.
- The Mac runs ChannelClient once under the strict cooperative pool, then the remaining suites.
- Bundle, Siri and signing checks run only in the release job.
- Workflow shell checks gate warnings and errors, not style hints.

## Benchmarks

`SCRATCH_PATH=/tmp/tbm-<you> bun run benchmark [--summaries] [launch|switch|messages|paging|key|idle ...]`
builds the release `dev.toybox.desktop.benchmark` app, runs each scenario on a fresh
`bun run demo:perf`, prints each result against its budget and exits 1 if any is over. The spec's
Performance budgets define busy time, saturated spans and frame gaps.

- Leave the window uncovered.
- `key` runs only when named. It takes focus for about 45 seconds and measures key-window CPU with
  4, then 20, working agents to expose continuous animation. Warn the user first.
- Catch-up summaries stay off unless you pass `--summaries`.
- Only one benchmark runs at a time on this Mac. Others wait for it, so never poll for one yourself.
- Under load, compare main-thread CPU. Scroll's CPU ms per 1,000 native points and paging's CPU ms
  per older page are informational. Judge wall-clock hitches only on a quiet machine, since busy
  time includes scheduling delays.

## Validating the Mac app

### Snapshots

```sh
SCRATCH_PATH=/tmp/tbm-<you> bun run snapshot --server http://127.0.0.1:3210 \
  --channel studio-demo --appearance light|dark --size 1280x840 --snapshot <file.png> [--state <name>]
```

Snapshot mode never marks read, saves settings or posts notifications. It uses the normal SwiftUI
scene, disables restoration only in the volatile argument domain, refuses application-state saving
and restoration, and renders attached sheets' layers into the PNG.

It's layout evidence only. It has no native interaction, WindowServer shadows or corner masks, or
correct 27+ Liquid Glass and sidebar selection. Verify materials, selection and scroll-edge effects
in a real window.

### Computer Use

- Computer Use takes bundle IDs, not paths. The user's app is `dev.toybox.desktop`, and agents use
  `dev.toybox.desktop.test` ("Toy Box Test"). Shared IDs permit reads, not clicks. Computer Use
  still asks for its own approval.
- It resolves the test ID through LaunchServices, which never resolves a copy under `/tmp` and
  otherwise picks among every registered copy. Any other copy is rejected with "no longer belongs
  to the approved app".
- So `SCRATCH_PATH=/tmp/tbm-<you> bun run validate` installs into the main checkout's
  `.build/agents/Toy Box Test.app` from any worktree and unregisters every other copy of the ID.
  It never falls back to a shared bundle. It always builds `CONFIGURATION=release`, swaps the
  optimized build into that bundle without disturbing running instances, and launches it against
  the demo in the background. Judge feel there, not in quick `bun run build` debug builds.
- Only one instance can hold the test ID for clicks. On "no perception baseline for this pid", wait
  for the other agent's instance to quit. Reads still work through `list_apps` with your own
  `window`.
- Confirm `studio-demo` before acting, and never act in a window listing live channels.
- Quit your instance with `kill <pid>` when you finish.

### Launching your own build

```sh
open -n -g "/tmp/tbm-<you>/Toy Box.app" --args --server http://127.0.0.1:3210 -ApplePersistenceIgnoreState YES
```

`-g` avoids taking focus. `--server` and `TOY_BOX_SERVER_URL` are session-only. Keep
`-ApplePersistenceIgnoreState YES` even with the restored-zero-window fallback, so test instances
neither restore nor overwrite the shared saved window state.

## The iPhone simulator

`SCRATCH_PATH=/tmp/tbm-<you> bun run simulator` builds, bundles, installs and launches
`dev.toybox.mobile` on the shared **Toy Box Mobile** iPhone Duo. It never opens or focuses Device
Hub (`com.apple.dt.Devices`). Select that device there to use its native hinge-posture slider.

| Option | What it does |
| --- | --- |
| `--hold` | Keeps the lease for manual checks. Ctrl-C or the 15-minute expiry shuts down and releases it |
| `--server <URL>` | Wins over a stale launch environment without saving Settings. Launches always pass `--server`, defaulting to `TOY_BOX_SERVER_URL` or `http://127.0.0.1:3210` |
| `--screenshot <file.png>` | Captures under the same lease. With `--hold`, it captures the current pose at lease end, before shutdown |
| `--displays` | Lists native display IDs |
| `--display <ID>` | Picks the screenshot display, including the Duo's secondary one. Otherwise it captures display `1`, the folded LCD |
| `--content-size <category>` | UIKit's process-only preferred category: `extraSmall`, `small`, `medium`, `large`, `extraLarge`, `extraExtraLarge`, `extraExtraExtraLarge`, `accessibilityMedium`, `accessibilityLarge`, `accessibilityExtraLarge`, `accessibilityExtraExtraLarge`, `accessibilityExtraExtraExtraLarge` |
| `--appearance light\|dark` | Passes `-appearance` in the app's process-only argument domain, ahead of saved Settings. It changes neither saved appearance nor the simulator's, so nothing needs restoring. It's app-only, not the Home Screen, Lock Screen or widget host |
| `--drive <steps.json>` | Runs a drive script, below |
| `--build-only` | Makes the Simulator bundle without booting |
| `--shutdown` | Shuts the simulator down |

- **One agent at a time.** Every simulator command takes a machine-wide `flock`, waits, and prints
  the holder's PID, command and worktree. Never boot another simulator or run `simctl` by hand.
  `MOBILE_SIMULATOR=<UDID>` selects an agreed shared device, not one per agent.
- Build-only, capture-only, display-list-only and shutdown-only commands reject launch options.
- Wait for visible drawing before ending the lease, not merely a launch PID.
- Simulator tests always build debug, and Simulator apps default to debug. Use
  `CONFIGURATION=release` for native performance comparisons. Output states the configuration and
  optimization.

### Drive scripts

`--drive <steps.json>` runs a DEBUG-only accessibility script under the lease, then shuts down on
completion or failure. Release builds have neither the startup hook nor the driver, and no script
runs without the explicit per-launch environment. It drives accessibility activation, native
control primary actions and text insertion, not finger touch. Reruns repeat sends, so use demo
servers for any script that writes. Never skip or retry actions.

| Step | Contract |
| --- | --- |
| `{"tap":"exact label or identifier"}` | Exact label or identifier, or the exact accessibility value of an unlabeled element such as native Search |
| `{"type":"text"}` | Text insertion |
| `{"wait":"label or value fragment"}` | `absent: true` waits for disappearance |
| `{"screenshot":"name","display":1}` | Captures only after settled accessibility and layout |
| `{"back":true}` | Native Back, including the restored stack's trait-less Back control through its primary action, then public window accessibility escape only if activation is unhandled. Disabled Back never falls through. `ifPresent: true` allows an explicitly optional initial return from restored navigation. Wait for the channel name, then optional Back, before tapping its row |
| `{"action":"Reply","on":"message-12"}` | A named accessibility custom action on one exact label or identifier |
| `{"posture":"unfolded","timeout":60}` | Waits for the measured scene, not hinge movement |
| `{"menuAction":"Edit Channel"}` | Visible-menu action dispatch, not a tap. See below |
| `{"scroll":"down","on":"scrollable-list"}` | One public accessibility scroll on that exact unique identifier, `up`, `down`, `left` or `right`. Missing targets wait within the step deadline. Ambiguous or unhandled actions fail without retries or direct content-offset changes. Some SwiftUI Forms decline this, so it isn't finger scrolling |
| `{"drag":"up","on":"conversation-transcript"}` | Moves the unique UIScrollView's content offset across 80% of its visible size over 24 frames, clamped to content, between delegate begin and end-dragging callbacks. Geometry and scroll phases drive older paging, but there's no pan gesture, deceleration, rubber-banding or drag dismissal of the keyboard |
| `{"zoom":2,"on":"screen-canvas"}` | Moves the unique UIScrollView's zoom scale to that scale over 24 frames, clamped to its limits and keeping the visible center in place, between delegate begin- and end-zooming callbacks. There's no pinch gesture, bounce or anchor under fingers |

- **Timeouts** are in seconds, 12 by default and 60 at most. Cancellation or a deadline stops drag
  and zoom steps but balances started end callbacks, never reporting completion.
- **Modal views.** Like VoiceOver, the tree skips the siblings beneath a visible
  `accessibilityViewIsModal` view, so a sheet hides the screen it covers and its own controls
  stay unambiguous.
- **Captures.** The host acknowledges a capture only with a settled app accessibility and layout
  snapshot and both `<name>.png` and `<name>.json` under `SCRATCH_PATH/mobile-drive/`, holding its
  step, state, labels and viewport. A later `status.json` can't erase it. The host bounds each
  capture or control child by the step timeout from the app's ready signal and always
  acknowledges. `simctl` can exit seconds after writing the image, so the app waits that timeout
  plus five seconds with its own step deadline paused. Children share the interruption signal, and
  cancellation kills the exact child and awaits its exit before shutdown and release.
- **Traits.** DEBUG status reports loaded content's `traits.contentSizeCategory` and
  `traits.interfaceStyle`, or `traitsError`. Active presented content takes priority, and visible
  controllers must agree. Never force view loading or substitute screen or requested launch traits
  for measured content. A drive verifies effective native traits before captures and completion.
- **Menus.** Dispatch needs one active menu in the current scene and one enabled, visible matching
  leaf. The driver tags its public accessibility identifier in UIKit's returned copy, requires the
  exact fresh tag on a measured native candidate, and restores the original identifier before
  dispatch or on failure. Same-title background controls don't establish ownership, and missing
  tags fail. Hidden items and unopened submenus are excluded. It dismisses through UIKit, waits for
  dismissal and settled layout within the same deadline, then performs the retained leaf through
  public `UIMenuLeaf`. Missing, dismissed, ambiguous or changed-scene menus fail explicitly. This
  proves neither finger selection, menu accessibility nor hardware-key delivery.

### Duo posture

- Posture needs Computer Use on Device Hub while the driver holds the lease. Confirm its window and
  selected device identify the leased simulator before using the native posture controls.
- The SDK 27.1 fixture waits for settled **466x678-point folded** and **669x951-point unfolded**
  proof scenes, not general device or hinge detection. Timeouts report the expected and measured
  scenes and stop without retrying.
- Observed: native Open, then Rotate Right, reached unfolded. Display **1** is the folded LCD
  (1398x2034) and **3** the unfolded LCD (2007x2853), both 3x. **2** is TVOut, not unfolded.
  Re-enumerate after runtime or device changes, and never infer IDs from posture.
- Slider **0** was folded. The unfolded value is unverified, because Computer Use refused setting
  it and its advertised increment. A requested value is not a measured result.
- Legacy `{"fold":false}` fails with native diagnostics. Never use display power: it didn't change
  the scene and can crash SpringBoard.

| Script | What it checks |
| --- | --- |
| `scripts/mobile/dogfood/drives/posture.json` | Folded, unfolded, then folded, without sending or editing a draft |
| `scripts/mobile/dogfood/drives/reply.json` | A real reply and send with both display captures. It needs message-row identifiers and baseline request sequence 15, sends on every run, and needs the same live Device Hub posture actions |

## On a real iPhone

- Install through TestFlight. Direct local device installs are retired, so development never
  replaces the user's TestFlight app or its data.
- There's no bundled server or Bonjour default. Never save launch overrides in Settings.
- Both apps accept user-selected HTTP or HTTPS servers, including fully qualified Tailscale names.
  ATS uses `NSAllowsArbitraryLoads` alone, not `NSAllowsLocalNetworking`, which defeats the
  opt-out. Local-network permission is separate, and HTTPS keeps normal certificate validation.
- Simulator push injection never invokes the notification service. Prove real APNs-to-service
  wake on a device.
- `bun run testflight --build-only` makes an **unsigned** release arm64 bundle without reading
  signing identities or profiles. Signed builds, validation and upload are in
  [iPhone TestFlight](releases.md#iphone-testflight).
- Before the first signed build, the **user** confirms an active Apple Developer team, accepts
  pending agreements, registers the explicit App ID `dev.toybox.mobile` and creates its App Store
  Connect app. TestFlight also needs an Apple Distribution certificate, App Store Connect profiles,
  required metadata, privacy and export-compliance answers and tester access, plus beta review for
  external testers.

## Bundle contents

### iPhone

- Before signing, the build stamps and verifies the selected iOS SDK in `LC_BUILD_VERSION`,
  keeping the plist's deployment minimum and the device or Simulator platform. `DTSDKName` alone
  isn't enough. Every executable's real SDK stamp is verified.
- It compiles `Resources/Shared/AppIcon.icon` with the selected platform's `actool`, embedding
  layered appearances, PNG fallbacks and generated metadata. There's no separate phone artwork or
  iOS asset catalog.
- It embeds `PlugIns/ToyBoxMobileWidget.appex` (`dev.toybox.mobile.widget`),
  `PlugIns/ToyBoxMobileNotification.appex` (`dev.toybox.mobile.notification`) and
  `PlugIns/ToyBoxMobileShare.appex` (`dev.toybox.mobile.share`) with SwiftPM
  application-extension safety. All enter through a verified `_NSExtensionMain`, which establishes
  context before WidgetKit's generated Swift main, the service or the share sheet.
- Simulator capabilities link into `__TEXT,__entitlements` and `__TEXT,__ents_der`, including all
  four bundles' `group.dev.toybox.mobile`. Ad-hoc signatures carry no restricted device
  entitlements. Simulator extensions are signed before the host, without device profiles or
  credentials.

### Mac

- The app has audio-input permission and, when Developer ID signed with its widget, the
  `RHFNBL7EG4.dev.toybox.desktop` app group.
- `Contents/PlugIns/ToyBoxDesktopWidget.appex` has App Sandbox, the same Team-ID-prefixed group
  and no networking. Its ID is the app's plus `.widget`, with matching version and build. Ad-hoc
  builds have no group entitlement or snapshot publishing, and isolated validation, snapshot and
  benchmark copies remove widget and group metadata. Register the containing app with
  LaunchServices before probing WidgetKit registration.
- The Quick Send and Needs You controls share that extension. Both executables include
  foreground intents from `ToyBoxControlIntents` through `AppIntentsPackage`. `bun run build`
  extracts the package metadata, merges it into the host and extension, then signs. Controls open
  host routes and never send from the extension.
- `ToyBoxDesktopShare.appex` builds through SwiftPM and `_NSExtensionMain`, without Xcode or a
  storyboard, and never auto-sends or connects to a server. Test, validation and benchmark clones
  and snapshots omit Share, Services, URL schemes and document handlers, so check
  `pluginkit -m -v -i dev.toybox.desktop.share` on a normal bundle, not an isolated clone.
- `scripts/desktop/bundle/sign.ts` signs Sparkle's components inside out before the app, never
  with `--deep`. Keep Sparkle's license in the bundle.

## Other commands

- `bun run cron-fixtures ../toy-box` regenerates the cron fixtures from the read-only reference
  without touching it.
- After changing `Resources/Shared/AppIcon.icon`, run `bun run icon` and commit it with
  `Resources/Desktop/AppIcon.icns` and `Resources/Desktop/Assets.car`. Generation needs Icon
  Composer and Xcode's `actool`. Mac builds only copy the outputs, so Command Line Tools and Mac CI
  need neither. `CFBundleIconName` selects the layered dark, clear and tinted appearances, and the
  Mac `.icns` and generated phone PNGs remain fallbacks.
- `bun run release-notes TAG [OUTPUT.md]` extracts one platform's entry from `CHANGELOG.md`.
