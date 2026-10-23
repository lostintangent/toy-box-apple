# Toy Box Desktop

Toy Box Desktop is a native SwiftUI client for Toy Box Channels. [docs/spec.md](docs/spec.md) is
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

- Build only with Command Line Tools. Never use `xcodebuild`, because the Xcode license is not
  accepted on this machine. `script/run` runs Xcode's `appintentsmetadataprocessor` directly for
  Siri and Shortcuts, which needs Xcode installed but not its license.
- Target macOS 27 or later on Apple Silicon with Swift tools 6.4 or later. `script/run` stamps the real SDK
  version before signing. Use its bundle for native visual checks, not SwiftPM's unstamped
  executable. `script/validate` rejects bundles whose recorded SDK is below macOS 27.
- Use your own scratch path so parallel builds never share `.build`:
  - `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path /tmp/tbm-<you>`
  - `SCRATCH_PATH=/tmp/tbm-<you> ./script/test` runs the suite with the Command Line Tools
    Testing macro plugin path, which a bare `swift test` can't find.
  - `SCRATCH_PATH=/tmp/tbm-<you> ./script/run` builds, bundles and opens a new app instance.
- Point the app at a server with `TOY_BOX_SERVER_URL` or Settings. Use our Minecraft demo wrapper
  (`bun script/demo.mjs` in this repository, port 3210) for write tests. It serves the required
  catalog lead profile without modifying the reference. The live server
  on port 3100 hosts real channels: read it freely, but never post or mutate there without the
  lead's approval of a specific scratch channel.
  Leave its current process running. Its cached route configuration can return 404 for the
  Providers-owned `/api/v1/models` until a user-approved restart. Do not add a compatibility shim.
- `bun script/history-demo.mjs` imports that reference factory read-only and serves `history-demo`
  on 3211 with 480 messages, canonical 100-message older pages and isolated read receipts. Use it
  for paging and key-window read checks without disturbing the shared 3210 screenshot baseline.
- Integration tests are opt-in: `TOY_BOX_DEMO_URL=http://127.0.0.1:3210 ./script/test`, and
  `TOY_BOX_HISTORY_DEMO_URL=http://127.0.0.1:3211 ./script/test --filter HistoryFixtureTests`
  against a freshly started history demo.
- `SCRATCH_PATH=/tmp/tbm-<you> ./script/benchmark [--summaries] [launch|switch|messages|paging|idle ...]` is the
  performance regression benchmark. It builds a release bundle as `dev.toybox.channels.mac.benchmark`,
  runs each scenario against a fresh `script/perf-demo.mjs` fixture on 3292 (`TOY_BOX_PERF_PORT`),
  prints each result beside its budget and exits 1 when one is over. Leave its window uncovered.
  Catch-up summaries stay off so the card can't land mid-measurement. `--summaries` leaves them on.
  Only one benchmark runs at a time on this Mac. Others wait for it, so never poll for one yourself.
- `node script/generate-cron-fixtures.mjs ../toy-box` regenerates the cron fixtures from the
  reference without touching it.
- Quit the instances you launch when you are done.
- Attach channel images from your own session `files/` folder, never `/tmp`. Toy Box serves
  attachments from their original paths, so a cleaned scratch folder breaks earlier posts.

## Validating the running app

- Snapshots: `SCRATCH_PATH=/tmp/tbm-<you> ./script/snapshot --server http://127.0.0.1:3210
  --channel studio-demo --appearance light|dark --size 1280x840 --snapshot <file.png>
  [--state <name>]`. Snapshot mode never marks read, saves settings or posts notifications.
  It opens the normal SwiftUI scene, disables restoration only in the process's volatile
  argument domain, and refuses application-state saving/restoration. Attached native sheets
  render their own layer trees into the parent PNG. These static renders do not prove native
  interaction or capture WindowServer shadows and corner masks.
  With the real 27+ SDK stamp, they also misrender Liquid Glass and sidebar selection. Use
  them for layout evidence only. Verify materials, selection and scroll-edge effects in a real window.
- Computer Use approves apps by bundle ID. A path is refused. The user's copy is
  `dev.toybox.channels.mac`. Agents test as `dev.toybox.channels.mac.test` ("Toy Box Desktop
  Test" in `.build/agents`), which `script/validate` builds and launches. Instances that share a
  bundle ID can be read but not clicked, so the separate ID is what lets you interact while the
  user's app is open. Until the user approves the test ID, `script/validate` falls back to the
  shared bundle and says so.
- Launch your own build in the background against the demo:
  `open -n -g "/tmp/tbm-<you>/Toy Box Desktop.app" --args --server http://127.0.0.1:3210 -ApplePersistenceIgnoreState YES`.
  `-g` keeps it from taking the user's focus. A `--server` or `TOY_BOX_SERVER_URL` launch is
  session-only and never replaces the server the user saved in Settings.
  `-ApplePersistenceIgnoreState YES` keeps test instances from restoring or overwriting the
  saved window state they share with the user's app. Keep it for validation isolation even
  though the normal launch fallback now handles a restored zero-window state.
- A Computer Use session binds to the first bundle path it inspects and then rejects windows from
  other paths ("no longer belongs to the approved app"). Keep using that one path. Run
  `SCRATCH_PATH=/tmp/tbm-<you> ./script/validate`, which builds, swaps your build into both
  bundles without disturbing running instances, and launches the test bundle in the background
  against the demo.
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

- Push a `vX.Y.Z` tag, only with the user's approval. Actions tests the tag, then signs,
  notarizes, staples and publishes the zip and its checksum. Running the workflow by hand on
  `main` is a dry run that keeps the zip as an artifact.
- One-time setup, by the certificate owner only:
  `./script/setup-release-secrets SHA1 AuthKey.p8 KEY_ID ISSUER_ID`, using a Team API key with
  Developer access. Agents never run it, create secrets or read keys and passwords.
- Locally: `SIGNING_IDENTITY=SHA1 BUILD_NUMBER=N NOTARY_PROFILE=toy-box-channels-notary
  ./script/release vX.Y.Z`. Without `NOTARY_PROFILE` the zip is named `SIGNED-UNNOTARIZED` and
  is never published.
- Hardened runtime, a secure timestamp and only the audio-input entitlement. Never `--deep`.
  Local builds use Command Line Tools, and CI uses the runner's selected Xcode 27 on `xcode-27`.
- The Developer ID certificate and its G1 intermediate expire February 1, 2027. Before then, move
  to a G2 certificate, rerun the setup, and update the workflow's intermediate URL and SHA-256.
- The app icon's only source is `Resources/AppIcon.icon` (Designer). After changing it, run
  `script/icon` and commit both it and `Resources/AppIcon.icns`.
- Never alter the user's installed validation bundle or microphone permission state to test a
  release.

## Source ownership

| Path | Owner |
| --- | --- |
| `Sources/ChannelKit/`, `Sources/ChannelClient/`, `Tests/` (except below), `script/`, `Package.swift` | Core |
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
