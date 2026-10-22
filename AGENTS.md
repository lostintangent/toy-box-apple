# Toy Box Channels for Mac

Native SwiftUI client for Toy Box Channels. [docs/spec.md](docs/spec.md) is the source of truth
for parity, protocol and design. Read its Design section before changing any view.

## Build and run

- Build only with Command Line Tools. Never use `xcodebuild`, because the Xcode license is not
  accepted on this machine.
- Use your own scratch path so parallel builds never share `.build`:
  - `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path /tmp/tbm-<you>`
  - `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test --scratch-path /tmp/tbm-<you>`
  - `SCRATCH_PATH=/tmp/tbm-<you> ./script/run` builds, bundles and opens a new app instance.
- Point the app at a server with `TOY_BOX_SERVER_URL` or Settings. Use the Minecraft demo server
  (`bun run demo` in `~/Desktop/toy-box-Minecraft`, port 3210) for write tests. The live server
  on port 3100 hosts real channels: read it freely, but never post or mutate there without the
  lead's approval of a specific scratch channel.
- Quit the instances you launch when you are done.

## Swift conventions

- The macOS 27 CLT SDK exports an unusable `@State` macro. Use `@ViewState`, which aliases
  `SwiftUI.State`.
- `ChannelKit` owns domain semantics and `ChannelClient` owns transport and stores. Views never
  reimplement reducer, audience, task, attention or transcript-grouping rules. Ask Core for a
  domain or store change instead of working around it in a view.
- `TranscriptView` is ChannelKit's message filter enum, so SwiftUI views use other names.

## Source ownership

| Path under `Sources/` | Owner |
| --- | --- |
| `ChannelKit/`, `ChannelClient/`, `Tests/`, `script/`, `Package.swift` | Core |
| `ToyBoxChannels/App`, `Shell`, `Sidebar`, `Settings`, `Shared`, `Channel/ChannelDetailView.swift` | Shell |
| `ToyBoxChannels/Transcript` | Transcript |
| `ToyBoxChannels/Composer` (composer and tray) | Composer |
| `ToyBoxChannels/Overview`, `Management` | Overview |

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
