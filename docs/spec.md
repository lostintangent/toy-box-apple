# Toy Box Desktop: spec

Toy Box Desktop is a native macOS client for Toy Box Channels. It gives the user the full Channel
pane experience (transcript, composer, overview) in an app that feels first-party on macOS. Toy Box
keeps owning Channels, agents, sessions and durable work. This app is a presentation and input
surface over the same public Channel protocol that the Minecraft client uses.

Reference sources (read-only):

- Toy Box server and pane: `~/Desktop/toy-box/src/features/channels` (start with its `AGENTS.md`)
- Minecraft client and the real contract fixtures: `~/Desktop/toy-box-Minecraft`
  (`docs/architecture.md`, `fixtures/channel-snapshot.json`, `fixtures/channel-transitions.json`)

## Success criteria

1. **Same protocol.** Listing, observing, paging, posting and reading use only `/api/v1` routes that
   Minecraft uses. No private TanStack server functions, no database access, and no parallel schema.
2. **Faithful state.** A Swift port of `reduceChannelState` produces the same state as Toy Box. Tests
   prove it against Minecraft's exported snapshot and transition fixtures.
3. **Pane parity.** Every capability in the parity checklist below works, or is explicitly excluded
   here with a reason.
4. **Idiomatic macOS.** This should read as an Apple-quality app, not a web view: native split view,
   sidebar, toolbar, inspector, menus, keyboard shortcuts, Settings, Dock badge and notifications,
   with correct behavior in light and dark mode, at any window size, and with accessibility.
5. **Resilient.** It resumes from the applied revision after a disconnect, falls back to a snapshot,
   visibly marks stale state, never auto-retries a send, and handles channel deletion cleanly.
6. **Verified.** Unit tests cover the model, reducer, transcript rows and audience policy. The running
   app is exercised against the demo fixture server and the live dev server, and we keep screenshots.

## Architecture

- Swift 6.4 (package tools 6.4) and SwiftUI on macOS 27 or later, Apple Silicon only, using AppKit where SwiftUI
  falls short (text input, for example). The project is a Swift package built with `swift build`
  from Command Line Tools, so it needs no Xcode project or Xcode license. A script assembles and
  launches a signed-ad-hoc `.app` bundle, stamping the binary with the installed SDK version so
  macOS draws it with Liquid Glass rather than in compatibility mode.
- **Targets:** `ChannelKit` is the pure domain: Codable wire types, the reducer, transcript rows,
  audience, tasks, presence and the SVG avatar path parser. `ChannelClient` handles transport:
  HTTP, SSE, the observer and the catalog. `ToyBoxDesktop` is the app. Tests live in
  `ChannelKitTests` and `ChannelClientTests`.
- **State:** each open channel has one `@Observable` store, which owns its `ChannelState`, connection
  phase, unread boundary and paging. The catalog store owns the channel list and refreshes it on
  launch, on app activation, on demand, and on a timer: about 5 seconds while the app is active, and
  about 15 seconds in the background so requests still reach the Dock badge and notifications.
  Neither waits for the main thread to start a request. Polling sends its first catalog request
  at once, and connecting starts the stream and the outbox read together. Events are read off the
  main actor and queued for it as each one decodes, after the restored outbox, so a snapshot that
  arrives while the first window is being built applies in the main thread's next turn.
  The first window connects its channel only once it appears. Connecting earlier gains nothing,
  because that snapshot already arrives while the window is built, and a channel loaded before the
  window holds the window back until its whole transcript renders, about 470 ms later on the launch
  benchmark.
  A window builds Overview and the composer once its first content has drawn and the main thread
  is about to sleep, or after a second for a channel that's slow to connect. Until then, a clear
  bar of the composer's resting height keeps the transcript's inset. That brings launch's first
  content about 340 ms sooner.
  A window, sheet or intent holds its channel's store while it shows it. When the last one lets
  go, the store stays connected for 5 seconds, so switching back lands on a live store. Its first
  frame then has a working composer, and the transcript lands without waiting on a reconnect. On
  the switch benchmark that's about 100 ms less main-thread time per warm switch. Only the two most
  recently released stores linger, and a server change disconnects them at once. A lingering store
  has no transcript, so it never marks read, and notifications come from the catalog, so it posts
  none.
  Views read the store's observed slices (`details`, `roster`, `agentStatuses`, `presence`,
  `messages`, `request`, `requestSequence`, `tasks`, `artifacts`, `artifactShares`, `routines`)
  rather than `state`, which changes on every event. An event then re-renders only the views that
  show what it changed. `roster` leaves out each agent's status, which `agentStatuses` carries, so
  status updates don't re-render identity. A catalog poll that changes nothing announces only
  `lastRefreshedAt` and `isLoading`, and a failure that repeats the current one isn't announced
  again. Views that only ask whether the catalog has loaded read `hasLoaded`.
- **Wire rules:**
  - Decode leniently, so unknown system message kinds and fields degrade to a generic row instead
    of failing the stream.
  - Resource URLs (artifacts, attachments) resolve against the configured server base URL, which may
    include a path prefix.

## Releases

Releases are Developer ID signed, notarized and stapled, then published with their SHA-256 checksum
and signed Sparkle appcast by `.github/workflows/build-and-release.yml` on an approved `vX.Y.Z` tag.
A manual run on `main` performs the same signing, notarization and appcast generation but keeps them
as artifacts, without publishing.
Local builds use Command Line Tools. CI uses its selected Xcode 27 toolchain on the `xcode-27` runner.

The app's bundle identity is `dev.toybox.desktop`. Agent validation uses `dev.toybox.desktop.test`,
and the benchmark uses `dev.toybox.desktop.benchmark`, keeping their preferences and permissions
isolated from the user's app.

Only the certificate owner runs the one-time setup:

```sh
./script/setup-release-secrets SHA1 APPLE_ID TEAM_ID
```

It uses an Apple ID and an app-specific password from account.apple.com. Its silent prompt reads
the password without echoing or logging it, and accepts piped stdin with or without a trailing
newline. Never pass the password as a script argument. The command optionally accepts `OWNER/REPO`
as the final argument and configures the local
`toy-box-channels-notary` keychain profile plus GitHub's `MACOS_SIGNING_CERTIFICATE`,
`MACOS_SIGNING_PASSWORD` and `NOTARY_APP_PASSWORD` secrets. Setup exports only the pinned
certificate's identity into a temporary encrypted file, then removes it on exit.

The workflow pins the public signing certificate SHA-1 (`69A492FDF7DDFC679B93DB465E0D5E94F22DAC6A`),
Apple ID (`joncart@outlook.com`) and Team ID (`RHFNBL7EG4`) directly, not as secrets. Keep those values
in sync with the setup arguments when rotating identities. CI stores the notarization login in a
temporary keychain profile. Missing or rejected credentials fail the release explicitly.

Agents never run setup with real credentials or read signing keys and passwords. The credential-free
regression suite, `python3 script/test-release-secrets.py`, replaces every credential, signing and
network command with a fake and runs in CI. For a local release, set `SIGNING_IDENTITY=SHA1`,
`BUILD_NUMBER=N` and `NOTARY_PROFILE=toy-box-channels-notary` when invoking `script/release vX.Y.Z`.
Without a notary profile, the archive is named `SIGNED-UNNOTARIZED` and is never published.
Notarization response tests also run macOS's real `plutil` against notarytool-shaped JSON, including
accepted, rejected, malformed and missing-status responses. The release script validates JSON by
extracting its status, not by treating it as a property list with `plutil -lint`.

### In-place updates

Sparkle 2.10.0 is an exact SwiftPM dependency of the app target. Every bundle includes the framework,
`Autoupdate` installer and `Updater.app`, thinned to arm64, with symlinks and license notices
preserved. Headers, modules and sandbox-only XPC services are omitted. The framework adds about
1.3 MB installed, or 0.5 MB compressed. Signing proceeds from installer to updater to framework to
app, verifying each component strictly and never using `--deep`. Developer ID releases use hardened
runtime and secure timestamps throughout. Ad-hoc development signing does not enable hardened
runtime, because library validation cannot match Team IDs between ad-hoc-signed binaries.

Only `script/release` adds the production `SUFeedURL` and `SUPublicEDKey`. The stable feed is
`https://github.com/lostintangent/toy-box-desktop/releases/latest/download/appcast.xml`, and every
enclosure points at that version's GitHub release asset URL. Development, validation,
snapshot and test bundles have no feed or verification key and never start an updater. Release
bundles enable automatic checking without Sparkle's permission prompt, but leave automatic
installation off by default. Both choices remain user-configurable through Sparkle.

The user runs `./script/setup-update-secrets [OWNER/REPO]` once. Sparkle generates or reuses the
app-specific `dev.toybox.desktop` Keychain account, without touching its global default key.
Setup uploads the exported key as `SPARKLE_ED_PRIVATE_KEY`, configures `SPARKLE_ED_PUBLIC_KEY` as a
public repository variable, and removes the temporary export. Keep a secure backup of the Keychain
key. Existing installs trust its public half, so losing or casually rotating it breaks the update
chain. Agents never run this setup with real credentials or read that key.

Before v0.1.1, the user approved renaming the old `dev.toybox.channels.mac` identity and its
unshipped Sparkle key. Rerun `./script/setup-update-secrets` to provision the new account and replace
the repository's update signing configuration. Only after setup succeeds, the user removes the
obsolete Keychain item with this exact command:

```sh
security delete-generic-password -s https://sparkle-project.org -a dev.toybox.channels.mac
```

Agents never execute this deletion or access the real keys. This rotation is safe only because
0.1.0 shipped without Sparkle and no published app trusts the obsolete key. The Developer ID
certificate and Apple ID app-specific password are unchanged. The renamed app needs new macOS
notification and microphone grants, and Computer Use needs approval for `dev.toybox.desktop.test`.

After notarization and stapling, `script/generate-appcast` uses Sparkle's checksum-pinned tools to
sign the finished archive and the whole feed with Ed25519. The archive signature, length, URL,
machine and human-readable versions, and minimum macOS version are checked before publishing.
The feed signature is independently verified with `sign_update`. Archive verification is required
before extraction, and signed feeds are required. Tag annotations are embedded as release notes,
with a version-title fallback for dry runs. Deltas are intentionally omitted for these small apps.
Both the feed and zip are attached to every release and retained by dry runs.

`CFBundleVersion` is `github.run_number.github.run_attempt`. Release workflows are serialized, and
the new numeric build must exceed every version in the latest published appcast. Missing or
malformed prior metadata fails the release instead of allowing a downgrade. The first Sparkle
release bootstraps from 0.1.0, which has no feed and must be upgraded manually. Local releases can
set `PREVIOUS_APPCAST` to apply the same monotonicity guard.

`script/test-sparkle.py` exercises packaging, inside-out signing, key setup, failure propagation
and numeric build ordering without real credentials. Its macOS native checks verify the bundled
architectures and signatures. A real `generate_appcast`/`sign_update` round trip uses an isolated
throwaway CryptoKit key file and verifies rejection of a modified archive and feed, never accessing the
default Sparkle Keychain entry.

## Protocol (v1)

| Request | Use |
| --- | --- |
| `GET /api/v1/channels` | Catalog `{version, channels, members, lead, working}` for the sidebar. `lead` is the profile every channel's lead shares, under the channel's ID, and is always present. `working` lists running agent IDs (added for this app) |
| `GET /api/v1/channels/:id` (SSE) | `snapshot`, then live events. With `after`/`Last-Event-ID`: replay, then `resumed` with full presence. `presence` is sparse and merges. `deleted` is terminal |
| `GET /api/v1/channels/:id/messages?before=N` | Older page of up to 100 messages `{version, revision, messages}` |
| `POST /api/v1/channels/:id/messages` | `{id, content, attachments?}` with a client UUID. 201 returns the message. 409 means a duplicate. Never auto-retry |
| `POST /api/v1/channels/:id/read` | `{sequence}` monotonic read, which acknowledges completion but never a request |

The model catalog is owned by Toy Box's Providers feature (`src/features/providers/AGENTS.md`),
not Channels:

| Request | Use |
| --- | --- |
| `GET /api/v1/models` | `{version, models, defaultModel}` for model pickers. Its URL, fields, version, status and cache headers are unchanged by the move to Providers, so no decoder migration is needed. A server process started before the move can still return 404 here until it restarts. Treat that as "models unavailable", never as a reason to invent a model |

Management routes (added to Toy Box for this app, documented in its Channels `AGENTS.md`):

| Request | Use |
| --- | --- |
| `POST /api/v1/channels` | Create `{name, purpose?, directory?, model}`. 201 `{version, channel}` |
| `PATCH /api/v1/channels/:id` | Edit `{name?, purpose? (null clears), model?}`. Returns `{version, channel}` |
| `DELETE /api/v1/channels/:id` | Delete the channel (204). The stream then sends `deleted` |
| `POST /api/v1/channels/:id/members` | Create a member `{name, role?, model?}`. 201 `{version, member}` |
| `PATCH /api/v1/channels/:id/members/:agentId` | Edit `{name?, role?, model?}`. Returns `{version, member}`. `model: null` clears the explicit override and is always allowed, even when the workspace default uses another provider. It never changes an established session's provider or history: a compatible default is followed, otherwise the existing provider's model is retained. After clearing, the returned member and its event omit `model`. Only an explicit model from another provider returns 422 |
| `GET /api/v1/channels/:id/members/:agentId/models` | `{version, provider, models, defaultModel}` for the Edit Member picker: models limited to the member's provider (session, else configured, else unrestricted when null). `defaultModel: null` means no compatible workspace default exists. It describes a model choice, not permission, so clearing the override stays available even when `models` is empty |
| `DELETE /api/v1/channels/:id/members/:agentId` | Remove a member (204) |
| `POST /api/v1/channels/:id/routines/:routineId/run` | Run a routine now (204) |
| `DELETE /api/v1/channels/:id/routines/:routineId` | Delete a routine (204) |

Errors return `{error}`. A malformed body is 400, a missing channel, member or routine is 404,
and a domain rejection such as a taken mention is 422 with a user-facing message. An unexpected
management failure is 500 with a generic `{error}`, and details stay in server logs. A 500 can
follow a committed change, including a deletion, so the client never retries a write on 500,
automatically or through an unchanged resubmission. It treats the outcome as uncertain and
reconciles from the authoritative catalog or channel detail before offering another write.

Attachments are `{name, url}` or inline `{mimeType, base64}`. Avatars are SVG path data in a
24×24 viewBox plus a hex color, and may carry an optional `ink` for the mark that only Toy Box's
own profiles set. The server serves the lead's profile in snapshots and the catalog, and the app
keeps no copy of it.

## Parity checklist

### Sidebar (channel list)

- [ ] Channels from the catalog, ordered like the browser and showing the lead and member avatars
- [ ] Each row shows last activity (`updatedAt`) and the working directory as a folder, with a way
      to open it, like the browser's location badge and Browse action
- [ ] Attention, in priority order: waiting for your reply (always shown, even when the channel is
      open), then all tasks completed (unread), then unread messages. Completion and unread are
      suppressed while the channel is open
- [ ] Live activity indicator while any agent is working (open channels use presence)

### Transcript

- [ ] Rows follow `transcriptRows`: user messages stand alone, consecutive agent messages form a run,
      and matching system messages merge. Each run message carries its addressee, its body without
      the leading mentions, its request state, whether it repeats the header, and whether it collapses
- [ ] Day dividers and the blue "New" unread divider, combined into one rule when they coincide. The
      unread boundary is captured on arrival and stays put while the user reads
- [ ] Markdown bodies with code, lists, links and tables, with mentions styled as agent references
- [ ] Attachments: inline images and video, and named files that open externally or in Quick Look
- [ ] Reactions (done, agree, celebrate, love, laugh) with their reactors
- [ ] System messages for every kind (tasks completed, member joined or left, renamed, purpose,
      directory, preview, artifact shared, routine scheduled, edited or deleted), each with its icon,
      text and tooltip
- [ ] The request marker on a flagged question until a later user message acknowledges it
- [ ] Working agents row showing who is working right now
- [ ] View filter: all messages, or only the user's own plus agent messages that never collapse
- [ ] Landing on the first unread row or the end, following the user's own post, and paging older
      history while scrolled to the top
- [ ] Reading advances `read` as messages become visible (active observation only)
- [ ] Copy message, plus reply and mention actions that edit the draft
- [ ] Removed agents display as "Deleted agent"

### Composer

- [ ] A multi-line input that grows to about three rows. Return sends and Shift-Return inserts a newline
- [ ] `@` completion: everyone, lead and members, each with an avatar and role
- [ ] An audience preview ("To Lead", or the mentioned agents) computed by a port of
      `resolveChannelAudience`
- [ ] Image attachments by paste, drag and file picker, sent inline as base64
- [ ] A per-channel draft that persists across launches
- [ ] An "Input needed" control while a request is pending: hovering previews the question and
      clicking reveals it, paging back if needed
- [ ] Disabled while disconnected, with a visible stale state. Failed sends stay in the draft with
      an error and are never retried automatically
