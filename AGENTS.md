# Toy Box for Apple

Native SwiftUI clients for Toy Box Channels: a Mac app and an iPhone companion, built from one
shared core in Swift 6.4 and SwiftPM, with no Xcode project. Both target the 27 releases on Apple
Silicon and talk to Toy Box's public `/api/v1` HTTP and SSE routes.

[docs/spec.md](docs/spec.md) is the source of truth for parity, protocol and design. Read its
Design section before changing any view.

| Read | Before |
| --- | --- |
| [docs/spec.md](docs/spec.md) | Changing behavior, protocol, design or release tooling |
| [docs/development.md](docs/development.md) | Opt-in tests, benchmarks, the simulator, drive scripts, validation builds or bundle contents |
| [scripts/README.md](scripts/README.md) | Running or changing a command |
| [docs/test-history.md](docs/test-history.md) | Touching a quarantined or restored test |
| `~/Desktop/toy-box` | Checking the server or web pane. It's a read-only reference, so never modify it |

## How we work

- **Own your files.** Edit only the files you own under [Ownership](#ownership), and ask the
  owner in the channel for anything else.
- **Show a picture first.** Before building anything the user will see, the owner, Designer or
  Lead posts a mockup within about 10 minutes, often a quick edit of a real screenshot. Building
  starts after the user's nod, because a prose spec alone is not agreement. If a visible task
  passes 30 minutes with nothing shown, or a small change starts growing, stop and show what exists.
- **Scale validation to the change.** A symbol, constant or spacing change needs a build, the
  touched suite and one capture of the result, not a light/dark and size matrix. Save full passes
  for behavior, layout or concurrency changes, and leave the rest to the release build.
- **Validate in Dark at the default text size,** which is how the user runs both apps. Add Light
  only when a change touches color values, materials or contrast, and larger sizes only when it's
  about text sizing. Both appearances and every size must still work, so never hard-code a color
  or size that would break them.
- **Hand off honestly.** Say what you verified, what you didn't, and what still needs a real
  device, server or signing key.
- **Never touch real data.** Write tests use the [demo servers](#build-and-test). Read the live
  server on 3100 freely, but never post or mutate there without the Lead's approval of a specific
  scratch channel, and leave its process running.
- **Work in isolation.** Use your own scratch path, take shared devices through their lease,
  and quit the instances you launch when you're done.
- **Attach channel images from your session `files/` folder,** never `/tmp`. Posts keep their
  original paths, so cleaning scratch would break them.
- **Leave credentials to the user.** Agents never create accounts, profiles or secrets, accept
  agreements, read keys or passwords, or run real credential setup.

## Architecture

`Sources`, `Tests` and `Resources` each split into `Shared`, `Desktop` and `Mobile`. Folders keep
their module names, and Swift imports by module.

| Module | Owns |
| --- | --- |
| `ChannelKit` | The domain: Codable models, the reducer, transcript grouping, attention, tasks and cron |
| `ChannelClient` | Transport: HTTP commands, SSE, reconnect and observable stores |
| `ChannelIntelligence` | On-device Foundation Models |
| `ToyBoxUI` | Shared SwiftUI presentation, without AppKit or UIKit |
| `ToyBoxDesktop`, `ToyBoxMobile` | Each app and its native platform integration, with AppKit or UIKit where SwiftUI falls short |
| `ToyBoxControlIntents`, `ToyBoxMobileIntegrations` | What each app shares with its extensions, which live under `Extensions` |

Views never reimplement reducer, audience, task, attention or transcript-grouping rules. Ask
Core for a domain or store change instead of working around it in a view.

### Seams between surfaces

| Seam | Lives in | Contract |
| --- | --- | --- |
| `AppModel` | Each app, environment | Server URL, `ChannelCatalogStore` and its `ChannelAPI` |
| `ChannelStore` | ChannelClient, passed in | One per channel, shared by every window that shows it |
| `ChannelInteraction` | ToyBoxUI, environment, one per channel window | Cross-surface intents: Reply, Focus Composer, Reveal message, Jump to Latest, the Message View filter and inspector visibility. Any owner may add a narrowly scoped intent and announce it in the channel |
| `ManagementPresenter` | ToyBoxUI, environment, one per window | `present(_:)` opens any management flow. Overview implements the flows, and every other surface only calls `present` |
| Identity and color | ToyBoxUI | `AgentAvatarView`, `AgentAvatarStack`, `ChannelMark`, `ChannelTaskColors`, `ChannelColors`, `Channel.Attention`'s `symbol` and `color(in:)`, and `TranscriptSurface` keep the Mac's identity and colors. Typography, navigation and layout stay platform-native |
| `TranscriptMarkdown` | ToyBoxUI | Portable Markdown, mention styling and find decorations. Hosts inject text scale, resolved mention ink and Copy Code, and keep bubble geometry, font preferences, system colors and the clipboard. `TranscriptMentionContrast` takes composited sRGB backgrounds. Landing, reveal, viewport coordinates and accessible message and divider labels live beside the renderer. Portable assertions run in `ToyBoxUITests`, and native selection, window, system-color and rendering ones in `ToyBoxDesktopTests` |
| `ComposerDraft`, `ComposerImage` | ChannelClient | Each app supplies its image-readability check: lazy `NSImage` validation on Mac, `UIImage` on iPhone. Persistence keys and send-attempt identity stay unchanged |
| `ChannelConnections` | ChannelClient | The spec's Connections invariants: one notice and one verb, Retry, per scope. Views change on `phase.isUnavailable`, never a timer, and actions wait for `phase.isConnected`. Refresh means only the channel list, and background work never lights the footer spinner |
| `SidebarFooter` | ToyBoxUI | Turns the catalog phase into the shared footer and names its server |
| `ChannelSidebarPresentation` | ChannelClient | Takes the catalog and the host's `openChannelIDs`. Its `channel`, `status`, `agents`, `working` and `catalogAgents` methods keep the Mac's live-versus-catalog rules and granular observation |
| `channel.matches(_:)` | ChannelKit | Matches name, purpose and directory. Callers keep their own query normalization and ordering |
| `ChannelAPI.channelURL(channelID:files:)` | ChannelClient | Builds browser routes, preserving deployment prefixes |

## Ownership

| Path | Owner |
| --- | --- |
| `Sources/Shared/ChannelKit/`, `Sources/Shared/ChannelClient/`, `Sources/Desktop/ToyBoxControlIntents/`, `Sources/Desktop/Extensions/ToyBoxDesktopShare/`, `Sources/Mobile/ToyBoxMobile/Automation`, `Tests/` (except below), `scripts/`, `Package.swift`, `package.json` | Core |
| `Sources/Shared/ToyBoxUI/` shared presentation, identity and interaction models | Core, with the originating UI owner |
| `Sources/Desktop/ToyBoxDesktop/App`, `Shell`, `Sidebar`, `Channel`, `MenuBar`, `Notifications`, `QuickSend`, `Intents`, `Settings`, `Shared` | Shell |
| `Sources/Desktop/ToyBoxDesktop/Transcript`, `Tests/Desktop/ToyBoxDesktopTests/TranscriptTests.swift` | Transcript |
| `Sources/Desktop/ToyBoxDesktop/Composer` (composer and tray), `Tests/Desktop/ToyBoxDesktopTests/ComposerTests.swift` | Composer |
| `Sources/Desktop/ToyBoxDesktop/Overview`, `Artifacts`, `Management` | Overview |
| `Sources/Shared/ChannelIntelligence/`, `Tests/Shared/ChannelIntelligenceTests/` | Intelligence |
| `Sources/Mobile/ToyBoxMobile/App`, `Shell`, `Sidebar`, `Channel`, `Notifications`, `Settings`, `Shared` | Shell |
| `Sources/Mobile/ToyBoxMobile/Transcript` | Transcript |
| `Sources/Mobile/ToyBoxMobile/Composer` (composer and tray) | Composer |
| `Sources/Mobile/ToyBoxMobile/Overview`, `Artifacts`, `LiveActivities`, `Management` | Overview |
| `Sources/Mobile/ToyBoxMobileIntegrations/`, `Sources/Mobile/Extensions/ToyBoxMobileNotification/`, `Sources/Mobile/Extensions/ToyBoxMobileShare/`, `Resources/Mobile/` | Core |
| `Sources/Shared/ToyBoxWidgetViews/`, `Sources/Desktop/Extensions/ToyBoxDesktopWidget/`, `Sources/Mobile/Extensions/ToyBoxMobileWidget/`, `Tests/Mobile/Extensions/ToyBoxMobileWidgetTests/` | Overview |
| `Resources/Shared/AppIcon.icon` | Designer |

UI owners may add one `Tests/Desktop/ToyBoxDesktopTests/<Surface>Tests.swift` file for their own
surface.

## Code

### Swift

- **Use `@ViewState`, never `@State`.** The macOS 27 Command Line Tools SDK exports an unusable
  `@State` macro, so `@ViewState` aliases `SwiftUI.State` once in `ToyBoxUI/Shared`.
- **Declare environment values with an `EnvironmentKey`,** not `@Entry`, in code that builds for
  the Mac. Command Line Tools lack the SwiftUIMacros plugin.
- **Put rules on their nouns.** Write members such as `channel.attention`, `agent.handle` and
  `state.applying(event)`, not free functions. Name a type for the thing itself, nesting a part
  under its owner (`Channel.Attention`, `ChannelTask.Timing`), and avoid Manager, Helper, Support,
  Context and Projection.
- **Adapt to the phone's scene.** Mobile views use SwiftUI's safe areas, layout margins, size
  classes and adaptive navigation. Never hard-code a safe-area inset, device size or Duo fold
  width. Mockup canvas measurements are not implementation constants.

### Client rules

- **Management writes are never retried.** A 422 is a rejection, but a 500, timeout or lost
  connection may have committed, so call `reconcileManagementWrite(channelId:)` before offering
  another attempt. Can't connect, offline and bad-host failures stay ordinary retryable errors.
- **A send makes one attempt** with a caller-owned UUID, kept in a per-channel outbox until
  confirmed. Send Again reuses that UUID, so the server can't deliver it twice.
- **Reading never answers a request,** and reconnects resume from the last applied revision.
- **The catalog's `lead` profile is required.** Treat a missing one as a protocol error, and never
  substitute client art.

## Build and test

Use Bun 1.4.4: run `bun install --frozen-lockfile`, then the root `package.json` commands. Give
every build its own scratch path, so parallel builds never share `.build`.

| To | Run |
| --- | --- |
| Build, bundle and open the Mac app | `SCRATCH_PATH=/tmp/tbm-<you> bun run build` |
| Run the Mac tests | `SCRATCH_PATH=/tmp/tbm-<you> bun run test`, never bare `bun test` or `swift test` |
| Run the iPhone tests | `SCRATCH_PATH=/tmp/tbm-<you> bun run test:mobile` |
| Run the phone on the shared simulator | `SCRATCH_PATH=/tmp/tbm-<you> bun run simulator` |
| Validate the running Mac app | `SCRATCH_PATH=/tmp/tbm-<you> bun run validate` |
| Serve sample channels for writes and screenshots | `bun run demo` on 3210 |
| Serve 480 messages for paging and read checks | `bun run demo:history` on 3211 |
| Check scripts and workflows | `bun check` and `bun run lint:workflows` |

- **The Mac builds with Command Line Tools only.** The phone builds with Xcode's toolchain
  through SwiftPM, never `xcodebuild`. Never download simulator runtimes.
- **The simulator and the benchmark run one at a time** on this Mac. Their commands wait for each
  other, so never boot another simulator, run `simctl` by hand or poll. Warn the user before
  `bun run benchmark key`, which takes focus for about 45 seconds.
- **Changes to bundle or release tooling need both real release dry runs.** There are no script
  tests.
- Opt-in suites, benchmark scenarios, simulator options and drive scripts are in
  [docs/development.md](docs/development.md).

## Validating the running app

- **Mac:** use Computer Use only on `dev.toybox.desktop.test` ("Toy Box Test"), which
  `bun run validate` builds optimized and launches against the demo. The user's
  `dev.toybox.desktop` permits reads, never clicks. Confirm `studio-demo` before acting, never act
  in a window listing live channels, and `kill <pid>` your instance when you finish.
  `bun run snapshot` is layout evidence only, so verify materials, selection and scroll-edge
  effects in a real window.
- **iPhone:** capture with `bun run simulator --screenshot` or a drive script under the lease.
  Check on a real phone only through TestFlight, never a direct install, so development never
  replaces the user's app or its data.

## Test reliability

- **Quarantine an unexplained failure the same day.** A test that fails on main without an
  identified code cause moves behind an explicit opt-in. Don't leave it in the merge gate while
  rerunning CI or patching timing races in place. Record the failed run, test case and
  diagnostics in [docs/test-history.md](docs/test-history.md), with an owner and a follow-up
  task. Quarantine changes gating, not responsibility for the failure.
- **Restore it only with its cause and deterministic coverage.** Never loosen assertions or add
  retries to turn an unexplained failure green.
- **CI protects decisions with deterministic tests** over inputs such as measured frames. Native
  window tests in CI assert settled end states, never per-frame timing. Frame-timing and
  WindowServer-event checks stay opt-in and run locally before changes to their behavior.
- **Test gates and hooks suspend,** never block a cooperative worker. CI runs ChannelClient with
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` to enforce this.
- **Client tests wait with `eventually`,** through Observation and the mock's own request,
  held-response and stop signals, never polling or an elapsed-time assertion. Their suites have a
  one-minute Swift Testing hang limit.

| Quarantined test | Opt-in | Owner and condition for restoring it |
| --- | --- | --- |
| `imageStripOverflowRespondsToWheelInput` | `TOY_BOX_TEST_IMAGE_STRIP_SCROLLING=1` | Composer: native wheel animation needs an awake, unlocked Mac, so per-frame and WindowServer checks stay opt-in |
| `HTMLKeepsAnOpaqueOriginAndCanLoadOnlyTheServersFileResources` | `TOY_BOX_TEST_ARTIFACT_HTML_ORIGIN_PROBE=1` | Overview: identify which WebKit step misses the probe deadline under load and cover it deterministically, without loosening the assertions or the 15-second wait |

## Releases

- **Tags need the user's approval.** `vX.Y.Z` ships the Mac to GitHub Releases, and
  `mobile-vX.Y.Z` ships the phone to TestFlight. A manual workflow run on `main` is a dry run.
  Signing, notarization, updates and TestFlight are in the spec's
  [Releases](docs/spec.md#releases).
- **Release notes are written at merge time.** The merge that lands a user-facing change adds its
  bullet to that platform's next unreleased `## Mac X.Y.Z` or `## iPhone X.Y.Z` entry in
  `CHANGELOG.md`, creating the entry if the newest one has shipped. A release is then only a tag.
- **Each bullet says what the user gains, in plain words,** under `### Features` or
  `### Bugs/Polish`: "The task list can now be filtered to only in-progress items, which makes it
  easier to track progress." Leave out mechanics such as placement, glyphs, colors, counts and
  gestures unless they're the point. Each platform's notes stand on their own, never compared to
  the web or the other app.
- **Workflow actions stay pinned** to full commit hashes with readable version comments.
  Dependabot checks them weekly.
- **Never alter the user's installed validation bundle** or microphone permission state to test a
  release.