- [ ] Optimistic message that the committed echo replaces

### Composer tray

- [ ] Shared artifacts, newest first
- [ ] Tasks with progress
- [ ] Preview: a URL preview opens in the browser, and a screen preview opens Toy Box

### Overview (inspector)

- [ ] Purpose, directory and preview
- [ ] Team: the lead first, then members, with avatar, role, presence, status text and the waiting
      wake time (shown as a countdown)
- [ ] Artifacts with when each was shared. Markdown opens in an in-app reader; others open in
      Toy Box or the default app
- [ ] Tasks: a nested tree with status, owner avatar and diff totals rolled up from descendants
      (pending tasks hide counts). Each task's own artifact action opens it. Section headings show
      counts
- [ ] Routines by title with their schedule, expanding to show the prompt

### Management (via the management routes above)

- [ ] Create, edit and delete a channel
- [ ] Create a member from an unknown mention, edit a member, and remove a member
- [ ] Run and delete a routine

## macOS idioms

- `NavigationSplitView` with a source-list sidebar, the transcript in the content column, and the
  overview as an `.inspector`
- Toolbar: channel title and purpose subtitle, presence summary, a view-filter menu, the inspector
  toggle, and Open in Toy Box
- Menu commands and shortcuts: next and previous channel, next unread, toggle inspector, focus the
  composer, jump to the request, refresh, and open the channel in a new window
- A Settings scene for the server URL (default `http://localhost:3000`, the port the `toy-box` CLI
  serves) and connection test
- A Dock badge counting channels that need attention, plus user notifications for requests and
  completions in channels that aren't currently focused
- Multiple windows, state restoration, and accent color and vibrancy that respect system settings

## Performance budgets

`script/benchmark` checks these on a release build against `script/perf-demo.mjs`, with 100
messages loaded and again with every older page loaded. It times the main run loop three ways:

- **Busy**: every pass from waking until the loop is about to sleep, added up.
- **Longest saturated span**: the longest of those passes. When work arrives faster than it
  finishes, main stays awake through many frames, so a long span isn't always a stall.
- **Longest frame gap**: the longest stretch with no chance to draw, from the loop waking or
  exiting until it next exits or sleeps, which is where Core Animation commits. This is what shows
  a stall.

| Scenario | Budget |
| --- | --- |
| Each live message | 16 ms median busy |
| 50 messages 20 ms apart | 100 ms longest frame gap. The saturated span and busy time are reported beside it |
| Each older page | 250 ms busy |
| Warm switch | 150 ms median longest saturated span. A switch that lands over several frames feels as slow as one long frame, so it isn't budgeted on frame gaps |
| Key window with 4, then 20, working agents | 3% process CPU over 15 s, so a continuous animation that updates views every frame fails it |

Launch and idle report the same figures with no budget.

## Design

### Direction and reference

**A calm place to direct a working team.** The conversation is the primary surface. Navigation
and controls use the system's materials, while messages remain legible, quiet and opaque. Agent
identity supplies the color. Attention is scarce: a question, completion and unread state are
different signals, not three versions of a notification dot.

The layout and behavior below are grounded in the running pane at `http://localhost:3100`,
`channels/AGENTS.md`, `ChannelComposer`, `AgentRun`, `SystemMessageGroup`, `transcriptRows`,
`ChannelOverviewContent`, `AgentItem`, `ChannelReactions` and `channelTaskItems`. Preserve their
domain decisions rather than restyling every event independently. The native differences are
navigation, presentation, keyboard access, local draft storage and offline editing.

[Main-window wireframe](channel-window.svg) shows the default geometry, a pending question, the
New divider, agent coordination, tray and expanded inspector. Its example content is illustrative,
not a second specification or a proposed change to any live channel.

### Whole-window composition correction

The visual review was reopened on 2026-10-22. Functional and accessibility corrections do not
constitute final visual acceptance. Review the actual user-facing build as a whole, not only an
isolated fixture render. The governing composition is one native channel title, one quiet
inspector, legible tonal messages, and one floating glass composer carrying the activity line.
The Liquid Glass composition below supersedes every earlier dock, toolbar-band and inspector
header rule.

The conversation lane spans the full detail column with 24-point horizontal insets, as in
Messages. Its width W is the conversation width minus 48, with no maximum. Agent messages pin to
the leading edge. The 32-point avatar and 12-point gap form a 44-point identity gutter, and each
agent surface hugs its content up to min(W − 44, 760). Your messages pin to the trailing edge
and hug their content up to min(0.8 × W, 640). Both caps multiply by the View > Text Size scale.
The caps hold a line near 115 characters, so a wider window adds air between the two sides
rather than longer lines. The floating activity row and composer span the whole lane, W. The
composer's leading edge sits on the avatars' leading edge. At the default 720-point conversation
width, W is 672, agent surfaces reach 628 and your messages 538. Do not let modifier order
produce a composer wider than the lane.

Normal agent surfaces use a visible neutral tonal fill, not an almost invisible outline on the
same color as the conversation. Derive the fill from primary ink over the opaque conversation
background: approximately 4.5% in light appearance and 7% in dark. Preserve normal primary text,
agent-colored avatars and the muted accent treatment for the user's own messages. A pending
question takes a warm orange wash, its explicit label and a Reply button, never an outline.
Increase Contrast adds a meaningful boundary rather than making all agent messages saturated
identity-colored cards. Every bubble, agent or your own, gets a 1-point `primary` edge at 50%, and
pending requests keep their orange edge.

The working summary is live application status, not historical transcript content. It floats
as a glass capsule directly above the composer, even when reading older history. Show at most
three 20-point avatars and the count or name. Details open in a native popover on explicit
activation. Hide working presence when observation is stale. Place Jump to Latest at the
trailing edge of the same floating row when needed. Neither control may become a synthetic
message or read target.

The context tray belongs inside the composer as a 28-point header, separated from text entry by
one internal hairline. Its controls share a baseline, rather than giving Tasks an extra
underlined progress track. Task rows in the tray popover and the inspector share one layout with
no disclosure gutter. Sibling status icons align on one x with their section heading, each
nesting level adds 22 points so a child's status sits under its parent's title, and a parent's
chevron trails its title inline (see Tasks in the Overview section).

The inspector has no title row of its own. The window toolbar never repeats the purpose. The
full purpose and agent roles belong in their inspector and detail presentations, not the title
bar or idle Team rows.

The shared `ConversationRail` modifier lays out the scrollable transcript, the floating activity
row and the composer on one lane. Hosted geometry regressions cover 420, 720, 760, 1000 and
1400-point conversation widths at the default text size. They yield composer widths of 372, 672,
712, 952 and 1352, agent surface maxima of 328, 628, 668, 760 and 760, and your-message maxima of
298, 538, 570, 640 and 640 (rounded). The
scroll-end anchor includes the intentional 16-point trailing clearance rather than adding a full
run gap. Consecutive system events retain their own 8-point breathing room without an additional
20-point conversation-run gap. Older-history loads preserve the anchored message with 0.0-point
displacement at 1280 x 840 and 760 x 560 in both appearances.

### Liquid Glass composition

Builds before 2026-10-22 were linked with an SDK stamp of 15.0, so macOS 27 drew them in
compatibility mode without Liquid Glass. That, plus the opaque unified toolbar band added during
the visual pass, is why the app read as dated. The app now requires macOS 27 on Apple Silicon,
links against the installed SDK, and `script/validate` fails when the bundle's SDK stamp is below
27. There is no fallback appearance and no availability branching in views.

**Layers.** Content is one opaque layer made of the sidebar list, the conversation and the
inspector. Liquid Glass is reserved for the navigation layer above it: toolbar controls, the
sidebar material, the composer, the activity row, Jump to Latest and transient notices. Never
put glass on messages, inspector sections or list rows, and never place glass on glass. Controls
inside a glass surface are plain or borderless, except Send. Let the system draw every standard
glass element. Custom `glassEffect` appears only on the surfaces this section names.

**Toolbar.** Use the system's default window toolbar style. Remove the explicit
`.windowToolbarStyle(.unified)`, and set no `toolbarBackground`, `toolbarBackgroundVisibility`
or column title plate anywhere. Never draw our own rule or band under the toolbar. The
conversation and the inspector scroll beneath the toolbar, and a top scroll-edge effect
separates content from the controls. Give both the conversation's and the inspector's
`ScrollView` `.scrollEdgeEffectStyle(.hard, for: .top)`. On macOS 27 the automatic top edge
resolves to the soft style, which the system doesn't draw at the top of a key window, so messages
and the inspector's dense 11-point status text ran crisp under the title and the glass controls.
The hard edge draws the toolbar's 1-point divider at the same height across both columns, even at
rest, so the toolbar reads as one unified band and rows blur as they pass beneath it.

The detail toolbar shows the channel name in the system title position. Its trailing items form
two `.primaryAction` groups. Message View and Channel Actions share one glass group, then
`ToolbarSpacer(.fixed, placement: .primaryAction)`, then Overview (`sidebar.trailing`) alone.
When the inspector is open, the Overview button sits over the inspector column, as in Xcode and
Pages. The only custom toolbar tint is the active
Message View filter symbol.

**Sidebar.** The `NavigationSplitView` sidebar runs the full window height with the traffic
lights over its top, and the system decides its shape. It runs flush to the window's leading,
top and bottom edges with no margin, as Finder and Mail do. Do not set a sidebar or list
background, and never imitate the shape by hand. Inactive windows render the sidebar and inspector materials as flat fills,
which is expected. Replace the hand-built search capsule with
`.searchable(text:placement: .sidebar, prompt: "Search Channels")`, and drive Edit > Find
Channel (Command-Option-F) through `.searchFocused`. Filtering semantics are unchanged.

**Inspector.** The Overview inspector runs the full window height, with toolbar items floating
over its top and its content scrolling under them. Attach `.inspector` where it produces that
full-height column, not a column that starts below the toolbar. Remove the 40-point title row,
its close button and its divider. The Overview toolbar button, Option-Command-0 and View > Hide
Overview close it. Give the inspector container the accessibility label "Overview". Content
starts 12 points below the top safe area, with 16-point horizontal insets and 16 points at the
end. Use the system inspector background, with no custom fill. In narrow windows the sheet keeps
a visible "Overview" title in a 16-point inset header and a Done button that is the default
action. Escape also closes it. The sheet has no X control.

**Conversation surface.** Keep `textBackgroundColor` as the opaque conversation background, and
let it extend beneath the toolbar and the composer, never clipped at a safe-area edge. The
transcript `ScrollView` respects the top and bottom safe areas, so its first row rests below the
toolbar and its last row rests 16 points above the floating controls. Rows scroll beneath both.
Use `.scrollEdgeEffectStyle(.soft, for: .bottom)` on the transcript, because the composer floats
inside the content rather than in the toolbar. The top edge is `.hard`, as Toolbar describes. The
soft edge is a fade that ramps across the whole bottom bar, from nothing at the
activity row's top to about 75 percent under the composer. Rows in the 8-point slot between the
activity row and the composer stay legible and only lightly faded. That is the system effect
working, not a gap. Never patch it with a mask, a fill or `.hard`, which draws its divider flush
against the capsules.

Glass covers part of the scroll view, so visibility excludes it. Read marking, first-unread
landing, Reveal, follow-at-bottom (within 48 points of the end) and paging anchors all measure
against the unobscured viewport between the toolbar and the floating controls. A message hidden
under the composer or toolbar is not visible and must not be marked read.

**Floating composer.** Shell attaches the composer with `safeAreaBar(edge: .bottom, spacing: 0)`
instead of `safeAreaInset`, including in the offline placeholder state. The bar has no
background. The composer is one glass surface.

| Property | Value |
| --- | --- |
| Width | The full `ConversationRail` lane, W. Its leading edge sits on the avatars' leading edge, with no gutter pad |
| Bottom inset | 16 points from the window's bottom edge |
| Shape | Rounded rectangle, radius 18, continuous corners, so a single 36-point row would read as a capsule |
| Material | `.glassEffect(.regular, in: .rect(cornerRadius: 18))`, not interactive |
| Edge | No custom stroke. Increase Contrast adds a 1-point `primary` stroke at 50% on the same shape |
| Drop target | 2-point accent stroke on the same shape while an image drag is over the composer |
| Focus | No ring around the composer. Like Messages and Notes, the primary text view shows focus with its caret |
| Text | Transparent NSTextView and scroll view. 14-point body, inset 12, one 20-point line minimum, three lines before scrolling |
| Tray | 28-point header at the top, then a 1-point `separatorColor` hairline inset 12 on both sides |
| Controls | 28-point row, 8-point horizontal and bottom padding, 8 points between controls |
| Send | The one filled control, a 28-point accent circle with a white `arrow.up`. Disabled uses a `quaternary` fill and a secondary symbol |
| Dictate | Borderless `mic` 8 points before Send, styled like Attach Image. Listening tints a 28-point circle with accent at 15% under an accent `waveform`, never a second solid fill. States are under Composer and tray |
| Height | About 80 points without the tray and about 109 with it, growing with text and thumbnails |

Composer errors, the connection explanation and the 12,000-character limit render inside the
glass surface as a caption notice row at its top, with 12-point horizontal and 8-point top
padding, separated from the tray by the same hairline. They never float as loose text over
messages. The system glass becomes opaque under Reduce Transparency. Do not substitute a custom
fill.

**Activity row.** The transcript adds its own `safeAreaBar(edge: .bottom, spacing: 0)` to its
scroll view for the floating controls, so they stack directly above the composer bar. The row is
present only while live agents are working or the reader is away from the end. Otherwise it
reserves no space.

| Property | Value |
| --- | --- |
| Position | 8 points above the composer, on the same rail, with leading and trailing edges matching the composer |
| Working capsule | Leading. Height 28, `.glassEffect(.regular.interactive(), in: .capsule)`. At most three 20-point avatars, inset 4 so they sit concentric with the capsule, 6 points to the label and 12 trailing padding |
| Label | "Ada is working" or "3 agents are working", 12-point medium in the primary label color. Activation opens the existing Working Now popover anchored to the capsule |
| Jump to Latest | Trailing. The same capsule and glass, with `arrow.down` and "Jump to Latest" in 12-point medium and 12-point horizontal padding |
| Notices | Reveal, send-action and read-position errors stack 8 points above the row in a glass rounded rectangle, radius 14, with primary caption text, 12 horizontal and 8 vertical padding, and borderless Retry or Dismiss |
| Motion | Appears and leaves with opacity and a 4-point rise over 0.2 seconds, ease-out. Reduce Motion uses opacity only |

When the row appears or leaves, a reader at the end stays at the end, and a reader elsewhere
keeps their anchor. Do not wrap the composer and the row in a shared `GlassEffectContainer` with
spacing of 8 or more, because that fuses them into one shape.

**Stale banner.** Replace the full-width `.bar` strip with a top `safeAreaBar` holding one glass
capsule, centered on the rail 8 points below the toolbar. It is 32 high with 14-point horizontal
padding and holds `wifi.exclamationmark`, "Reconnecting. Messages may be out of date" in
caption, and a borderless Retry. The full error stays in its help text.

**Real-window acceptance.** App snapshots capture the composited window and its sheets with
ScreenCaptureKit, so they show glass and content beneath a `safeAreaBar` as drawn. Without Screen
Recording they warn and fall back to `cacheDisplay`, which leaves both blank, and those captures
cannot judge this section. Judge this section only in a real window on the stamped build,
captured with ScreenCaptureKit or Computer Use, in light and dark, active and inactive, with the
inspector open and closed, scrolled to the top and mid-history, and with Reduce Transparency
and Increase Contrast. Confirm that the sidebar runs flush and full height, that the
only rule under the toolbar is the system's own edge, that no inspector row runs under the
toolbar controls, that message text beneath the composer
never competes with typed text, and that the activity capsule and composer read as two related
pieces of glass.

| Surface | Expected |
| --- | --- |
| Sidebar | Flush and full height, no margin |
| Conversation top edge (explicit `.hard`) | Crisp 1-point divider, also at rest, in key and inactive windows |
| Inspector top edge (explicit `.hard`) | The same divider, continuous with the conversation's |
| Bottom edge above the composer | Our explicit `.soft` fade, ramping across the activity row and composer |
| Glass controls, composer, capsules | System Liquid Glass |

**Liquid Glass slider.** macOS 27's Liquid Glass setting in Appearance runs from Clear to
Tinted and is stored as the global default `NSGlassTintAmount`, 0 to 1. Every glass surface
here is system glass, so it follows the slider exactly as the toolbar buttons and search field
do. Never read the value or compensate for it with fills, strokes or opacity. At Clear, content
beneath the composer may show as soft color but never as readable text, and every label inside
the glass stays legible. At Tinted, the glass turns nearly opaque. To check both ends without
touching the user's setting, launch a test build with `-NSGlassTintAmount 0` or
`-NSGlassTintAmount 1`, which overrides it for that process only. The hover Reply and Copy
capsule keeps `.regularMaterial` and doesn't follow the slider, because it belongs to its
message in the content layer.

### Window and navigation

All dimensions are logical points, not pixels.

| Surface | Default | Limits and behavior |
| --- | --- | --- |
| Main window | 1280 x 840 | Minimum 760 x 560. Restore size, selected channel, sidebar, filter and inspector per window. When quitting closed the windows, the first new window at launch opens on the channel you were last in on that server. Later new windows open without one |
| Sidebar | 248 wide | Resizable 220...320. Full window height, system floating glass panel and source-list selection |
| Conversation | Remaining width | At least 420. One full-width lane inside 24-point side insets. Agent surfaces cap at 760 and yours at 80% of the lane up to 640, both scaled by Text Size. The floating composer spans the lane |
| Inspector | 312 wide | Resizable 280...400. A dragged width survives sidebar toggles, channel switches and hiding and showing Overview. Full window height with no title row. Do not squeeze conversation below 420 |
| Toolbar | System height | System default style, transparent, glass controls, traffic lights and normal window dragging. No band or rule beneath it |
| Narrow window | Below 1000 wide, or wherever a wider sidebar or inspector leaves the conversation under 420 | Inspector opens as a native sheet, preferred width 360, rather than stealing transcript width |

Use `NavigationSplitView` for sidebar and conversation, and a trailing `.inspector` when there is
room. The inspector is initially visible at the default width. Remember its desired visibility
when temporarily adapting to a narrow window. Only the toolbar, the menu or a divider drag change
that choice. Resizing, tiling and AppKit's own collapses never do. The column steps aside 20
points before the split view's minimum, so a live resize never stalls against it. An abrupt
resize below that width, such as tiling, removes the column without animation, because AppKit
can't lay out a split view narrower than its minimum. Do not automatically hide a user-opened
sidebar.
With the sidebar hidden, the lane and composer widen with the window. Messages keep their
readable caps and stay pinned to their edges.

The sidebar toolbar holds the sidebar toggle, title "Channels" and New Channel (`plus`).
The detail toolbar shows only the channel name, without a decorative hash prefix or purpose
subtitle. The name is a title menu, the pattern Pages, Keynote and Numbers use for a document
title, so channels stay one click away with the sidebar collapsed. `toolbarTitleMenu` only draws
for document-based windows, so the title is a native toolbar `Menu` in the navigation slot,
styled as the system title: 15 semibold, dimmed in inactive windows, and a chevron that fades in
on hover. Keep `.navigationTitle` for Mission Control and the Window menu. The title text sits
where the system title did, 20 points from the detail column's leading edge with the sidebar
visible, and at the system title's spacing after the leading toolbar items with it collapsed. It
lists every channel in sidebar order with the current one checked, then a divider, New Channel… and
Edit Channel…. Choosing a channel behaves like selecting it in the sidebar. Items mirror the
sidebar's attention state with the system menu-item badge (Input Needed, Unread or Done). If the
title menu can't carry badges, omit them rather than appending text to channel names. Shell
verifies the hover chevron and menu in the real glass toolbar.
Trailing controls are Message View (`line.3.horizontal.decrease`),
Channel Actions (`ellipsis`), and Overview
(`sidebar.trailing`). Put Open in Toy Box in Channel Actions and the menu bar, not another
permanent toolbar button. A long name truncates at the tail like the system title, so every
control fits down to the 760-point minimum window. NSToolbar never compresses a SwiftUI item, so
the title takes its width from the detail column. It ends 12 points short of an open inspector
rather than running over it, and leaves the 20 points NSToolbar needs before the trailing capsule,
plus 4 of margin. While it's truncated, its help shows the full name instead of Switch Channel,
like an expansion tooltip, and the menu still names the channel in full. Should the toolbar run out of room
anyway, Channel Actions overflows first, then Message View, and the title and Overview stay. Keep
working status in the floating activity row, not duplicated beside the window title.

Opening a channel selects it in the current window. Command-click or Open in New Window creates a
separate window for that channel and leaves the current window's channel and selection unchanged. Windows share the same channel store and draft. Only a key,
visible conversation actively acknowledges reading. Restoring a window must not send a message or
silently mark its unseen content as read.

### Visual system

Use SF Pro through system fonts and semantic weights. No custom typeface, hard-coded all-caps
section headings, gradients on messages, dashboard cards around every section, or decorative
drop shadows. Use an 8-point spacing rhythm, with 4-point adjustments inside compact controls.

| Token | Native treatment |
| --- | --- |
| Conversation background | `textBackgroundColor`, opaque in both appearances |
| Agent message surface | Neutral tonal fill over the conversation, approximately 4.5% primary ink in light and 7% in dark. A pending request swaps it for a warm orange wash. Borders only under Increase Contrast |
| Your message surface | Accent at 9% over the conversation, with normal label text. Under Increase Contrast, the same 1-point `primary` edge at 50% as agent bubbles |
| Navigation and inspector | System sidebar and inspector materials, no manual blur stacking |
| Floating controls and popovers | Native toolbar, popover and control materials |
| Text | `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor` by hierarchy |
| Selection and focus | System accent, source-list selection and focus ring. Respect user accent |
| Toy Box identity | The lead's avatar exactly as the server supplies it, a navy `#1E3A8A` circle with a gold `#FACC15` outline star, drawn as that color's `.gradient` like every avatar. Channel icons keep Toy Box's channel cyan `#0891b2`, which no longer belongs to the lead. Recolor neither to the accent |
| Unread | Semantic system blue, 1-point New rule. Blue does not mean working |
| Requests | Orange wash on the pending bubble, orange `questionmark.bubble.fill`, primary label text and a Reply button. Never an outline |
| Completion and additions | The shared completion green (`#196C2E` light, `#70D58A` dark) plus a knocked-out checkmark or explicit `+` sign. Never a white glyph on system green |
| Error, blocked and removals | Semantic system red plus symbol, label or explicit `-` sign |

Let the system render its Liquid Glass toolbar, sidebar and navigation controls, as described
in the Liquid Glass composition section. Do not give the detail column a separate rectangular
title-bar plate that steps against the sidebar, and do not draw a band or rule under the
toolbar. The active and inactive window must each read as one window. Custom glass is limited
to the floating composer, the activity row, Jump to Latest, transient notices and the stale
banner. Reduce Transparency makes glass and material backgrounds opaque. Increase Contrast strengthens separators and control outlines, not saturation alone.
Small status, action and diff-count text must reach 4.5:1 against its actual background in both
appearances. Green additions and red removals need contrast-safe adaptive text colors, not raw
system green/red that can fail on a light inspector or popover background.
Raw system orange is not a safe foreground for small text on white. Use a contrast-safe adaptive
amber text token, or primary text with an orange symbol, for Input Needed, request labels, waiting
details and unmatched-audience warnings. Non-text status symbols need at least 3:1.

| Content | Size and weight | Layout |
| --- | --- | --- |
| Sidebar channel title | 13, medium | One line, tail truncation |
| Sidebar detail and timestamps | 11, regular | Secondary, tabular digits for time/counts |
| Message body and composer | 14, regular | Approximately 20 line height. Never compress line height to fit |
| Message author | 12, semibold | Timestamp and addressee 11, regular |
| Day divider and system rows | 11, semibold / 11, regular | Centered, secondary, values in primary medium |
| Inspector section heading | 13, bold (Headline) | Count follows in 13 regular secondary. No capsule, no forced uppercase |
| Inspector body | 13, regular | Approximately 18 line height |
| Inspector status and detail lines | 11, regular | Secondary, tabular digits for counts and countdowns |
| Inline code and diff counts | System monospaced, 12 / 11 | Code blocks scroll horizontally |

Honor the system accessibility text size where available and a native View > Text Size control
(Smaller, Default, Larger). Scale content text, row height and wrapping together. Keep toolbar and
standard controls at native sizes. At the largest size, no critical text truncates without an
accessible full value or an expansion action.

### Sidebar

Use the system sidebar search field from `.searchable(placement: .sidebar)`. It filters the local
catalog by channel name, purpose or directory without making a network search request. Preserve
the selected channel while filtering. The list remains one "Channels" group in server order.
Do not reorder it for presence or attention. Refresh preserves scroll and selection.

Rows follow the Mail and Messages list pattern: who or what on the left, when on the right, and
detail beneath. Each row is at least 52 high (scaled with text size), with 8 horizontal and 8
vertical content padding and native source-list selection. A 30-point channel icon sits 10 points
before the text and is centered on it: a circle filled with `Color(#0891b2).gradient` (Toy Box's
channel cyan through SwiftUI's standard gradient, a constant of its own and never read from the
lead's avatar) and a 14-point semibold white `number`. A round icon
matches the avatars and status glyphs and replaces the tinted rounded tile, a web convention.

The first line is the name (13 semibold, primary, one line, tail truncation), then at least 6
points, then the last-activity time (11 regular, secondary, tabular, never truncated), aligned on
the first baseline. The second line is 18 high and 3 points below. It leads with the folder token
and ends with the working-agent stack, 6 points, and then attention. Only working agents appear in
the stack, in existing team order. Avatars are 16 and overlap by 4 with the shared 1.5-point
knockout (see the stack paragraph under Transcript). They show at most three, then `+N` in 9-point
medium, secondary and tabular, with 7 points of leading padding. Draw no presence rings, outlines
or separate spinner. An idle or stale channel has no activity stack.

**Faces yield to the folder.** On line 2 the folder name identifies the channel, while the stack
only summarizes it. When space runs short, the stack gives up faces before the folder gives up
letters. Build line 2 as `HStack(spacing: 0)`: the detail, a spacer, the stack, then attention
with 6 points of leading padding. After a folder token the spacer's minimum is 6, so with the
token's own 6-point trailing padding the name always keeps 12 points before the stack. After
purpose text the minimum is 12. Both kinds of row wrap line 2 in `ViewThatFits(in: .horizontal)`.
A folder row offers, in order:
1. The full stack, with the token at `.fixedSize()`.
2. Each smaller face count down to one, the token still fixed. Offer a count only while its `+N`
   stands for at least two agents, because `+1` is wider than the face it replaces. Two working
   agents therefore have only the full stack, and three go from three faces straight to one face
   and `+2`.
3. The smallest of those stacks with the token free to middle-truncate, as the last resort.

`AgentAvatarStack` takes a `limit` (default 3) for this. At the default 248-point width,
"toy-box-mac" with five agents working and unread reads in full beside one face and `+4`. A folder
name of about 11 characters stays whole beside any stack and attention, about 15 without
attention, and wider sidebars restore faces. Only longer names or the 220-point minimum still
truncate.

Purpose rows yield the same way, with the same face counts, but only to keep a readable stem,
because prose truncates anyway and a face carries more than a few letters. Each purpose candidate
measures the text as `.frame(minWidth: 0, idealWidth: 60, maxWidth: .infinity, alignment:
.leading)` with `.layoutPriority(1)`, so a candidate fits only when about ten characters of
purpose remain. The last resort is again the smallest stack with the text free to tail-truncate.
Nothing changes at 248 or wider. At 220, "Build…" becomes "Build a wel…" beside one face and
`+3`, and a short purpose like "Write docs" stays whole.

Help and VoiceOver always name every working agent, however many faces show.

**Last-activity time** is the catalog's `updatedAt`, which the server bumps for every appended
message and for user edits, but not for task revisions alone. Format it as Mail and Messages do,
with no relative wording: today shows the time (`date.formatted(date: .omitted, time:
.shortened)`, "9:04 AM"), the previous day shows "Yesterday", 2 through 6 days ago show the
weekday ("Tuesday"), and anything older (including 7 days ago, which shares today's weekday name) shows a short numeric date (`.dateTime.month(.defaultDigits)
.day().year(.twoDigits)`, "10/14/26"). A future timestamp from clock skew counts as today. Refresh
on a 60-second timeline so labels roll over at midnight. Help and accessibility say "Last activity
today at 9:04 AM".

**Folder token.** When the channel has a directory, line 2 leads with a 10-point medium `folder`
symbol, 4 points, then the last path component (11 regular, secondary, middle truncation). The
token has 6 points of horizontal padding, is outset 6 points to the left so its glyph aligns with
the name, and is 18 high with no resting fill. Whether it's a button depends on whether the
directory is on this Mac. The directory is a path on the server, so it is openable only when both
of these hold:
- The server URL's host is this Mac: `localhost`, a `*.localhost` name, `127.0.0.1`, `::1`, or one
  of the names in `Host.current().names`.
- `FileManager.fileExists(atPath:isDirectory:)` finds a directory there.

Check this when the catalog loads or refreshes and when the app becomes active, and cache it per
server and path. Never stat on every render. The three folder states are:

| State | Token | Click and hover | Help |
| --- | --- | --- | --- |
| Openable | `folder` and name, secondary | Hover shows a capsule fill of primary at 8% light or 12% dark, plus 5% while pressed. Click opens the folder in a Finder window with `NSWorkspace.selectFile(nil, inFileViewerRootedAtPath:)`, never `NSWorkspace.open`, so a directory that is a package such as an app bundle never launches. It never selects the row | "Open toy-box in Finder", then the full path with `~` abbreviation |
| Server is another machine | `folder` and name, secondary | Static: no hover fill and no action | "On [host]: [full path]. Folders open only when the server runs on this Mac." |
| Missing on this Mac | `questionmark.folder` and name, secondary | Static | "This folder no longer exists: [full path]" |

Every token uses secondary ink, so the folder name stays readable in every state, including on
the accent selection. The glyph, its help and the lack of a hover capsule mark a folder as
unavailable. Don't dim the missing token: 30% or tertiary ink measures under 2:1 at rest and
about 1.6:1 on the accent.

With no directory, line 2 leads with the purpose's first line (11 regular, secondary, tail
truncation). With neither, line 2 holds only its trailing indicators, and the row keeps its height.

**Selection.** Selected rows use the native source-list highlight. In the key window it is the
accent fill (`backgroundProminence == .increased`), and every custom color must yield to it. The
icon becomes a 22% white disc with a white `number`. The request bubble, completion check and
unread dot become white. The hover capsule becomes 20% white. Text uses `.primary` and
`.secondary` so it whitens on its own. Working avatars keep their own colors. Never draw cyan,
orange or green on the accent fill. In an inactive window, or when the list isn't focused, the
highlight is gray and every row color returns. Search, filtering and keyboard selection never
change these metrics.

Attention sits at the trailing end of line 2, in a 16-point slot shown only when there is
attention. The name and time line never moves:

| Priority | Indicator | Help and accessibility |
| --- | --- | --- |
| Pending request | Orange `questionmark.bubble.fill`, 13 point | "Waiting for your response". Remains visible while open |
| Unread completion | Semibold `checkmark.circle.fill` in the shared completion green, check knocked out | "All tasks completed". Suppressed for an open channel |
| Ordinary unread | Blue 7-point dot | "Unread messages". Suppressed for an open channel |
| Working, without attention | Working-agent avatar stack, no extra spinner | Names of agents working. Not an unread badge |

The working-avatar stack exists independently of attention, so a working team and pending question
can coexist. Keep the full-team names in row help/accessibility even though idle members are no
longer pictured in the activity stack. Closed channels use catalog activity only if the protocol actually supplies it. Never
invent presence or keep stale work animations after losing observation.

The row stays one accessibility element. Its value reads in this order: last activity, folder (with
"not on this Mac" or "missing" when it applies), attention, working agents, then team. When the
folder is openable, the row adds an Open Folder in Finder action.

Context menu, in groups:
1. Open in New Window, Open in Toy Box.
2. Open Folder in Finder, Open Folder With, Copy Folder Path.
   - The first two appear only when the folder is openable. Open Folder With lists
     `NSWorkspace.urlsForApplications(toOpen:)` for the folder, with the default app first and
     then the rest alphabetically, each with its 16-point icon.
   - Copy Folder Path appears whenever the channel has a directory, including remote and missing
     folders, and copies the full server path.
   - Omit the whole group when there's no directory.
3. Edit Channel….
4. Delete Channel…, separated and destructive, never triggered by the unmodified Delete key.

**Catalog activity:** the catalog now includes `working`, the IDs of leads and members whose
sessions are running. This is the same fact the browser reads from workspace session state and
the stream uses for presence. Sidebar rows for closed channels use it, while an open channel uses
its live presence. Activity can lag by one catalog refresh. It must clear when observation is lost
rather than keep animating.

**Connection footer.** The bottom of the sidebar names the server this window talks to, as the
wireframe's `sidebar-connection` group draws it. Attach it with `.safeAreaBar(edge: .bottom)` on
the sidebar list so rows scroll beneath it under the system scroll edge effect. Give it no
background, divider or material of its own. The status line is a 7-point dot (the unread dot's
size), 6 points, then the server's host and port in 11 regular, secondary, one line, middle
truncation. Omit the port when it is the scheme's default. The line is 22 high with 6 points of
top padding. The dot's leading edge aligns with the channel icons, 24 points from the sidebar's
leading edge, and its center sits 24 points above the sidebar's bottom edge, so it clears the
corner as evenly as the rows clear the side.

| Catalog state | Dot | Above the status line |
| --- | --- | --- |
| First load | `.secondary`, then a spinner after 300 ms | Nothing. The placeholder rows already show loading |
| Last refresh succeeded | `.green` | Nothing |
| Refresh failing, rows kept | `.orange` | The existing error block: "Channels may be out of date", the readable failure, then Retry and Settings |
| Never loaded, invalid URL or authorization failure | `.red` | The same block, headed "Can't connect to Toy Box" |

The error block moves into the same bar, 10 points above the status line and on the same 24-point
leading edge, so a problem and the server it concerns read as one footer. The status line never
repeats the block's words. Differentiate Without Color holds because every state other than
connected shows either the loading placeholders or the block's heading directly above the dot.

The footer is the sidebar's only progress indicator. When the first load or a refresh the user
asked for (Retry, or View > Refresh) takes longer than 300 ms, the dot's slot shows a native
indeterminate spinner,
`ProgressView().controlSize(.mini)`, which is 10 points. Center it on the dot's center and don't
clip it, so it overhangs the 7-point slot by 1.5 points on each side and the host text never moves.
When the attempt resolves, it crossfades back to the resulting dot. Background polling never shows
the spinner. Never overlay a spinner or "Loading Channels" on the list. The static placeholder rows
show the shape and the footer shows the activity.

In an inactive window the system draws a hairline above the bar, just as it does under the
toolbar. Keep it, because the soft edge in the active window comes from the same system effect.
Never fake that line, and never hide the scroll edge effect to remove it.

The status line is a borderless button that opens Settings, where the server URL lives. Hover and
press use the folder token's capsule (primary at 8% light or 12% dark, plus 5% while pressed),
outset 6 points so the dot never moves. Help reads "Connected to http://localhost:3100", or
"Connecting to", "Reconnecting to" or "Can't connect to", then "Change the server in Settings."
VoiceOver reads one button labeled "Server" with the value "localhost:3100, connected" (or
connecting, reconnecting, can't connect). Dot colors crossfade over 0.2 seconds, instantly with
Reduce Motion. Never pulse the dot. The footer reflects the catalog connection only. An open
channel's own stream keeps its inline "Reconnecting" banner in the detail column.

### Transcript

Use the canonical row projection unchanged. Avatar column is 32, gap is 12, and body begins 44
points into the lane. Runs have 20 points between them, 8 between entries in a run and 4 between
header and body. A header only repeats when `showHeader` says it does. Agent bubbles have 12-point
corners, 12 horizontal and 10 vertical padding, and no tail. They fit their content up to
min(lane − 44, 760). The user's message pins trailing, up to min(80% of the lane, 640), both caps
scaled by Text Size (see the lane rules in Whole-window composition), with a low-intensity accent-tinted
surface and normal label text. Do not use white body text on a saturated brand color.

Agent avatars are circular, with the supplied color and path. Fill the circle with the supplied
color as SwiftUI's `Color.gradient`, the same soft top-light gradient as the sidebar's channel
icon, so every avatar reads as slightly raised. This is one change in the shared
`AgentAvatarView`, so an agent looks identical in the team list, transcript, composer, reactions,
task owners and sidebar stacks, at every size. Add no shadow, rim or highlight: a shadow muddies
light mode, disappears in dark and smears overlapping stacks. With Increase Contrast, fill flat
with the exact supplied color. Draw the 24-unit path at 64% of the avatar, stroke 2.25 units at
every size, round caps and joins. Don't thicken the stroke at small sizes: today's denser marks,
with parallel lines 2 to 3 units apart, fill in at 2.75 units. Path ink is the avatar's optional
`ink` when it is a valid `#RRGGBB` that keeps at least 3:1 against the base color. Otherwise choose
black or white by measured contrast against the supplied base color, as the pane does, never
against the rendered gradient. The lighter top costs a white mark about a third of its contrast,
and even a color at the black and white crossover keeps 3:1 for the mark. A missing profile uses
the name's initial on a subtle cyan field. A removed agent uses `person.crop.circle.badge.xmark`,
neutral fill and the name "Deleted agent" everywhere, including reactions and task owners. Both
stay flat. Historical text stays intact.

**The lead's avatar** is navy `#1E3A8A` with the same outline star drawn in gold `#FACC15`, Toy
Box's own yellow, through `ink`. That is 6.8:1 on the base color and about 3.9:1 on the gradient's
lighter top, and it reads as the one in charge at 14 points. It also stops the lead from matching
the channel icon's cyan. Increase Contrast flattens the navy and keeps the gold. The server is the
single source of this art. Every channel snapshot already carries the lead's `avatar`, so Toy Box
adds the optional `ink` to the avatar shape and sets it only on its lead profile. `update_member`
never accepts it, so members keep black or white ink. A client without `ink` support draws the
star white on navy, a safe fallback. The Mac keeps no lead art of its own. The
`/api/v1/channels` catalog always carries one `lead: { name, role, avatar }` profile beside its
members, and each channel's lead is that profile under the channel's ID. The sidebar's working
stack draws it before a channel opens, so the browser and the Mac never show two different leads.
The Mac requires it and has no fallback. Never substitute a built-in star.

**Overlapping stacks** (the sidebar's 16-point working stack and the activity row's 20-point
working capsule) put the first agent in front, overlap each avatar 4 points onto the next, and cut
a 1.5-point gap around the avatar in front at every size. The gap is a true knockout, so the
sidebar glass, the accent selection or the capsule's glass shows through. Never stroke a guessed
background color, which reads as a ring on translucent materials and selection. Mask every avatar
after the first with an even-odd shape, the avatar's rectangle plus a circle of radius
`size / 2 + 1.5` centered `size - 4` points to its left:

```swift
var path = Path(rect)
let r = size / 2 + 1.5
path.addEllipse(in: CGRect(x: rect.midX - (size - 4) - r, y: rect.midY - r, width: r * 2, height: r * 2))
// avatar.mask { StackKnockout(...).fill(style: FillStyle(eoFill: true)) }
```

Keep the gap under Increase Contrast and Reduce Transparency. The shared `AgentAvatarStack` owns
it, with `size`, `limit` and `showsOverflow`. The working capsule adopts it with `showsOverflow:
false` and hides it from accessibility, because its label already names the agents. Reaction chips
space their 14-point avatars 4 points apart and need no knockout.

The addressee follows the author with a muted right arrow. Known leading mentions are omitted
only according to the canonical helper. In-body mentions are selectable, semibold text in the
agent's identity ink, with no background, and keep the accessible agent name. Derive the ink from
the avatar color. Mix it toward black in light appearance and white in dark, in 5% steps, until
it reaches 4.5:1 against the composited surface it sits on: the agent fill, the user's
accent-tinted bubble or the pending orange wash. Under Increase Contrast the target is 7:1.
Everyone and Lead follow the same rule with the accent and the lead's color. Weight carries the
cue for color-blind readers. Unknown mentions remain literal, not a false agent chip.
Links have normal native link affordances. Render headings, emphasis, lists, blockquotes, fenced
code, inline code and tables, with selectable text. Code blocks offer Copy Code, and tables may
scroll horizontally. Never execute HTML, scripts or embedded remote content from Markdown.

Only coordination entries marked collapsible truncate, at 160 points of body text, with a subtle
24-point bottom fade and Show More. Show Less returns to that same anchored row. Messages for the
user and all flagged requests always remain expanded. User-initiated expansion is preserved while
rows update. The copy action copies the original full message, including its leading mentions.

A pending request asks the user for something, so it offers an action rather than an alarm.
Never outline it. The bubble keeps its normal shape and padding, but trades the neutral fill
for a warm wash. In light, use `Color.orange` at 10%. In dark, keep the 7% neutral fill and layer
orange at 10% over it, so the bubble reads warm gray rather than brown. The header adds an orange
`questionmark.bubble.fill` and "Needs your reply" in primary text at medium weight. Inside the
bubble, 10 points below the body, a small untinted bordered Reply button
(`.controlSize(.small)`, `arrowshape.turn.up.left`) performs the same Reply as the hover action,
like the actionable bubbles in Messages. A later committed user message removes the wash and the
button, and the historical header shows a secondary `checkmark` and "Replied". Neither reading
nor an optimistic send clears a request. Requests never pulse. Increase Contrast adds a 1-point
orange border to pending bubbles only. VoiceOver reads "Needs your reply" with the message and
exposes Reply as an action.
Reply and Copy Message appear on hover or keyboard focus and in the context menu. As with AppKit's
tracking areas, a message that slides under a still pointer, as when the transcript follows a new
message or scrolls, shows them once the pointer moves. Reply prepends the agent's mention once,
preserves the draft and focuses the composer. Deleted agents cannot be replied to. Your own
messages expose Copy Message as an accessibility action, as well as in their context menu. Keep
message selection, link selection and context menus usable independently.

System rows are channel events, not speech, so they sit in the neutral center of the
conversation, as in Messages, rather than in the avatar column that belongs to agents. Each row
is one centered, multiline `Text`: the event's inline SF Symbol, two spaces, then the sentence,
in 11 regular secondary. Center on the full lane, including the identity gutter, with a 480-point
maximum text width and centered wrapping. Consecutive system rows stack 4 points apart as one
group, with normal 20-point run spacing around the group. Rows are at least 18 high, and each
link keeps a 28-point hit target. Help shows the full local date and time and any full values.
Matching membership events and same-agent artifact shares merge only where the canonical
projection does. Keep a sentence on one line when it fits, and never force a two-line card.
Keep event phrases regular and secondary, with names, routine titles and other values in
primary ink at medium weight. The weight change replaces a separating colon. Artifact titles
and preview URLs use native semantic link ink (`NSColor.linkColor`), a pointing-hand cursor and an underline on hover.
Do not use a fixed accent constant that misses the 4.5:1 text floor in either appearance.
Sentence joiners remain secondary. Preserve selection, full-value help and text scaling.
The inline symbol is decorative. The accessible label is the sentence alone, never beginning
with the object replacement character (U+FFFC) or the two spaces that follow the symbol.

| Event | SF Symbol | Presentation |
| --- | --- | --- |
| Tasks completed | `checkmark.circle.fill` | Green icon, "All tasks completed" |
| Member joined / left | `person.badge.plus` / `person.badge.minus` | Names or "Name and N others", full names on help |
| Renamed / purpose changed | `pencil` | Short changed value, full value on help. Cleared purpose is explicit |
| Directory changed | `folder` | Path truncates in the middle, preserving final components |
| Preview changed | `play.rectangle` | Link to the typed preview, or "Preview cleared" |
| Artifact shared | `doc.badge.arrow.up` | Sharer's identity and individually actionable artifact titles |
| Routine scheduled / edited / deleted | `calendar.badge.clock` | Title, with full schedule and prompt in help/details |
| Unknown future kind | `info.circle` | "Channel updated", timestamp and available textual description |

Day dividers are centered labels with no rule, as in Messages: 11 semibold secondary, centered on
the full lane, 16 high, with the header trait. Labels are "Today", "Yesterday", the weekday
within the past six days, "Saturday, October 18" this year and "Saturday, October 18, 2025"
otherwise, from localized date templates. Day dividers are not sticky. The New divider keeps
Toy Box's blue: a 1-point system blue rule at 70% across the full lane, and "New" in 11
semibold blue 6 points after its trailing end. When a day change and the unread boundary
coincide, the day label sits 6 points above the New rule as one divider, read as "Today, New
messages". Capture the unread boundary only after snapshot or replay completes, and never move it as
the user reads. This boundary is not an extra synthetic message. Reference renders of day labels,
the New divider, system rows and both request states: `docs/transcript-events.png`.

Land on the first unread row, otherwise the end. When a catch-up summary is eligible, land on its
card instead (see Mac features beyond the pane). Follow incoming messages only while within
48 points of the end, or immediately after the user's own successful post. If scrolled away, a
small glass Jump to Latest capsule appears in the floating activity row above the composer.
It shares that row with the working summary when present. Preserve the visible top message and its offset while prepending history. While reading above the end, rows only move when the reader scrolls: when a row above the viewport changes height, or the lazy stack corrects its estimate for rows it hasn't built yet, the first row starting in the viewport keeps its place, and a row starting in the viewport grows downward. Following the end, landing, jumps, reveals and paging own the position instead. At the top,
show Load Older Messages when more history is available, a small loading row while fetching, or
"Couldn't load older messages" with Retry on failure. Once all history is loaded, show no
"Beginning of conversation" label and reserve no empty header space. A filtered view must
continue paging even when a page contains no visible rows.

Long histories must stay as fast as short ones. Build rows incrementally: derive each message's
audience, display text and reactions once, and when messages only append, rebuild from the last
row rather than from the start. Give each row only the values it renders and compare rows, so a new
message, status or reaction re-renders only the rows it changed. Only a message that can collapse
measures its own height, so a new message lays out once rather than again when its height arrives.
Compile Markdown and mention patterns once, not once per row. The transcript reads only the
`messages`, `roster`, `agentStatuses`, `presence` and `request` slices, so task, artifact, routine
and detail events don't re-render it.

The Message View menu is a native radio-choice menu: All Messages and Your Messages. A non-default
filter gives its toolbar button an active tint and label/help. It does not change the composer
audience or channel-wide read policy. Read only committed visible sequences in the active window.
Opening an inspector, reading a preview popover or watching a background window does not mark
unseen messages read.

Attachments appear below their own message, with 8-point spacing and corners. Images form an
inline horizontal filmstrip, scrolling horizontally when needed rather than stacking into a
column. Do not show permanent image filenames, captions or a strip title. Keep the filename in
each thumbnail's accessible View action and hover help. A tile without a filename is labeled
by position, "Image 2 of 2", never a bare "Image". Align a fitting strip with the
message's leading or trailing edge, retaining attachment order when it scrolls. Image thumbnails fit within
240 x 160, never crop away essential content, and open the image viewer on click, Return or Space when
focused. Their context menu keeps Quick Look and Open in Browser. Each image tile draws a 1-point inner hairline over its clipped 8-point corners, primary
at 10% in light and 14% in dark, so screenshots with white or black margins keep an edge. Light
appearance adds a soft shadow (black 10%, radius 3, y 1). Dark adds none. Increase Contrast
raises the hairline to 40%. While an image loads, show a neutral tile at its final size
(quaternary fill at 30%, the same corners and hairline). Add a small spinner after 300 ms and
never show the filename. Read inline images' pixel size from the image header before decoding,
so the first layout is final. A remote image an earlier load cached reads its size from the cached
file's header the same way, so scrolling back to it never resizes its row. Remote images without a
known size use 120 x 90 and resize once.
Videos have a poster, duration when known, and an explicit Play action.
Other files show document icon, name and Open. Resolve resources against the server base URL.
An unavailable file keeps its name and an explicit retryable error, not a blank thumbnail.
Opening remote URLs must not assume a matching local filesystem path.

**Image viewer.** Images open in place, as in Photos, never in another app or a floating Quick
Look panel. The viewer pages through the clicked message's images in attachment order and
doesn't cross into other messages. Videos and files keep their own actions.

| Part | Specification |
| --- | --- |
| Presentation | Replaces the detail column (conversation and inspector) until closed. The sidebar stays. The canvas is `underPageBackgroundColor`, full bleed under the glass toolbar. The toolbar band settles at exactly the canvas color, with no change after the fade ends. The canvas stops at the sidebar, whose glass keeps its tint while viewing. Transcript scroll, draft and inspector state are untouched underneath |
| Image | Fits the canvas with 24-point side margins, 16 below the toolbar and 16 above the capsule. Never upscale past the image's point size, so a 2x screenshot shows at native size. 6-point continuous corners, the tile's 1-point hairline (10% light, 14% dark, 40% Increase Contrast) and, in light only, a shadow of black 12%, radius 12, y 4 |
| Toolbar | Back (`chevron.backward`, help "Back to Conversation") leads. Title is the sender, subtitle "Today at 5:23 PM · 2 of 4" (one image omits the position). Trailing: Share (`square.and.arrow.up`) and More (`ellipsis`: Copy Image, Open in Preview). Message View, Channel Actions and Overview hide while viewing |
| Capsule | Only with two or more images. Centered 16 above the bottom edge, `.glassEffect(.regular.interactive(), in: .capsule)`, 8 padding. Previous and next (`chevron.backward` and `chevron.forward`, 13 semibold, 28 x 28) flank 32-point thumbnails (aspect fill, 6-point corners, hairline, 6 apart, 70% opacity). The current thumbnail is opaque with a 2-point accent ring 2 points outside it. Arrows go tertiary and disabled at the ends, with no wrap. Past nine thumbnails the strip scrolls, keeping the current one in view |
| Keys and gestures | Left and Right, the capsule, a thumbnail click or a two-finger swipe change images. Escape, Space or Back close. Double-click toggles fit and actual size at the clicked point, except on Live Text. Pinch and `Cmd-=`, `Cmd--`, `Cmd-0` zoom only while viewing, overriding Text Size. Scroll or drag pans a zoomed image, and changing images resets zoom. `Cmd-C` copies selected Live Text, otherwise the image, and dragging it out exports the file. Live Text rules are under Mac features beyond the pane |
| Motion | Opening zooms the image from its thumbnail's frame to its fitted frame (spring, response 0.35, damping 0.9) while the canvas fades in over 0.2 seconds. Closing reverses into the current image's thumbnail, scrolling the strip to it first. Paging slides 40 points with a crossfade in the direction of travel. The tile steps aside only while the zooming image covers it, so the strip never shows a hole. Without a thumbnail frame (a tile less than half visible on close), the image fades and scales from 94%, and the tile stays in place under the canvas until the viewer is gone. Reduce Motion uses 0.2-second crossfades throughout, with no scale, and the tile never steps aside |
| Loading and errors | Show the cached thumbnail at the final fitted frame immediately and swap in the full image when decoded. A spinner appears only after 300 ms. Failure shows "Couldn't Load Image" and Retry, centered on the canvas |
| Accessibility | Modal. Focus moves to the image, labeled "Image 2 of 4 from Lead, [filename]", with Next, Previous, Copy, Share and Close actions. Closing returns focus to the current image's thumbnail. The stage's `.isModal` trait alone removes the conversation and inspector from the tree. Never put `.accessibilityHidden(false)` on them: on macOS 27 an explicit false re-exposes their hidden descendants and moves the bottom bars ahead of the transcript |
| Lifecycle | One viewer per window. Switching channels, a deleted message or a lost channel closes it without animation. Not restored on relaunch |

Transcript owns the viewer and its transition. Shell routes the viewing toolbar and the zoom
and close commands.

Reactions are display-only in this client, matching the user pane. Use the existing emoji for
done, agree, celebrate, love and laugh. Also show the projected looking/working reactions while
the agent's live presence and matching status target permit them. Group by reaction, then show up
to three 14-point reactor avatars and `+N`. Chips are 24 high with a subtle border. Hover, keyboard
focus or activation reveals every reactor name. Do not make a reaction chip look like an enabled
"add reaction" button. The working summary floats as a glass capsule above the composer, outside
the scrollable history. It has 20-point avatars, "Name is working" or "N agents are working", and status details on
activation. Waiting belongs in the inspector, not this row.

### Composer and tray

The composer floats over the conversation in a bottom `safeAreaBar`, as one glass surface
spanning the full conversation lane from the avatars' leading edge, 16 points above the window's bottom
edge. Messages scroll beneath it. Do not add a full-width background, separator or second glass
panel behind it. The Floating composer table in the Liquid Glass composition section is
authoritative for its shape, material, edge, focus and internal metrics.

The composer and context tray form a single glass rounded rectangle, radius 18. Text is inset 12, starts at one 20-point line and grows through three lines before
scrolling internally. The controls row is 28 high, with 8 points between controls. Baseline height
is approximately 80, or 109 with the tray, and grows to three text lines before attachment
thumbnails. Attach Image
(`photo.badge.plus`, 28-point hit target) is leading, then audience, then Input Needed. Dictate
(`mic`) is trailing, 8 points before Send. Send is a
28-point circular `arrow.up` trailing button using system accent. Empty content is sendable only
when at least one valid attachment exists.

Return sends. Shift-Return inserts a newline. Command-Return also sends. Do not submit an IME
marked-text composition or while a completion menu is consuming Return. Escape dismisses
completion or a popover without destroying text. Tab and Shift-Tab leave the composer for the
next and previous key views, like a browser text area, and Option-Tab inserts a tab. Standard selection, undo, spelling, dictation,
writing-direction and accessibility behavior must work through native text input.

**Dictation.** System Dictation already works in the composer because it is a real `NSTextView`.
The Dictation key and Edit > Start Dictation… stream words in at the caret with the system's own
indicator. Keep that path intact and never remove the menu item. The composer also has its own
Dictate button, because a button must say honestly whether it is listening, and there is no public
API that starts system Dictation. The button uses the on-device `SpeechAnalyzer` with a
`DictationTranscriber` on the `progressiveLongDictation` preset, which gives punctuation and live
tentative results. Audio never leaves the Mac.

| State | Dictate button | Composer |
| --- | --- | --- |
| Ready | `mic` with the same borderless style, 12-point symbol, secondary ink and 28-point frame as Attach Image. Help and label "Dictate" | Unchanged |
| Unsupported | Hidden when `DictationTranscriber.supportedLocale(equivalentTo:)` finds no match for the user's language | Unchanged |
| No microphone | Disabled `mic` once a click finds no input device. Help "Connect a microphone to dictate" | Notice row: "Connect a microphone to dictate." It clears when a microphone connects |
| First use | A 22-point determinate ring around a 10-point `mic`, 2-point accent stroke over a `primary` 12% track, showing the language asset download. Clicking cancels | Notice row: "Downloading English dictation. This happens once." in the composer's caption notice style |
| Listening | `waveform` at 13 points semibold in accent ink on a 28-point circle of accent at 15%. Its `variableValue` follows the smoothed input level, about 12 updates a second. Help and label "Stop Dictation". Reduce Motion holds a static full `waveform` | An empty draft's placeholder reads "Listening…". Tentative words draw in secondary ink at the insertion point and settle to primary ink as they finalize |
| Access off | `mic.slash` in secondary ink once a click finds access off. That click and every later one open a popover from the button | Unchanged |
| Failed | Returns to Ready | Notice row names the cause, such as "Dictation stopped because the microphone became unavailable." Every finalized word stays |

Send stays the only filled control. Listening uses a tint, never a second solid accent circle, and
never red, which reads as recording or error.

- **Start.** Click Dictate. Focus moves to the composer, and words replace the selection at the
  caret. The first click, never launch, raises the system microphone prompt, plus speech
  recognition if the framework requires it. Launch and channel switches only check the language.
  The first click is also the first time the app looks for an input device or reads microphone
  access, because finding the default input device starts Core Audio. There is no separate menu
  command or shortcut, because Edit > Start Dictation… and the Dictation key already own those.
- **Stop.** Stop on any of these, keeping every word: click the button again, press Escape, type
  any character, switch channels, the window resigns key, or 30 seconds pass with no new words.
  Stopping finalizes the pending tentative words before returning to Ready.
- **Send while listening.** Return, Command-Return or Send stop dictation, wait for the final
  result and then send the finalized draft. Never post tentative words.
- **Text.** One dictation session is one undo group. Only finalized words enter the persisted
  draft. The audience preview updates from dictated text exactly as it does from typed text, but
  dictation never invents mentions. Pass the channel's agent names, "Lead" and "Everyone" as
  `AnalysisContext.contextualStrings` so names come out spelled correctly. Dictation keeps working
  offline once the language asset is installed, like the rest of offline editing.
- **Access off popover.** 280 wide with 14-point padding. A 15-point secondary `mic.slash` sits
  before the 13-point semibold title "Microphone Access Is Off". The 12-point secondary body reads
  "Allow Toy Box Desktop to use the microphone in Privacy & Security settings. The Dictation key
  still works." It has one trailing button, "Open System Settings", which opens Privacy & Security >
  Microphone. If speech recognition is the missing permission, the title and body say "Speech
  Recognition" instead.
- **Accessibility.** VoiceOver announces "Listening" on start and "Dictation stopped" on stop. The
  live level is never announced. Full Keyboard Access reaches the button in control order.
- **Bundle.** `Info.plist` carries `NSMicrophoneUsageDescription`, "Toy Box Desktop uses the
  microphone only while you dictate a message.", and `NSSpeechRecognitionUsageDescription`,
  "Dictation is transcribed on this Mac."

Mentions remain plain `@handle` text. The completion popover anchors to the caret, opens above the
composer when needed, is 300 wide and at most 320 high, and scrolls its own list. Order: Everyone,
Lead, alphabetically matching members, then Create [Name] where canonical matching permits it.
Rows are at least 44 high with 24-point avatars, name and one-line role. Up/Down select, Return or
Tab without Shift accept, Escape cancels. Shift-Tab and Shift-Return pass through to the
composer, and Option-Tab still inserts a tab. Accepting inserts one trailing space and restores the caret. A
member's secondary Edit action opens a sheet without accepting the mention. A Create action
explicitly says it creates and starts a new agent. During creation show progress on that row,
disable duplicate acceptance, preserve typed text on failure and show the error in the popover.

The audience pill reads "To Lead", the canonical audience label, or "No one will be notified" in
amber. At narrow widths, show avatars plus a count and preserve the full names in help and
accessibility. This is a preview of delivery, not a manually selected recipient control, so it
is exposed as static text ("To Ada, Pixel"), never as an unknown element or a button.
A pending request causes an unmentioned response to reach the lead, and an explicitly addressed
response still acknowledges the request and reaches the lead according to the canonical policy.

Input Needed stays visible until a committed user response. It has an amber question icon and
label, not a constantly moving spinner. Hover after a short native delay previews the retained
request in a max-320 x 280 popover. Keyboard activation or click reveals and focuses its transcript
row, paging backward as necessary, with a brief static highlight. If loading fails, retain the
request preview and show Retry. Revealing a request never changes composer height.

Paste, file picker and drag accept the same image formats as the server. A drop highlights the
composer, not the whole window. Show attached images as 56-point thumbnails in a horizontal row,
with an accessible Remove button and filename. Invalid files produce a specific inline error.
Do not silently drop unsupported attachments or invent a size limit different from the server's.
Text drafts persist locally per normalized server URL and channel ID, including after failed
delivery. Preserve attachments across channel switches. Restored attachments that are no longer
readable explicitly require reattachment, and must not appear ready to send.

Editing remains available while offline, an intentional native improvement. Send and management
mutations are unavailable until live state is established. Explain the reason next to the input
rather than using disabled controls alone. Every channel switch reconnects, so a connect that goes
live within a second shows no explanation and the composer doesn't jump. A slower connect, a stale
connection or a deleted channel explains it. A stale snapshot must never determine a new send's
audience without reconnection.

Submitting creates one optimistic row with "Sending". A committed echo replaces it by UUID.
On a definite rejection, retain the draft and mark the row "Not sent". On timeout or lost response,
say "Delivery not confirmed" rather than falsely claiming failure. Expose Edit and explicit Send
Again, never an automatic retry. Keep the original UUID when verifying or explicitly repeating
that attempted send so a 409 cannot deliver it twice. Do not clear a newer draft when an older
send eventually succeeds.

The tray is a compact 28-point header inside the floating composer. Lead with the newest shared
artifact as a borderless document action, then `+N` for remaining artifacts. Trailing controls are
Tasks with direct-root `done/total`, and Preview when set. Tasks speaks as the label "Tasks" with
the value "1 of 4 done", never the visible slash. Keep every action on the same baseline,
without a separate progress underline. Zero-content controls
are absent. When space is insufficient, collapse artifact names before hiding Tasks or Preview,
and use a native overflow menu rather than a horizontally scrolling toolbar. Artifacts and Tasks
open anchored native popovers, preferred 360 wide, max 420 high. Task rows are the same projection
as the inspector. URL Preview opens the configured URL in the default browser. Screen Preview
opens that channel in Toy Box, with an explicit label, never a fictitious local live screen.

### Overview inspector and readers

The Overview is an inspector in the Keynote and Xcode sense: a quiet, dense column of facts about
the selected channel, with each action sitting next to the fact it acts on. It is not a
dashboard and does not copy the pane's layout. People follow Messages' Details sidebar,
and structure follows Xcode's inspectors. Reference renders: `docs/overview-inspector.png`.

The inspector has no title row or close button. It runs the full window height, its content
starts 12 points below the toolbar's safe area and scrolls beneath the toolbar, and its
container is labeled "Overview" for accessibility. Only the narrow-window sheet shows a visible
"Overview" title, with a Done button. Do not set a nested navigation title. Use a `ScrollView`
with a zero-spacing `VStack` and 16-point horizontal insets. Order: About (untitled), Team,
Tasks, Artifacts, Routines. Separate sections with a native `Divider()` across the content
width, with 2 points of vertical padding. No cards, count capsules, section fills or uppercase.

**Section headers.** Headline style (13 bold), then the count 6 points later in 13 regular
secondary with tabular digits: "Team 9", "Tasks 1/4", "Artifacts 2", "Routines 1". The
header row is 28 high, sits 8 points below the divider above it, and has 4 points to its first
row. A section ends 12 points above the next divider. Headers collapse, as in the Finder
sidebar: a trailing 10-point semibold `chevron.down` (expanded) or `chevron.right` (collapsed)
in secondary appears on hover or keyboard focus and stays visible while collapsed. Clicking the
header toggles it with the 180 ms disclosure animation, or instantly under Reduce Motion.
Persist collapsed sections per window scene, not per channel. The header is a button with the
header trait, labeled "Team, 9" with the value "Expanded" or "Collapsed". Tasks shows its
recursive diff total at the trailing edge, before the chevron. Empty sections stay, with one
12-point secondary sentence: "No tasks yet", "Nothing shared yet" or "No routines".

**About.** The purpose is 13 regular primary, about 18-point line height, at most 4 lines, then
an inline "More" link that expands in place ("Less" collapses it). A missing purpose reads "Add
a purpose…" in secondary and opens Edit Channel. Below it, 10 points down, come compact property
rows, each 22 high: an 18-point secondary SF Symbol column, a 6-point gap and a 12-point value.

- Folder: `folder` and the path, middle-truncated and selectable. Abbreviate it with `~` only when
  the server runs on this Mac, because a remote home isn't this Mac's home. When the folder is
  openable (the same rule and cached check as the sidebar's folder token), help shows the full
  path and a trailing tertiary
  `arrow.forward.circle.fill` (Xcode's reveal arrow, 4 points after the path) shows it in
  Finder. Remote and missing folders use `folder` or `questionmark.folder` in the same ink, with
  no arrow, and reuse the sidebar token's help strings as both help and VoiceOver hint, so the
  missing arrow is always explained. The context menu offers Show in Finder (when openable), Copy
  Path and Open in Toy Box. Never claim a remote path was opened. Omit the row when the channel
  has no directory.
- Preview: `play.rectangle` and the typed URL's host and path in link ink, opening the default
  browser. A screen preview reads "Window preview" and opens the channel in Toy Box. Omit the
  row when there is no preview.

**Team.** The lead first, then members alphabetically. Never reorder by presence, because stable
positions are what make the list scannable. Rows are at least 38 high with 4 points of vertical
padding: a 24-point avatar, a 10-point gap, then the name in 13 regular primary over a one-line
11-point status, 1 point apart. Status truncates at the tail with the full text in help.

| Presence | Status line | Trailing |
| --- | --- | --- |
| Working | Presence text, or "Working", in primary at 85%, after a 9-point heavy `ellipsis` in the agent's color, 4 points before the text. This is Messages' typing cue | Nothing |
| Waiting | The reason in secondary, such as "Waiting for Moss's review" | With a wake time, "8 min" in 11 secondary tabular digits, updated at minute boundaries, help "Checks again at 9:32 AM". "Due" once it passes |
| Idle | "Idle" in secondary | Nothing |

The working ellipsis pulses only while the window is key. Under Reduce Motion, and in every other
window, it is static at full color. The pulse matches the system's iterative variable color on that
symbol, measured from `.symbolEffect(.variableColor.iterative)`. All three dots rest at 25%
opacity. Each in turn rises to 100% over 0.31 s and falls back over 0.31 s, easing in and out. Dots
start 0.33 s apart, so a cycle lasts 1.67 s and ends with all three resting for 0.375 s. Starting
fades all three from full to 25% over 0.31 s before the first dot rises. Stopping restores full
color at once. Each dot's opacity is a Core Animation keyframe animation that is committed once and
interpolated by the render server. It is never a SwiftUI animation, symbol effect, timeline or
display-link callback that updates views every frame. It may cap its frame rate at 30 fps. Its
static frame stays pixel-identical to the 9-point heavy symbol, in the same place in the row, at
every text scale.

There are no rings around Team avatars. The row is one button that opens the member's About popover
(name, full role, status and model) anchored to the avatar, never private session contents. On
hover or keyboard focus, a borderless 14-point `ellipsis.circle` menu in secondary, with a 28 x 28
target, replaces the trailing countdown. It offers Reply to [Name], About [Name], Edit Member… and
Remove Member…. The lead offers Reply and About only, because its identity is intrinsic. The
context menu has the same items. Add Agent… ends the list in a 36-point row: a 24-point dashed
tertiary circle with an 11-point `plus`, and the label in 13 regular secondary. It opens Add
Member.

**Tasks.** Status is read-only, in a 16 x 16 cell at 14 points: pending `circle` in secondary,
in progress `circle.lefthalf.filled` in secondary, blocked `exclamationmark.circle.fill` white
on system red, done `checkmark.circle.fill` in monochrome rendering filled with the shared
completion green (`ChannelTaskColors.changes(in:).added`, `#196C2E` light and `#70D58A` dark),
so the check is knocked out to the inspector behind it. That is the same mark and palette as
the sidebar's finished marker and the transcript's "All tasks completed" row. The two filled
glyphs use semibold weight so the check and bang hold up at 14 points. Never paint a white
check on system green, which measures about 2:1. The knockout measures 5.8:1 light and 8.3:1
dark against the inspector and keeps done calmer than blocked in dark. The outline glyphs stay
regular weight. Never render toggleable checkboxes. Root
status icons sit on the 16-point content rail, aligned with the section heading, with the title
6 points after. Nothing hangs in the leading margin. Each nesting level indents 22 points, so a
child's status icon sits directly under its parent's title, as in Reminders.

A parent's disclosure trails its title inline, as macOS sidebar section headers and the pane do.
Build the first line as one wrapping `Text`: the title, then two spaces and the progress count
for an open parent (11 regular, monospaced digits, secondary, "3/4"), then one space and the
chevron as a text image (`chevron.right` collapsed, `chevron.down` expanded, 9 bold, secondary).
The chevron ends the title's last line and wraps with it, never orphaned on a line of its own
when the title fits. The whole parent row is the click target, so the chevron needs no
separate hit area. Done parents drop the count, because their children are all done. Pending
parents omit it too. Leaf rows have neither.

A parent's disclosure derives from its status, exactly as the pane's checklist: a done parent
starts collapsed and every other parent starts expanded, so finished work folds down to its
title, chevron and diff while open work stays visible. When a parent's status changes, its
disclosure re-derives from the new status. A parent that becomes done collapses with the
0.18-second ease-in-out disclosure animation (instant under Reduce Motion), and a reopened
parent expands. A user's toggle holds until that parent's next status change. The same rule
applies in the Composer's Tasks popover, which shares these rows.

Rows have 5 points of vertical padding. The first line is the title (13 regular, wrapping, done
titles in secondary, never struck through) with the owner's 16-point avatar at the trailing
edge, centered on the first line and at least 8 points from the title. A second line, 3 points
below and aligned with the title, appears only when there is a diff or artifact, with 10 points
between items: the diff ("+1.5K −114", 11 medium tabular,
in the adaptive green and red tokens) and the task's artifact as an 11-point link ("Workshop
plan" after `doc.text`, 3 points apart) that opens only that artifact and never toggles
disclosure. Measured zero ("+0 −0") is distinct from absent. The header count is done over
total for direct roots, exactly as the pane, written "9/12" like the composer's Tasks button
rather than "9 of 12". Visible counts use the compact slash form, and spoken values keep "of".
Completion attention
still requires every descendant to be done. Aggregate diffs recursively without double
counting, and keep exact accessible values: "Build the workshop, in progress, 1 of 2 subtasks
done, 1,522 additions, 114 deletions, owner Pixel", with Open Artifact and Expand or Collapse
actions. A parent row is a button whose value is "Expanded" or "Collapsed" and whose press
toggles it, so VoiceOver reads "Build the workshop, …, collapsed, button". A leaf row is static
text. Neither may surface as an unknown element, matching the routine rows. A missing referenced artifact keeps a disabled link labeled "Artifact unavailable".

**Artifacts.** Rows are at least 40 high: the file's real Finder icon at 28 points
(`NSWorkspace.shared.icon(for:)` with the UTType from its extension), a 10-point gap, the title
in 13 regular on one line, and an 11-point secondary line, "Kit · 3 hr. ago", with the full date
in help. Format the time with `RelativeDateTimeFormatter`, `.named` and `.short` ("3 hr. ago",
"yesterday"). The sharer is the actor of the latest matching `artifact_shared` event. Until Core
projects it, show the localized type ("Markdown") instead. Keep canonical order. The tray is
explicitly newest-first. Clicking opens the artifact, and Space on a focused row shows Quick
Look. The context menu offers Open, Quick Look, Show in Transcript (reveals the share event) and
Copy Link. Markdown opens a native reader sheet or window with a selectable body, title, path,
Open in Toy Box and Share or Copy Link. Other supported types use Quick Look or the default
application. Show actual fetching and error states, and never open a blank success-shaped
reader. Load reader content from the server resource URL, never by assuming the file is local.

**Routines.** Rows share the artifact geometry: a 28-point icon cell with a 15-point secondary
`calendar.badge.clock`, the title in 13 regular, and the schedule in words in 11 secondary:
"Weekdays at 9:00 AM", "Every day at 9:00 AM", "Mondays at 9:00 AM" or "Every hour". Anything
else shows the literal cron expression. Core provides this summary next to its cron parser. The
disclosure trails the title inline, as for task parents: one wrapping `Text` with the title, a
non-breaking space and the 9-point bold secondary `chevron.right` or `chevron.down` text image,
so "Daily review ›" never orphans its chevron. Nothing hangs in the leading inset, and the whole
row toggles it. Expanded content is indented 38
points to the title: the prompt in 12 regular primary, selectable, then an 11-point grid with
trailing-aligned secondary labels, "Next run" ("Tomorrow at 9:00 AM") and "Schedule" (the cron
expression in monospaced type and the time zone). An invalid or unavailable calculation shows
"Next run unavailable", not a guessed date. A hover or focus `ellipsis.circle` menu and the
context menu offer Run Now and Delete Routine…. Run disables while pending and shows "Run
requested" in place of the schedule line for 4 seconds, never as a synthetic transcript post.
Delete has a native confirmation that names the routine. The user does not create or edit
routines here, matching the pane.

### Management and Settings

All management uses the approved v1 endpoints, not browser RPC or filesystem writes. Fields:
channel name (required, server's 100-character limit), purpose (optional, multiline, server's
12,000-character limit), lead model, and working directory. Directory is selectable only on
creation, read-only on edit. For a member, always offer clearing the model override, even when
there is no compatible workspace default or the catalog has no choices. Never describe the
workspace default's provider as forbidding it. Restrict explicit model choices to the current
provider where required. Never invent a model when the catalog is unavailable. Cancel and the
default button sit trailing. Command-Return submits a valid sheet, Escape cancels. A failed mutation
leaves all fields and the sheet intact. After a 500, say the change may have been applied, block
resubmitting against the old baseline, and refresh from the server. Then either show the
reconciled state or offer a reviewed retry.

New Channel, Edit Channel, Add Agent and Edit Member share one sheet language:

- **Size.** 480 wide. The sheet fits its content, with no empty band above the buttons and no
  inner scroll view until it reaches the window's height. Initial focus is Name.
- **Header.** 20-point insets. A 40-point identity mark, 12 points, then a 15-point semibold title
  over one 12-point secondary line. No divider follows the header. Channel sheets use the
  sidebar's cyan `#` mark at 40 points (19-point semibold glyph). Edit Member uses the member's
  own avatar at 40 points. Add Agent uses a 40-point dashed circle with a plus, matching Team's Add
  Agent row.
- **Body.** One `.formStyle(.grouped)` form. Section 1 is identity: Name as a native text field
  with the prompt "Required", then Purpose or Role. That label sits above a `TextField(axis:
  .vertical)` with its label hidden, so its text shares the label's leading edge and Name's field
  chrome. Purpose reserves 3 lines and grows to 6. Role reserves 5 and grows to 10. Past that the
  field scrolls. Return submits, Option-Return inserts a line break. Never use a bordered
  `TextEditor`. Section 2 is the model: Lead model or Model, Reasoning and Context only when the
  chosen model offers them, then Working directory on channel sheets. Help lives in section
  footers (11-point secondary), never as loose rows between fields.
- **Validation.** Never show a message for an empty required field. The default button stays
  disabled and the prompt already says Required. A real violation, such as a length limit, a
  taken name or an emptied existing role, replaces its section's footer with a red
  `exclamationmark.circle.fill` and a secondary sentence. It's also the field's accessibility
  hint. Connection, server and recovery notices sit above the buttons.
- **Models.** While loading, the model row's value is a small spinner. When the catalog fails, the
  value is secondary "Couldn't Load" with a small Retry button, and the section footer gives the
  reason. Don't stack a warning, a message and a Reload button under the picker. A member's
  first choice reads "Workspace Default (Model Name)" when the default is known.
- **Progress.** Busy titles use the ellipsis character: "Creating…" and "Saving…".

Copy:

| Sheet | Subtitle | Section footers | Buttons |
| --- | --- | --- | --- |
| New Channel | The lead starts right away and adds specialists as needed. | Purpose prompt: "What should this team work toward? The lead reads this first." Directory prompt "Optional", footer: "A folder on the server. Leave it empty for a discussion-only channel." | Cancel, Create Channel |
| Edit Channel | Name and purpose changes appear in the conversation. | Directory is a read-only row, middle-truncated and selectable. Footer: "Only the lead can change the directory. Model changes apply the next time the lead works." | Cancel, Save |
| Add Agent | Joins {channel} and starts onboarding right away. | Identity: "Mentioned as @handle. Names are unique in this channel." (live). Role prompt: "What this agent owns and how it works, including any persona." | Cancel, Add Agent |
| Edit Member | Member of {channel} | Identity as Add Agent. Model: "Model changes apply the next time {name} works. Its history is kept." | Remove from Channel… (leading, destructive), Cancel, Save |

Names affect mentions, so the identity footer always shows the resulting handle. Preserve server
validation for unique handles and role requirements. The lead cannot be edited through the member
sheet. Deletion confirmations name the exact target and consequence:
deleting a channel removes its agents and private sessions, removing a member retains public
messages and reactions as Deleted agent, and deleting a routine stops future scheduled runs.
Cancel is the safe default. There is no fake Undo for irreversible server deletion.

Settings uses a native scene with General and Notifications sections. General includes Server
URL, Test Connection, status, and the selected appearance (System by default). Validate HTTP(S),
preserve path prefixes and display actionable failures. Changing servers prompts before replacing
live connections, namespaces drafts, then refreshes the catalog. Notifications explains requests
and completions before asking system permission in response to an explicit enable action.
Permission denial shows Open System Settings, never repeated permission prompts. General also
holds Show in menu bar and the two on-device toggles specified under Mac features beyond the pane.
Release builds also show Updates, with "Automatically check for updates" and "Automatically
download and install updates" bound to Sparkle's own settings. Automatic installation is disabled
while automatic checks are off or the updater disallows it. These controls are hidden without a
running updater. Only a bundle containing `SUFeedURL` outside snapshot mode starts the standard
Sparkle updater, so development, validation and test bundles cannot update themselves.
The first ordinary launch of `dev.toybox.desktop` imports missing persistent preferences from
`dev.toybox.channels.mac` once, before creating the app model. Existing new-domain values always
win, including per-server channel memory. Snapshot and non-production identities never import or
mark that migration. System permission grants do not transfer. An imported notification opt-in
requests authorization once, on the first active app window, only if permission is undetermined.
A background Siri launch leaves that request pending until the app comes forward. An imported
opt-out never prompts, and denial clears the enabled preference.

### Menu and keyboard model

Use native About, Settings (`Cmd-,`), Services, Hide, Quit, Edit, Window and Help menus. Standard
text-editing shortcuts retain their native meaning. Commands below disable when inapplicable.
Focus Composer does not discard selection or any existing draft.
Check for Updates… follows About in the app menu and uses Sparkle's standard window. It is
disabled whenever the updater's `canCheckForUpdates` is false, including in bundles without a feed.

| Menu | Command | Shortcut |
| --- | --- | --- |
| File | New Channel | `Cmd-N` |
| File | Open Channel in New Window | `Cmd-Shift-N` |
| File | Open in Toy Box | `Cmd-Shift-O` |
| File | Open Folder in Finder (selected channel, only when its folder is openable) | `Cmd-Option-R` |
| Edit | Find Channel (reveals a hidden sidebar, then focuses its search) | `Cmd-Option-F` |
| View | Show/Hide Sidebar | `Ctrl-Cmd-S` |
| View | Show/Hide Overview | `Cmd-Option-0` |
| View | All Messages / Your Messages | `Cmd-1` / `Cmd-2` |
| View | Refresh | `Cmd-R` |
| View | Text Size: Larger / Smaller / Default | `Cmd-+` / `Cmd--` / `Cmd-0` |
| Channel | Next / Previous Channel | `Ctrl-Tab` / `Ctrl-Shift-Tab` |
| Channel | Next Channel Needing Attention | `Cmd-Shift-U` |
| Channel | Focus Composer | `Cmd-L` |
| Channel | Jump to Latest / Input Needed | `Cmd-J` / `Cmd-Shift-J` |

Space opens a focused image in the image viewer and previews other attachments with Quick Look,
Return opens a focused artifact, and Right/Left expand or
collapse a focused task or routine. Sidebar arrows select without stealing first responder to the
composer. Switching channels by click may focus the composer after connection, but keyboard
navigation keeps list focus until explicitly moving into the conversation.

### Loading, empty, error and stale states

| State | Presentation and available actions |
| --- | --- |
| First catalog load | Three static placeholder rows, no fabricated channel names. After 300 ms the connection footer's dot becomes a mini spinner (see Sidebar). Nothing overlays the list |
| No channels | Source-list empty state: "Your channels live here" and New Channel. The connection footer already names the server, so the empty state doesn't repeat it |
| Search has no matches | "No channels match [query]", Clear Search. Do not show the no-channels creation state |
| Nothing selected | Centered `bubble.left.and.bubble.right` symbol, "Choose a channel", concise navigation hint |
| First channel snapshot | Static message placeholders and "Connecting". Composer shell remains present, Send unavailable |
| New empty channel | "Your lead is getting started", "Send a message or type @ to add an agent". Keep composer and working status visible |
| Filter has no messages | "No messages for you yet", Show All Messages. Keep paging older history until exhausted |
| Reconnecting with cached state | Keep transcript and scroll intact. A 32-point inline banner below toolbar says "Reconnecting. Messages may be out of date" with Retry. Disable delivery, not editing |
| Disconnected without any state | `wifi.exclamationmark`, "Can't connect to Toy Box", server host, readable failure, Retry and Settings |
| Catalog refresh fails | Keep existing rows, mark them stale and show the error block above the connection footer's orange status line (see Sidebar). Never replace them with "No channels" |
| Failed send | Inline error above composer and explicit status on optimistic row, preserved text/attachments, no automatic retry |
| Channel deleted | Stop observation, dismiss its inspector, show "This channel was deleted". Back to Channels and Copy Draft if nonempty. Never silently discard a draft or redirect to another channel |
| Invalid URL or authorization failure | Show the actual category and server, Settings/Retry as appropriate. No fabricated successful connection |
| Failed image/artifact/history | Localized error at that surface with Retry. Keep the rest of the channel usable |
| Unsupported future event | Neutral system row, no stream-wide crash and no raw JSON wall |

Connection status is separate from agent activity. Reconnection does not show a team as still
working unless current presence establishes that. No repeated full-window spinner after content
has already loaded. Retry is user-initiated and does not resend messages or replay mutations.

### Motion, accessibility and attention outside the window

Use native selection and inspector transitions. Custom hover/focus fades last 120 ms, disclosure
and tray changes approximately 180 ms. Scrolling to a user-requested target may animate for
180...240 ms, but initial landing and history anchoring must be immediate. The Team's working
ellipsis pulses only in the key window, as a render-server animation. Reduce Motion keeps it static
beside its text. No continuous animation may update SwiftUI views or run main-thread work every
frame, and a key window with working agents idles under 3% CPU. Requests never animate. No looping
shimmering skeletons or large empty-state art.

Every icon-only control has a localized label and help. Minimum compact control hit target is
28 x 28. Keyboard focus is visible without hover. Expose one semantic message group with author,
time, addressee, body, request state and actions, with attachments and reactions as reachable
children. VoiceOver order follows chronological messages, then working row, tray and composer.
Do not announce the whole transcript on every event. Announce a new relevant request or send
error once, with a polite concise message. Day and New dividers are named separators.
Status uses symbol and words as well as color. Confirm text contrast in both appearances,
including avatar ink, selected sidebar rows, tinted user messages and amber request labels.

The Dock badge counts channels needing attention once each, not message volume. Notification
categories are pending requests and unread completions, deduplicated by channel and milestone
sequence. Ordinary chatter does not notify by default. Suppress notifications for the active key
channel, but never hide its request marker. Activating a notification opens the right channel and,
for a request, reveals its message. Respect system notification permission and Focus. Content,
quick reply and withdrawal are under Mac features beyond the pane.

### Mac features beyond the pane (M8)

These features exist only on the Mac. Each one stays quiet until it has something true to say,
and disappears rather than degrading when the Mac can't support it. On-device work never sends
message text or images off the Mac.

**Notifications.** A notification says what is being asked, and you can answer it without
opening the window.

| Part | Request | Completion |
| --- | --- | --- |
| Title | Channel name | Channel name |
| Subtitle | "[Agent] needs your reply", using the requester's current name | None |
| Body | The request's plain text (see below) | One top-level task: "Completed “[title]”". Otherwise "All [n] tasks completed" |
| Hidden previews placeholder | "Waiting for your reply" | "Tasks completed" |
| Category and actions | `request`, with Reply | `completion`, with no actions |
| Sound | Default | Default |
| Thread | `[server]:[channel ID]`, so Notification Center groups each channel | Same |
| Activation | Opens the channel and reveals the request | Opens the channel at its normal landing |

The request body is the message as a reader sees it, flattened to plain text. Drop the leading
mentions the transcript omits. Links become their text, code keeps its contents, list items keep
a "• " prefix, and paragraphs keep one line break. Cut at a word boundary to 400 characters with
"…" and let the system clamp the display. A request with only attachments says "Sent an image",
"Sent 3 images" or "Sent a file". Get the text from an open channel's state, otherwise from
`history(channelId:before: requestSequence + 1)`. Wait at most 3 seconds for it. On failure or
timeout, deliver anyway with the body "Your team is waiting for your reply." and no subtitle.
Never delay the notification more than those 3 seconds, and never deliver a second one when the
text arrives late. Agent avatars as the notification image need Communication Notifications and
are out of scope.

Reply is a `UNTextInputNotificationAction`: title "Reply", button "Send", placeholder "Reply". It
posts in the background without activating the app or opening a window. The posted text is
addressed exactly like the in-app Reply: prepend the requester's `@handle ` unless the reply
already starts with an @mention. Use a fresh message ID, and retry once after 2 seconds with the
same ID only for a transport failure. On success, mark the channel read through the reply's own
sequence, as replying from a Messages notification does, and show nothing else. Empty or
whitespace-only replies post nothing.

When a reply can't be sent, never lose it. Save the text as that channel's draft for the
notification's server, appending after a blank line when a draft exists, and deliver one
notification: title the channel name, body "Your reply wasn't sent. It's saved as a draft."
Activating it opens the channel with the composer focused. A deleted channel says "Your reply
wasn't sent because [channel] was deleted." A notification from a server other than the current
one never posts to the current server. It takes the same failure path, with its draft saved
under its own server.

Notifications withdraw themselves. Remove a channel's delivered request notification as soon as
its `requestSequence` changes or clears, wherever it was answered. Remove a completion once
`seenThrough` reaches its sequence. Remove all of a channel's delivered notifications when it
becomes active in a key window. While the app is active, present requests from other channels as
banners with sound and send completions to Notification Center only, since the sidebar already
shows them. The active key channel still never notifies. Keep the existing per-milestone
deduplication and the two Settings toggles.

**Menu bar extra.** One template symbol tells you, from any app, whether your team is working or
waiting for you. It never animates, because a team can work for hours, and it never uses color.

| State | Symbol | Accessibility value |
| --- | --- | --- |
| A channel is waiting for you | `questionmark.bubble.fill` | "1 channel waiting for you" (plus the working count when nonzero) |
| Agents working, nothing waiting | `ellipsis.bubble` | "3 agents working" |
| Nothing active (Always only) | `bubble` | "No agents working" |
| Catalog unreachable | `bubble` | "Not connected" |

The label is "Toy Box Desktop". Waiting outranks working. The symbol swaps with
`.contentTransition(.symbolEffect(.replace))` where the status item supports it, and instantly
under Reduce Motion. Show no count, because the Dock badge already counts.

General settings adds "Show in menu bar" as a pop-up with Always, When Active and Never. When
Active is the default, with the footer "When Active shows the icon while agents are working or a
channel is waiting for you." In When Active, the item appears as soon as anything is active,
stays 10 seconds after the last activity ends so short gaps between agent turns don't shift the
menu bar, and never leaves while its menu is open.

Use `MenuBarExtra` with `.menuBarExtraStyle(.menu)`, a real menu with native keyboard and
VoiceOver behavior, not a popover window.

| Menu part | Specification |
| --- | --- |
| Waiting for You | Section header. One item per channel with a pending request, newest request first. Title: channel name. Subtitle: "[Agent]: [request text]" cut to 60 characters with "…", or "Needs your reply" until the text is known. Image: the requester's 16-point avatar, otherwise none |
| Working | Section header. Channels with working agents and no pending request, most recently updated first. Subtitle: "Shell is working", "Shell and Transcript are working" or "Shell, Transcript and 2 others are working". Image: the first working agent's 16-point avatar, lead first |
| Overflow | At most 6 channel items per section, then "[n] More Channels…", which opens the main window |
| Empty | One disabled item, "No agents are working". When the catalog is unreachable, "Can't connect to [host]" instead |
| Footer | Separator, "Open Toy Box Desktop", then "Settings…". No Quit, because this is a regular Dock app |
| Activation | A channel item activates the app, brings the main window forward (opening one if needed) and selects the channel. A waiting item also reveals the request, through the same route as notification activation |

Waiting comes from the same attention as the sidebar. Working must come from the one function
the sidebar row uses (live presence for an open channel, otherwise the catalog's `working`), so
the menu bar, the sidebar and the Dock can never disagree. Render avatars with `AgentAvatarView`
into images. Don't refresh the catalog when the menu opens, so items never move under the
pointer. Its normal cadence (5 seconds active, 15 inactive) is the latency.

**Catch-up summary.** When you return to a busy channel, a short on-device summary sits above the
New divider. Each line points at the messages it came from.

A channel is eligible only when all of these hold: the service's `availability` is `.available`,
"Summarize new messages" is on, Message View is All Messages, the summary for this boundary hasn't
been dismissed, and the unread span (after the boundary the New divider captured) holds at least
4 messages from others whose text together runs to at least 1,500 characters. The character
floor means "more than about one screen". Four quick "On it" replies are faster to read than a
4-second wait, and they would still pass a count alone. System rows and your own messages never
count. Both numbers are parameters.

| Part | Specification |
| --- | --- |
| Placement | Scroll content, not a message or glass. Directly above the New divider, and above a coinciding day label, with 12 points to the divider and the conversation-run gap (20) above it |
| Width and shape | Leading edge on the avatars' leading edge, trailing edge at min(lane, 804), the widest agent bubble's trailing edge. 12-point continuous corners. Fill primary at 3% in light and 5% in dark, with a 1-point inner hairline at 10% light, 14% dark and 40% under Increase Contrast. Padding 12 horizontal and 10 vertical |
| Header | 18 high. `text.line.3.summary` in 12-point medium secondary, 6 points, then "Summary of 42 new messages" in 12-point semibold secondary, counting messages from others. Trailing Dismiss: `xmark`, 10-point semibold tertiary, 28 x 28 hit area, help "Dismiss Summary" |
| Lines | 8 points below the header, 2 apart, each 3 points of vertical padding. A 16-point leading slot, 8 points, then 13-point primary text, wrapping up to 3 lines and then truncating, with the full line in help. The slot holds the 16-point avatar of the sender of the line's first source. When that source is a channel event, it holds the event row's own symbol and color at 13 points instead, such as the green `checkmark.circle.fill` of All tasks completed, never a generic `info.circle`. Text scales with Text Size |
| Needs you | The first line, only while a request is pending. The slot holds an orange 13-point `questionmark.bubble.fill`, and the text is medium weight. Once the transcript shows the request as Replied, the symbol becomes a secondary `checkmark` and the text turns secondary, in place, so the card never changes height. A later landing drops it |
| Line action | Each line is a button. Hover fills primary at 5% in a 6-point rounded rectangle extending 6 points past the text horizontally and 3 vertically. Click, Return or Space reveals the first source through the existing Reveal. Help "Show Message" |
| Footer | 8 points below the lines. "Summarized on this Mac" in 11-point tertiary. Its help: "Made on this Mac from the messages below. Summaries can be wrong." |

| State | Behavior |
| --- | --- |
| Loading | The card shows only its header, reading "Summarizing 42 new messages", with a mini spinner 6 points before Dismiss after 300 ms. About 40 points high. There are no placeholder lines or shimmer. The result runs from 1 to 4 lines of 1 to 3 text lines each, so any reserved height would be a guess, would push the real messages down while you wait, and would leave a larger hole to close when a summary fails |
| Ready | The card takes its full height in one layout pass, and the lines fade in over 0.2 seconds. A cached result is ready on the first frame |
| Nothing new, declined, unavailable, or no result after 15 seconds | The card fades over 0.15 seconds, then leaves in one layout pass. Failures stay silent, because the messages are right below |
| Stale | When at least 4 messages from others arrive after the result's `through`, the footer reads "Summarized on this Mac · 6 newer messages", with a borderless 11-point medium accent "Update". Update dims the lines to 50%, shows the header spinner, and crossfades in the new result. Nothing regenerates on its own |
| Dismissed | Fades and leaves as above, and focus moves to the New divider. It doesn't return for this channel and boundary during this app session |
| Unavailable from the start | No card and no reserved space |

Landing and motion. When a channel is eligible, land with the card's top where the New divider
would otherwise land. Until the reader scrolls, uses the keyboard in the transcript or reveals
anything, the card's top stays pinned, and its growth or collapse moves the rows below it. This
keeps the change in the place the "Summarizing" header promised. After that, height changes keep
the first visible row still, as paging does.

The card never animates its height. Only its contents fade, and every growth, update or removal
changes the layout once. Animating the height lays out the whole transcript on every frame, which
cost about 0.5 seconds of 33 ms frames at 480 loaded messages. The fades are crossfades, so Reduce
Motion needs no variant. The lines clip 6 points outside their own bounds, which holds their hover
backgrounds and focus rings and stays inside the card's padding. So when an update is shorter, its
outgoing lines never draw past the card's border onto the messages below.

The card is one accessibility container labeled with its header text, ordered before the New
divider. Lines are buttons labeled with their text, and the needs-you line reads "Needs your
reply: [text]" or "Replied: [text]". Arrival is never announced. The card lives only for this
landing. Leaving the channel and returning recaptures the boundary. Intelligence owns selection,
grounding and caching, and Transcript owns the card and landing.

**Image descriptions.** Generated descriptions are for VoiceOver. Sighted readers already see the
image, so descriptions never appear as captions, help, copied text or exports.

Generate only while VoiceOver is running (observe `NSWorkspace.shared.isVoiceOverEnabled`), when
"Describe images for VoiceOver" is on and the service is available. Request inline image tiles as
they appear, and the viewer's current image first. Don't request images in the composer tray,
artifact readers, videos or files. A tile keeps its label, "View [name]" or "View Image 2 of 2",
and the viewer keeps "Image 2 of 4 from Lead, [filename]". The description goes in the
accessibility value as "Generated description: [text]", replacing the empty value once the tile
has loaded. Nothing is spoken while it generates, and a missing result leaves the value empty.
Descriptions are one or two plain sentences, at most 160 characters, never starting with "Image
of" or "Picture of". Text quoted from the image must match on-device text recognition of it,
or the description is dropped.

**Live Text in the viewer.** Text in a screenshot is real text: select it, copy it and follow
its links.

| Part | Specification |
| --- | --- |
| Analysis | `ImageAnalyzer` with `.text` and `.machineReadableCode`, starting once the full image has decoded and the opening motion has ended. Cancel it on paging or closing, and keep the last 8 analyses by attachment digest per window. There is no progress UI |
| Overlay | `ImageAnalysisOverlayView` exactly over the displayed image, tracking its fitted and zoomed frame. `preferredInteractionTypes` is `[.textSelection, .dataDetectors]`. No Visual Look Up or subject lifting, which would badge screenshots and fight drag export |
| Live Text button | The system's supplementary button, only when text is found, inside the image's bottom-trailing corner, so it never meets the capsule. Hidden while zoomed, when selection still works. It takes its appearance from the image beneath it, not the window: set the overlay to light when the image's bottom-trailing 64-point square averages above 0.5 relative luminance, and dark otherwise. Where that corner is transparent, the canvas behind it counts. Measure once per decoded image. Otherwise a dark window's glass turns gray over a white screenshot and the glyph drops to about 1.9:1. The text menu keeps the window's appearance |
| Pointer and gestures | The system I-beam over text. A drag that starts on text selects text at any zoom. Elsewhere a drag pans when zoomed and exports the file at fit. Double-click on text selects a word and triple-click a line. Double-click elsewhere toggles zoom. Scrolling always pans and swiping pages. Data detectors underline on hover and open on click |
| Keys | `Cmd-C` copies the selected text when there is a selection, otherwise the image, and Edit > Copy keeps the title "Copy". More > Copy Image always copies the image. Escape clears a selection first, and a second Escape closes. Left, Right and paging clear the selection |
| Menus | A right-click on selected text shows the system text menu (Copy, Look Up, Translate, Share). Everywhere else is unchanged |
| Accessibility | Recognized text is exposed as the overlay provides it. The image keeps its label and description value |

**Siri and Shortcuts.** Ask what needs you, open a channel or send a message by voice, from
Spotlight or in a shortcut, without touching the window. Every answer is the team's own words or
the transcript's summary, and asking never marks anything read.

| Intent | Mode | Parameters | Result |
| --- | --- | --- | --- |
| Catch Me Up | Background | Channel, optional | A card with a spoken headline, or the whole answer spoken when there's no card or no screen. The whole answer is also returned as text |
| Open Channel | Foreground | Channel | Opens it through the notification route: activate, request navigation, and open a window only when none shows a channel |
| Send Message | Background | Channel, then Message (multiline) | "Sent to [channel]." after the system's Send confirmation |

| Phrases (each ends "in [app name]") | Intent |
| --- | --- |
| "Catch me up", "What's new", "Catch me up on [channel]", "What's new in [channel]", "Summarize [channel]" | Catch Me Up |
| "Open [channel]", "Show [channel]", "Open a channel" | Open Channel |
| "Send a message", "Send a message to [channel]", "Message [channel]" | Send Message |

The app name is "Toy Box Desktop" or its alternate, "Toy Box" (`INAlternativeAppNames`). The
shortcut tile is navy, like the icon. Tile symbols are `text.line.3.summary`,
`bubble.left.and.bubble.right` and `paperplane`.

The Channel entity is identified by channel ID and displays the name, with `number` as its image
(the whole icon in Spotlight) and the sidebar's attention as its subtitle: "Needs your reply", "All
tasks completed" or "Unread messages". It has Name, Unread Count (`latestSequence - seenThrough`,
which counts channel events too), Needs Your Reply and Tasks Completed properties. Its query reads
the catalog fresh, suggests channels in sidebar order and matches names ignoring case, accents and
punctuation, exact names first, then prefixes, then substrings. The app refreshes the shortcuts'
parameters whenever the set of channel names changes, so Siri learns them.

**Spotlight.** Every channel on the server saved in Settings is in Spotlight by name, with the
first line of its purpose under it and the sidebar's cyan channel icon (a 128 px PNG) beside it.
Attention is left out, since Spotlight would keep it after it goes stale. Picking a channel runs
Open Channel. The Channel entity is an `IndexedEntity`, keyed `ChannelEntity/<id>` in the app's
default index. The first catalog load after launch replaces whatever Spotlight held, and the last
launch's channels stay until then. After that the app indexes only renames, purpose changes,
additions and deletions. Switching servers, or having no valid one, removes every channel at once,
before the new server's catalog arrives. A failed call makes the next catalog change replace
everything. Launches with `--server`, `TOY_BOX_SERVER_URL`, a snapshot or a benchmark never touch
the index. When Spotlight asks the app to reindex, it indexes the catalog's channels and removes
identifiers the catalog no longer has.

A window that shows a channel makes it the window's user activity (`dev.toybox.desktop.channel`)
with `appEntityIdentifier` set to its Channel entity, through `userActivity(_:element:_:)` so the
activity follows a switch. AppKit makes the main window's activity current, so Siri and Apple
Intelligence take "this channel" to mean the one in front, and with no channel shown there's no
activity. Handoff stays off, since no other device can open the channel. The activity carries only
the identifier. The entity isn't `Transferable`, so Siri learns what a channel says only from
Catch Me Up's answer.

Catch Me Up without a channel says "You're all caught up." when nothing needs you, catches up on
the one channel that does, or gives an overview: "You have updates in 4 channels." and then one
line for each of the first 3 in attention order (waiting, completed, unread, then most recently
updated), such as "Studio demo is waiting for your reply.", "Docs finished all its tasks." or
"Design has 3 new messages.", then "There's 1 more channel with updates." Every line starts with
the channel's name, because listeners catch the first word. A count comes from one history page
and becomes "has new messages" when the page doesn't reach the boundary.

For one channel, connect its shared store for the duration (live windows already have it), take
the boundary from `seenThrough`, and answer in this order:

| Case | Answer |
| --- | --- |
| Nothing unread or pending | "You're all caught up in Studio demo." |
| The transcript's summary is eligible, on and ready within 15 seconds | "Here's a summary of 27 new messages in Studio demo." Then the needs-you line (or the request quoted as below), the changes, and "All tasks are done." unless a change already cites the completion |
| Otherwise, a pending request | "Lead needs your reply in Studio demo: “[request]”" |
| Otherwise, up to 3 unread messages from agents totaling at most 600 characters | "There's 1 new message in Studio demo." (or "There's also…" after a request), then "Ada wrote: “…”", "Moss shared an image." or "Moss shared 2 images and wrote: “…”" |
| Otherwise | "There are 12 new messages in Studio demo, from Iris, Finch, Moss and 2 others." "at least 12" when the loaded history doesn't reach the boundary |
| Completed since the boundary | Adds "All tasks are done." or, alone, "Studio demo finished all its tasks." |

Quotes are the message text with leading mentions dropped, Markdown flattened and inline
mentions as names, cut at a word to 280 characters (a request keeps its start and end). The
summary shares the transcript card's cache, so a channel summarized in either place is instant in
the other. It respects "Summarize new messages" and the model's availability, and a slow or
declined summary falls back to the quotes silently.

**Catch Me Up card.** Catch Me Up returns `IntentDialog(full:supporting:)`: Siri says the
headline beside the card and the whole answer only where it can't show one. Headlines are "Here's
a summary of 27 new messages in Studio demo.", "Lead needs your reply in Studio demo.", "There
are 3 new messages in Design." ("There's 1 new message…", "at least" as above), "Docs finished
all its tasks." and "You have updates in 4 channels." When nothing is new there's no card, just
the sentence.

| Part | One channel |
| --- | --- |
| Header | The channel's name, 15 pt semibold, over a 12 pt secondary caption: `text.line.3.summary` with "Summary of 27 new messages", or "Waiting for your reply" (then "Replied") with " · 1 new message" when there are others, "3 new messages" or "All tasks completed" |
| Lines | The spoken answer's, in 13 pt up to 3 lines each beside the transcript card's 16-point slots. With a summary, its needs-you line and changes, exactly as the transcript card leads them. Otherwise the request, then the newest 3 messages as "**Ada:** …" beside the author's avatar, or "Moss shared 2 images." for images alone. Inline mentions keep their @ ("@Moss", "@everyone") in the transcript's mention ink and weight, though speech says the names. A completion adds "All tasks completed" with its event symbol, unless the summary cites it |
| Footnote | 11 pt tertiary: "Summarized on this Mac", or "Plus 9 earlier messages" ("Plus at least 9…" when the loaded history doesn't reach the boundary) |
| Buttons | Large capsule buttons of equal width. "Reply to Lead" (`arrowshape.turn.up.left`) is prominent while the request waits, and plain "Reply" otherwise. "Open" (`arrow.up.forward.app`) runs Open Channel |

The overview card is "Updates in 4 channels" over a row for each of the first 5 channels: the
sidebar's indicator, the name in 13 pt medium, then the status in 12 pt secondary ("Waiting for
your reply", "Finished all its tasks", "3 new messages", "New activity" or "New messages") and a
chevron. Each row runs Open Channel. "Plus 2 more channels" follows when there are more.

The card is a hidden `SnippetIntent` that carries its content as JSON, so the system can redraw
it after a relaunch without the server or the model. Its `perform` only reads. It shows the
request as Replied once the app has sent a reply to it, or once a window's live store has a
message from you after it, and never connects a channel. The view is plain SwiftUI with
`AgentAvatarView`, because the system archives it, and its buttons are `Button(intent:)`, because
closures don't run in a snippet. Reply is a hidden background `ReplyIntent`. It asks "What do you
want to say to Lead?", confirms "Send “[text]” to Lead in Studio demo?", then sends "@lead [text]"
through Send Message's path, mentioning the asker as the transcript's Reply does, or no one if
they've left. It returns no dialog, so the card redraws as Replied.

Send Message trims the text and refuses an empty one before asking anything. It confirms with
`requestConfirmation(actionName: .send)` and "Send “[text]” to [channel]?", then posts once
through the channel's shared `ChannelStore` with a fresh caller-owned ID, so it joins the outbox
and appears in an open window at once. It never retries. A rejection says "Your message to
[channel] wasn't sent. It's waiting in the channel so you can send it again." An unconfirmed
delivery says "Your Toy Box server didn't confirm your message to [channel]. Open the channel to
see if it arrived before you send it again." Other errors: "Toy Box Desktop isn't connected to a
server. Choose one in Settings.", "Can't connect to your Toy Box server. Check that it's running,
then try again." and "That channel isn't on your Toy Box server anymore." Errors about the server
always say "your Toy Box server", since "Toy Box" alone now also names the app.

When Catch Me Up, Send Message or the card's Reply launches the app, the system starts it hidden with activation
prohibited. That launch presents no window and runs as an accessory app outside the Dock, so the
system quits it once the intent finishes. Windows restored from the last session stay hidden, and
no extra window opens. Activation or a shown window, from a reopen, Open Channel, the menu bar
extra or a notification, makes it an ordinary app. Every other launch, Dock click and reopen is
unchanged.

`script/run` generates `Contents/Resources/Metadata.appintents` by running Xcode's
`appintentsmetadataprocessor` directly over the const values SwiftPM already emits, so it needs
Xcode installed but never `xcodebuild`. Titles, phrases and parameter names must stay literals.
The system only indexes a bundle outside `/tmp` that has launched once, and parameterized phrases
need a team-signed build, so verify Siri with a Developer ID build in Applications.

**Settings additions.** General gains "Show in menu bar" (above) and a group of two toggles, both
on by default. Each toggle's description sits in its row as secondary text under the label, the
way System Settings describes its toggles, rather than as a section footer:

| Toggle | Description |
| --- | --- |
| Summarize new messages | "When you return to a busy channel, a summary appears above the new messages. Made on this Mac." |
| Describe images for VoiceOver | "While VoiceOver is running, images get descriptions made on this Mac." |

When the service isn't available, both toggles are disabled and keep their values, their
descriptions hide, and one footer under the group explains why. It reads "This Mac doesn't support
Apple Intelligence.", "Turn on Apple Intelligence in System Settings to use these." with an Open
System Settings button trailing on the footer's line, "Apple Intelligence is getting ready. Try
again later.", or, when the model doesn't support the Mac's language (`unsupportedLanguage`),
"Apple Intelligence doesn't support your Mac's language yet." with no button. The Settings window
grows to fit General rather than scrolling.

Owners: Shell owns notifications, the menu bar extra and Settings (t94, t95). Intelligence owns the
model layer (t96), Siri and Shortcuts (t126) and Spotlight (t166). Transcript owns the catch-up
card, descriptions in tiles and the viewer, and Live Text (t93, t97). Designer reviews each one in
real-window captures, in light and dark, with VoiceOver and with Reduce Motion.

### App icon

The icon is the Toy Box robot's head as a speech bubble, alone and centered. It means your agents,
talking. It carries the brand's navy and robot face, the channel cyan in the eyes and a gold
antenna for one warm accent, and it never shows text or a hash mark.

| Part | Specification (1024 pt Icon Composer canvas) |
| --- | --- |
| Source | `Resources/AppIcon.icon`, an Icon Composer document with one 1024 x 1024 SVG per layer. It's the only artwork. Edit it in Icon Composer or as text |
| Background | Vertical linear gradient `#1C4090` to `#071937`. The dark specialization is `#122656` to `#040B1A` |
| Head group (back) | Speech bubble body x 193...831, y 305.2...778.2, corner radius 187, with its tail to x 261.2, y 879.4 at the lower left. The body is centered on x 512, and the whole robot, antenna to tail, on y 512. Antenna stem 39.6 x 121 at x 492.2, y 210.6. Fill `#F3EFE6`, `#E6E2DA` in dark. Glass on, translucency 0.3, neutral shadow 0.5 |
| Face group (front) | Visor 492.8 x 277.2 at x 265.6, y 402, radius 138.6, `#0A1530`, not glass. Eyes 61.6 x 110 capsules at x 391 and 571.4, y 468. Smile is a radius-66 arc from x 465.8 to 558.2 at y 617.6 with a 26.4 pt round stroke. Eyes and smile are `#67E8F9`. Antenna ball radius 50.6 at 512, 195.2 in gold `#FACC15`, glass |
| Shipped artwork | `Resources/AppIcon.icns`, committed. `script/icon` renders the Default appearance with Icon Composer's `ictool` and places it on Apple's grid: an 824 pt body inset 100 pt, with a black 22% shadow offset 10 pt down and blurred 34 pt. That matches Apple's own `.icns` files within a pixel. Output is byte-identical across runs |
| Builds | Local and GitHub bundles copy the same `.icns` and set `CFBundleIconFile`. No build renders the icon, so neither needs Icon Composer or `actool`. macOS 27 shows it at the system size with no gray plate |
| Not shipped yet | The source also defines Dark, Clear and Tinted appearances. They apply only to a compiled `Assets.car`, which needs `actool`. Adding one later must ship in both local and GitHub builds, never in only one |

Change the artwork only in the `.icon`, then run `script/icon` and commit both files together.
Check 16 and 32 px on light and dark before accepting a change. The 16 px icon must still read as a
navy tile with a white speech-bubble head.

### Implementation review gates

Native polish is a release criterion, not a cosmetic phase after functional completion. A
successful build and nominal SwiftUI controls do not establish first-party quality. Prefer the
real AppKit/SwiftUI behavior over a custom imitation, and preserve it through all app states.

| Native quality gate | Required result |
| --- | --- |
| Window chrome and scroll edges | Real window on the stamped build only. No band or rule of our own under the toolbar, only the system's top scroll edge, continuous across the conversation and the inspector. Toolbar title, glass controls, the floating composer and the activity row remain legible while any message, reaction or attachment scrolls underneath. Hidden content is never read. Active and inactive windows both look intentional |
| Geometry and resizing | 760 x 560 is a working layout, not an error case. Initial launch, resize, inspector adaptation, full screen and return from full screen preserve selection, draft and reading position |
| Control fit and rhythm | Shared lane edges align. Symbols use native optical sizing. Toolbar menus have one affordance each, no duplicate chevrons. No clipped text, one-pixel seams, arbitrary spacer gaps or misleading enabled controls |
| First responder and keyboard | Native focus rings, Escape, Tab order, menus, context menus and text undo behave correctly. Reconnects, background updates and popovers never steal the user's caret or keyboard focus |
| Pointer and popover behavior | Hover controls do not move content or disappear while moving into them. Popovers anchor to their triggering control/caret, stay inside the visible screen and dismiss predictably without losing selection |
| Text and information density | Short content never shows an unnecessary Show More. Timestamps do not tick every second. Full values remain available without turning every row into a multi-line card. Messages and artifact prose are genuinely selectable |
| Platform appearance | Light, dark, inactive selection, user accent, increased contrast, reduced transparency and reduced motion retain the same hierarchy and meaning. Custom rendering is justified only when native controls cannot meet the behavior |
| Evidence and closure | Recheck the actual corrected build, not just the intended code change. A screenshot closes only the visual state it shows. Missing interaction or accessibility evidence remains explicitly open |

#### Accessibility audit evidence, 2026-10-22

The initial audit covers source semantics, actual light/dark renders at both window sizes, the
compact sheet's upper and lower sections, and a real accessibility-tree read of demo window
25059. That tree exposes channel activation, image filenames, section headings and exact
task/diff values. An earlier window read was unavailable, and the first attempted Tab action
failed in the tool with "no perception baseline for this pid" before reaching the app.
Spoken VoiceOver output, actual Tab traversal and OS-level accessibility preference changes
have not been independently verified by Designer.

| Finding | Owner | Verification and remaining work |
| --- | --- | --- |
| Mention ink | Transcript | Reopened 2026-10-22 because mentions didn't stand out. Semibold identity ink, clamped per surface to 4.5:1 (7:1 with Increase Contrast), with no background, supersedes primary ink on a 10% tint. Keep the seven-color, five-surface contrast regression with the new targets. Original light `@moss` was 2.69:1 |
| Message identity and grouping | Transcript | Closed for the inspected states. Lead's rebuilt-window AX pass confirms author, time, addressee and request labels on per-message groups. The filename-bearing Quick Look button remains reachable and opens its panel |
| Compact targets | Transcript, Overview, Composer | Source bounds are now at least 28 x 28 for reaction chips, task disclosures, task artifact actions and attachment Remove. Native hosting verifies reaction sizing. Corrected transcript/Overview renders retain the intended glyph scale and layout |
| Reaction action semantics | Transcript | Native activation verified by Lead after replacing the gesture-backed chip with a plain native Button. The rebuilt dark studio-demo window opens the reactors popover anchored to the chip and shows the reaction and reactor name. Spoken VoiceOver feedback remains unverified |
| Mention selection feedback | Composer | Source exposes the selected completion and announces a newly active keyboard choice without moving the insertion point. Actual screen-reader selection feedback remains unverified |
| Native composer keys after the visual pass | Composer | Owner exercised mention opening, Down/Tab acceptance, caret placement, Undo and Escape in the normal scene at 1280 x 840 light and 760 x 560 dark. This does not verify spoken selection feedback or every keyboard-only focus path |
| System-link text contrast | Transcript | Closed for rendered ink. Native semantic link color measures 5.25:1 on white and 5.89:1 on the dark transcript after ICC conversion. A permanent owner regression also covers Aqua, Dark Aqua and both Increased Contrast appearances |
| Error and status contrast | Overview, Transcript, Composer, Shell | Closed. Corrected PNGs, converted through their embedded ICC profiles to sRGB, show management error text at 14.94:1 and completed-task symbols at 6.51:1 light / 8.12:1 dark. Settings/composer errors use the same primary-text/red-symbol pattern. Overview, transcript and sidebar use the same Shared completion palette |
| Transient announcements | Transcript, Composer, Core | Closed in source/tests. Request baseline, deduplication and background/snapshot suppression checks pass. Every failed explicit send, including a retry with the same delivery UUID and phase, now emits a fresh store-owned failure ID. Composer consumes that ID directly and deduplicates across windows. Journal restoration is quiet, and confirmation/discard clear resolved failures |
| Menu names | Overview, Shell | Lead activated Channel Actions and the title-bearing member/routine menus in the rebuilt window. A native Settings read confirms the notifications toggle, "Requests for your response" and "Completed tasks", with the two subordinate toggles dimmed while notifications are off. That toggle has since been renamed "Allow notifications" in source, and the new label has not had a native read. Spoken VoiceOver traversal remains unverified |
| Missing-profile avatar | Shell | Closed. The fallback initial uses primary ink on its cyan field. Rendered regressions pass the 4.5:1 floor for missing and invalid-mark profiles in both appearances. Supplied marks retain contrasting black/white ink |

Designer independently passed the selected regressions using `script/test` with the filters
`'TranscriptTests|ManagementTests'`, `'ComposerTests|ShellTests'` and
`'SendAttemptTests|ComposerTests'`.
This verifies the implemented source/test remedies above, not spoken VoiceOver output or
every runtime focus path. The last run explicitly includes repeated same-UUID 422/503 failures,
quiet restoration, resolved-event clearing and cross-window announcement deduplication.

Designer approved the corrected wide-dark task hierarchy, compact-light expanded routine,
compact-dark Edit Channel and light New Channel with the real catalog. The task title retains
its full line, the routine details fit, and Purpose no longer touches the model row in those
renders. The real-history paging validator checks the same message after fresh-page layout
and settling, with a 2-point displacement limit. Transcript reports all four prepends passing at
1280 x 840 light, 760 x 760 dark and the actual 760 x 560 minimum in dark. The minimum run reports
0.0-point displacement on every page, and Designer reviewed its correctly sized render.
Lead subsequently verified native reaction activation, the pinned Working Now popover and
routine expansion in the rebuilt dark studio-demo window. Expanded routine details end at the
inspector's bottom edge. Lead also verified first-unread landing below New and native Jump to
Latest, which hides at the end and returns after scrolling away. Incoming-message auto-follow
and final light/dark acceptance of the user-facing build remain open. These owner/Lead interaction checks are distinct from Designer's
static approvals and do not prove spoken VoiceOver output.

Already reviewed: request/waiting text and adaptive diff counts meet their corrected visual
treatments, the non-default filter is distinguishable without color, task progress and diff
values expose exact semantics, and image actions include filenames. The Overview working ring
read Reduce Motion, pausing its timeline and removing rotation. Its replacement, the Team's
typing ellipsis, must be rechecked under Reduce Motion. Sidebar activity no longer
animates or uses a spinner. There
are no explicit animated transcript scrolls. These source checks do not substitute for a
spoken screen-reader or runtime preference-switching check. Owner fixes and remaining runtime
evidence are tracked by channel tasks t21 and t26.

Before calling the UI complete, inspect the running app in light and dark at 1280 x 840 and the
760 x 560 minimum. Exercise a long purpose/name, no members, many members, removed agent, nested
tasks, zero diffs, missing task artifact, attachments, request outside the loaded page, both
filters, offline/reconnect and terminal deletion against a scratch/fixture channel. Verify first
unread anchoring, no scroll jumps on paging or new reactions, selection and text-copy behavior,
keyboard-only composing, IME Return, VoiceOver grouping, Reduce Motion and Increase Contrast.
Screenshots are visual evidence, not a substitute for interaction checks. Public shared channels
remain read-only during this review.

## Exclusions

- Private agent sessions and tool logs. These never enter the channel, matching the pane.
- Live screen-preview canvas. The app opens the screen in Toy Box instead of streaming it.
