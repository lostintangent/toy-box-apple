# Toy Box for Apple: spec

Toy Box for Apple is two native clients for Toy Box Channels: a macOS app and an iPhone companion,
including iPhone Duo folded and unfolded. Each gives the user the full Channel pane experience
(transcript, composer, overview) in an app that feels first-party on its platform, with the same
scope tailored to each. The Toy Box server owns Channels, agents, sessions and durable work.
Both apps are presentation and input surfaces over Toy Box's public Channel protocol, the
`/api/v1` HTTP and SSE routes.

Reference sources (read-only):

- Toy Box server and pane: `~/Desktop/toy-box/src/features/channels` (start with its `AGENTS.md`)
- Contract fixtures: `Tests/Shared/ChannelKitTests/Fixtures`. The demo servers read the same
  `channel-snapshot.json`.

Signing, notarization, in-place updates and TestFlight are in the [release skill](../.agents/skills/release/references/distribution.md).

## Success criteria

1. **Same protocol.** The Mac app and the iPhone companion speak the same protocol. Listing,
   observing, paging, posting and reading use only the public `/api/v1` routes. No private
   TanStack server functions, no database access, and no parallel schema.
2. **Faithful state.** A Swift port of `reduceChannelState` produces the same state as Toy Box. Tests
   prove it against the snapshot and transition fixtures.
3. **Pane parity.** Every capability of the pane works, as the surface sections under Surfaces
   describe, or is explicitly excluded here with a reason. The iPhone companion offers the same
   scope tailored to the phone, and each surface section states where the phone differs.
4. **Idiomatic on each platform.** Each app should read as an Apple-quality app, not a web view,
   with correct behavior in light and dark mode, at any window or scene size, and with
   accessibility. On the Mac that means native split view, sidebar, toolbar, inspector, menus,
   keyboard shortcuts, Settings, Dock badge and notifications. On iPhone it means the platform's
   own navigation, sheets, toolbars and controls, in layouts that adapt to the scene the system
   provides. The Mac's idioms are:
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
  phase, unread boundary and paging. The catalog store owns the channel list and holds the
  server's catalog stream from launch, so each change arrives as it happens, in the background
  too, where requests still reach the Dock badge and notifications.
  Neither waits for the main thread to start a request. The catalog opens its stream at once, and
  connecting starts a channel's stream. Events are read off the main actor and queued for it as
  each one decodes, so a snapshot that arrives while the first window is being built applies in
  the main thread's next turn.
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
  recently released stores linger, and changing or removing a server disconnects its stores at once. A lingering store
  has no transcript, so it never marks read, and notifications come from the catalog, so it posts
  none.
  Views read the store's observed slices (`details`, `roster`, `agentStatuses`, `presence`,
  `messages`, `request`, `requestSequence`, `tasks`, `artifacts`, `artifactShares`, `routines`,
  `bookmarks`, `bookmarkList`)
  rather than `state`, which changes on every event. An event then re-renders only the views that
  show what it changed. `roster` leaves out each agent's status, which `agentStatuses` carries, so
  status updates don't re-render identity. A catalog that changes nothing announces only
  `lastRefreshedAt`, and a failure that repeats the current one isn't announced again. Views that
  only ask whether the catalog has loaded read `isLoaded`.
- **Phone scene:** the iPhone keeps its channel streams and catalog stream while its scene is
  merely inactive, as under Control Center, Notification Center or the app switcher, so a brief
  look away never forces a reconnect. It drops them only when the scene enters the background, and
  reconnects as soon as it returns. Marking read, management and treating the open channel as seen
  still need the active scene. Nothing on screen changes because the scene went inactive or a
  channel is reconnecting quietly: sidebar working agents and the notification tip stay until the
  channel is stale or deleted.
- **Sending:** every message goes through one outbox, as [Sending](#sending) describes.
- **Wire rules:**
  - Decode leniently, so unknown system message kinds and fields degrade to a generic row instead
    of failing the stream.
  - Resource URLs (artifacts, attachments) resolve against the configured server base URL, which may
    include a path prefix.

### Connections

A channel's stream, the catalog's stream and Settings' Test Connection each report `connecting`,
`connected` or `failed`, and a channel can also be `deleted`. Each scope shows one notice: the
transcript's "Reconnecting to server" for a channel, the sidebar footer for the catalog and Settings
for Test Connection. A channel with cached state reconnects on its own, so its notice has no verb
and Overview adds no notice of its own. Retry stays only where nothing has loaded yet, on Can't
Connect and a management sheet with no channel behind it, and on the catalog footer and Test
Connection. Three invariants hold:

- **A channel failure keeps retrying its stream.** A channel is `failed` once it has tried for a
  grace (`ReconnectPolicy.grace`, three seconds spent trying) in which nothing arrived, without
  connecting. It keeps trying with backoff and stays `failed`, and so does its notice, until the
  stream connects. Three moments try again at once with the backoff reset. The network path
  becoming satisfied or moving to another interface starts a fresh attempt for every held channel
  that isn't connected, since one under way may be stuck on the old path. Coming back to the app,
  and a catalog arriving after the catalog failed, end every held channel's backoff but leave an
  attempt under way to finish, so a snapshot still arriving never starts over.
- **A catalog failure describes stream and refresh health.** The stream reports after failing for
  the grace, counted from a drop or from an attempt that never delivered a catalog, and a refresh
  someone asked for reports at once. Reconnecting continues and the rows stay. The
  error stays typed, because a refused sign-in shows red and the widget rethrows it. Refresh, from
  Cmd-R, the footer, pull to refresh or Quick Send, means only this channel list.
- **A Test Connection failure is final.** It reports one attempt and doesn't retry.

Send, management and read marking wait for `isConnected`. A read write belongs to the store, so
cancelling the reader that started it neither interrupts it nor reports an error. A later read
joins that write, which sends the newest position before it finishes. A failed read shows nothing,
since marking read is never something you asked to save, and the next read sends it again. Notices, agent status and working
presence change on `isUnavailable` (failed or deleted), never on a view timer. The outbox, Retry
and `reconcileManagementWrite` are delivery, not connection, and a handed-off channel that
couldn't be opened is Handoff's `missing`.

- **Channel stream:** `connect()` starts the stream and keeps retrying until `disconnect()`, and
  does nothing while already trying. `disconnect()` stops trying and leaves `connecting` unless
  deleted. Nothing waits on that phase change. `reconnect()` serves Can't Connect's Retry. One
  observation loop opens the stream, receives each event and backs off after an error. Reading a
  stream opens its request in the reading task, so only that loop ever connects: a stream it never
  reads, or reads only after a disconnect, sends nothing. The grace
  runs only while that loop is trying and the phase is `connecting`. A grace with stream bytes in
  it waits another round, so a large snapshot on a slow link reads Connecting while it arrives, and
  failure follows the first full grace in which nothing arrived. The server's heartbeat keeps the
  stream open: 35 seconds of silence fails it through the stream request's own timeout.
- **Catalog:** a quick reconnect never changes its phase, so it's `connecting` only before its
  first outcome and coming back never turns the footer dot gray. `isLoaded` means a catalog has
  arrived, the same word `ChannelStore` uses. `startPolling()` opens the catalog's stream in one
  task, which reconnects with the channel stream's backoff until `stopPolling()` cancels it. Each
  attempt opens with the whole catalog, since the stream has no cursor, and later changes apply
  only on top of it. Each catalog and change moves `lastRefreshedAt`. Keepalives move it at most
  every 15 seconds, the old idle poll's cadence, so its observers wake no more often on a quiet
  server than they used to. `refresh()` joins
  an attempt already in flight. Otherwise it reopens the stream and returns with its catalog, or
  fetches the catalog once where nothing streams, as in the widget and share extensions.
  `setActive(true)` ends the stream's backoff but leaves a live stream or an attempt under way
  alone. While streaming, the catalog watches the network path through `NetworkPathSource`, which
  follows `NWPathMonitor` unless a test injects one. Its first report is only where things stand.
  A path that comes back or moves reopens a stream that isn't live, and the held channels try
  again as the first invariant describes.
- **Sessions:** every stream uses `ChannelAPI.streamSession`, one session for all servers that
  allows 64 connections per server. One-shot requests keep `URLSession.shared`, so a dozen open
  channels never hold a request behind them. One shared session would fill its six connections
  per server with streams and stall every other request.
- **Footer:** `SidebarFooter` (ToyBoxUI) turns `phase` and `isLoaded` into the dot, heading, help
  verb and VoiceOver value on both apps (see Sidebar). Only a refresh the user asked for lights the
  Mac's footer spinner, through `AppModel.isRefreshingCatalog`. The stream, Handoff, management and the
  widget never do.
- **Test Connection:** `ServerConnectionProbe.phase` is nil until a test runs, then `connecting`,
  `connected` with the channel count, or `failed`. `isConnecting` drives the button.
- **Holders:** `ChannelConnections` counts who holds each store through `hold` and `release`. The
  last release lingers as State describes, and `disconnectAll(in:)` serves changing or removing a
  server.

### Several servers

Both apps can stay connected to several Toy Box servers at once. A server is its address, the
normalized URL that drafts and push registrations already key on, and a name that starts as its
host. Each server has its own `ChannelAPI`, catalog stream and channel stores, and every rule in
this spec holds within each server unchanged. Nothing else is new. Where this spec says a server
change, it means changing or removing one server, which touches only that server's channels.
Drafts stay keyed to the address, so adding it back finds them.

- **One server looks exactly as it does today.** The list has no section headers, and the Mac
  footer keeps its status line as Sidebar describes. Everything below applies with two or more.
- **Grouped list.** The Mac sidebar and the phone list show one collapsible section per server, in
  Settings' order. Its header is the server's name, with the status line's help and VoiceOver
  value. A connected or connecting server shows no dot, since the list is shaped for success. Only
  a failing server's orange or red dot leads its name, and on the Mac a load longer than 300 ms
  shows the footer's mini spinner there until it resolves. Nothing holds that spot empty, so a
  healthy server's name starts at the header's edge. On the Mac, the name is secondary, the same
  color as the footer's status line at rest. The header keeps the sidebar's own section header
  inset, which puts its leading edge 4 points inside the search field's edge, and every header has the same room above it, whether it follows the
  search field or another server's last row, matching the gap between two servers. On the phone, the name is followed by how many channels the server has, in
  the header's font and secondary color, once its catalog has loaded. A failing server shows only
  its header's orange or red dot, never a notice in the list, so the list always shows every
  server and its channels. On the Mac the header's help adds the readable failure, and on the
  phone tapping the dot shows it in a popover (see Phone channel search).
  While a section is collapsed and any of its channels waits for the user's response, its header
  also shows the waiting attention symbol, trailing in its color and without a count, so
  collapsing a server never hides a request. It hides while the section is open, and VoiceOver
  adds "waiting for you" after the header's value. The Mac footer's status line reads "2 servers" instead of a host, with its dot showing the
  least healthy server: red, then orange, then the first load's gray, then green. That dot never
  spins, since each header shows its own server's load. Its help names the least healthy server,
  like "Reconnecting to 127.0.0.1:3211", or reads "Connected to 2 servers" when every server is
  connected, then "Change servers in Settings.", and VoiceOver reads the same. Search filters every server and keeps the sections. The phone
  keeps one open Needs You card, the newest across every server, in its server's section.
- **Choosing a server.** New Channel and the Screens list start on the selected channel's server,
  with a server menu to pick another.
- **Beyond the window, everything spans every server.** The Dock and phone badges, notifications,
  the menu bar, Quick Send, Share, Siri, Spotlight, the Needs You widget and Live Activities cover
  all servers. Every reference to a channel, in a notification, a widget, a Live Activity,
  Spotlight, an intent, Quick Send, Share or a restored window, names its server by the address
  or push registration it carries, so it opens the right one. Handoff carries only the channel,
  because two devices often reach one server by different addresses. It, and any reference
  without a server, opens in the first server in Settings order whose catalog lists the channel,
  and reports the channel missing only once every server has answered. The menu bar inbox, the
  Dock menu and the Needs You widget list every server's requests together, newest first, without
  naming the server. Each is out of date when any server is, the widget showing the oldest
  server's last update, and Retry refreshes every server. The morning digest stays one
  notification, and each line opens on its own server.
- **Settings** lists the servers with their dots and names, even when there's one, so Add is
  always there. On the Mac, they have their own Servers tab between General and Notifications,
  and the list has Add and
  Remove buttons and drags to reorder, and the selected server's Name, Server URL with Test
  Connection and status sit below it. The list adds no inset of its own: its dots line up with
  the labels below, and it's as tall as its rows. Its card keeps the grouped Form's own padding
  around a list, a little roomier than the details card below it. On the phone, each row opens Welcome's Server URL card with
  a Name field, Add Server follows the rows, and Edit reorders and deletes. Adding an address
  that's already listed selects that server instead. Removing one asks first, then disconnects it
  and removes its channels from Spotlight, notifications, widgets and Live Activities. The last
  server can't be removed, only given a new address, so Welcome appears only on first launch.
- **Updating a server.** Settings' server list updates each server and restarts it onto the new
  release, the same way on both apps, through `GET /api/v1/server`, `POST /api/v1/server/update`
  and `POST /api/v1/server/restart`. The server answers `version`, the release it runs, and
  `installedVersion`, the release on disk, which is null when no package manager owns the install.
  Each row shows its server's version in secondary ink after the name. One Check for Updates
  serves the whole list: on the Mac at the trailing end of the list's bar, beside Add and Remove,
  and on the phone as a row after Add Server with `arrow.triangle.2.circlepath`. It's there
  whenever a server has an installed version, and it asks every connected one to install whatever
  is newer, skipping servers that are offline or have none. Each row being checked shows a
  spinner in its version's place, and the button dims until every check ends. Then a row reads
  Up to date when nothing was newer, or the error in words after a yellow
  `exclamationmark.triangle.fill`, in the row on the Mac and under the address on the phone.
  A failed install's error is its package manager's own output and can run to many lines, so the
  Mac shows its first line with the rest in its help tag, and the phone shows up to three lines.
  VoiceOver reads all of it. Results stay until the next check or until Settings closes. While a server isn't connected, its
  row shows a spinner in its version's place as the app reconnects, for any reason, until it
  connects or has failed for the catalog's grace, when the row shows its failure as it does for any
  server that can't connect. A restart is pending exactly when `installedVersion` isn't null and
  differs from `version`, whichever device ran the update, and then a connected row shows a
  prominent Restart, after "0.3.10 installed" on the Mac. Restart has no confirmation, and the
  apps give it no handling of their own. A server that accepts answers 202 and drops every
  connection at once, without accepting new ones, so the apps see an ordinary disconnect: the row
  spins while they reconnect with the usual backoff and grace, then reads the new server and shows
  its version. A rejected restart shows its error the same way, with the old server still running,
  and a server that doesn't come back reads like any other that can't connect. The apps read
  `GET /api/v1/server` while Settings shows the list, after each check and
  each time a server reconnects. These are management writes: an update that times out or drops
  may still have installed, so the row reads the server again before offering another try.
- **Linking servers.** A linked server's channel leads can find and privately message the leads
  on the user's other linked servers, with every app closed. Linked servers always reach each
  other at `https://<host>` through `tailscale serve`, so a link is a host: lowercase, with its
  port only when it isn't 443. The apps link through `GET`, `POST` with `{address}` and
  `DELETE ?address=` on `/api/v1/server/links`, which each answer
  `{links: ["mac-mini.tail1234.ts.net", "studio.tail1234.ts.net:8443"]}` in link order, and send
  each address as a host. Reading links contacts no other server. Linking and unlinking are
  idempotent, and linking checks once that the other server is reachable, so a 422 `{error}`
  means it refused and stored nothing, with the reason, as it does for an `http://` address. A
  server that answers 404 is too old to link. A link only works both ways, so the apps always
  link and unlink a pair of saved servers in both directions. They match a link to a saved
  server by the host of its `https://` address, or its Tailscale address below, and leave links
  to servers the app hasn't saved alone and unshown.
  - **The list.** A saved server is linked when it and another saved server each list the other.
    Its row shows `link` in secondary ink after its name, 11 pt on the Mac and 13 pt on the
    phone, and VoiceOver adds "linked". Nothing else in the row changes, and a server that's
    linked with only some of the others still shows it.
  - **The Linked switch.** Each server's details end with a Linked switch in its own card, under
    the details on the Mac and under Server URL on the phone. Its footer names the saved servers
    it's linked with, then reads "Linked servers' leads can see each other's channel names and
    purposes, and ask each other for work." Linked servers are one group in which every pair is
    linked, so every server showing the symbol can reach every other. Turning the switch on links
    the server with every linked server, or, when none is linked yet, links every saved server
    with every other. Turning it off unlinks it from every other saved server. The card shows only
    when the app has two or more saved servers and at least one of them can link, so linking stays
    out of sight until a server supports it. A server too old to link shows the switch off and
    disabled, with a footer like "Update Mac mini to link it.", and other footers and links leave
    it out. When a server is the only saved one that can link, its switch is off and disabled with
    "Update your other servers to link it."
  - **Add Server.** When a saved server can link, the sheet, and the phone's Add Server page, show
    the same switch under the address, on by default, with a footer naming the servers it would
    link with. It links once the server is added, and Settings then selects the new server. A new
    server too old to link is added unlinked, and its details say so through the disabled switch.
  - **Failures.** Each change links once, with no retry and nothing in the background, so it can
    never fight an unlink made elsewhere. Each server that didn't link adds one row under the
    switch: a yellow `exclamationmark.triangle.fill`, "Couldn't link with Mac mini.", "Couldn't
    link Mac mini with Build Box." for a pair that doesn't include this server, or "Couldn't
    unlink from Mac mini.", with the reason on a second line in secondary ink, and Try Again,
    which repeats only that pair. The reason is the server's own words, or "Mac mini needs an
    update.", which gets no Try Again, or "Studio needs its Tailscale address."
    Results stay until Settings closes. These are management writes, so after a timeout or a lost
    connection the row reads both servers' links again before offering Try Again.
  - **A server without an HTTPS address.** A server saved at an `http://` address, like one on
    this Mac at `127.0.0.1:3100`, links by its Tailscale address. The Linked card shows a field
    under the switch for each saved server that linking would need one for, including other
    servers, so turning a switch on never fails for a missing one. It reads "Tailscale address",
    or "Tailscale address for Studio" for another server and in Add Server, with the placeholder
    `machine.tail1234.ts.net` and the caption "Other servers reach Studio at this address, through
    `tailscale serve`." It takes a host or an `https://` URL, and an `http://` one replaces the
    caption with "Other servers reach Studio only over HTTPS, so use its host or an https://
    address." and disables Add. Settings saves it on Return or when the field loses focus, with
    that server, and the app uses it to link and to recognize that server's links. While the
    server is linked, its address shows as a plain value, since changing it would strand the
    others' links, and turning Linked off makes it editable again. A server saved at an
    `https://` address, as the phone saves them, never asks.
  - **Removing a server doesn't unlink it,** because other devices and the web rely on the link.
    The apps store nothing else about links and read every saved server's links while Settings
    shows the list, and after each change.

### Sending

Every message the user sends goes through one `ChannelOutbox` (ChannelClient), from a composer,
a card, a choice, a notification, Siri, Quick Send or the share sheet. Each app makes one at
launch, and the catalog store for the current server delivers that server's messages, whether or
not their channel is open. So every entry point just calls `send` and moves on. None waits on the
network, retries or reports a delivery failure itself. Management writes aren't messages, so they
keep `reconcileManagementWrite`.

- **Saved before it returns.** `send` shows the message in its channel at once as Sending, saves
  it as its own file and returns. It never throws, and if saving fails the message still sends
  from memory. The Mac keeps the files in Application Support and the phone in its app group, so
  the share extension writes to the app's outbox. Messages still Sending resume at the next
  launch.
- **Offline still disables Send.** A surface that knows it's offline keeps Send disabled, as
  [Connections](#connections) describes. Only the Lock Screen, Siri and the share sheet send
  without checking, since they can't know first.
- **In order, under one ID.** Each message records its server and channel, so a reply to another
  server's notification waits for that server. A channel's messages go one at a time, oldest
  first, and every attempt reuses the UUID `send` gave it, so the server never posts one twice.
  Channels deliver independently.
- **The server's answer confirms it.** A 2xx or the message arriving in a snapshot or replay
  takes it out of the outbox. An ID the channel already has answers with the message it stored, so
  a retry after a lost answer confirms like the first. An ID from another channel is a 409, refused
  like any other 4xx. An open channel merges the message the POST returns, and the outbox then
  marks the channel read through the message, since the user's own message never leaves a
  channel unread. Every list treats it as read from the moment the server has it, without waiting
  for that round trip, so a row never flashes unread for the user's own message. The first of
  these to bring the message back also files each image its row already loaded under the link the
  server gave it, pairing them in the order sent, so the server's row draws at once without a
  download. Filing it again changes nothing.
- **When delivery fails:**

  | What happened | For example | The outbox |
  | --- | --- | --- |
  | Toy Box can't reach the server | Offline, can't find or connect to the host, a lost connection, or a timeout or 502, 503, 504 or 530 while the catalog isn't connected, as when a phone's signal is weak or the Mac behind Tailscale Serve or Cloudflare Tunnel sleeps | Waits for the catalog to recover, the network to return or the app to come back, with the reconnect backoff as a fallback, then sends again. It never gives up, even across launches |
  | The server has trouble | 408, 429, any other 5xx, or a timeout or gateway error while the catalog is connected | Retries with the reconnect backoff, from half a second up to every 15 seconds, for 2 minutes, then stops. Becoming unreachable meanwhile waits as above and starts the 2 minutes over |
  | The server says no | Any other 4xx | Stops at once. A deleted channel's messages leave with it |

- **Not sent is the one failed state.** A message the outbox stops trying shows Not sent on its
  row in the transcript, with Retry and Delete, and nowhere else. Retry puts it back in line under
  the same ID, and Delete withdraws it. It steps out of line so the channel's later messages
  continue, and it stays Not sent across launches.
- **The waiting rule.** The catalog's `waitingRequests` decides what's waiting for the transcript's
  choices, Needs You, the menu bar, the Dock, widgets and notifications. Each message records the
  request its caller answered, or the one waiting in its channel when it was sent, so a newer
  request is never hidden. While the answer is Sending its request counts as answered, and once
  it's confirmed the request stays answered until the catalog stops listing it. A Not sent answer
  stops counting, so the request comes back. In the channel the choices stay hidden while any
  answer to the request is in the outbox, since its row sits just below.
- **The phone finishes sends in the background.** While `isDelivering` is true, the app delegate
  holds background time, so a Lock Screen reply finishes after its action returns. Whatever is
  still Sending when that time ends resumes when the app next launches or comes back. The share
  extension's outbox is made with `sendsOnce`, since the extension ends before it could retry. It
  leaves the folder's other messages to the app, and its `send` makes one attempt and marks the
  channel read before it returns. The attempt gives up after 10 seconds without hearing from the
  server, so a sleeping server never holds the sheet for long. Whatever that attempt leaves Sending,
  the app sends. ChannelClient
  makes no `UIApplication` call.

## Protocol

Responses carry no version envelope, and a write that returns one resource returns it bare. A
change to these shapes ships with both apps' builds alongside the Toy Box release that makes it.
The apps decode only the current shapes, with no fallback for an older server.

| Request | Use |
| --- | --- |
| `GET /api/v1/channels` | Catalog `{channels, members, lead, working}` for the sidebar. `lead` is the profile every channel's lead shares, under the channel's ID, and is always present. `working` lists running agent IDs. Its channels carry no `tasks`, which only a channel's snapshot carries, and each carries `request`, its waiting message without reactions, or `null`, whose sequence is always `requestSequence`. With `Accept: text/event-stream` it streams: `snapshot` with the catalog, then `working`, `channel.upserted`, `channel.deleted`, `channel.member.upserted` and `channel.member.deleted`, with a keepalive every 5 seconds. There's no cursor, so every reconnect starts with a fresh `snapshot` |
| `GET /api/v1/channels/:id` (SSE) | `snapshot`, then live events. With `after`: replay, then `resumed`. The store holds the replay and publishes it with `resumed` as one change, so a reopened channel never redraws what it missed event by event. A drop mid-replay publishes nothing, and the retry asks again after the published revision. Presence isn't read from this stream, which is dropping it: the client ignores `presence` events and any `resumed` payload, and decodes a snapshot without `presence`. `deleted` is terminal |
| `GET /api/v1/channels/:id/messages?before=N` | Older page of up to 100 messages `{revision, messages}` |
| `POST /api/v1/channels/:id/messages` | `{id, content, attachments?}` with a client UUID. 201 returns the message, and the stored one for an ID the channel already has. An ID from another channel is 409 |
| `POST /api/v1/channels/:id/read` | `{sequence}` monotonic read, which acknowledges completion but never a request. Returns `{seenThrough}` |
| `PUT /api/v1/channels/:id/bookmarks/:sequence` | Bookmark a user or agent message (204). A message that's already bookmarked is also 204, and a system or missing message is 422 |
| `DELETE /api/v1/channels/:id/bookmarks/:sequence` | Remove a bookmark (204), including one that isn't there |

A channel's `avatar` comes on its catalog entry and its snapshot. It's either a mark,
`{mark, color}` shaped like a member's, or `{image}`, a server-relative URL resolved like an
attachment. Only the channel's lead sets it, and native never does. Missing means it was never set,
and it can't be cleared. A change arrives as the `channel_avatar_changed` system message
`{type, actor, avatar}`, which the reducer applies as it applies a rename, so it shows in the
transcript, moves `updatedAt` and counts as unread like any identity change. The server names a
stored image by its content, so a URL always shows the same picture, and the apps fetch and decode
each one once per launch. A failed connection tries again on the next frame that asks, and a
refusal or an image the platform can't decode shows the `#` until the URL changes.

Bookmarks belong to the user, and every client of the server shares them. A snapshot carries
`bookmarks`, the bookmarked sequences in ascending order, and the `bookmarks` event replaces the
whole list. A resume keeps the last list. `ChannelStore.setBookmarked` shows the change at once
and makes one attempt. The stream's echo confirms it, and a failure undoes it and sets
`bookmarkFailure`, which says whether it was a removal. Changing it again is the retry, which is
safe because both routes are idempotent. Writes go out in order, so a quick second toggle can't
overtake the first.
`ChannelStore.bookmarkList` is the list both apps show, newest first, and the tray counts it
toward its visibility. Each `ChannelBookmark` carries its message once that page of history
loads, and until then the row draws a placeholder. `preview(agents:)` is its first line of plain
text, or the attachment count, without an agent's leading mentions, since the transcript shows
those as routing. Opening the list calls `loadHistory(through:)` with its last entry, the oldest.

Screens are owned by Toy Box's Screens feature (`src/features/screens/AGENTS.md`):

| Request | Use |
| --- | --- |
| `GET /api/v1/screens` | `{displays, windows}`, each `{id, title, application?}`. The host's live state, fetched only when the list opens |
| `GET /api/v1/screens/:id/thumbnail` | One JPEG thumbnail, never cached |
| `/socket?service=screens&screen=:id&width=:px&height=:px` (WebSocket) | One live screen, sized to the viewer's pixels. Text `state` messages carry `{title?, status: live/paused/ended, reason?, hasControl}`, and `{type: "error", message}` reports a refused command. Any other type is ignored. Binary packets are two big-endian `UInt32` lengths, the frame `{sequence, width, height, radius?, region?}` as JSON, then its JPEG. A region draws over the latest full frame, never over another region, and its empty JPEG restores the full frame. The viewer sends `{type: "ack", sequence}` once a frame is drawn and `{type: "resize", size: {width, height}}` once a new size settles. In control, it sends `{type: "take-control"}`, `{type: "release-control"}` and `{type: "input", actions}` with 1 to 64 actions: `pointer {x, y, phase: move/down/up, button?: 0/1/2}`, `scroll {x, y, dx, dy}` in pixels, `key {code, down}` by DOM `KeyboardEvent.code`, and `text {text}`. Positions are fractions of the frame. One viewer controls at a time, so taking control takes it from anyone else, and a disconnect releases it and any held input. Messages may reach 16 MiB. The socket keeps the server URL's host, port and path prefix, over `wss` for `https` and `ws` for `http` |

The model catalog is owned by Toy Box's Providers feature (`src/features/providers/AGENTS.md`),
not Channels:

| Request | Use |
| --- | --- |
| `GET /api/v1/models` | `{models, defaultModel}` for model pickers. A 404 here means "models unavailable", never a reason to invent a model |

Management routes (documented in Toy Box's Channels `AGENTS.md`):

| Request | Use |
| --- | --- |
| `POST /api/v1/channels` | Create `{name, purpose?, directory?, model}`. 201 returns the Channel |
| `PATCH /api/v1/channels/:id` | Edit `{name?, purpose? (null clears), model?}`. Returns the Channel |
| `DELETE /api/v1/channels/:id` | Delete the channel (204). The stream then sends `deleted` |
| `POST /api/v1/channels/:id/members` | Create a member `{name, role?, model?}`. 201 returns the member |
| `PATCH /api/v1/channels/:id/members/:agentId` | Edit `{name?, role?, model?}`. Returns the member. `model: null` clears the explicit override and is always allowed, even when the workspace default uses another provider. It never changes an established session's provider or history: a compatible default is followed, otherwise the existing provider's model is retained. After clearing, the returned member and its event omit `model`. Only an explicit model from another provider returns 422 |
| `GET /api/v1/channels/:id/members/:agentId/models` | `{provider, models, defaultModel}` for the Edit Agent picker: models limited to the member's provider (session, else configured, else unrestricted when null). `defaultModel: null` means no compatible workspace default exists. It describes a model choice, not permission, so clearing the override stays available even when `models` is empty |
| `DELETE /api/v1/channels/:id/members/:agentId` | Remove a member (204) |
| `POST /api/v1/channels/:id/routines/:routineId/run` | Run a routine now (204) |
| `DELETE /api/v1/channels/:id/routines/:routineId` | Delete a routine (204) |

Errors return `{error}`. A malformed body is 400, a missing channel, member or routine is 404,
and a domain rejection such as a taken mention is 422 with a user-facing message. An unexpected
management failure is 500 with a generic `{error}`, and details stay in server logs. A 500 can
follow a committed change, including a deletion, so the client never retries a write on 500,
automatically or through an unchanged resubmission. It treats the outcome as uncertain and
reconciles from the authoritative catalog or channel detail before offering another write.
The apps show a server's own `{error}` words as they are, without a status code. Only a failure
without them reads the generic status text with its code, like "bad gateway (HTTP 502)".
A timeout or lost connection is also uncertain, since the request may already have reached the
server. The same reconciliation is required. Can't-connect, offline and bad-host failures remain
ordinary retryable errors rather than blocking management editing.

Attachments are `{name, url}` or inline `{mimeType, base64}`. Avatars are SVG path data in a
24×24 viewBox plus a hex color, and may carry an optional `ink` for the mark that only Toy Box's
own profiles set. The server serves the lead's profile in snapshots and the catalog, and the app
keeps no copy of it.

### Push and topic subscriptions

The phone icon badge counts channels with an open request, using the same
`channel.attention == .waiting` predicate as the widget. Each successful app catalog refresh
reconciles the badge, including the stream's keepalives every 15 seconds and zero waiting channels. Cached-only state,
failed refreshes and unrelated navigation changes do not overwrite it. Badge updates do not wait
for notification authorization reads or request-history loading. The in-app Allow notifications
choice gates the badge independently of authorization: turning it off immediately clears the
badge, and catalog refreshes keep it at zero while off.

The shared client, the 3210 demo and the shipping server use these routes. Writes make one attempt
and return no response body. Registration PUT returns 201 when created and 204 when updated.
Subscription writes and deletes return 204.

| Request | Body or effect |
| --- | --- |
| `PUT /api/v1/push/:registrationID` | `{token, environment}` |
| `DELETE /api/v1/push/:registrationID` | Remove the registration and its subscriptions. Idempotent even when unknown |
| `PUT /api/v1/push/:registrationID/topics/:topic` | `{}` uses the registration address. `{token, startedAt}` supplies an Activity token in the registration's environment |
| `DELETE /api/v1/push/:registrationID/topics/:topic` | Unsubscribe from the topic |

`registrationID` is a caller-owned UUID carried only by the path. Tokens are hexadecimal, and
`environment` is `sandbox` or `production`. The signed host's `ToyBoxPushEnvironment` is derived
from its validated APNs entitlement, never from `DEBUG`: optimized development builds still use
sandbox. Request and completion preferences independently subscribe `requests` and `completions`.
A token belongs to one registration. Subscription requires an acknowledged registration and returns
404 for an unknown install. Topic subscriptions inherit its environment and either use its device
token or supply an Activity token, and are unique per registration/topic. A topic is opaque to Push; Channels uses `channel:<id>` and the
iPhone presents that subscription as a Live Activity.
Subscription does not require the source to exist. An absent channel receives the channel-deleted
ending on the next delivery pass. The phone resends the original `startedAt`, in Unix seconds,
on every Activity token rotation. Server scheduling and delivery live in Toy Box's Push guide.
After every successful registration with known alert choices, the phone PUTs or DELETEs both
notification topics, so failed preference writes recover on the next launch without a saved receipt.
The next app activation also retries a failed registration or topic write. Successful applies
are not repeated on activation, and failures never start a background retry loop.
Until the actual authorization state is loaded, registration and Follow can become ready but
topic writes wait, preserving the server's existing choices. A stalled read therefore delays
preference changes without clearing the previous subscriptions.
A 201 also restores active Follows. New Follow remains unavailable until the channel's server
acknowledges its registration. Restored Activities survive that wait and replay deferred tokens after either 201 or
204, independently of alert preferences.
Allow notifications off unsubscribes only the two notification topics, retaining Follow and the address.
The demo stores all state in memory and never contacts APNs.
The demo exposes canonical read-only history pages for the app, and its catalog lists
each channel's request as the server's does. It keeps a sent message's images as served files,
named and returned in the order sent as the server does.

`ChannelPushPayload` carries `kind`, `channelID`, positive `sequence`, `registrationID` and an
optional requester's `handle` beside the system `aps` envelope. Its kinds and categories are
`request` and `completion`; request uses the `reply` text action. The service must match one of the
phone's saved registrations before allowing actions or requesting a widget reload.
The fixtures are `Tests/Shared/ChannelKitTests/Fixtures/push-request.apns`, `push-completion.apns` and
`push-activity.apns`.

The server supplies the channel name as the alert title and the flattened question as its body,
using the Mac's `NotificationText` policy: remove known leading mentions, preserve attachment-only
fallbacks and truncate at 400 extended graphemes on a word boundary. Completion uses the Mac's
task-count text. The actual encoded JSON must also fit APNs' 4,096-byte limit without splitting
a grapheme. Requests retain the requester's `handle` for Lock Screen Reply. Both alerts group
by a registration-qualified channel `thread-id`, with no requester subtitle.
They use the Toy Box app icon, with no communication intent or donation.
This display-ready text passes through the stateless push relay and Apple without application-level
encryption. The relay streams the body without parsing or logging it, and its observability is
disabled. Channel names and request text travel this way by design.

`MobileNotificationHandler.process(_:)` checks the payload's saved registration and immediately returns
the received content, preserving its title, body, sound, thread, Reply handle, badge and routing.
It makes no catalog, history or other network request and has no enrichment deadline or cache.
Valid request and completion alerts request a WidgetKit reload before delivery.
A missing or mismatched registration, malformed payload or registration-read failure clears the
category and omits the badge, preventing Reply and a stale alert's badge change without discarding
the received text. Omitting the badge preserves the current icon count, rather than clearing it.
Each callback is called once.
The channel name and question therefore remain available when the phone cannot reach the server.
Neither the app nor the notification extension requires the Communication Notifications
capability.

The icon badge counts channels whose `channelStatus` is `waiting`, exactly like the widget.
Reading does not close an open request. Unread messages and completed channels do not count.
The server sends the current `aps.badge` only in badge-only pushes after catalog changes, including
a zero when the last request closes or its channel is deleted. Alerts carry no count and do not
acknowledge badge delivery, so an alert delayed by its service extension cannot overwrite a newer
count. Badge-only pushes contain no alert, sound or `content-available`, so iOS applies them without
launching the app. In the foreground, the notification delegate permits `.badge` for these pushes,
without a banner, list entry or sound, and suppresses them when notifications are disabled.
One install receives one badge update even when both alert topics are subscribed.
With several servers, the app writes the waiting count summed across every server whenever a
catalog refreshes. A server's badge-only push carries only its own count, so the icon shows that
count until the app next refreshes and sums them all again.
Only request or completion subscriptions qualify, never a Live Activity alone. When Allow
notifications is off, the app clears the badge and suppresses future catalog badge writes,
and unsubscribes both alert topics to prevent server pushes from restoring it.
Fresh successful app catalog refreshes reconcile the same count. Offline or cached-only state
does not manufacture a fresh count. Subscription reloads and the server's five-minute
tick catch up failed badge delivery.

`ChannelActivityAttributes` has `channelID`, `channelName`, `registrationID` and the original
`startedAt`, persisted by ActivityKit rather than a separate app dictionary. Attributes are not
part of the APNs payload. Its `ContentState`
has working agent identities, top-level tasks done/total, optional waiting request sequence,
`updatedAt` and optional ending. Its custom Codable implementation uses Unix seconds for
`updatedAt` with an ordinary JSONDecoder, as ActivityKit requires. Active state is stale after
15 minutes. Confirmed server endings have no stale date and use `completed`, `channelDeleted` or
`tasksRemoved`. Local Stop and server changes dismiss the current content immediately without
inventing an ending state.

ActivityKit receives the APNs `aps` envelope, including `update`/`end`,
`timestamp`, `content-state`, `stale-date` and optional `dismissal-date`, with Unix seconds
throughout. The Activity fixtures cover working, quiet, request, completed, other ending and
stale states. `push-activity.apns` is the request state; its five named sibling fixtures cover
the others. Every payload fits APNs' 4 KB limit. Contract tests decode the fixture content with the
native codec.

`ChannelActivityLink` carries channel ID, registration ID and an optional positive request sequence
in `toybox-desktop://activity` URLs. The receiving app checks the selected registration before
opening anything. Stale Activity taps omit the sequence and open only the channel.

The phone stores one registration per server in `group.dev.toybox.mobile`. Adding a server
generates a new UUID, including when adding back an earlier one, and removing one deletes its
registration. Equivalent URL spelling preserves the UUID. `MobileWidgetSnapshotPublisher.update(catalogs:)` writes
the Mac's `NeedsYouSnapshot` schema and filename from each catalog's `waitingRequests`, one part
per server, without SSE or channel stores, and reloads `ToyBoxNeedsYou`. It keeps each server's
last part as its offline cache, drops a removed server's part, and shares the Mac's 30-minute freshness and `NeedsYouSnapshot.replacing`.
Offline-only writes keep the cached observation time, never heartbeat, and write and reload only
when visible content changes. Live writes rewrite an unchanged snapshot every 15 minutes.

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

### Visual system

Use SF Pro through system fonts and semantic weights. No custom typeface, hard-coded all-caps
section headings, gradients on messages, dashboard cards around every section, or decorative
drop shadows. Use an 8-point spacing rhythm, with 4-point adjustments inside compact controls.

| Token | Native treatment |
| --- | --- |
| Conversation background | `textBackgroundColor`, opaque in both appearances |
| Agent message surface | Neutral tonal fill over the conversation, approximately 4.5% primary ink in light and 7% in dark. A pending request swaps it for a warm orange wash. Borders only under Increase Contrast |
| Your message surface | Accent at 9% over the conversation, with normal label text. On the phone's pure black Dark canvas, the wash sits over the agent bubble's 7% neutral lift so the bubble stands off black as clearly. Under Increase Contrast, the same 1-point `primary` edge at 50% as agent bubbles. A message that didn't send swaps the accent for a red wash at the request wash's strength, over the neutral fill in dark, with a red edge under Increase Contrast |
| Navigation and inspector | System sidebar and inspector materials, no manual blur stacking |
| Floating controls and popovers | Native toolbar, popover and control materials |
| Text | `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor` by hierarchy |
| Selection and focus | System accent, source-list selection and focus ring. Respect user accent |
| Hover (Mac) | One hover fill for every custom control and row that responds to the pointer: primary at 12% in Dark and 8% in Light, 5% more while pressed, in the control's own shape, fading over 120 ms. On an accent selection it's white at 20%. A borderless button's secondary ink turns primary while lit, and a colored symbol keeps its color. The fade holds under Reduce Motion, since it moves nothing. Disabled controls stay unlit. It's defined once and every hover uses it. Native toolbar, menu and list controls keep the system's own |
| Toy Box identity | The lead's avatar exactly as the server supplies it, a navy `#1E3A8A` circle with a gold `#FACC15` outline star, drawn as that color's `.gradient` like every avatar. A channel without an avatar of its own falls back to Toy Box's channel cyan `#0891b2`, which the lead doesn't use. Recolor neither to the accent |
| Unread | Semantic system blue, 1-point New rule. Blue does not mean working |
| Requests | Orange wash on the pending bubble, orange `questionmark.bubble.fill`, primary label text and a Reply button. Never an outline |
| Completion and additions | The shared completion green (`#196C2E` light, `#70D58A` dark) plus a knocked-out checkmark or explicit `+` sign. Never a white glyph on system green |
| Error, blocked and removals | Semantic system red plus symbol, label or explicit `-` sign |

Let the system render its Liquid Glass toolbar, sidebar and navigation controls, as described
under Composition. Do not give the detail column a separate rectangular
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
| Day divider and system rows | 11, semibold / 11, regular | Secondary. Day labels lead their rule, system rows are centered, values in primary medium |
| Inspector section heading | 13, semibold | Count follows 6 points later in 13 regular readable secondary. No capsule, no forced uppercase |
| Inspector body | 13, regular | Approximately 18 line height |
| Inspector status and detail lines | 11, regular | Secondary, tabular digits for counts and countdowns |
| Inline code and diff counts | System monospaced, 12 / 11 | Code blocks scroll horizontally |

Honor the system accessibility text size where available and a native View > Text Size control
(Smaller, Default, Larger). Scale content text, row height and wrapping together. Keep toolbar and
standard controls at native sizes. At the largest size, no critical text truncates without an
accessible full value or an expansion action.

### Composition

The governing composition is one native channel title, one quiet inspector, legible tonal messages,
and one floating glass composer carrying the activity line.

The app requires macOS 27 on Apple Silicon, links against the installed SDK, and `bun run validate`
fails when the bundle's SDK stamp is below 27. There is no fallback appearance and no availability
branching in views.

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

On the phone, the transcript, activity controls and composer also span the full available lane,
with no overall cap in a wide scene. The transcript's side insets are 16 points folded and 20
unfolded, and the composer's are 12 and 16. The Mac's 720-point example above is a sample
conversation width, not a lane cap. Document readers have their own 720-point text lane, as
Artifact viewer describes.
Phone message surfaces share the Mac's text-scaled caps: agents up to 760, and yours up to 640
and at most 80% of the available lane unfolded or 88% folded. A phone agent message's identity
gutter is 40 points, a 32-point avatar and an 8-point gap.
Folded with the software keyboard down, the composer's bottom edge meets the bottom safe area,
with no gap, toolbar-frame geometry seam or measured offset. Above a visible keyboard the
composer keeps 8 points of clearance, with native keyboard avoidance and every control target.
Unfolded, the composer sits 8 points above the bottom safe area. Find's bar follows the same
rule. The channel screen owns the only keyboard observer, and the composer, Find and the
notification tip all read it. A bar that arrives over a keyboard that's already up, or returns
after the keyboard went down behind Find, starts from the current state.

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
activation. Keep the last working presence while the channel connects or reconnects, and hide it
only once the channel is stale or deleted. Place Jump to Latest at the
trailing edge of the same floating row when needed. Neither control may become a synthetic
message or read target.

The context tray belongs inside the composer as a 34-point header, separated from text entry by
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

**Layers.** Content is one opaque layer made of the sidebar list, the conversation and the
inspector. Liquid Glass is reserved for the navigation layer above it: toolbar controls, the
sidebar material, the composer, the activity row, Jump to Latest and transient notices. Never
put glass on messages, inspector sections or list rows, and never place glass on glass. Controls
inside a glass surface are plain or borderless, except Send. Let the system draw every standard
glass element. Custom `glassEffect` appears only on the surfaces this section names.

**Toolbar.** Use the system's default window toolbar style, with no explicit
`.windowToolbarStyle(.unified)`, and set no `toolbarBackground`, `toolbarBackgroundVisibility`
or column title plate anywhere. Never draw our own rule or band under the toolbar. The
conversation and Overview scroll beneath the toolbar under the system's soft top scroll edge,
`.scrollEdgeEffectStyle(.soft, for: .vertical)` on the conversation and the automatic edge on
Overview, so the toolbar's glass controls float over the content with no band or divider.

The detail toolbar leads with the channel title, a glass button in the navigation slot, then a
flexible space and Message View. Overview runs the full window height beside the split view, in
an `.inspector` outside `NavigationSplitView`, with only its toggle (`sidebar.trailing`) over its
top. A closed Overview's toggle sits after Message View. The only custom toolbar tint is the
active Message View filter symbol.

**Sidebar.** The `NavigationSplitView` sidebar runs the full window height with the traffic
lights over its top, and the system decides its shape. It runs flush to the window's leading,
top and bottom edges with no margin, as Finder and Mail do. Do not set a sidebar or list
background, and never imitate the shape by hand. Inactive windows render the sidebar and inspector materials as flat fills,
which is expected. Search is `.searchable(text:placement: .sidebar, prompt: "Search Channels")`, and
Edit > Find Channel (Command-Option-F) drives it through `.searchFocused`.

**Inspector.** The Overview inspector runs the full window height, with toolbar items floating
over its top and its content scrolling under them. Attach `.inspector` where it produces that
full-height column, not a column that starts below the toolbar. It has no title row, close
button or divider. The Overview toolbar button, Option-Command-0 and View > Hide
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
| Tray | 34-point header at the top: a 28-point row of controls with 3 points above and below, then a 1-point `separatorColor` hairline inset 12 on both sides |
| Controls | 28-point row, 8-point horizontal and bottom padding, 8 points between controls |
| Send | The one filled control, a 28-point accent circle with a white `arrow.up`. Disabled uses a `quaternary` fill and a secondary symbol |
| Dictate | Borderless `mic` 8 points before Send, styled like Attach Image. Listening tints a 28-point circle with accent at 15% under an accent `waveform`, never a second solid fill. States are under Composer and tray |
| Height | About 80 points without the tray and about 115 with it, growing with text and thumbnails |

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
| Label | "Ada is working" or "3 agents are working", 12-point medium in the primary label color. Activation opens the Working Now popover anchored to the capsule. It lists the working agents, then a plain rule and the waiting agents in roster order, in the same rows with the shared status text, such as "Waiting for Moss's review". Idle agents stay out, and waiting agents alone never show the capsule |
| Jump to Latest | Trailing. The same capsule and glass, with `arrow.down` and "Jump to Latest" in 12-point medium and 12-point horizontal padding |
| Notices | Reveal, send-action and read-position errors stack 8 points above the row in a glass rounded rectangle, radius 14, with primary caption text, 12 horizontal and 8 vertical padding, and borderless Retry or Dismiss |
| Motion | Appears and leaves with opacity and a 4-point rise over 0.2 seconds, ease-out. Reduce Motion uses opacity only |

When the row appears or leaves, a reader at the end stays at the end, and a reader elsewhere
keeps their anchor. Do not wrap the composer and the row in a shared `GlassEffectContainer` with
spacing of 8 or more, because that fuses them into one shape.

**Reconnecting notice.** While the channel's stream is down, a glass capsule floats over the top of
the transcript like the phone's pill, centered on the rail 8 points below the toolbar. It is an
overlay, not a `safeAreaBar`, so it changes no inset and no row moves when it appears or leaves.
It holds a small spinner beside "Reconnecting to server" in subheadline semibold over "Messages may
be out of date" in secondary caption, with 14-point horizontal and 7-point vertical padding. There
is no Retry, since the channel is already reconnecting. While Find is open the capsule sits 8 points
below Find's 40-point bar instead. The full error stays in its help text and VoiceOver hint, and
VoiceOver reads both lines as one element. It fades in and out over 0.2 seconds with a 4-point drop,
opacity only with Reduce Motion. It fits at the narrowest conversation, about 440 points beside the
open inspector in a 1000-point window.

**Real-window acceptance.** App snapshots capture the composited window and its sheets with
ScreenCaptureKit, so they show glass and content beneath a `safeAreaBar` as drawn. Without Screen
Recording they warn and fall back to `cacheDisplay`, which leaves both blank, and those captures
cannot judge this section. Judge this section only in a real window on the stamped build,
captured with ScreenCaptureKit or Computer Use, in Dark, active and inactive, with the
inspector open and closed, and scrolled to the top and mid-history. Add Light, Reduce
Transparency and Increase Contrast when a change touches colors or materials. Confirm that the
sidebar runs flush and full height, that the
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

The sidebar toolbar holds the sidebar toggle at its leading end and New Channel (`plus`) at its
trailing end. A collapsed sidebar leaves room for only the toggle after the traffic lights, so
New Channel steps out while the sidebar is collapsed or sliding open, and the title menu still
offers it.
The detail toolbar shows only the channel's avatar and name, without a purpose subtitle. The name
is a title menu, the pattern Pages, Keynote and Numbers use for a document title, so channels stay
one click away with the sidebar collapsed. `toolbarTitleMenu` only draws for document-based
windows, so the title is a native toolbar `Menu` in the navigation slot, a glass button with the
name in 15 semibold, dimmed in inactive windows, and no chevron. The capsule leads with the
channel's 24-point `ChannelMark`, inset 6 points from its top, bottom and leading edges and 8
points before the name, with the 12-point trailing inset unchanged. Like a document's proxy icon,
the avatar dims with the name in inactive windows, and it's decorative, so VoiceOver reads only
the name. The window shows no system title beside it. Keep `.navigationTitle` for Mission Control and the
Window menu. It lists every channel in sidebar order with the current one checked, then New
Channel…, then Edit Channel… and Open in Toy Box, then Delete Channel…, each group after a
divider. There's no separate Channel Actions button. Choosing a channel behaves like selecting it
in the sidebar. Items mirror the sidebar's attention state with the system menu-item badge (Input
Needed, Unread or Done). If the title menu can't carry badges, omit them rather than appending
text to channel names.
Trailing controls are Message View (`line.3.horizontal.decrease`) and Overview
(`sidebar.trailing`). Put Open in Toy Box in the title menu and the menu bar, not another
permanent toolbar button. A long name truncates at the tail, so every control fits down to the
760-point minimum window. NSToolbar never compresses a SwiftUI item, so the title takes its width,
avatar included, from the detail column and stops short of an open Overview and the trailing controls. While it's
truncated, its help shows the full name instead of Switch Channel, like an expansion tooltip, and
the menu still names the channel in full. Should the toolbar run out of room anyway, Message View
overflows first, and the title and Overview stay. Keep
working status in the floating activity row, not duplicated beside the window title.

Opening a channel selects it in the current window. Command-click or Open in New Window creates a
separate window for that channel and leaves the current window's channel and selection unchanged. Windows share the same channel store and draft. Only a key,
visible conversation actively acknowledges reading. Restoring a window must not send a message or
silently mark its unseen content as read.

**Phone folds.** Folding, unfolding and rotating the Duo keep whether the list and Overview are
open, so the user carries on where they were. A channel open folded unfolds without the list,
which the sidebar toggle brings back, and the list folded unfolds with the list showing. Rotating
keeps the list as it was. Folding with a channel open shows the channel. Overview keeps its own
presence the same way, as Overview describes.

**Phone channel search.** Use the native bottom-bar search item in the channel-list column,
folded and unfolded. Search leads the bar, and a flexible space puts Settings (`gearshape`, the
Mac's gear) at its trailing end. While the split view is collapsed, as
on a folded Duo, `.searchToolbarBehavior(.minimize)` shows it as a Search button that expands into
the bottom field, because a full field makes UIKit cancel the first pull to refresh after Back.
The unfolded overlay sidebar keeps the full field, since UIKit places the minimized button
past the sidebar's trailing edge. Its prompt is "Search", which fits the unfolded sidebar without
truncating. Search raises the keyboard with its field above it, and Cancel
restores the bar. No hand-built safe-area text field or duplicate gear in the rail. Keep the large
Toy Box title at the top, with New Channel and then Screens (an outline `display`) in separate
glass groups, and no More menu or Refresh item. A native placement limitation in the unfolded column
never justifies substituting custom controls.
With one server, the phone list has no connection dot, server label or busy
footer spinner, and with several each server's header names it (see
[Several servers](#several-servers)).
Settings owns server identity and connection details. The list has pull to refresh, and search
uses the shared name/purpose/directory filtering. Pull to refresh holds its spinner until the
finger lifts, so a fast fetch never ends it mid-pull. Command-F focuses channel search when the
list is active, without replacing in-conversation Find. The list never shows a connection error, a
pill or a Retry, because pull to refresh already retries. A failing server shows only its orange or
red dot, with the same colors as the Mac's (see Sidebar), and only in its header when there are
several servers. A connected or connecting server's header shows no dot. With one server the list
shows no dot at all, and its status lives in Settings' server list, as on the Mac. Tapping a header's dot, through a 44-point
hit area, opens a popover with the status line, like "Reconnecting to 127.0.0.1:3211", over the
readable failure in secondary, then a Server Settings button, which opens Settings because a wrong
address is the one failure a retry can't fix. The rest of a header still collapses and expands.
VoiceOver reads the dot as a button whose label is the status line and whose hint is the failure.
With Differentiate Without Color, the dot becomes the Mac's `exclamationmark.circle.fill`. Cached
rows alone do not prove a live connection.

**Phone channel toolbar.** The bar holds only the channel's title, Overview and Message View. Like
the Mac's, the title is a floating glass button: the channel's avatar and name in a `.topBarLeading`
toolbar `Menu` with its indicator hidden, so it sits where the system title did, wears the bar's
shared glass and shows no chevron. The avatar is the list row's 28-point `ChannelMark`, so the
channel you tapped stays with you. It sits 10 points in from the capsule's leading end, concentric
with its round end, and 8 points before the name, and centers on both lines when the name has a
second. It's decorative, so VoiceOver reads only the name. The whole capsule opens Channel Actions, with no ••• of the app's own,
because Find, Follow, Edit and Delete aren't used often enough to need a bar button.
`.navigationTitle` still names the screen for Back and VoiceOver, and `.toolbar(removing: .title)`
keeps the system from drawing it twice. The bar gives a leading item its whole ideal width and moves
it to its own ••• when that doesn't fit, so the name's width is capped by the screen's width less the
bar's margins, the capsule's insets, the avatar and its gap, and room for the bar's buttons, which the bar keeps even when
they stand in a vertical bar, and a long name truncates inside the capsule. The conversation's top
scroll edge is `.soft`, so rows blur under the title and bar buttons with no bar or hairline. A
compact top bar shows Overview. Regular width shows
Message View, then Overview. Tasks has no bar button because Overview already holds them. Where the
system stands bar items in a vertical bar (`toolbarVerticalEdge` non-nil, as on the folded Duo),
and in regular width, Message View stays its own filter item. A compact scene with no vertical bar
has no room for it: a `.bottomBar` item would sit under the composer. There the same All Messages /
Your Messages picker leads the title menu in a Message View section, and Your Messages adds a
second line, "Your Messages", under the channel name inside the capsule. All Messages shows no
second line. iOS 27.0 has no vertical-bar API, so it always takes the compact no-bar path. Open
readers keep their own system titles, without the button.

**Phone Welcome.** With no working server the phone shows Welcome, not a titled form. Its
first Form row, with a clear background and no horizontal insets, holds the large bold heading
"Welcome to Toy Box 👋" and one secondary sentence. The navigation bar is hidden. The shared Server
URL card follows: the address and Test Connection, each a native row of the same height, with
errors below them. Continue is a full-width `.glassProminent` button at `.controlSize(.extraLarge)`
in `.safeAreaBar(edge: .bottom)`, aligned to the card's measured edges and 8 points above the
bottom safe area, so it rides above the keyboard. The Form keeps its default soft bottom scroll
edge, so Continue floats like the composer, with no band or hairline. At accessibility sizes the
bar would cover the card, so Continue becomes the Form's last row after the card instead, with the
same edges and style. It's disabled until the current address tests successfully.

**Phone sheet semantics.** Working Now, Select Text, reactors, system-message details, Overview in both presentations,
and Settings use native `Button(role: .close)`. iOS supplies the X. Place it at
`.topBarTrailing` with an explicit accessible close label, never `.confirmationAction`, which iOS
draws as blue prominent glass. No custom circle or fill. Settings changes remain applied on closing.

New Channel, Edit Channel, Add Agent and Edit Agent have no text
Cancel. They close with the same system `Button(role: .close)` X at `.cancellationAction`, which
discards the draft exactly as Cancel would, labeled "Cancel". Create, Add and Save are
`Button(role: .confirm)` at `.confirmationAction`: iOS draws the blue glass checkmark, the same
prominent treatment as Send. Their accessibility labels stay "Create Channel", "Add Agent" and
"Save", and while a write is pending the checkmark gives way to the small delayed spinner, with
the label becoming "Creating…", "Adding…" or "Saving…". The confirm stays disabled until the
form can save. Never hand-place, restyle or regroup these items. The system places both, so
where it reports a trailing vertical bar, as on the folded Duo, they join that column the way
Settings' close does. Where it reports a leading vertical bar, keep the bar horizontal as
Overview does, so neither covers the form. The Mac uses text buttons. Swipe dismissal is
disabled while a write is pending. These sheets keep their own focus/draft restoration and read
blocking.

### Menu and keyboard model

Use native About, Settings (`Cmd-,`), Services, Hide, Quit, Edit, Window and Help menus. Standard
text-editing shortcuts retain their native meaning. Commands below disable when inapplicable.
Focus Composer does not discard selection or any existing draft.
Check for Updates… follows About in the app menu and uses Sparkle's standard window. It is
disabled whenever the updater's `canCheckForUpdates` is false, including in bundles without a feed.

| Menu | Command | Shortcut |
| --- | --- | --- |
| App | Quick Send | Configurable global shortcut, `Ctrl-Shift-Space` by default |
| File | New Channel | `Cmd-N` |
| File | Open Channel in New Window | `Cmd-Shift-N` |
| File | Open Screen… | `Cmd-O` |
| File | Open in Toy Box | `Cmd-Shift-O` |
| File | Open Folder in Finder (selected channel, only when its folder is openable) | `Cmd-Option-R` |
| Edit > Find | Find… / Find Next / Find Previous (open channel) | `Cmd-F` / `Cmd-G` / `Shift-Cmd-G` |
| Edit | Find Channel (reveals a hidden sidebar, then focuses its search) | `Cmd-Option-F` |
| View | Show/Hide Sidebar | `Ctrl-Cmd-S` |
| View | Show/Hide Overview | `Cmd-Option-0` |
| View | All Messages / Your Messages | `Cmd-1` / `Cmd-2` |
| View | Refresh (the channel list) | `Cmd-R` |
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
| First channel snapshot | Static message placeholders and "Connecting", whose spinner appears after 300 ms. On the Mac the label waits with it. Composer shell remains present, Send unavailable |
| New empty channel | "Your lead is getting started", "Send a message or type @ to add an agent". Keep composer and working status visible |
| Filter has no messages | "No messages for you yet", Show All Messages. Keep paging older history until exhausted |
| Reconnecting with cached state | Keep transcript and scroll intact. After about three seconds of trying without connecting, the transcript's floating pill says "Reconnecting to server" over "Messages may be out of date" (see Reconnecting notice), the channel's only outage notice. It has no Retry, because the channel keeps trying and tries again at once when the network comes back or moves, the app becomes active again or the catalog recovers (see Connections). The notice stays until the channel connects. A reconnect that goes live sooner shows nothing. Until then agent status, working presence and every connection notice stay as they were while live. Disable delivery and management actions, not editing. Time away from the app never counts toward the three seconds |
| Disconnected without any state | `wifi.exclamationmark`, "Can't connect to Toy Box", server host, readable failure, Retry and Settings |
| Catalog refresh fails | Keep existing rows, mark them stale and turn the connection footer's dot orange, with the readable failure in its help (see Sidebar), after the catalog's stream has failed for about three seconds or at once for a refresh the user asked for. Never replace them with "No channels". When it recovers, every channel waiting out a backoff retries at once |
| Failed send | The message stays on its row in the transcript as Not sent, with its text and attachments, Retry and Delete, after the outbox's own retries (see [Sending](#sending)) |
| Channel deleted | Stop observation, dismiss its inspector, show "This channel was deleted". Back to Channels and Copy Draft if nonempty. Never silently discard a draft or redirect to another channel |
| Invalid URL or authorization failure | Show the actual category and server, Settings/Retry as appropriate. No fabricated successful connection |
| Failed image/artifact/history | Localized error at that surface with Retry. Keep the rest of the channel usable |
| Unsupported future event | Neutral system row, no stream-wide crash and no raw JSON wall |

Connection status is separate from agent activity. Reconnection does not show a team as still
working unless current presence establishes that. No repeated full-window spinner after content
has already loaded. Retry is user-initiated and does not resend messages or replay mutations.

### Motion and accessibility

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

## Surfaces

Each surface section holds what the surface covers, its Mac design and how the phone differs.
Parts labelled **Phone** apply only to the iPhone companion.

### Sidebar

Use the system sidebar search field from `.searchable(placement: .sidebar)`. It filters the local
catalog by channel name, purpose or directory without making a network search request. Preserve
the selected channel while filtering. The list remains one "Channels" group in server order, or
one group per server when there are several (see [Several servers](#several-servers)).
Do not reorder it for presence or attention. Refresh preserves scroll and selection.

Rows follow the Mail and Messages list pattern: who or what on the left, when on the right, and
detail beneath. Each row is at least 52 high (scaled with text size), with 8 horizontal and 8
vertical content padding and native source-list selection. A 30-point channel icon sits 10 points
before the text and is centered on it, showing the channel's avatar in a rounded square with
continuous corners at 26% of its side, like the pane and the system's app icons. The square tells a
channel from the round agents beside it. `ChannelMark` draws it everywhere a channel appears:

- **Mark.** Its color's `.gradient` (flat with Increase Contrast), with the 24-unit path at 64%
  and a 2.25-unit stroke in contrast ink, exactly as member avatars draw theirs.
- **Image.** Edge to edge with no fill behind, under a 1-point inner hairline of the primary color
  at 10%, so a light picture keeps its edge on a light background. The square stays empty while it
  loads.
- **Fallback.** With no avatar, or an image that won't load, a 14-point semibold white `number` on
  `Color(#0891b2).gradient`, Toy Box's channel cyan as a constant of its own, never read from the
  lead's avatar. Other sizes scale the glyph with the square.

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
| Openable | `folder` and name, secondary | Hover shows the hover fill in a capsule. Click opens the folder in a Finder window with `NSWorkspace.selectFile(nil, inFileViewerRootedAtPath:)`, never `NSWorkspace.open`, so a directory that is a package such as an app bundle never launches. It never selects the row | "Open toy-box in Finder", then the full path with `~` abbreviation |
| Server is another machine | `folder` and name, secondary | Static: no hover fill and no action | "On [host]: [full path]. Folders open only when the server runs on this Mac." |
| Missing on this Mac | `questionmark.folder` and name, secondary | Static | "This folder no longer exists: [full path]" |

Every token uses secondary ink, so the folder name stays readable in every state, including on
the accent selection. The glyph, its help and the lack of a hover capsule mark a folder as
unavailable. Don't dim the missing token: 30% or tertiary ink measures under 2:1 at rest and
about 1.6:1 on the accent.

With no directory, line 2 leads with the purpose's first line (11 regular, secondary, tail
truncation). With neither, line 2 holds only its trailing indicators, and the row keeps its height.

**Selection.** Selected rows use the native source-list highlight. In the key window it is the
accent fill (`backgroundProminence == .increased`), and every custom color must yield to it,
except the avatars. The channel's avatar keeps its own colors, the cyan `#` fallback included,
like the app icons in System Settings' sidebar, because an avatar is identity rather than a status
color. The request bubble, completion check and unread dot become white. The hover capsule becomes
20% white. Text uses `.primary` and `.secondary` so it whitens on its own. Working avatars keep
their own colors. Apart from avatars, never draw cyan, orange or green on the accent fill. In an inactive window, or when the list isn't focused, the
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

**Phone.** Attention shows icons only, retaining the Mac's spoken phrases from this table.
At standard text sizes, keep the time on the name line for quiet and working rows alike, never
vertically centered in a quiet row. Line 2 keeps the faces' 20-point height whatever it shows, so
the name and time line sits 12 points down on every row, where a Needs You card's heading sits. A
row with only its name centers it. Accessibility sizes use the stacked heading. Folded rows
hide the system navigation indicator and draw a small tertiary `chevron.forward` immediately
after the time, aligned on the first baseline. The chevron becomes white when selected.
Unfolded rows show no chevron, and the sidebar marks the open channel with the list's native
selection, like iPad Mail, never a custom or cleared row background. Under an accent fill
(`backgroundProminence == .increased`) the opaque secondary grays become `.secondary`, the chevron
and attention turn white, and the channel's avatar keeps its own colors, as on the Mac.

The working-avatar stack exists independently of attention, so a working team and pending question
can coexist. Keep the full-team names in row help/accessibility even though idle members aren't
pictured in the activity stack. Closed channels use catalog activity only if the protocol actually supplies it. Never
invent presence. An open channel keeps its last working agents while it reconnects quietly, and
drops them once it is stale or deleted.

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

**Catalog activity:** the catalog includes `working`, the IDs of leads and members whose
sessions are running. This is the same fact the browser reads from workspace session state, and it's the one source of
who's working for every channel, open or closed: the sidebar, the working summary, Overview,
reactions and Live Activities. As the web derives it, an agent is working while `working` lists it,
with its status text when its status is working, and otherwise waiting when its status says so and
idle when not. Activity can lag by one catalog refresh. It must clear when observation is lost
rather than keep animating.

**Connection footer.** The bottom of the sidebar names the server this window talks to, as the
wireframe's `sidebar-connection` group draws it. With several servers, each server's header
carries its own status, and the footer's status line sums them up (see
[Several servers](#several-servers)). Attach it with `.safeAreaBar(edge: .bottom)` on
the sidebar list so rows scroll beneath it under the system scroll edge effect. Give it no
background, divider or material of its own. The status line is a 7-point dot (the unread dot's
size), 6 points, then the server's host and port in 11 regular, secondary, one line, middle
truncation. Omit the port when it is the scheme's default. The line is 22 high, and its row is as
tall as the large glass Open Screen button at its end, with 10 points above and below so the row
centers in the bar. The dot's leading edge sits 20 points from the sidebar's leading edge, 4
before the channel icons, and its center sits 24 points above the sidebar's bottom edge.

| Catalog state | Dot |
| --- | --- |
| First load | `.secondary`, then a spinner after 300 ms. The placeholder rows already show loading |
| Last refresh succeeded | `.green` |
| Refresh failing, rows kept | `.orange`. Recovery retries every failed channel at once |
| Never loaded, invalid URL or authorization failure | `.red` |

The dot is the sidebar's only sign of a problem. The sidebar never shows an error message, so it
always holds the list and the footer, and nothing appears above the status line. The status line's
help puts the readable failure, like "bad gateway (HTTP 502)", on its own line between the status
and "Change the server in Settings.", and VoiceOver reads it as the button's hint. The catalog keeps
retrying on its own and the status line already opens Settings, so there is no Retry. With
Differentiate Without Color, an orange or red dot becomes an `exclamationmark.circle.fill` of the
same color and size, so a problem never depends on color alone.

The footer is the sidebar's only progress indicator. When the first load or a refresh the user
asked for (View > Refresh, which refreshes only the channel list) takes longer than 300 ms, the dot's slot shows a native
indeterminate spinner,
`ProgressView().controlSize(.mini)`, which is 10 points. Center it on the dot's center and don't
clip it, so it overhangs the 7-point slot by 1.5 points on each side and the host text never moves.
When the attempt resolves, it crossfades back to the resulting dot. The catalog's stream never shows
the spinner. A dropped stream also stays quiet and reconnects with backoff until it has failed for
about three seconds, the same grace a channel gets, so coming back to the app never flashes the
orange dot. A refresh the user asked for reports its failure at once. Never overlay a spinner or "Loading Channels" on the list. The static placeholder rows
show the shape and the footer shows the activity.

In an inactive window the system draws a hairline above the bar, just as it does under the
toolbar. Keep it, because the soft edge in the active window comes from the same system effect.
Never fake that line, and never hide the scroll edge effect to remove it.

The status line is a borderless button that opens Settings on the Servers tab, where the server
URL lives. Hover and
press use the folder token's capsule of the hover fill,
outset 6 points so the dot never moves. Help reads "Connected to http://localhost:3100", or
"Connecting to", "Reconnecting to" or "Can't connect to", then "Change the server in Settings."
VoiceOver reads one button labeled "Server" with the value "localhost:3100, connected" (or
connecting, reconnecting, can't connect). Dot colors crossfade over 0.2 seconds, instantly with
Reduce Motion. Never pulse the dot. The footer reflects the catalog connection only. An open
channel's own stream keeps its floating "Reconnecting to server" pill over the transcript.

The status line's row ends in Open Screen, a large glass circle with the outline `display`
symbol, as far from the trailing edge as the capsule is from the leading one. It
runs File > Open Screen… (see Screens), with the help "Open Screen (Command-O)", and is disabled
without a server. It leaves with the sidebar when the sidebar is hidden, and the command stays.

#### Talk to the Lead

Phone only. Swiping a channel row right records a spoken note and sends it to that channel's
Lead without opening the channel. It is always a new message to the Lead. It never answers a
request, never changes attention and has nothing to do with Needs You. Every note goes to the
Lead, so the recorder shows no avatar or recipient.

**Swipe.** `.swipeActions(edge: .leading, allowsFullSwipe: true)` holds one button, Talk, with
`mic.fill` and `.tint(.accentColor)`. Delete keeps the trailing edge. Both show only their icons
and keep their names for VoiceOver. A short swipe reveals Talk,
and tapping it starts listening. A full swipe starts listening at once, with the system's
full-swipe haptic. Talk is absent when dictation doesn't support the user's language. While a
recorder is open, no other row offers swipe actions. Unfolded, the sidebar's rows work the same
way, including the open channel's row, where the note also appears in the conversation, and the
card stays within the sidebar's column.

**The recorder floats from the row.** Nothing already in the row moves. The mark stays pinned
where it sat in the row, and the name keeps its baseline. Content only swaps in place or grows
below, so the row seems to come alive rather than be replaced. The channel's cell never changes
height. The recorder is a card overlaid on the list and anchored to the cell's frame with
SwiftUI geometry, an anchor preference or `onGeometryChange`, so it follows the row through
rotation and posture changes. It opens on the row's frame and draws the row's own content at the
same positions while the cell's content hides, so the handoff is invisible. It then grows
downward over the dimmed rows. Every change, the card's size included, runs in one transaction
with `.spring(duration: 0.4, bounce: 0.12)`, which starts the moment the swipe action fires so
it overlaps the system closing the swipe. Never drive a size frame by frame or insert a second
row for the note.

**Room.** The card opens on its row and grows downward, so a row with room below for the card's
tallest size, with five lines of words, never moves. Near the bottom of the list's visible area,
inside the safe area and any bottom bar, the card grows downward only until its bottom meets that
edge. From then on it holds its bottom there and grows upward, carrying the heading with it, never
past the top of the visible area. The top edge moves in the same transaction as the card's size,
so the bottom holds still as lines arrive. If even the top of the visible area leaves too little
room, as at accessibility text sizes or in landscape, the card fills the visible list and its
words show fewer lines. Closing returns the top to the row in the same transaction that shrinks
the card.

**Edges.** The card's sides sit 12 points outside the row's text, before the mark and past the
time's trailing edge, and never beyond the list's visible area. At accessibility sizes, where the
time leads its own line, that trailing edge is the end of the row's text. The counter, the
waveform, the words and Send all end on it, so the card has one trailing margin. The row's
trailing column, the chevron and any attention mark beside line 2, stays empty while the card is
up. The card clips everything it draws to its own shape, so nothing ever sits on or past its edge.
While the card is open, the list's lines above and below the row and the one under the next row
hide, so the card never crosses a line. All three return as the card starts shrinking, on Send and
on Cancel, so they're already in place beneath it as it pulls away.

**The glass sidebar.** Unfolded, the sidebar is Liquid Glass, so no opaque base can match a row
the way the list's background does folded. There the card's whole surface, base and wash, is
solid from the first frame, and only the edge and shadow fade in. The row steps once to the
card's color as the swipe closes and never dips darker on the way. The card keeps the user's
own-message fill, a little darker and bluer than the glass, like the user's bubbles in the
conversation beside it, and its edge and shadow lift it. The open channel's row wears the glass
selection, a gray band with the row's standard ink. When the note is for that channel, the band
hides on the card's first frame, so none of it shows around the card, and returns as the Sent
wash fades or as Cancel's card lands. When the note is for another channel, the open channel's
row keeps its band while its content dims with the rest of the list, so where you are never
changes and the band never blinks off and on. It still ignores taps.

| Part | Row | Recorder | Transition |
| --- | --- | --- | --- |
| Surface | None | An opaque card: `systemBackground`, then the phone's 7% neutral lift and accent at 9%, so the dimmed rows never show through. 20-point continuous corners, with the sides under Edges. A 0.5-point edge of accent at 30%, or the Increased Contrast edge when that's on, and a shadow of black at 30% in Dark or 12% in Light, 24-point radius, 8 points down | Starts on the row's frame. Folded, the `systemBackground` base is solid from the first frame, since it matches the list's background under the row, and the lift, accent, edge and shadow fade in over 0.2 seconds as the card grows with the spring. On the glass sidebar, the base and wash are both solid from the first frame and only the edge and shadow fade in |
| Mark | The channel's 28-point avatar | The avatar's 28-point rounded square in accent at 15%, with an accent `mic.fill`. Never a solid fill, because Send is the only filled control | The avatar, mic and check share one 28-point tile with the avatar's continuous corners, so the mark keeps one shape and only its face changes. The avatar fades as the symbol scales in from 50%, and the way back runs in reverse. The mic and the check swap with `.contentTransition(.symbolEffect(.replace))`. With Reduce Motion, every swap is a crossfade |
| Time and chevron | Last activity, then the folded `chevron.forward` | The elapsed time, "0:06", in caption, secondary and tabular, on the time's exact baseline and trailing edge. The chevron's space stays empty, so nothing on the top line shifts | The time leaves with a 2-point blur and fade over 0.15 seconds, then the counter fades in over 0.15 seconds, so the two never show together. Every later swap in this slot, to Offline or back to the time, works the same way, except at the settle. The chevron and attention mark fade out with the time. The counter's digits change in place, with no transition |
| Line 2 | Folder or purpose, working stack, attention | The waveform, 24 high | Line 2 fades out with a 2-point blur over 0.15 seconds as the bars rise from 20% of their height |
| Words | None | Body text 8 points below the waveform, up to five lines, then the oldest line scrolls under a 12-point top fade. "Listening…" in secondary until the first word. Tentative words are secondary and settle to primary as they finalize | Each new line grows the card with `.smooth(duration: 0.25)`. Up to five lines, the lines already shown hold still and the new one appears beneath them, while the controls and the card's bottom edge move down together in that one transaction. Once the card holds its bottom near the end of the list, the heading, the lines and the top edge move up together instead. Only from the sixth line does the text move, as the oldest line slides up under the fade |
| Controls | None | A trailing pair 10 points below the words: Cancel, a 32-point circle of primary at 12% with `xmark`, then 12 points, then Send, the composer's 32-point accent circle with a white `arrow.up`. Both have 44-point hit targets. Send keeps the quaternary fill until there's a finalized word | Fade in and scale from 90%, 0.06 seconds behind the spring |

**Alive while you talk.** Your voice drives the recorder through the dictation level, smoothed
and updated about 12 times a second. Each update applies with `.linear(duration: 0.08)`, and
nothing updates SwiftUI every frame.
- A halo of accent at 25% around the mic, in the mark's rounded square, scales from 1.0 at
  silence to 1.4 at full voice. It's the pulse, so it never loops on its own and rests when you
  pause.
- A soft radial glow of accent behind the mic, inside the surface, rises from 0 to 30% opacity
  with the same level.
- The waveform is a `Canvas` of 3-point bars with 3-point gaps, 3 to 22 points tall. Each sample
  enters at the leading edge beside the mic, and older bars step toward the trailing edge,
  fading from accent to accent at 25%. Your voice reads as flowing out of the mic down the row.

**The rest of the list.** While the recorder is open, every other row fades to 40% opacity over
0.25 seconds and ignores taps and swipes. The list doesn't scroll and keeps its order, even when
the sent note's activity would move the channel to the top. The order catches up with the List's
ordinary move after the settle. The toolbar stays live, and anything that leaves the list ends
the note as a draft (below).

**Listening.** The recorder reuses the composer's dictation: the same transcriber and
contextual names, the access sheet, the first-use download and the failure notices, which
appear in place of the words. After 30 seconds without new words, listening stops. The halo
and waveform rest, the timer stops, and the mic becomes a button labeled Resume. While the
server is unavailable, listening continues, the timer slot reads "Offline" and Send stays
disabled.

**Send.** Tapping Send runs these steps in order:
1. Listening stops and the waveform eases flat over 0.2 seconds. Only finalized words are sent,
   so Send waits for the final result. Cancel disables.
2. The note goes to the outbox with its own UUID, and the card holds only while it's saved.
3. Once the outbox has it, the recorder closes into the Sent beat in one
   `.smooth(duration: 0.35)` transaction, while the note may still be sending:
   - The words, waveform and controls fade out over 0.15 seconds while the card shrinks back to
     the cell's frame, its top returning to the row if it rose. The rows it covered reappear
     as it shrinks.
   - Line 2's folder or purpose crossfades back in over the second half. Its attention mark
     waits for the wash to fade.
   - The rest of the list returns to full opacity over 0.25 seconds.
   - The mic becomes the done check through `.replace`: a semibold `checkmark` knocked out of the
     mark's rounded square, filled in `ChannelTaskColors.changes(in:).added`, the color a
     completed task wears. The square is 26 points, centered in the mark with the avatar's 26%
     corners, because a solid bright square reads larger than the avatar beside it. The surface
     beneath shows through the check. Nothing rings or pulses around it.
     `.sensoryFeedback(.success)` plays as it arrives.
   - The counter gives way to the time the note was sent, in the row's ordinary format, through
     the slot's swap. No word says Sent, because the check does.
   - The card's shadow and edge fade out as it lands, and its fill stays as a wash.
4. As the card lands, its wash fades over 0.4 seconds with `.easeOut`, and the chevron and
   attention mark fade back. The row now looks ordinary except that it wears the check in
   place of its mark.
5. Two seconds after the card lands, the check fades back into the channel's avatar,
   as the Mark row describes. That's the settle. The card hands back to the cell, which already looks the same,
   and the row is an ordinary row with no preview of the note. The note's time becomes the row's
   own time without a swap, since both read the same. Swiping the row again before the
   settle starts a new note, and the check swaps straight to the mic.

On the open channel's row, the selection band returns as the wash fades. The check stays green
on it, since the glass selection keeps the row's standard ink.

**Not sent.** The card never waits on the server or reports a failure. A note the outbox can't
deliver waits in its channel as Not sent, with Retry, like any message.

**Cancel and leaving.** Cancel discards the note without confirmation, since nothing was sent.
The card shrinks back to the row with the open spring in reverse as the mic swaps back to the
mark, then its fill, edge and shadow fade as it lands. Leaving mid-note keeps the words. Opening
a channel, Search or Settings, backgrounding or locking stops listening and saves the finalized
words as that channel's draft, after any existing draft on a new line. The card then closes
without the Sent beat.

**Reduce Motion.** The card changes size, and rises when it must, with a 0.2-second ease and no
bounce, and every swap is a 0.2-second crossfade. The halo's opacity follows the level instead
of its scale. Bars stay in place and only their heights follow the level. The done check arrives
and leaves with the same crossfade and keeps its 2-second hold. Haptics stay.

**VoiceOver.** Talk is the row's custom action, "Talk to Lead". The card is a modal container,
so focus stays inside it while it's open and returns to the channel's row when it closes.
Opening moves focus to the words and announces "Listening". The words are one element whose
value updates without announcing each word. Send reads "Send to Lead" and Cancel reads "Cancel".
The Magic Tap sends and the escape gesture cancels. A send announces "Sent to Lead in
[channel]", so the check is hidden from VoiceOver. At accessibility text sizes the recorder keeps
the stacked heading, and its words and controls grow with the text.

#### Needs You in the list

Phone only. A channel waiting for the user shows its request in the list, and the user can answer
it there without opening the channel. The list and the Needs You widget read the catalog's
`waitingRequests`, so they agree on which requests wait, newest first, and on each one's
words. `NeedsYouCards` in ChannelClient holds the cards' rules, and the views only draw them.

**Waiting rows.** A waiting channel's row shows its question in one line of primary text in place
of its folder or purpose, up to three lines at accessibility sizes, and keeps its attention mark.
A channel becomes a waiting row only once its request's message is known, so a card always opens
with its words. Until then it stays an ordinary row with its waiting mark. Tapping a waiting row
opens its card rather than the channel. Unfolded, the channel the detail column shows stays an ordinary row.

**One open card.** The newest waiting request's row is open as a card, and only one is open at a
time. Tapping another waiting row opens its card as the other closes, in one
`.spring(duration: 0.4, bounce: 0.12)`. A card the user opened stays open while its request
waits. The list scrolls only for a card the user opened, by tapping its row or by answering the
card before it, and brings it fully into view as it opens and grows. A card that opens because a
request arrived leaves the list where it is. The list never scrolls while a finger is on it or a
fling is still slowing, and once the user scrolls it, a card that grows later stays put.

**The card.** It's the talk card's surface in Needs You orange: 20-point continuous corners, the
0.5-point edge and the wash, with no base, no shadow and no dimming, so the list stays fully
usable around it. Its sides sit 12 points outside the row's content, as the recorder's do, so
the mark, name, time and chevron stay exactly where the row draws them as the card opens and
closes, and only the card grows around them. Everything inside, lifted or not, ends on the row's
trailing edge, under the chevron. A folded list ends at its rows, so there the content steps in
instead. Once that card closes, its row keeps the card's time and chevron place until the check
settles, then they slide out to the row's. The mark centers between the heading and the
question's first line. The heading keeps the row's name, time and folded chevron, and tapping it
opens the channel at the request. The
whole request follows without an attention mark, in the transcript's own body, so its Markdown,
mentions and mention ink read exactly as in its bubble. The choices and Reply follow at the
bubble's 10-point gap, in the phone's layout under Suggested replies. The waiting row and the
widget keep the one-line plain question. The card grows to fit the whole request, which scrolls
only once the card would run past the visible list, fading at whichever edge it continues past, so
the choices and Reply always stay in view. The lines above and below the card hide, and it offers no
Talk swipe.

**Choices.** A choice goes at once as written to the outbox with its own UUID, answering the
card's request, as in the transcript. The card holds as it was only while the outbox saves it,
its choices still and ignoring taps, then runs the talk card's beats while the reply may still be
sending. In one `.smooth(duration: 0.35)` transaction the card shrinks straight back into its row
as the next waiting request's card opens, and the row's avatar becomes the talk card's done check
the way its Mark row describes, with `.sensoryFeedback(.success)`. Two seconds after the card
lands, the check fades back into the avatar. No word says Sent and the reply's
words don't show, because the check does. Answering the next card before then leaves the first
check in place, and each row settles on its own. The waiting rule counts a request answered from
the moment its reply is sending, so it never reopens while the reply sends or the catalog catches
up.

**Reply.** Reply lifts the card above the list, where it gains the recorder's base and shadow and
every other row dims to 40% and ignores taps. A plain field takes the choices' place, focused at
once with the prompt "Reply to [requester]", and grows to five lines. Cancel and Send are the
talk card's controls. The card follows the recorder's Room rules within the area above the
keyboard, so its controls always stay visible. The reply leads with the requester's `@handle`
unless it starts with a mention. While the server is unavailable Send disables, as the choices
do, and the words stay. Send holds the lifted card only while the outbox saves the reply, then it
shrinks from above the list straight into its row, its words fading with its base
and shadow, in the choices' one transaction as the next card opens, and its row wears the check,
as a choice's does.

**Not sent.** The card never waits on the server or reports a failure. A reply the outbox can't
deliver waits in its channel as Not sent, with Retry, and its request comes back where it was in
the list, without scrolling it.

**Leaving.** Cancel discards a typed reply. Opening a channel, Search, Settings or a management
sheet, backgrounding, or the channel going away ends it, and saves its words as that channel's
draft, after any draft already there.

**Reduce Motion and VoiceOver.** Under Reduce Motion each beat is a 0.2-second ease without
bounce, and the check keeps its 2-second hold. A waiting row's hint is "Shows the request", and the card's heading reads the channel's
name with the hint "Opens the channel at this request". The lifted card is modal, and the escape
gesture cancels. A sent reply announces "Reply sent in [channel]", so the check is hidden from
VoiceOver.

### Transcript

Use the canonical row projection unchanged. Avatar column is 32, gap is 12, and body begins 44
points into the lane. Runs have 20 points between them, 8 between entries in a run and 4 between
header and body. A header only repeats when `showHeader` says it does. Agent bubbles have 12-point
corners, 12 horizontal and 10 vertical padding, and no tail. They fit their content up to
min(lane − 44, 760). The user's message pins trailing, up to min(80% of the lane, 640), both caps
scaled by Text Size (see the lane rules in Composition), with a low-intensity accent-tinted
surface and normal label text. Do not use white body text on a saturated brand color.

Agent avatars are circular, with the supplied color and path. Fill the circle with the supplied
color as SwiftUI's `Color.gradient`, the same soft top-light gradient as the sidebar's channel
icon, so every avatar reads as slightly raised. This lives in the shared
`AgentAvatarView`, so an agent looks identical in the team list, transcript, composer, reactions,
task owners and sidebar stacks, at every size. Add no shadow, rim or highlight: a shadow muddies
light mode, disappears in dark and smears overlapping stacks. With Increase Contrast, fill flat
with the exact supplied color. Draw the 24-unit path at 64% of the avatar, stroke 2.25 units at
every size, round caps and joins. Don't thicken the stroke at small sizes: the denser marks,
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
the channel fallback's cyan. Increase Contrast flattens the navy and keeps the gold. The server is the
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
accent-tinted bubble, the pending orange wash or the Not sent red wash. Under Increase Contrast the target is 7:1. Keep the seven-color, six-surface contrast regression
with these targets.
Everyone and Lead follow the same rule with the accent and the lead's color. Weight carries the
cue for color-blind readers. Unknown mentions remain literal, not a false agent chip.
Links have normal native link affordances. Render headings, emphasis, lists, blockquotes, fenced
code, inline code and tables, with selectable text. Code blocks offer Copy Code, and tables may
scroll horizontally. Never execute HTML, scripts or embedded remote content from Markdown.

Only coordination entries marked collapsible truncate, at 160 points of body text, with a subtle
24-point bottom fade and Show More. Show More and Show Less are quiet secondary text, not the
accent, on both platforms. Show Less returns to that same anchored row. Messages for the
user and all flagged requests always remain expanded. User-initiated expansion is preserved while
rows update. The copy action copies the original full message, including its leading mentions.

On the phone, a Show More/Less footer occupies 40 visible points at Large and grows with its
text at larger Dynamic Type. Center the footnote semibold label vertically in that footer and
align it to the body's leading edge. There is no additional 4-point body/footer gap or 10-point
bubble padding below it. Its 44-point tap target extends 4 points below the bubble, never up
into the body, so it doesn't overlap links. The body has 12-point horizontal and 10-point top
padding and the 24-point fade. Bubbles without this action have 10-point bottom padding. Phone
mentions follow the identity-ink and contrast policy above, not generic primary text.

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
exposes Reply as an action. On the phone, a header too wide for one line stacks, and its "Needs
your reply" or "Replied" wraps like the name, so at the largest text sizes the header never widens
the bubble past its column.
Reply, Copy Message and Bookmark appear on hover or keyboard focus, in the toolbar Bookmarks
describes, and in the context menu. Every message takes keyboard focus, the user's own included,
so Full Keyboard Access reaches its toolbar. As with AppKit's
tracking areas, a message that slides under a still pointer, as when the transcript follows a new
message or scrolls, shows them once the pointer moves. After the reader's own scroll settles, the
message under the still pointer is selectable at once, so a drag can start without moving first.
One the transcript carries there itself, as when following a new message, waits for the pointer
to move. Reply prepends the agent's mention once,
preserves the draft, focuses the composer and leaves the caret after the mention. Deleted agents
cannot be replied to. Your own
messages get the same toolbar, mirrored, and expose Copy Message as an accessibility action and in
their context menu. Keep
message selection, link selection and context menus usable independently.

System rows are channel events, not speech, so they sit in the neutral center of the
conversation, as in Messages, rather than in the avatar column that belongs to agents. Each row
is one centered, multiline `Text`: the event's inline SF Symbol, two spaces, then the sentence,
in 11 regular secondary. Center on the full lane, including the identity gutter, with a 480-point
maximum text width and centered wrapping. Consecutive system rows stack 4 points apart as one
group, with normal 20-point run spacing around the group. Rows are at least 18 high, and each
link keeps a 28-point hit target. Help shows the full local date and time and any full values.
Matching membership events and one actor's consecutive artifact shares or removals merge only
where the canonical projection does. A merged artifact line is one sentence, "Pixel shared A, B,
and C", built once in ChannelKit for display, Find and catch-up. Find matches within each title.
Removed titles are links too and open the artifact like the web, since its file stays on disk.
On iPhone each title is a link in the row's one `Text`, and the event's details move to the
row's context menu.
Keep a sentence on one line when it fits, and never force a two-line card.
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
| Avatar changed | `photo` | "Avatar updated", then the new avatar in `ChannelMark`'s frame, as tall as the line and scaling with the text, like the pane. VoiceOver reads "Avatar updated". An older message keeps showing the avatar it set, since the server keeps every avatar image |
| Directory changed | `folder` | Path truncates in the middle, preserving final components |
| Preview changed | `play.rectangle` | Link to the typed preview, or "Preview cleared" |
| Artifact shared | `doc.badge.arrow.up` | Sharer's identity and individually actionable artifact titles |
| Artifact removed | `minus.circle` | Remover's identity and individually actionable artifact titles, each with its path on help |
| Routine scheduled / edited / deleted | `calendar.badge.clock` | Title, with full schedule and prompt in help/details |
| Unknown future kind | `info.circle` | "Channel updated", timestamp and available textual description |

Day dividers follow the web: the day label in 11 semibold secondary on the leading edge, 16 high,
with the header trait, then a 1-point separator rule across the rest of the lane, 8 points after
the label. Labels are "Today", "Yesterday", the weekday
within the past six days, "Saturday, October 18" this year and "Saturday, October 18, 2025"
otherwise, from localized date templates. Day dividers are not sticky. The New divider keeps
Toy Box's blue: a 1-point system blue rule at 70% across the full lane, and "New" in 11
semibold blue 6 points after its trailing end. When a day change and the unread boundary
coincide, they share one line, the day label, the blue rule and New, read as "Today, New
messages". A divider has equal space above and below it, on both platforms and whether it
shows a day, New or both. On the Mac that's 16 points above its 16-point line and 16 below it,
before the row it introduces.
The phone uses the same leading layout in caption semibold: 8 points from the label to a hairline
rule. When unread, the rule and "New" turn blue, with "New" 6 points after the rule's trailing end.
It has 26 points above the line and 26 below. Capture the unread boundary only after snapshot or replay completes, and never move it as
the user reads. A reopened store that disconnected while the channel was closed waits for its
reconnect, rather than capturing from the state it cached. This boundary is not an extra synthetic
message. Reference renders of day labels, the New divider, system rows and both request states:
`docs/transcript-events.png`.

Opening uses only the latest 100 messages supplied by the snapshot and never fetches older pages.
Land on the first unread row when its boundary is in the loaded page, otherwise the end. Both apps
land only once the store is connected, so a reopened channel lands on that boundary rather than on
its cached end. Until then the cached conversation rests at its end, unread. Landing may hide the
rows only until the first layout pass puts its target in place, never until layout goes quiet,
so streaming or a busy app can't leave an opened channel blank. Later corrections move the rows in
view. If the
first unread predates the snapshot and older history exists, show no synthetic New divider or
catch-up summary. Scrolling up loads the real unread boundary in its original place.
When a catch-up summary is eligible, land on its card instead (see Catch-up summaries).
Older pages load only through reader paging, Find navigation or Reveal.
Follow incoming messages only while within
48 points of the end, or immediately after the user's own successful post. If scrolled away, a
small glass Jump to Latest capsule appears in the floating activity row above the composer.
It shares that row with the working summary when present. On the phone, those pills and the transient notices use plain regular glass with no tint, like the toolbar. They and the composer float over the transcript like Messages: the conversation keeps the system's default bottom scroll edge, so rows pass behind the glass right to the screen edge with no band or hairline. Never add `.hard`, a band or a fill behind them. In Dark over a bright image, the placeholder and Find's result count read faintly. That is the deliberate cost of floating plain glass. Preserve the visible top message and its offset while prepending history. While reading above the end, rows only move when the reader scrolls: when a row above the viewport changes height, or the lazy stack corrects its estimate for rows it hasn't built yet, the first row starting in the viewport keeps its place, and a row starting in the viewport grows downward. Following the end, landing, jumps, reveals and paging own the position instead. At the top,
show Load Older Messages when more history is available, a small loading row while fetching, or
"Couldn't load older messages" with Retry on failure. Once all history is loaded, show no
"Beginning of conversation" label and reserve no empty header space. A filtered view must
continue paging even when a page contains no visible rows.

`ToyBoxUI.TranscriptPlacement` defines container-independent placement from ordered row frames
and the viewport's width, height and glass insets. Its adapter sends `layoutChanged` only when
`layoutEvent` detects changed geometry, never just because another native layout pass ran.
The pure `placement(for:rows:viewport:)` function projects an existing intent against current
frames for adapter-owned animation, using the same fallback, clamping and end clearance
without inventing a layout event.
Reader input updates intent without returning an origin. Opening Find uses `holdCurrentPosition`
to capture reading even at the end without moving. With no anchorable rows it preserves the existing intent.
After the Find bar's closing geometry settles, `resumeFromCurrentPosition` restores the normal
following threshold without moving. Jump to Latest immediately resumes following at the end.
Landing and reveal targets retain their
conversation order so a target removed during layout falls forward to its next surviving row,
then backward to the last row, then to the end. Only explicit missing-target actions report an
unavailable target without moving. The model's document end owns the 16-point clearance exactly
once, and read eligibility excludes both glass insets and zero-sized viewports.
`RowFrame.isAnchorable` defaults to true. History and empty-state accessories set it to false:
they still contribute document height, but are never reading anchors, fallback targets or read
candidates. Explicit row-target actions reject accessories. With only accessory geometry remaining,
a layout-time target loss falls back to the document end.

Lazy containers use the model's `Layout` entry points. A layout separates all canonical
`RowIdentity` values in conversation order from the subset of measured `RowFrame` values,
and supplies the viewport, native origin and native `documentEnd`. That extent already
includes the 16-point clearance. Following, threshold classification and clamping
use it without adding clearance or inferring an end from the last measured row.
A known target without a frame returns `needsMeasurement` and no origin, retaining its intent.
Only canonical absence triggers unavailable-target errors or layout-time survivor fallback.
The adapter materializes the requested ID, then submits a new measured layout.

The adapter builds each `Layout` from one layout callback, never mixing old frames with a
new native viewport, origin or document extent. Identities and measured frames have unique
IDs, and frame identity metadata must match canonical membership. Before capturing reader
input or Find's position, the adapter requires current measured viewport geometry. If that
geometry is not available, it retains the reader-input notification and suppresses programmatic
placement until it can reduce that input first. Expansion actions require the clicked row's
measured frame. The model never invents an anchor offset or falls back to following merely
because a known row is unmeasured.
Violations of those live-input requirements assert in debug builds and leave the intent and
position unchanged in release builds, never crashing a release app for delayed geometry.
`layoutEvent(from:to:)` compares membership, measured geometry, viewport and document extent,
not reader-only origin changes. Complete-frame entry points are also available and use the
same reducer and placement logic.

Long histories must stay as fast as short ones. Build rows incrementally: derive each message's
audience, display text and reactions once, and when messages only append, rebuild from the last
row rather than from the start. Give each row only the values it renders and compare rows, so a new
message, status or reaction re-renders only the rows it changed. Only a message that can collapse
measures its own height, so a new message lays out once rather than again when its height arrives.
Compile Markdown and mention patterns once, not once per row. The transcript reads only the
`messages`, `roster`, `agentStatuses`, `presence` and `request` slices, so task, artifact, routine
and detail events don't re-render it.

Message View shows all messages, or only the user's own, agent messages that never collapse and
the messages the user bookmarked.
The Message View menu is a native radio-choice menu: All Messages and Your Messages. Like the web
pane and Messages, each choice carries an outline SF Symbol, `bubble.left.and.bubble.right` for All
Messages and `person` for Your Messages, beside the system checkmark. The same labels appear in the
toolbar menu, the View menu commands and, on the phone, the Channel Actions section. The Mac toolbar
menu lists the two choices directly with an inline picker and no header, while the menu bar's View
menu keeps its Message View submenu among its other sections. The phone's menu also lists them
directly. A non-default
filter gives its toolbar button an active tint and label/help. On both apps that's the accent
glyph: the same outline `line.3.horizontal.decrease` turns accent while Your Messages is on, never
a filled or circled variant, and a standalone phone Message View item keeps its neutral glass. A toolbar `Menu` takes no prominent glass fill, even with `.menuStyle(.button)`
and `.glassProminent`, and a Button with a popover would trade the one-tap menu for a cosmetic
fill. Its accessibility value is "Your Messages". Where Message View sits in the phone's title menu, the "Your Messages" subtitle
carries the state and the title stays untinted. It does not change the composer
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
raises the hairline to 40%. The phone draws the same hairline on its 10-point continuous thumbnails
and video posters. While an image loads, show a neutral tile at its final size
(quaternary fill at 30%, the same corners and hairline). Add a small spinner after 300 ms and
never show the filename. Read inline images' pixel size from the image header before decoding,
so the first layout is final. A remote image an earlier load cached reads its size from the cached
file's header the same way, so scrolling back to it never resizes its row. Remote images without a
known size use 120 x 90 and resize once. An image that can't load keeps that same tile, with
`photo.badge.exclamationmark` centered in secondary and no filename or error text, on both apps.
Clicking or tapping it tries again. On the Mac its help reads "Couldn't load this image. Click to
try again.", and VoiceOver reads the tile's usual label with the value "Couldn't load" and the hint
"Tries again".
Videos have a poster, duration when known, and an explicit Play action.
Other files show document icon, name and Open. Resolve resources against the server base URL.
An unavailable file keeps its name and an explicit retryable error, not a blank thumbnail.
Opening remote URLs must not assume a matching local filesystem path.

**Phone attachment parity.** The entire attachment set occupies one horizontally scrolling
row, with 8-point gaps and no stacking or wrapping. Images use the shared
`ChannelThumbnails.boxSize(fitting:)` cap of 240 x 160, and video previews cap at 240 x 120.
Keep attachment order, leading/trailing alignment, the correct image index on opening, and the
presented tile in view when returning. The hosts share the portable strip container where
practical, each with its own native tiles. File and video actions keep minimum-44 targets.

**Image viewer.** Images open in place, as in Photos, never in another app or a floating Quick
Look panel. The viewer pages through the clicked message's images in attachment order and
doesn't cross into other messages. Videos and files keep their own actions.

| Part | Specification |
| --- | --- |
| Presentation | Replaces the conversation until closed. The sidebar stays, and an open Overview stays beside the viewer in its own column. The canvas is `underPageBackgroundColor`, full bleed under the glass toolbar. The toolbar band settles at exactly the canvas color, with no change after the fade ends. The canvas stops at the sidebar, whose glass keeps its tint while viewing. Transcript scroll, draft and inspector state are untouched underneath |
| Image | Fits the canvas with 24-point side margins, 16 below the toolbar and 16 above the capsule. Never upscale past the image's point size, so a 2x screenshot shows at native size. 6-point continuous corners, the tile's 1-point hairline (10% light, 14% dark, 40% Increase Contrast) and, in light only, a shadow of black 12%, radius 12, y 4 |
| Toolbar | Back (`chevron.backward`, help "Back to Conversation") leads. The title follows in its own glass capsule, the same title menu as the artifact viewer's, and the window shows no system title while viewing: the sender, 13 semibold, over "Today at 5:23 PM · 2 of 4" in 11-point secondary (one image omits the position). The menu lists every image action, Copy Image and Open in Preview, and its help shows the sender and filename. Trailing: Copy (`doc.on.doc`, help "Copy Image") and Share (`square.and.arrow.up`), so Copy Image is both in the menu and a button. The title truncates before them down to 760 x 560. Message View steps aside until closing. Overview's toggle stays with Overview's column |
| Capsule | Only with two or more images. Centered 16 above the bottom edge, `.glassEffect(.regular.interactive(), in: .capsule)`, 8 padding. Previous and next (`chevron.backward` and `chevron.forward`, 13 semibold, 28 x 28) flank 32-point thumbnails (aspect fill, 6-point corners, hairline, 6 apart, 70% opacity). The current thumbnail is opaque with a 2-point accent ring 2 points outside it. Arrows go tertiary and disabled at the ends, with no wrap. Past nine thumbnails the strip scrolls, keeping the current one in view |
| Keys and gestures | Left and Right, the capsule, a thumbnail click or a two-finger swipe change images. Escape, Space or Back close. Double-click toggles fit and actual size at the clicked point, except on Live Text. Pinch and `Cmd-=`, `Cmd--`, `Cmd-0` zoom only while viewing, overriding Text Size. Scroll or drag pans a zoomed image, and changing images resets zoom. `Cmd-C` copies selected Live Text, otherwise the image, and dragging it out exports the file. Live Text rules are under Image descriptions and Live Text |
| Motion | Opening zooms the image from its thumbnail's frame to its fitted frame (spring, response 0.35, damping 0.9) while the canvas fades in over 0.2 seconds. Closing reverses into the current image's thumbnail, scrolling the strip to it first. Paging slides 40 points with a crossfade in the direction of travel. The tile steps aside only while the zooming image covers it, so the strip never shows a hole. Without a thumbnail frame (a tile less than half visible on close), the image fades and scales from 94%, and the tile stays in place under the canvas until the viewer is gone. Reduce Motion uses 0.2-second crossfades throughout, with no scale, and the tile never steps aside |
| Loading and errors | Show the cached thumbnail at the final fitted frame immediately and swap in the full image when decoded. A spinner appears only after 300 ms. Failure shows "Couldn't Load Image" and Retry, centered on the canvas |
| Accessibility | Modal. Focus moves to the image, labeled "Image 2 of 4 from Lead, [filename]", with Next, Previous, Copy, Share and Close actions. Closing returns focus to the current image's thumbnail. The stage's `.isModal` trait alone removes the conversation and inspector from the tree. Never put `.accessibilityHidden(false)` on them: on macOS 27 an explicit false re-exposes their hidden descendants and moves the bottom bars ahead of the transcript |
| Lifecycle | One viewer per window. Switching channels, a deleted message or a lost channel closes it without animation. Not restored on relaunch |

Transcript owns the viewer and its transition. Shell routes the viewing toolbar and the zoom
and close commands.

The phone image gallery's pager capsule and both arrow targets stay anchored across page
changes, loading, and different image aspect ratios. Only the image, selected outline and
thumbnail scroll position change. End arrows stay in place, disabled rather than removed.

**SVG attachments.** SVGs are images throughout the transcript filmstrip, viewer and gallery
capsule, with the same loading, error and keyboard behavior as raster images. Read their intrinsic
dimensions before the first layout when available. Decode and rasterize off the main thread,
at the effective display size and scale up to an 8192-pixel cap. Keep vector detail sharp
at supported zoom levels rather than enlarging a thumbnail, within that cap. For viewer fit, an
SVG's intrinsic dimensions are logical points, not Retina pixels. Fit large drawings down to the
available canvas, but do not enlarge a small icon past its natural point size until the person
zooms. A raster image's point size is its pixel size divided by the display scale. Live Text
receives the resulting `CGImage`. External image or font references must not trigger network
requests. Malformed, unusably sized or unsupported SVGs show the same retryable image error as
raster images, never a crash, blank success state or unbounded allocation. Attachments and artifacts
share the bounded native `TranscriptSVGImage` decoder, while keeping their viewer state and
navigation separate.

Reactions are display-only in this client, matching the user pane. Done shows ✅, agree 👍,
celebrate 🎉, love ❤️ and laugh 😂. Also show the projected looking (👀) and working (🏃) reactions
while the agent's live presence and matching status target permit them. Group by reaction, then show
up to three 14-point reactor avatars and `+N`. Chips are 24 high with a subtle border. The phone
draws the same shared pill at caption size, with its avatars and height scaling with Dynamic Type,
inside a 44-point target. Chips wrap onto as few lines as fit, with lines as far apart as the chips.
Where pills are shorter than 44 points, adjacent rows split the gap between their targets at its
midpoint, so a tap anywhere on a visible pill opens that pill, and the outermost rows keep their
full reach. On the phone's pure black Dark canvas the pill fills with native
`tertiarySystemBackground` (`#2C2C2E`) instead of the soft fill, so it reads raised above black and
the agent bubble. Hover, keyboard focus or activation reveals every reactor name. Do not make a
reaction chip look like an enabled "add reaction" button. The working summary floats as a glass
capsule above the composer, outside the scrollable history. It has 20-point avatars, "Name is
working" or "N agents are working", and status details on activation. Waiting belongs in the
inspector, not this row.

#### Suggested replies

A request may offer two to four suggested replies. ChannelKit reads them through `ChannelMessage.suggestedReplies`, which returns trimmed, non-empty labels of at most 80 UTF-16 units, and only on a `request: true` message. A malformed list reads as no choices, so the request still shows with Reply.

**Instant send.** A tap sends the label as the user's reply at once, through the same optimistic send as Reply, with a caller-owned UUID kept in the outbox until the server confirms it. Choices leave when the user answers. A failed send stays in the transcript as Not sent with Retry, and the choices do not return. Reading a request never answers it, and choices never send in the background.

**Where choices appear.** Choices appear on the transcript's pending request, the Mac menu bar inbox, the Mac notification banner, the phone transcript, the phone list's Needs You card and the phone Lock Screen notification. They do not appear on sidebar or menu badges (counts only), the composer's Input needed state (it opens the question, and choices stay in the transcript), the Dock menu, Spotlight, the morning digest, Control Center, Quick Send or the Siri snippet. Menu items cannot hold buttons, so those surfaces keep Reply or open the channel.

**Layout.** Every surface keeps the lead's order for its choices, with Reply last. Labels wrap in full, reading from the leading edge, and never truncate, except the first Mac banner action, which macOS truncates. With no choices, Reply is the only action, so the request still looks finished. Lock Screen and banner actions are laid out by the system, so the platform rules below do not govern them.

**Phone layout.** The phone uses the Mac layout below, with 8 points between buttons, at the small control size and the footnote font. Reply is the same small untinted bordered button with its arrow as on the Mac, so a request without choices shows only that button, at its natural width on the leading edge. Each button keeps a hit target at least 44 points tall, and long labels wrap inside their own full-width button. A wrap makes the bubble taller, never wider.

**Mac layout.** Choices and Reply flow as small bordered buttons at the system's small size, with 6 points between buttons across and down. Each button is as wide as its label, so the Mac never sets an equal share. A button that does not fit the rest of its line moves to the next line. A label wider than the row wraps inside its own button at full width. Reply is last. In the pending bubble, under the question, it is the small bordered button with its arrow, so it flows like a choice. In the inbox it is a plain link, below the choices.

**Control style.** In both transcripts, each choice copies the transcript's Reply exactly: the system's bordered style at the small control size, in the system's default shape, without its arrow. Labels are untinted primary text, never the accent color, so they never set blue on the orange wash. No reply uses the prominent style, a custom fill or a shadow. macOS 27 and iOS 27 render these styles, and their look is the reference. They sit in the content layer, so they never use Liquid Glass.

**Read Aloud.** In both transcripts and on the phone's Needs You card, a pending request ends with an icon-only Read Aloud button after Reply, in the same bordered style and at Reply's height. A tap reads the request's plain text in the user's Spoken Content voice, and the button shows Stop Reading until it ends or a tap stops it. One reader serves the whole app, keyed by channel and sequence, so a new request replaces the one being read and every surface showing that request shows Stop Reading. On the phone it takes the audio session for spoken audio, pausing other spoken audio while mixing with music, keeps reading when the phone locks, and gives the session back when it ends. Choosing a reply stops reading that request, while Reply keeps reading so the user can type as they listen. Starting dictation on either app stops reading, and Read Aloud stays disabled while the microphone is open, since the phone would cut the microphone off and the Mac would transcribe the voice. On the phone the microphone keeps the session.

**Mac menu bar inbox.** Each waiting request shows its choices above Reply, under the Mac layout at inbox width. The Open icon stays top right. Requests have no Open Channel row, and notices keep theirs. A long choice makes its row taller, and the list scrolls. A choice sends through the same path as the transcript's choices.

**Mac notification banner.** Reply and the first choice show as actions, and the rest sit under Options. The banner is posted locally from the request the app already holds, so the Mac needs no push payload for it. Registering a request's reply categories must not replace the app's other categories, and requests with the same labels share one category.

**Phone widget.** The Needs You widget offers only Reply, which opens Quick Send. Choices stay in the transcript and on the Lock Screen, and the widget never sends in the background.

**Phone Lock Screen.** The card is a translucent material over the wallpaper, not a solid dark panel, and its action labels take the accent color. The push carries the replies as a top-level `replies` array of two to four labels, beside `handle` and outside `aps`, on request messages that have them. The notification service extension registers a reply category keyed by its labels, with one action per reply, then sets it as the content's `categoryIdentifier`. Requests with the same labels share one category, and each registration keeps the reply categories that a delivered notification still uses, plus the last four that process registered, whose notifications may not have posted yet. The actions appear only when the notification is expanded by long press, above the Reply text field. The collapsed banner shows no buttons. A choice sends its label as written, without the requester's mention, through the same path as the Reply text action. The notification's own payload names the channel, since the shared category carries only labels. If the category cannot register on device, the notification falls back to Reply only.

#### In-channel message search

Find belongs to the open channel, not the channel catalog. On Mac, Edit > Find > Find… (`Cmd-F`)
opens and focuses a native find bar at the top of the conversation column, directly below the
window toolbar. It does not cover the sidebar or Overview. The bar uses the system control
background, with no custom glass plate, 12-point horizontal and 6-point vertical insets. Its
single row places a flexible native search field with the prompt "Search this channel" in a
28-point row, followed by a width-stable status slot in secondary 11-point monospaced digits,
one native two-segment previous/next control and Done, matching AppKit's find bar rather than
using separate loose chevrons.
Controls retain 28-point hit targets, and the field yields width before the controls truncate.
At the narrow supported window size the count and all controls remain visible.

On iPhone, Find takes the composer's place at the bottom, like Safari's and Notes' find bars,
so the keyboard and the field stay together and the transcript keeps the space above them. While
Find is open, `ChannelInteraction.isFinding` hides the composer, which keeps its draft, images and
request, and the working and Jump to Latest pills. The reconnecting banner stays. Closing Find
brings the composer back with the keyboard down. With the keyboard down the bar stays docked, and
tapping the field brings the keyboard back. Opening and closing swap the bars in one
`.smooth(duration: 0.3)` transaction: the outgoing bar fades with a slight blur and drops 8
points while the incoming one rises into the same place. Reduce Motion gets a plain 0.2-second
crossfade. The keyboard keeps UIKit's own animation, and the transcript's bottom edge follows the
bar's height in the same transaction, so no frame shows two settled bars or an empty gap and the last message
glides rather than hops. Find sits in the conversation's bottom `safeAreaBar`,
not an overlay or another screen, so revealed matches land in the visible band above it. It uses
the composer's frame: 12-point side insets in compact width (16 in regular), 8 points above, and
`ComposerBottomSpacing` below. Use plain regular Liquid Glass on three surfaces in one
`GlassEffectContainer(spacing: 8)`: a flexible capsule field, one joined Previous/Next capsule
and a circular Close. All three share one 44-point height from one `@ScaledMetric`. The arrows are
two 44-point targets in an 88-point capsule, `chevron.up` and `chevron.down` in primary body
medium with the system's disabled dimming. Close is `xmark`, labeled "Close Find". The caret is
the bar's only accent. The folded Duo gives the bar 382 points, measured in the native frame.
Inside the field, keep a 7-point horizontal inset and a 4-point gap between the magnifier and the
query, so all three surfaces share one row.
Use native body text for the query, the compact prompt "Find" and footnote tabular result digits.
The field retains the accessible scope "Find in [channel]". Reserve its trailing 84-point status
slot for every nonempty-query state; a spinner/count/error swap must not resize the field.
Use real Liquid Glass, not thin material, a painted blur or a custom gradient. Find floats over
the conversation's default bottom scroll edge like the composer, with no band or hairline.
At accessibility sizes or failed measured fit, place the full-width field above the controls.
Grow with native text rather than shrinking it. If status cannot fit beside a 64-point query
viewport, allow status to wrap within the same growing field. No separate progress sentence.
The Mac retains its native search field, 28-point controls and bar material, not phone glass.

Find Next (`Cmd-G` or Return in the search field) and Find Previous (`Shift-Cmd-G` or
Shift-Return) move chronologically through matching messages and wrap at the ends. Each matching
message is one result, even if its text contains the query more than once. Escape, the Mac's Done or the
phone's Close closes the bar without moving the conversation or changing its draft. Opening and closing both preserve
the visible message anchor at the same pixel-aligned screen position after layout, with no bounce.
Changes to progress or error status preserve that anchor too. Closing retains the query.
Reopening Find selects the current query for replacement. Switching channels cancels that
channel's in-flight search and closes the bar, so an old response cannot navigate the newly
selected channel.

Match case- and diacritic-insensitively against the rendered message text: visible link labels,
code contents and prose, not Markdown delimiters or invisible link destinations. Search loaded
messages immediately, then read older pages through `ChannelAPI.history` into a separate search
index. Fetching results never prepends them to the channel store or disturbs its scroll anchor.
Use the reveal path to navigate to a selected result, loading the target only on
navigation. While Find is open, persistently highlight every rendered occurrence of the query
with the system find highlight color. Give occurrences in the current result message stronger
emphasis than matches in other messages, without changing the one-result-per-message count.
The highlights and result index use the same case- and diacritic-insensitive matching, including
Markdown prose, code, visible link labels and mention-stripped agent text. Preserve text
selection, link actions and readable foreground contrast in both appearances. Closing Find or
clearing its query removes every find highlight. Only matching messages should rerender as the
query changes, and the normal scrolling and paging budgets still apply.
If Your Messages hides the result, switch to All Messages.
Keep the selected message stable when older results arrive, even when its position changes.
Do not add a second results pane, replace message bubbles or use custom highlight colors.

Both apps use one status slot, inside the phone field and beside the Mac search field. No
persistent second row. An empty query shows no count or progress, fetches no pages and leaves
the scroll position alone. For a nonempty query, the slot stays blank for the first 300 ms,
then shows a native mini spinner while older history is incomplete. The spinner replaces the
count even while Previous/Next can navigate partial matches. Do not display a provisional
"so far" count. Only completion shows the final result position ("7 of 13") or "No matches".
On history failure, the slot becomes an "Incomplete" button opening a native popover, not a
sheet, with "Couldn't search older messages", the actual error, the partial-result count and
Retry. Keep the query, partial results and selected message. Retry searches history again
without clearing them. At accessibility sizes the phone button may use only the warning
symbol with its full spoken label and minimum-44-point target. Dismissing the popover restores
prior focus without reopening a dismissed keyboard. No progress/error transition changes the
field's width or the conversation anchor. Changing the query dismisses its obsolete error
popover. Changing the query, closing Find or switching server cancels obsolete work, delayed
progress and announcements.

Opening Find, fetching history and revealing results never mark messages read or answer a
request. Read marking remains suspended after search navigation until the reader explicitly
resumes normal scrolling or Jump to Latest. Closing the bar alone is not a read action.
VoiceOver gets "Find in [channel]", named Previous Match and Next Match controls, the result
position and, on the Mac, a "Done" button with "Close Find" help, or the phone's "Close Find" button. Give one delayed "Searching older messages"
announcement and one polite completion or error announcement per current query, never per
older page. User-initiated navigation speaks the position, "found so far" and "still searching"
when results remain incomplete. Preserve the text field's native editable value.
Use semantic colors in both appearances, the system focus treatment and native Increase
Contrast/Reduce Transparency behavior. Reduce Motion uses the reveal path's nonmoving alternative.

#### Bookmarks

Bookmarks mark user and agent messages to come back to. They belong to the user, and every
client shares them (see Protocol). System rows can't be bookmarked, and neither can a row that's
still sending or wasn't sent, since it has no sequence yet.

**Symbols and color.** The outline `bookmark` means Bookmark, a system blue `bookmark.fill` means
bookmarked, and `bookmark.slash` means Remove Bookmark in menus and swipe actions. It's the New
divider's blue, and only the bookmarked state uses it. Every way to bookmark or remove one is
disabled while the channel isn't connected, like Send, and existing marks stay.

**Mac hover toolbar.** Every message shares one hover toolbar, 28 points tall: 24 x 24 buttons
with 11-point symbols, 2 points apart inside 2 points of padding, on `.regularMaterial` in an
8-point continuous rounded rectangle with the 0.5-point separator hairline. A 16-point separator
rule with 3 points on each side sets Bookmark apart. Agent messages read Reply, Copy, rule,
Bookmark at the bubble's top trailing corner, 8 points in from its edge, and a deleted agent's
drop Reply. The user's own messages mirror it at the top leading corner: Bookmark, rule, Copy.
The toolbar's top sits 20 points above the bubble, so it ends 8 points into the bubble's 10-point
top padding and never covers the first line. It never covers the header either. Where it would
overlap the header's text, as on a short bubble, it slides outward to start 8 points past that
text, or to end 8 points before it on the user's side, even beyond the bubble.

**Hover feedback.** Each button highlights under the pointer like an accessory-bar button: a
6-point continuous rounded hover fill, concentric with the toolbar, and its symbol turns from secondary to primary ink. The fill
fades over 120 ms. Full Keyboard Access draws the system focus ring on the focused button. Help reads "Reply to Ada", "Copy Message", "Bookmark" or "Remove Bookmark".

**Mac at rest.** A bookmarked message keeps a chip showing when it isn't hovered: the toolbar
with only its blue bookmark, 28 x 24, exactly where the bookmark sits in the full toolbar.
Hovering or focusing the message grows the rest of the toolbar out of the chip over 120 ms, so the
bookmark never moves, and clicking it removes the bookmark, like a tapback in Messages. Reduce
Motion fades the other buttons in without the width change. The context menu ends with a divider
and Bookmark or Remove Bookmark, after Reply to Ada and Copy Message on agent messages and after
Copy Message on the user's.

**Phone menu and mark.** The long-press menu ends with its own section holding Bookmark or Remove
Bookmark, after Reply, Copy Message and Select Text. The user's own messages have no Reply. A
bookmarked message shows a 24-point circle of regular glass holding a 12-point blue
`bookmark.fill` on the bubble's outer top corner, trailing for agents and leading for the user's
own. It sits where the Mac's chip does, 16 points above the bubble and 8 in from its edge, under
the same header rule. The mark is display-only, with no hit testing, because a 24-point target
invites mis-taps. Long-press or the list removes a bookmark.

**Follow-up messages.** An agent's follow-up message has no header and sits 8 points under the
message above, closer than the chip or mark reaches. When one is bookmarked, the gap above it
grows to 20 points on both apps, the run spacing, so the chip or mark clears the message above by
4, the way Messages makes room for a tapback. The gap changes together with the chip or mark, over
the chip's 120 ms on the Mac or at once under Reduce Motion, and never on its own. The hover
toolbar on a follow-up that isn't bookmarked may overlap the message above, since it shows only
while hovered.

**Accessibility.** On both apps the message's label adds "Bookmarked", and Bookmark or Remove
Bookmark is one of its actions. Using that action announces "Bookmarked" or "Bookmark removed"
once. The Mac's chip and the phone's mark are hidden, since the label carries the state.

**Failed writes.** A toggle shows at once and makes one attempt. If the write fails, the mark goes
back and the channel window shows one alert, "Couldn't Bookmark Message" or "Couldn't Remove
Bookmark", with the readable failure and OK. Toggling again is the retry. Removing from either
list reports through the same alert.

**Opening the list.** On the Mac, Bookmarks leads the composer tray while the channel has any: a
28-high borderless button with the blue `bookmark.fill` and the count in the tray's 12-point
secondary label, with help and label "Bookmarks" and the count as its value. Bookmarks alone make
the tray visible, and the button never collapses. It opens a `.popover(arrowEdge: .top)` like the
artifacts list, with the same native glass. On the phone, a 44-point circle of
`.regular.interactive()` glass with a blue `bookmark.fill` at body size sits at the trailing
edge of the floating activity row, where Jump to Latest sits. The row shows one trailing button at
a time, so the working capsule has room for its sentence: Jump to Latest once the reader has scrolled
up, and Bookmarks otherwise, crossfading between them. It's labeled
"Bookmarks" with the count as its value and offers the large-content viewer. It opens the list
exactly as the capsule opens Working Now: `.popover` with `.presentationDetents([.medium,
.large])`, a sheet on the folded phone and an anchored popover when the Duo is unfolded. Either
button stays while its list is open, even after the last bookmark goes, so the list keeps its
anchor.

**The list.** Both lists show ChannelClient's shared list of bookmarked messages, newest first,
with no filter. Each row has the author's avatar and name, the time and a preview. The user's own
messages show "You" with a secondary `person.crop.circle.fill`, and deleted agents keep the
deleted identity. Times use `ChannelActivityTime`: 4:55 PM, Yesterday, a weekday, then a short
date. VoiceOver reads them as "today at 4:55 PM", never "Last activity". The preview is each
entry's shared `preview`, the first line of the message's plain text as the web shows it, or the
attachment count when it has no text. Previews truncate natively at the tail, with no fade.
Choosing a row closes the list and calls `interaction.reveal(sequence:)`, which pages back and
scrolls there like Input Needed.

| Part | Mac | iPhone |
| --- | --- | --- |
| Frame | "Bookmarks" in headline at a 16-point inset, then the rows. 360 wide, max 420 high, scrolling | `NavigationStack` with the inline title "Bookmarks" and a trailing Close (`role: .close`, "Close Bookmarks"), like Working Now. A plain `List` with its background hidden, so the glass shows, and native separators |
| Row | At least 48 high and 2 apart, with 8-point padding inside an 8-point inset, so avatars align with the title. A 20-point avatar, 8 points to the text. The name in 13 semibold with the time trailing in 11 secondary, and the preview in 12 secondary on one line | A 28-point avatar centered on the name's line, 12 points to the text. The name in body semibold with the time trailing in subheadline, and the preview in subheadline on up to two lines, both in `ChannelInk.secondary` |
| Highlight | One highlight that the pointer and the arrow keys share: the hover fill in a 6-point continuous rounded rectangle. The highlighted row's time becomes a Remove button, `xmark.circle.fill` in secondary, with help "Remove Bookmark" | The system's row highlight on touch |
| Remove | The highlighted row's Remove button, the Delete key or Remove Bookmark in the row's context menu | A trailing swipe to Remove, `bookmark.slash` in blue, with full swipe allowed |
| Open | Click, Return or Space | Tap |

**Mac keyboard.** The list is one keyboard target, like a menu, and takes focus when the popover
opens, with no row highlighted. Down highlights the newest row and Up the oldest. After that each
arrow moves one row, stopping at the ends and scrolling the row into view. Hovering a row moves
the highlight there, so the arrows continue from wherever the pointer left it. Return or Space
opens the highlighted row. Delete or Forward Delete removes it and moves the highlight to the next
row, or to the previous one at the end. With nothing highlighted, these keys do nothing. Escape
closes the list, and focus returns where it was. VoiceOver reads each row as one button, "Lead,
today at 4:55 PM, Where should the shared library sit…", with a Remove Bookmark action, and the
highlighted row is selected.

**States.** Opening either list calls `loadHistory(through:)` with the oldest bookmark. A row whose
message isn't loaded yet shows a static placeholder at its final size, a quaternary circle for the
avatar and two rounded bars for the name and preview, with no shimmer and no actions. If loading
fails, a footer under the placeholders reads "Couldn't load older messages" with Try Again.
Removing the last bookmark while the list is open shows "No Bookmarks" in a
`ContentUnavailableView` with `bookmark`, and the button leaves when the list closes.

### Composer and tray

The composer covers:

- An audience preview ("To Lead", or the mentioned agents) computed by a port of
  `resolveChannelAudience`
- Image attachments by paste, drag and file picker, sent inline as base64
- Sending is unavailable while disconnected, with a visible stale state, but editing isn't. A
  message the outbox can't deliver stays on its row in the transcript as Not sent, with Retry,
  and the composer never takes its text back
- Optimistic message that the committed echo replaces, drawn exactly as the echo (bubble, gap and
  day divider) so confirming changes nothing on screen. Only a send still going after 1 second
  shows a quiet "Sending"
- Send is always the plain arrow, never a spinner or retry arrow. The composer clears the moment
  the outbox records a send and stays ready. While a send is in flight, Send is disabled, Return
  does nothing and typed text is never cleared. Only connecting and dictation finishing show a spinner

**Phone input refinement.** Native input text and placeholder share 16-point horizontal and
14-point top insets, applied once. The action row has 8-point horizontal and 6-point bottom
padding, with 4 points between controls. The input grows by measurement from one to three lines.
The placeholder uses muted readable-secondary ink rather than primary draft ink and must reach
4.5:1 over actual Light/Dark glass. The static audience preview matches the Mac's capsule shape:
7-point horizontal inset and minimum-24 visual height growing with text, in the 44-point row. Its
fill is `secondarySystemFill` rather than the Mac's 8% secondary, so it reads on plain glass in
Light and Dark at least as clearly as the disabled Send background. The orange No-one state keeps
its own fill. Idle Dictate draws its `mic` in primary ink, like Attach Image, so every control in
the row reads at full contrast over bright content. Input Needed stays unfilled with the Mac's
filled orange question-circle.

At larger phone text sizes, measure the full context without truncation. If audience and
Input Needed cannot fit together, put the audience on its own row and the full wrapping
request label on a separate minimum-44 row above Attach, Dictate and Send. Neither context
row has a fixed height. Keep Input Needed's orange question-circle and text, not an icon-only
substitute. Attach uses an explicit 17-point symbol within its 44-point target, like Send,
rather than inheriting an overflowing body glyph. When the full ordinary hint cannot fit at
the actual body font, use the short visual hint "Message", preserving the native editor's
full accessibility label and any real dictation state. Do not shrink or ellipsize the hint.
Attach, Dictate and Send expose the native large-content viewer for enlarged labeled
controls on long press at large text sizes.
At short keyboard heights, let the upper context/accessory region scroll while retaining one
measured editor line and the Send row. No font caps, fixed composer height or extra glass.

Phone conversation dragging dismisses the keyboard interactively. Tapping genuinely empty
transcript space dismisses it too, without swallowing links, message controls or selection.
Keep draft, caret and undo. After an explicit dismissal, do not refocus until the user chooses
the composer or Reply. The working capsule is a minimum-44 button opening Working Now in an
anchored native popover with compact sheet adaptation: actual working agents, then a plain
rule and the waiting agents in roster order with the same rows and shared status text, 24-point
avatars, body-17 names, wrapping subheadline-15 status and 12-point row gaps. No navigation or
management action is implied by these informational rows. Status uses opaque
readable-secondary ink locally, with at least 4.5:1 contrast against the actual Light/Dark
presentation, not translucent secondary that fades into the sheet's glass.

The composer floats over the conversation in a bottom `safeAreaBar`, as one glass surface
spanning the full conversation lane from the avatars' leading edge, 16 points above the window's bottom
edge. Messages scroll beneath it. Do not add a full-width background, separator or second glass
panel behind it. The Floating composer table under Composition is
authoritative for its shape, material, edge, focus and internal metrics.

The composer and context tray form a single glass rounded rectangle, radius 18. Text is inset 12, starts at one 20-point line and grows through three lines before
scrolling internally. The controls row is 28 high, with 8 points between controls. Baseline height
is approximately 80, or 115 with the tray, and grows to three text lines before attachment
thumbnails. Attach Image
(`photo.badge.plus`, 28-point hit target) is leading, then audience, then Input Needed. Dictate
(`mic`) is trailing, 8 points before Send. Send is a
28-point circular `arrow.up` trailing button using system accent. Attach Image and Dictate show the
hover fill in their 28-point circle, and Input Needed shows it as a capsule like the tray's, its
label 6 points further from the audience so the lit capsule stays 8 clear. Send and the audience
stay unlit, and Listening keeps its accent circle with nothing on top. Empty content is sendable only
when at least one valid attachment exists.

Return sends. Shift-Return inserts a newline. Command-Return also sends. Do not submit an IME
marked-text composition or while a completion menu is consuming Return. Escape dismisses
completion or a popover without destroying text. Tab and Shift-Tab leave the composer for the
next and previous key views, like a browser text area, and Option-Tab inserts a tab. Standard selection, undo, spelling, dictation,
writing-direction and accessibility behavior must work through native text input.

**Dictation.** System Dictation already works in the composer because it is a real `NSTextView`.
The Dictation key and Edit > Start Dictation… stream words in at the caret with the system's own
indicator. That path and its menu item always stay available. The composer also has its own
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
  "Allow Toy Box to use the microphone in Privacy & Security settings. The Dictation key
  still works." It has one trailing button, "Open System Settings", which opens Privacy & Security >
  Microphone. If speech recognition is the missing permission, the title and body say "Speech
  Recognition" instead.
- **Accessibility.** VoiceOver announces "Listening" on start and "Dictation stopped" on stop. The
  live level is never announced. Full Keyboard Access reaches the button in control order.
- **Bundle.** `Info.plist` carries `NSMicrophoneUsageDescription`, "Toy Box uses the
  microphone only while you dictate a message.", and `NSSpeechRecognitionUsageDescription`,
  "Dictation is transcribed on this Mac."

Mentions remain plain `@handle` text. The completion popover anchors to the caret, opens above the
composer when needed, is 300 wide and at most 320 high, and scrolls its own list. Order: Everyone,
Lead, alphabetically matching members, then Create [Name] where canonical matching permits it.
An agent matches when what follows the @ appears in its name or handle, ignoring case, and never
in its role, since roles often name other agents. This holds on both apps. Rows are at least 44 high with 24-point avatars, name and one-line role. Up/Down select, Return or
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
delivery. Saving never holds up typing, even when the disk is busy: each change shows at once and
is written in the background, one write at a time, with only the newest draft waiting, so a burst
of keys costs one more write. A clear after sending lands after any earlier write. Quitting or
leaving the app finishes the write, and a draft only counts as saved locally once it's on disk.
Preserve attachments across channel switches. Restored attachments that are no longer
readable explicitly require reattachment, and must not appear ready to send.

Editing remains available while offline, an intentional native improvement. Send and management
mutations are unavailable until live state is established. The transcript's banner explains a
failed channel and owns its Retry, and Send's help gives the reason, so the composer adds a notice
only for a deleted channel, with its draft recovery. A stale snapshot must never determine a new
send's audience without reconnection.

Submitting creates one optimistic row, which shows "Sending" only while the send is still going
after 1 second. A committed echo replaces it by UUID. When a send fails, the row keeps its text
and attachments, its bubble's accent wash turns red, like the orange of a waiting request, and a
Retry button sits below it. Delete sits in the bubble's menu and each attachment's, so a message
with only images can be deleted too, without a wash. VoiceOver reads the message as "Not sent". Retry keeps the original UUID, so the server can't deliver it twice. Do not clear a newer
draft when an older send eventually succeeds.

The tray is a compact 34-point header inside the floating composer: a 28-point row of controls
with 3 points above and below. Lead with Bookmarks when the channel has any (see Bookmarks), then
the newest shared artifacts as borderless document actions, then `+N` for the rest. With at least
672 points left for artifacts, the three newest show, otherwise only the newest. Each is at most
230 wide and truncates in the middle. Artifacts sit 16 apart so each icon reads with its own
title, and every other control sits 12 from its neighbor, with the first and last 12 from the
glass edge. Every tray control, including `+N` and the narrow tray's Artifacts menu, shows the
hover fill as a 24-point capsule centered in the row and 6 points past its label on each side,
and the whole capsule takes clicks. Trailing controls are
Tasks with direct-root `done/total`, and Preview when set. Tasks speaks as the label "Tasks" with
the value "1 of 4 done", never the visible slash. Keep every action on the same baseline,
without a separate progress underline. Zero-content controls
are absent. When space is insufficient, collapse artifact names before hiding Tasks or Preview,
and use a native overflow menu rather than a horizontally scrolling toolbar. Bookmarks, Artifacts
and Tasks open anchored native popovers, preferred 360 wide, max 420 high. Task rows are the same projection
as the inspector. URL Preview opens the configured URL in the default browser. Screen Preview
opens the screen's live window (see Screens).

The tray is Mac only. The iPhone composer has no tray at any screen height, size class or text
size. Tasks, Artifacts and Preview live in Overview, with no separate channel bar button, and
Bookmarks open from the floating activity row.

### Overview

The Overview is an inspector in the Keynote and Xcode sense: a quiet, dense column of facts about
the selected channel, with each action sitting next to the fact it acts on. It is not a
dashboard and does not copy the pane's layout. People follow Messages' Details sidebar,
and structure follows Xcode's inspectors. Reference renders: `docs/overview-inspector.png`.

The inspector has no title row or close button. It runs the full window height, its content
starts 12 points below the toolbar's safe area and scrolls beneath the toolbar, and its
container is labeled "Overview" for accessibility. Only the narrow-window sheet shows a visible
"Overview" title, with a Done button. Do not set a nested navigation title. Use a `ScrollView`
with a zero-spacing `VStack` and 16-point horizontal insets. Order: About (untitled), Team
Members, Tasks, Artifacts, Routines. Separate sections with a native `Divider()` across the content
width, with 2 points of vertical padding. No cards, count capsules, section fills or uppercase.

**Phone Overview.** The phone Overview has a plain native background.
Section distinction comes from larger headings and deliberate space, not grouped cards.
No colored panels, glass, shadows, section fills or nested task cards. Count, diff and
disclosure share one minimum-44 heading button.
Separators appear only between rows, never below a group's final row. Navigation, swipe actions,
task guides, disclosure, retained scroll and the Tasks reveal are native.

The phone sheet's close is the system `Button(role: .close)` glass X, trailing in Overview's own
inline navigation bar with no title, labeled "Close Overview". It sits on the root and on every
pushed page and stays pinned while the content scrolls beneath it. UIKit owns its glass, size,
hit target and placement. Where the system reports a trailing vertical bar, the close joins that
column beside the status bar, as every trailing bar item does. Folded landscape stands the bar on
the leading edge, so in compact height the sheet sets `toolbarVerticalBehavior(.disabled)` and the
bar stays horizontal, with the close at the top trailing edge, clear of the list. The vertical size
class decides, never the reported edge, because a horizontal bar reports none and switching on it
would never settle. The landscape inspector
column has no close and keeps its root bar hidden, because the channel toolbar's Overview button
closes it, like the sidebar. Overview has no channel-actions menu: Follow, Edit Channel and
Delete Channel live in the channel's Channel Actions menu. The purpose starts 12 points below
the bar (or the column's safe content edge) at every text size, using the full content width,
and Folder and Preview use the full width below it. All opening information stays outside cards.
Both presentations have the Overview accessibility label, native sheet dismissal, nested task
navigation and the same content.
Overview takes the inspector column only where the conversation keeps the Mac's 420 points beside
it, which on the Duo is unfolded landscape. The column opens at its 280-point minimum and widens to
360. Folded and unfolded portrait use the
sheet, decided by the scene's width rather than its size class alone. Overview's presence is one
state the sheet and column share, so rotating, folding or unfolding never opens or closes it, and
the first tap of the Overview button after any of them toggles it. An open Overview moves between
the two, keeping its open page, disclosures and section state. The new presentation opens at its top rather than the reader's scroll position: SwiftUI's
List ignores a restored offset, and a restored top row doesn't hold through every Duo rotation and
fold. The column never writes back to Overview's presence, so the transient close SwiftUI
reports while columns reflow cannot dismiss it.
Apply the compact 16-point / regular 20-point outer rail once, with no compounded
44-point list margin. Treat purpose, folder and Preview as the headerless first section.
Use one 24-point section-gap constant from that block's last row to Team and between every
pair of sections, whether collapsed or expanded. At Large, keep 16 points from purpose to details and 4 from
heading to content. Folder and Preview stack with no gap, so their 44-point rows read as a pair.
Show More/Show Less is quiet footnote-semibold secondary text, matching the transcript's toggle,
and stays minimum 44 with no extra spacer above it. Omit absent content and its gaps.
Headings and rows grow with Dynamic Type.

On the phone, Folder is a minimum-44-point row of plain primary text, never link ink: the
`folder` icon and name, then a trailing `doc.on.doc` copy button in secondary glyph ink with a
44 x 44 target. The button copies the original full server path, briefly replaces its symbol with
a checkmark and gives success sensory feedback. VoiceOver reads the row as "Folder, {name}" and
the button as "Copy Path", valued "Copied" while the checkmark shows. A long-press context menu
on the row is titled with the full path and offers Copy Path. Do not show "Folder on Mac" or a
path row. Screen Preview has only its icon and title, with no window/display identity line.
URL previews keep their address line.
Folder and Preview symbols share monochrome rendering rather than a mixed outline/filled palette.
On the phone both symbols draw in primary foreground ink. The Preview title is About's one real
link, so it alone keeps link ink. The Mac draws both in the property rows' secondary ink.
Both sidebars and Overviews use one shared folder-name rule: `NSString.lastPathComponent`,
falling back to the original path if the component is empty, without expanding or resolving it.

Phone Team avatars are 28 points at default text size, scaling natively up to a 36-point cap.
This applies only to the phone Team row, not message, completion, task or Mac avatars.

**Section headers: names lead, facts follow.** The name is the primary anchor and its count is
quiet supporting information, never a badge or part of the name. Mac uses 13 semibold primary
and 13 regular readable secondary; phone uses native title3 20 semibold primary and
footnote 13 regular readable secondary at Large. Baseline-align name/count with a 6-point gap
and tabular digits. Set both text styles explicitly, not through inherited Form header ink.
Use package-scoped ToyBoxUI `ChannelOverviewInk.secondary(in:)`, opaque sRGB `#636366` Light /
`#AEAEB2` Dark, for header details and task metadata on both hosts. It is separate from
`ChannelInk.secondary`, Mac global secondary ink and waiting amber. Text reaches 4.5:1 against
actual native surfaces and non-text disclosure reaches 3:1.

Team Members counts the lead plus current members, not working agents. Tasks uses shared completed
roots / total roots, never descendant or visible-row counts: "Tasks 1/4", or "Tasks 0" when
there are no roots. Artifacts counts channel artifact entries; Routines counts registered
routines, not executions. Keep known zeros and local empty sentences. Never invent zeros
before loading; retain cached counts while reconnecting. Tasks' recursive `tasks.diff`
is separate change volume, not progress. Keep the shared +/− pair together in 11-point Mac /
footnote 13 phone, with its readable colors, tabular digits and 6-point pair gap. Leave at least
12 points after name/count and 8 before the disclosure lane. Nil omits the diff; measured
`+0 −0` stays. Facts update while collapsed without expanding or announcing every change.

Mac header minimum 28, not fixed height: 8 below divider, 4 to content, 12 after section.
Keep the Finder convention: trailing 10-point semibold `chevron.down` appears on hover or
keyboard focus; collapsed `chevron.right` stays visible. Reserve the 16-point lane when hidden
so nothing jumps. Phone minimum 44 with an always-visible 11-point semibold chevron and the
explicit plain-list rhythm above. Scale text and symbols with host text sizing, growing the lane as needed.
When the complete baseline row cannot fit, move the whole diff to a leading-aligned second
line, 4 points below. If name/count cannot fit together, keep name and top-trailing disclosure
first, count next, diff last. Phone accessibility sizes deliberately use this single column.
If the diff pair itself cannot fit, additions/deletions may stack within that one fact group.
Wrap a localized name if necessary; never shrink, clip or hide facts to preserve one line.

The whole header is one heading button, including count/diff. Enter/Space or accessibility
activation toggles once with 180 ms disclosure, instantly under Reduce Motion, and retains
focus. Speak natural counts and exact changes: "Team Members, 9 agents", "Tasks, 1 of 4 top-level tasks
complete, 1,522 additions, 114 deletions", or "Tasks, no tasks", with Expanded/Collapsed value.
Use proper plurals, not spoken slash or compact K/M. Symbols/values add no focus stops. The
Tasks header's in-progress filter and the Team Members header's working filter are each
their header's one extra control, described with task disclosure and Team Members. Headers
use native focus indication and Show/Hide help. Collapsed sections belong to the Mac window
scene, not channel, and to the phone's retained per-channel Overview session. Empty sections stay
with "No tasks yet", "Nothing shared yet" or "No routines".

**About.** The purpose is 13 regular primary, about 18-point line height, at most 4 lines, then
an inline "Show More" link in quiet secondary ink that expands in place ("Show Less" collapses
it), matching the transcript's toggle. Truncation leaves room for "… Show More" on the fourth
line. A missing purpose reads "Add a purpose…" in secondary and opens Edit Channel. Below it, 10 points down, come compact property
rows, each 22 high: an 18-point secondary SF Symbol column, a 6-point gap and a 12-point value.

- Folder: `folder` and the shared folder name, middle-truncated and selectable. Keep the original
  full server path in help, the accessibility value and Copy Path. When the folder is
  openable (the same rule and cached check as the sidebar's folder token), help shows the full
  path and a trailing tertiary
  `arrow.forward.circle.fill` (Xcode's reveal arrow, 4 points after the name) shows it in
  Finder. Remote and missing folders use `folder` or `questionmark.folder` in the same ink, with
  no arrow, and reuse the sidebar token's help strings as both help and VoiceOver hint, so the
  missing arrow is always explained. The context menu offers Show in Finder (when openable), Copy
  Path and Open in Toy Box. Never claim a remote path was opened. Omit the row when the channel
  has no directory.
- Preview: `play.rectangle` and the typed URL's host and path in link ink, opening the default
  browser. A screen preview reads "Window preview" and opens its live screen. Omit the row when
  there is no preview.

**Team Members.** The section is titled Team Members on both apps. The lead first, then members
alphabetically. Never reorder by presence, because stable positions are what make the list
scannable. Rows are at least 38 high with 4 points of vertical
padding: a 24-point avatar, a 10-point gap, then the name in 13 regular primary over a one-line
11-point status, 1 point apart. Status truncates at the tail with the full text in help.

Phone rows have a 38-point content minimum, a 12-point avatar/text gap, a 2-point name/status gap
and the scaled avatar capped at 36. Ordinary text sizes use explicit 12-point vertical
row insets, making each row exactly 6 points shorter than the measured 15-point system
defaults. Accessibility sizes use 13, 4 points shorter, and keep native wrapping. Snug, never
cramped: every navigation target remains at least 44 points high.
Phone Add Agent uses the same 38-point content minimum and vertical spacing, matching a member
row's height exactly at default text size. Its 12-point ordinary / 13-point accessibility
padding belongs inside the button, with zero native vertical row insets, so the whole row is
tappable and its accessible target spans that height. Its label grows and wraps without clipping.

| Presence | Status line | Trailing |
| --- | --- | --- |
| Working | Presence text, or "Working", in primary at 85%, after a 9-point heavy `ellipsis` in the agent's color, 4 points before the text. This is Messages' typing cue | Nothing |
| Waiting | A static 9-point heavy `pause.fill` in a 12-point cue lane, then a 4-point gap and the reason in secondary, such as "Waiting for Moss's review". Center the glyph on the status font's cap height, not its line box, within 0.5 points on Mac. Tint only the glyph `#9A6700` in Light and `#F4BE66` in Dark, shared with iPhone | With a valid wake time, a leading `bell`, 4-point gap and "8m" in 11 secondary tabular digits, updated at minute boundaries, help "Checks again at 9:32 AM". "Due" once it passes |
| Idle | "Idle" in secondary | Nothing |

Both apps share status copy and spoken state. Missing live presence reads "Status unavailable".
A stale or deleted channel reads "Status unavailable while disconnected". Neither keeps an
activity cue. A channel that is connecting or reconnecting keeps its last presence, so coming
back to the app doesn't blink every status.
Both also read the status-text ink rule from `ChannelAgentStatusPresentation`: working uses
primary foreground ink at 85%, while waiting, idle and unavailable remain muted. The phone
must not render working text in the same secondary ink as waiting. Keep cue colors separate
from this text rule. Muted status and countdown use `ChannelInk.secondary`: opaque `#636366`
Light / `#AEAEB2` Dark on the phone, and the semantic secondary on the Mac.

Both apps show the waiting check-in in the member's row, never a separate metadata line. On the
Mac it sits trailing and the hover menu replaces it. Phone places the bell and duration at the
row's trailing edge, in muted footnote text. Show this only for waiting presence
with a valid `wakeAt` on a channel that isn't stale or deleted; omit it for working, idle,
unavailable or absent/invalid wake times. A single ToyBoxUI view owns both the countdown and its
localized text, rounding the remaining duration up and showing Due once it passes. Phone updates
only at minute boundaries while its row is visible. Keep the bell/value group together and trailing
even when phone name/status wrap at accessibility sizes. Add no row height at default text. Both
rows speak "checks again in 8 minutes" or "check-in due". About's Checks again and Mac help show the
exact date. The bell is decorative, not a second button. It means time until the next check-in,
unlike the task clock's elapsed time. No activity or progress is inferred.

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
target, replaces the trailing countdown. It offers Reply to [Name], About [Name], Edit Agent… and
Remove Agent…. The lead offers Reply and About only, because its identity is intrinsic. The
context menu has the same items. Add Agent… ends the list in a 36-point row: a 24-point dashed
tertiary circle with an 11-point `plus`, and the label in 13 regular secondary. It opens Add
Agent.

Phone Team rows are also one button, with no chevron, and their tap and the context menu's
About [Name] open the same About content. When the window has a regular width it's a popover
from the row, opening toward the conversation in the landscape column and above or below the row
in the unfolded sheet, dismissed by tapping outside or the VoiceOver escape. The window decides,
not the Overview sheet's own compact width, because UIKit adapts the popover to the window. It's
320 points wide with 20-point padding and bounds a long role at 210 points, scaled with body text.
A compact window adapts it to a sheet sized to its content, with the drag indicator and a close
button labelled "Close About [Name]". Content taller than about half the Overview it rises over
offers the medium and large detents instead. The sheet fills its width, never bounds the role and
scrolls as one. Below the header ("Name" over "Lead · @handle" or "@handle"), a trailing-keyed
grid shows Status, Checks again (the time alone today, otherwise the abbreviated date and time)
and Model: "name · provider", selectable, then "[effort] reasoning" in secondary with Edit
Agent's labels, or "Workspace default". At accessibility sizes the header stacks, the role is
unbounded, each key sits above its value, and the popover takes the system's width and scrolls
as one. VoiceOver reads the header as "Name, Lead, @handle" and each fact as one element. It
updates live and never shows private session contents.

**Working filter.** Team Members has the Tasks header's filter toggle, with the same glyph, ink,
placement after the count, targets and focus behavior, so the user can see only who's working.
Its label and Mac help read "Show Only Working Agents". While it's on, the list keeps exactly the
agents whose row shows the working cue, the lead included, in their usual order. ToyBoxUI owns
this rule, so the filter and the cue never disagree. Rows keep their slots, so toggling never
moves one. Add Agent stays. The count still describes the whole team. With nobody working, the
section shows "No agents working" in the empty-sentence style. While the channel is unavailable
no row shows the working cue, so the list is empty and reads "Status unavailable while
disconnected" instead, the rows' own offline status, never a guess from stale presence. Show
the toggle whenever the channel has an agent. It starts off and keeps the same scope as the Tasks filter.

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

Expanded inline child groups on both Mac and phone have a native separator-colored ancestry
guide in the indent gutter at the parent's status-column center. Phone uses the native
list rule's 1-point weight. Mac also uses 1 point, matching its native `Divider()`. Keep both edges
pixel-aligned at the nearest centered position. It spans that child group's bounds with 4-point
clearance at each end. Nested expanded
groups add their own guide. No horizontal elbows, root-level rule, extra indent or title-width
loss. Collapsing removes it with the children. Do not draw a dangling guide to a phone
"View N subtasks" link; its scoped list starts a fresh local tree. Guides never hit-test or
enter accessibility. The shared Mac Tasks popover draws the same guides. Guides change no
disclosure, hierarchy or row-action semantics.

**Phone task disclosure.** Every visible task and scoped-subtasks link is its own native List
row, with stable depth-first identities. Task and scoped rows inherit the same native surface
as Team in Light, Dark, the elevated sheet, the inspector and the pressed state. Never add an
opaque task-only background. Both user-triggered and status-driven task disclosure change
immediately, without a fade, at every text size and under Reduce Motion in the root and scoped
lists. Following-section text must not pass through task rows. Do not stage a second content
fade, animate the whole list by its visible IDs or add a separate animated height transition.
One shared phone motion policy owns this. Section headers follow their own disclosure rule
above. Adjacent row guide segments join continuously, with 4-point clearance only at the whole
child group's ends.

At ordinary phone text sizes, task headings use 11-point top and bottom padding. When the task
has its own artifact action, the heading has no bottom padding, the artifact line keeps its own
top gap (see the task's artifact below) and 11 points follow that line. At accessibility sizes
the outer padding is 12 points. Root groups are 8 points apart, and every target is at least
44 points.
"View N subtasks" adds no vertical padding beyond its 44-point minimum and uses only the native
navigation indicator, like Team. It has no handmade chevron; the title-inline task disclosure
remains separate. These padding rules apply only to the phone.

A parent's disclosure trails its title inline, as macOS sidebar section headers and the pane do.
Build the first line as one wrapping `Text`: the title, then two spaces and the progress count
for every parent, whatever its status (11 regular, monospaced digits, secondary, "3/4"), then one space and the
chevron as a text image (`chevron.right` collapsed, `chevron.down` expanded, 9 bold, secondary).
The chevron ends the title's last line and wraps with it, never orphaned on a line of its own
when the title fits. The whole parent row is the click target, so the chevron needs no
separate hit area. Pending and done parents keep the count too, so a collapsed parent still
says how many subtasks it holds: "0/3" and "3/3". Its spoken "N of M subtasks done" and the
phone's scoped subtask header follow the same rule. Leaf rows have neither.

A parent's disclosure follows its work in progress: a parent starts expanded only while it or
any descendant is in progress. Every other parent, pending, blocked or done, starts collapsed to
its title, chevron and facts, so the list leads with what's moving. ChannelKit owns this test,
the same one the in-progress filter uses. When a parent gains or loses work in progress, its
disclosure re-derives: it expands or collapses with the 0.18-second ease-in-out disclosure
animation (instant under Reduce Motion). A user's toggle holds until that parent's next such
change, not merely its next status change. This departs from the pane, which collapses only
done parents. The same rule applies on the phone and in the Composer's Tasks popover, which
shares these rows.

**In-progress filter.** Like the pane, Tasks can show only the work that's moving. A filter
toggle sits in the Tasks header on both apps, right after the count, because it changes the list
the count describes. The gap after the count matches the gap between the title and the count,
and the glyph is vertically centered on the count's digits. It's `line.3.horizontal.decrease`, the Message View glyph, in secondary ink while off and
system blue while on. It's a sibling of the heading button, never inside it, so pressing it never
collapses the section. It's its own focus stop with toggle semantics: label "Show Only
In-Progress Tasks", value on or off, and the same text as Mac help. Mac uses an 11-point medium
glyph in a 24-point target. The phone uses a 44-point target, and keeps the glyph with the count
when the header stacks while the chevron stays at the top-trailing edge. Neither target takes taps
meant for the count. Show it whenever the channel has a task, collapsed or
not, and omit it when Tasks is empty. It starts off and keeps the collapsed sections' scope: the
Mac window scene, and the phone's retained per-channel Overview session.

While it's on, each level of the tree keeps only the tasks that hold work in progress, the same
ChannelKit test as disclosure. ChannelKit owns this filtering. Every kept task renders from its
full value, never a pruned copy, so its x/y count, spoken subtask count, diff and timing still
describe all of its children. A kept parent with no kept children shows its count without a
chevron, since it has nothing to disclose. Toggling the filter leaves every parent's disclosure
alone. The header's count and diff always describe the whole channel. With nothing in progress,
the section shows "No tasks in progress" in the empty-sentence style. On the phone, a "View N
subtasks" link and its scoped list apply the same filter, and N counts what that list shows.
The Composer's Tasks popover has no header and always shows every task.

Rows have 5 points of vertical padding. The first line is the title (13 regular, wrapping, done
titles in secondary, never struck through) with the owner's 16-point avatar at the trailing
edge, centered on the first line and at least 8 points from the title.

**Task facts have a dedicated home.** Start metadata 6 points below the final title/progress
line, aligned with the title and extending to the row's trailing edge under the avatar column,
not merely its narrower title allocation. At ordinary sizes, elapsed/check-in sit leading and
the recursive diff sits trailing, sharing the first baseline. Diff trailing edges align down
the list, including indented children. Use 11 regular Mac / native footnote 13 phone, scoped
readable Overview ink, tabular digits, 4 points between timing symbol/value, 12 between time
labels, at least 16 between times/diff and the shared 6-point diff gap. Keep each timing symbol
and complete value as one title-and-icon label. No icon-only fallback or reserved empty slot.

Measure the groups against actual lane width. If times + 16 + diff will not fit, times get the
full lane and the complete diff moves to a trailing-aligned next line, 4 points below. If time
labels cannot fit together, stack them leading. At phone accessibility sizes, use a single
leading column: elapsed, check-in, then diff, 4 points apart. If the diff pair itself cannot
fit, additions and deletions can use successive lines. Never squeeze text, clip values,
horizontally scroll or reserve a fixed blank metadata box. Pending omits row diff; measured zero
("+0 −0") is distinct from absent. The header count is done over
total for direct roots, exactly as the pane, written "9/12" like the composer's Tasks button
rather than "9 of 12". Visible counts use the compact slash form, and spoken values keep "of".
Completion attention
still requires every descendant to be done. Aggregate diffs recursively without double
counting, and keep exact accessible values: "Build the workshop, in progress, 1 of 2 subtasks
done, 1,522 additions, 114 deletions, owner Pixel", with Open Artifact and Expand or Collapse
actions. A parent row is a button whose value is "Expanded" or "Collapsed" and whose press
toggles it, so VoiceOver reads "Build the workshop, …, collapsed, button". A leaf row is static
text. Neither may surface as an unknown element, matching the routine rows.

The task's own artifact is a separate line on both hosts. It is an action, not another statistic. Place it 4 points
after metadata, or 6 below the title when no metadata exists, aligned to the title. Keep
`doc.text` and full wrapping title 6 points apart in one leading-aligned group. Use a growing
minimum-24 Mac target with 12-point title and native link ink. Phone uses a minimum-44 target,
native footnote 13 and explicit primary label ink for readable text under native action tint.
Top-align the phone label within that growing target. No stretched icon/title gap or centered
title. Keep the action outside the parent toggle target: opening never toggles, toggling never
opens. Speak "Open [artifact title]" and open it through the same reader route as Artifacts. No
reference means no empty artifact lane; a missing reference keeps disabled "Artifact unavailable" in
tertiary label ink on both hosts, never a descendant's file. These row rules also apply to Mac's
shared Tasks popover.

Tasks with a valid server-owned `startedAt` show elapsed in the metadata lane:
a small `clock` before "1h 26m", with monospaced digits. Use "59m" below an hour,
"1h" at an exact hour, and keep hours beyond 24. An in-progress task with a valid `checkInAt`
adds a `bell` before its remaining time. At zero keep "0m", without warning
color. Hover spells out "Elapsed: 1 hour 26 minutes", "Check-in in 31 minutes" or "Check-in
due". Elapsed time rounds down and remaining time rounds up, both clamped at zero. The
measured lane reflow above never drops the diff or the separate artifact line. Shared
`ChannelTaskTimingPresentation` owns this arithmetic, and agent wake times follow the Team
Members rules. Update once a minute only while the timed row
is visible. VoiceOver uses expanded units, with no live announcements. These rules apply
to the shared tray rows too.

**Artifacts.** Mac rows are at least 40 high: a 28-point native Finder file icon, a 10-point gap, the title
in 13 regular on one line, and an 11-point secondary line, "Kit · 3 hr. ago", with the full date
in help. Format the time with `RelativeDateTimeFormatter`, `.named` and `.short` ("3 hr. ago",
"yesterday"). The sharer is the actor of the latest matching `artifact_shared` event. Until
that event is loaded, show the localized type ("Markdown") instead. Sort by `sharedAt` newest
first, with undated items last and existing order preserved for equal dates. The tray is also
newest-first. Clicking opens the artifact, and Space on a focused row shows Quick
Look. The context menu offers Open Artifact, Show in Transcript (reveals the share event) and
Copy Link, without Quick Look, which Space already gives. A `…` menu on the row offers the same actions, with Remove from Channel after a divider.
Remove from Channel is destructive and has no confirmation. It sends `removeArtifact` once and
disables the row while the request is in flight, with a spinner and "Removing from channel". It never
removes the row optimistically. The row leaves when the server's `artifact_removed` event arrives. A
rejected request shows its error inline. After a 500, timeout or lost connection, the row shows that
the removal is unconfirmed, checks the server with `reconcileManagementWrite`, and offers no new attempt
until the check finishes. Markdown, HTML, SVG and image artifacts open the in-window artifact viewer below,
not a reader sheet. Other types use Quick Look and the default application. Show actual
fetching and error states, and never open a blank success-shaped reader. Load content from the
server resource URL, never by assuming the file is local.

Mac Overview and the artifact pager use Finder-provided, file-type-specific icons, never the
phone's monochrome symbols.
The phone Overview list uses one pure file-type-to-SF-Symbol mapping: Markdown and unknown
types use `doc.text`, HTML uses `chevron.left.forwardslash.chevron.right`, SVG uses
`square.on.circle`, and raster images use `photo`. Use the same mapping in phone artifact-viewer
pager tiles so a file's symbol matches its list entry. Classify SVG before generic images using
`ArtifactContentKind`. Every phone symbol fits the 24-point icon lane at the `doc.text` symbol's
visual size. Bound wider HTML and SVG artwork to that footprint without stretching its aspect ratio,
enlarging the column or adopting the Mac's 28-point size. Phone artifact rows match Team's compact
two-line rhythm: body title and footnote date, 4-point title/date gap, 24-point icon lane and
12-point icon/text gap. Team's name/status gap is 2 points. There is no 64-point content minimum.
Add exactly 6 points of native vertical row inset above and below the minimum-44 label, for both
short and two-line titles. Rows keep readable content and the full target and are never squeezed to
60. Rows grow for wrapping or larger text. Phone artifact rows also offer a trailing swipe labelled
"Remove", hidden under VoiceOver. Swiping all the way across removes the artifact without tapping
the button, like Mail. Team and Routines swipes keep full swipe off. The row stays in place with its
"Removing from channel" spinner until the server's event arrives, so a full swipe must not animate
it away and bring it back. Its context menu and accessibility action say "Remove from Channel". All
three use the same rules as Mac: no confirmation, one request, no optimistic removal, and
unconfirmed results are checked before another attempt. This is the Artifacts section, not the
separate task-artifact link.

**Routines.** Rows share the artifact geometry: a 28-point icon cell with a 15-point secondary
`calendar.badge.clock`, the title in 13 regular, and the schedule in words in 11 secondary:
"Weekdays at 9:00 AM", "Every day at 9:00 AM", "Mondays at 9:00 AM" or "Every hour". Anything
else shows the literal cron expression. Core provides this summary next to its cron parser. The
disclosure trails the title inline, as for task parents: one wrapping `Text` with the title, a
non-breaking space and the 9-point bold secondary `chevron.right` or `chevron.down` text image,
so "Daily review ›" never orphans its chevron. Nothing hangs in the leading inset, and the whole
row toggles it. Expanded content is indented 38
points to the title: only the prompt in 12 regular primary, selectable. The schedule line
already says when the routine runs, so the details repeat neither a next run date nor the raw
cron expression. The schedule line's hover tooltip names the cron expression after its summary,
or alone when it has no summary. VoiceOver hears "Shows the prompt" or "Hides the prompt" as
the row's hint. A hover or focus `ellipsis.circle` menu and the
context menu offer Run Now and Delete Routine…. Run disables while pending and shows "Run
requested" in place of the schedule line for 4 seconds, never as a synthetic transcript post.
Delete has a native confirmation that names the routine. The user does not create or edit
routines here, matching the pane.

Phone routine rows match the phone artifact rows: `calendar.badge.clock` in the same 24-point
icon lane, primary ink and 12-point icon/text gap, so routine and artifact titles share one
leading edge. The body title and footnote schedule line sit 4 points apart in a minimum-44 label
with exactly 6 points of native vertical row inset, growing for wrapping or larger text, with no
64-point minimum. The disclosure trails the title inline, as for phone task parents: one wrapping
`Text` with the title, two non-breaking spaces and the footnote-semibold secondary
`chevron.right` or `chevron.down`, never a stock `DisclosureGroup` or trailing accessory. The
whole row is one plain button that toggles immediately, without a fade, and keeps its expansion
for the Overview session. Expanded content is only the selectable prompt, indented to the title.
Like the Mac, it repeats neither a next run date nor the raw cron expression, which the schedule
line already shows when it has no summary. The final row hides only the section's last separator.
Run Now and Delete Routine live on the row itself, as Team's actions do, never as buttons in the
expanded content. Swiping right reveals Run Now (`play`) in the accent color, and swiping left
reveals only a destructive Delete (`trash`), as Mail keeps its main action on the leading edge and
Delete alone on the trailing edge. Neither fires on a full swipe, because a run can't be undone,
and the long-press menu offers Run Now and Delete Routine. Run Now is
unavailable while a run is pending, while disconnected or while a recovery check blocks writes.
Delete is unavailable while a run is pending or while disconnected. VoiceOver reads the title as
the label, the schedule line then "Expanded" or "Collapsed" as the value, "Shows the prompt" or
"Hides the prompt" as the hint, with Expand or Collapse, Run Now and Delete Routine as actions.
Under VoiceOver the swipe actions are hidden, so nothing is offered twice.

### Artifact viewer

Shared work deserves the same direct, in-window treatment as an image, not a dialog around a
document. Every artifact entry point uses `ArtifactOpener.open`: inspector rows, the composer
tray, task links and transcript share events all open the same viewer. The person remains in
their channel and can move between its artifacts without closing and reopening files.
`docs/artifact-viewer.svg` is the layout wireframe, not evidence of native materials.

| Part | Specification |
| --- | --- |
| Presentation | Replace the conversation with one viewer in the detail column, as the image gallery does. Overview stays beside it in its own column, visible and usable, with its width and visibility unchanged. The source-list sidebar stays visible and usable. Keep the underlying transcript and composer draft mounted and unchanged. No sheet, floating window, second sidebar or browser address bar |
| Toolbar | Native window toolbar, not a custom header. Leading Back uses `chevron.backward`, help "Back to Conversation". The title is the artifact title over its subtitle, each one line with tail truncation. Subtitle is "Markdown · 2 of 5", "HTML · 3 of 5", "SVG · 4 of 5" or the localized file type. Omit position for one artifact. On the Mac, Back has its own glass and the title follows as a second glass capsule that opens the title menu, 13 semibold over 11-point secondary text, with full title and path in help. The window shows no system title while viewing. Trailing on the Mac: Reload (`arrow.clockwise`) and Share (`square.and.arrow.up`), and the title yields before them down to 760 x 560. The iPhone centers the title, with Share and More (`ellipsis`) trailing. Message View and Find step aside until closing. Overview's toggle stays with Overview's column |
| Canvas | Full bleed under the toolbar. The top scroll edge is the native soft one on the Mac, matching the conversation and Overview, and the native hard one on the iPhone. Markdown adds the native soft bottom edge. HTML uses only the top edge, without an artificial bottom band or fade. Images and SVG use `underPageBackgroundColor`. Markdown has a flat `textBackgroundColor` reading surface, without a boxed paper card, border or shadow. HTML retains its authored background inside the native frame. Do not recolor an artifact's artwork or HTML to imitate dark mode |
| Navigation capsule | Only with two or more artifacts. Center horizontally, 16 points above the detail's bottom edge. Reuse the image gallery's regular interactive glass capsule, 8-point padding, 28 x 28 Previous/Next targets, 32-point preview cells, 6-point gaps and 6-point corners. Native Finder icons represent Markdown, HTML and unsupported types. Images and SVG use safely decoded thumbnails when available, otherwise their Finder icon. The current cell has the gallery's 2-point accent ring. Full titles appear in help and accessibility, not tiny filenames beneath every cell |
| Order and identity | Use the inspector's channel artifact list, newest first, including unsupported types. Previous goes toward newer artifacts and Next toward older ones. Disable at either end, without wrapping. Past nine cells the strip scrolls and keeps the selected one visible. Track selection by server, channel and artifact ID, never its list index. Arrivals and metadata changes may update the list or count but never change the displayed artifact |
| Content clearance | Markdown and HTML can scroll their final content fully above the capsule, leaving at least 16 points of clear space. Images and SVG fit within 24-point side margins, 16 points below the toolbar and 16 above the capsule. Without a capsule, retain a 24-point bottom margin. At 760 x 560, the reading surface and navigation still work, and long titles yield before toolbar actions |
| Actions | Share uses the original artifact resource, not a screenshot or sandbox wrapper. The Mac's title menu holds every action: Open in Toy Box, Reload and Copy Link, then Quick Look and Open in Default Application, then Show in Transcript. Reload stays in the toolbar as well. The iPhone's More leads with Open in Toy Box, Reload and Copy Link. Keep Quick Look and Open in the default application available for supported files. Show in Transcript is available when the share event is known and closes the viewer before using the transcript's reveal path. Failed actions show an explicit, actionable error without discarding the displayed artifact |
| Transition and return | Open and close with a 0.2-second crossfade, not a zoom from a document icon. Paging crossfades with the gallery's 40-point directional slide. Reduce Motion uses crossfade only. Closing returns to the exact channel reading position and draft. Overview's column stays as it was. A narrow Overview sheet dismisses before opening and is not automatically reopened on close. Return keyboard focus to the invoking artifact control when it still exists, otherwise its owning section or the Overview toolbar button |

#### Each kind keeps its own strengths

| Content | Behavior |
| --- | --- |
| Markdown | Render natively with the transcript's shared `TranscriptMarkdown`, selectable text, normal links, code and tables. Mac uses a centered text lane at most 720 points wide, at least 24-point side insets and 32-point top padding. Match each platform's transcript body, code and line spacing, following its Text Size setting (Mac: 14-point body, 12-point code, 3-point additional line spacing; iPhone: its scaled transcript body metric and no additional line spacing). Keep the existing 10-point gaps between blocks, scaled with the text, with 8 extra scaled points before H1/H2 only when another block precedes them. H1/H2 have a native rule inside the heading; list markers use secondary ink. The first and last blocks add no outer spacing, including a `---` divider, whose fixed 4-point insets belong in its neighboring gaps. Keep wrapped list-item lines inside the item; join soft source-wrapped lines into continuous prose only in files, preserving explicit hard breaks and transcript message line breaks. Do not display source syntax or put prose inside a web view. Keep document scroll position when revisiting it during this viewer visit |
| HTML | Display the authored page as the root `WKWebView` document, not an iframe. Extend its background beneath the native bars while its unobscured viewport excludes the toolbar and floating capsule, preserving responsive layout, `100vh` and fixed headers. Use the platform's native top scroll edge, as Canvas describes. The capsule floats over HTML without a bottom soft edge, but final content still clears it by at least 16 points. Preserve in-page forms and interactions; forms that navigate and other replacement-document navigation remain blocked. Use a non-persistent data store and the reference pane's CSP sandbox with scripts, forms, modals, popups and user-activated external navigation, but no same-origin permission. Its origin is opaque, and it must have no Toy Box server cookies, API access or privileged host bridge. Relative resources resolve from the artifact's directory. User-activated links and new-window requests open in the default browser, never replace the Toy Box channel. Leave ordinary text input, selection and scrolling with the web view. Restore its reading position when revisiting it during this viewer visit |
| SVG | Mac uses the shared `TranscriptSVGImage` bounded native decoder, not a web renderer. It decodes off the main thread and rerasterizes at display size. The phone-only `ArtifactImageDecoder` adapter uses script-disabled, nonpersistent WebKit to export a local PDF from an inert SVG image, then CoreGraphics to produce a bounded bitmap for the native canvas. Block every non-data request; no web view is presented. Both hosts apply the 8192-pixel cap, fit without cropping and intrinsic logical dimensions: large drawings fit down and small icons stay at natural point size. Preserve transparency, magnification and pan. Never execute scripts or request external resources to display a drawing. This is a viewing surface, not an SVG editor |
| Raster images | Use the native image rendering and zoom/pan behavior of the image gallery, including Live Text when available. Changing artifacts resets image zoom as changing gallery images does. Do not fabricate a transcript message to represent an artifact |
| Other files | Keep the artifact title, type and gallery position visible. Center the real file icon, a short explanation, Quick Look and Open in the default application. Unsupported content is an honest fallback, not a failed Markdown page. Quick Look may use its normal system panel |

Same-document anchors stay inside the artifact. The HTML policy follows
`src/shared/embeddedHtml.ts` in the reference. Its current permissions
are downloads, forms, modals, popups, scripts and top navigation by user activation, deliberately
without `allow-same-origin`. The native implementation must establish the equivalent boundary,
not merely use a private cookie jar. The trusted loader may fetch the artifact and approved
relative resources; the embedded page cannot use that loader as arbitrary server API access.
Block privileged URL schemes. Do not add a JavaScript bridge into the app. Stop a web renderer's
work when paging away or closing, rather than keeping hidden interactive pages running.
Serve the immutable root HTML through a private document scheme with the CSP sandbox on the
response itself. Block replacement documents so navigation cannot discard that sandbox.
Capture and restore reading offsets in an isolated JavaScript world, without exposing an
authored-page bridge or depending on the page's JavaScript globals.

#### Keyboard, accessibility and state

Back and Escape close the viewer. Escape first dismisses an active native popover or dialog.
Left and Right page when the viewer or strip owns keyboard focus, but never intercept text
selection, caret movement, form controls or a web page's own interaction. Space belongs to the
focused control or scrollable document, not a universal artifact-dismiss shortcut. This is an
intentional difference from the image-only gallery because an artifact may be interactive.
Native Markdown supports normal scrolling and selection keys; image/SVG zoom commands apply
only to those renderers. The content remains read-only unless the artifact itself is an
interactive HTML page. Editing the original file stays in Open in Toy Box.

Expose one modal viewer region within the channel window. The sidebar and Overview remain
available, but the covered transcript is absent from the accessibility tree. Focus first moves
to the artifact title or document, announced as "[Title], [Type], artifact 2 of 5". Name controls
"Back to Conversation", "Previous Artifact", "Next Artifact" and "[Title], selected, 2 of 5".
Use native document and web accessibility rather than one flattened text label. Loading and
failure announcements are polite and occur once, not on every layout pass.

| State | Required result |
| --- | --- |
| Loading | Show the final-size viewer and title immediately. A mini spinner with "Loading artifact…" appears after 300 ms. Keep Back, the strip and available navigation working. Cancel obsolete loads so a late response cannot replace the newly selected artifact |
| Load failure | Center `doc.badge.ellipsis`, "Couldn't Load Artifact", the actual useful error and Retry. Keep the selected cell, title and neighbor navigation. Never turn failure into an empty document |
| Missing or removed artifact | "Artifact Unavailable" and "This artifact is no longer available." Keep Back and other artifacts available. Do not silently substitute a neighbor |
| No artifacts | `doc`, "No Artifacts Yet", "Files shared by this team will appear here." No empty capsule or enabled paging arrows |
| Offline | Keep already loaded content visible. A fetch that cannot complete shows the connection error and Retry rather than a false empty state |
| Channel/server change | Close the viewer without animation and cancel its loads. A deleted channel returns to the normal deleted-channel state. Do not retain another server's files, gallery or web state |

Opening, rendering, paging and closing never post messages, answer requests or mark underlying
messages read. Do not restore a viewer on app relaunch. One viewer per channel window is active
at a time; opening an attachment image replaces an artifact viewer and vice versa, without a
stack of hidden viewers. Overview owns the artifact presentation, loaders and renderers.
The image gallery is Transcript's surface.

### Screens

A channel's preview can be a window or display on the Mac running Toy Box. The apps watch it live,
the same picture a browser pane shows, and can take control of it like the browser pane.

| Part | Specification |
| --- | --- |
| Opening | Mac: File > Open Screen… (`Cmd-O`), or Open Screen at the end of the sidebar's connection footer, opens a new Screens window on the list, disabled without a server. iPhone: Screens (`display`) after New Channel in the sidebar's top bar opens a sheet. On both, the list's title is one glass button with no chevron, reading "Screens" over the server's name in secondary text, or just "Screens" with one server. The Mac's is the artifact viewer's title capsule, leading in the toolbar, and the window shows no system title. The iPhone's floats leading over the list under the system's soft scroll edge, in the same slot as a channel's title. It always opens a menu that starts with Refresh (`arrow.clockwise`) and a divider. With several servers, the menu then lists them in Settings' order with the current one checked, then Add Server (`plus`). With one server, Add Server follows Refresh directly. Add Server opens Settings' Add Server sheet over the Mac's window, or its Add Server page inside the phone's sheet, and once that server connects, the list switches to it. A channel's screen preview opens its screen directly from the tray's Preview, Overview's Preview row and the transcript's "Preview updated Screen preview" line |
| List | Shared by both apps. Displays, then windows in an adaptive grid of 16:10 thumbnails, each titled with its application beneath and decoded at its card's pixel width. Search matches a window's title and application as one string, so one query can span both. On iPhone, scrolling the results dismisses the keyboard and keeps the query, so the floating search field never covers the last match. Loading, failure with Try Again and "No windows found" are explicit. Refresh, in the title menu on both apps, with `Cmd-R` on the Mac and pull to refresh on iPhone, refetches the list and every thumbnail, keeping each old picture until its new one is decoded. It's disabled while a load is in flight, and the Mac's is hidden on an open screen. The toolbar has no separate Refresh button. Nothing polls |
| Viewer | Mac: the chosen screen replaces the list in its Screens window, and Back returns to the list. The window keeps its screen across relaunch, a restored screen that is gone shows Ended, and opening a screen a window already shows brings that window forward. Each Screens window keeps its own server, starting on the selected channel's. Its title menu picks another server (see Opening). Changing that server's address or removing it closes the window. iPhone: a full-screen cover with Close. The screen pinches to zoom up to 8× and pans like a photo, centered while smaller than the viewer. A pinch stops at 1× and 8× rather than springing back, and panning, new frames, a pause or a reconnect keep its zoom and position. Its bar never minimizes, since that would resize the screen with every pan. A new size, from a rotation, keeps the zoom and the point at the center of the view, and a side of the view against the picture's edge stays against it, so at 1× the screen simply fits again. Closing returns to where it opened, the list or Overview, which stays in place under it through a rotation. Opening a channel from a notification, the widget or Handoff closes Screens and Settings, and a channel they cover isn't marked read |
| Control | A Take Control toggle (`hand.point.up.left`), trailing in the viewer's toolbar, enabled only while the screen is live, takes control of the host, and turning it off releases control. It's the Mac's primary action, and sits before Close on iPhone. In control it shows `hand.point.up.left.fill` as a prominent glass button. That's the one sign of control, so the picture draws no ring. It follows the server's `hasControl`, which is true for one viewer across every screen, so another viewer taking control of any screen, a pause, an end or a reconnect turns it off, and control is never restored on its own. A server `error`, like a failed take or input after the window's app lost focus, releases control and shows nothing more, so the toggle turns off and taking control again retries. In control, a press, drag, click or scroll lands where it's made on the picture, mapped through the fitted and zoomed frame, and anything off the frame sends nothing. Mac: the mouse hovers, clicks with any of its three buttons and drags on the host, the scroll wheel and trackpad scroll it, and while the screen has keyboard focus, every key goes to the host by its code, down and up, including Command shortcuts, except Command-V, which sends your clipboard as text. The window losing key status releases control, so no key or button stays down. iPhone: one finger drives the host. A touch waits for lift, 10 points of movement or 150 ms before pressing, so a tap clicks where it lifts and a drag presses where it began. A second finger before then pinches and pans the screen locally until every finger lifts, and after it, extra fingers are ignored. A cancelled waiting touch sends nothing, and a cancelled press releases it. While in control, a Keyboard button (`keyboard`) leading the toggle shows the keyboard. It slides over the picture without moving or resizing it, and adds just enough room to pan the picture's bottom edge above it with two fingers, so nothing shifts while you type. Its typing goes out as text, its Delete and Return as keys, and a hardware keyboard's keys by code. Going to the background closes the socket, which releases control. VoiceOver reads the toggle as Take Control or Release Control |
| Picture | Fitted to the viewer with the window's rounded corners. Frames are sized to the viewer's pixels, sent once a live resize or pinch settles. Connecting shows until the first frame is drawn. Paused and Ended show the server's reason, and Ended offers Try Again |
| Lifecycle | One socket per visible viewer and none otherwise. A Mac window closes its socket on Back and while occluded or minimized, and the iPhone viewer while the app is inactive. A lost socket clears the picture and reconnects after 250 ms, doubling to 4 s until the server answers. An ended screen stays closed until Try Again |

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

**Phone channel forms.** Neither New Channel nor Edit Channel shows
a Folder/Working directory field. Phone creation omits the directory from its request and
creates a discussion-only channel. Editing must preserve any existing server directory
without exposing or writing it. New Channel's Name row has a visible "Name" label aligned like
Lead model, with "Required" as the field prompt. Purpose, model/options, validation, focus,
cancellation and write recovery follow the shared rules in this section. Neither channel form
shows an explanatory introduction. Edit Channel also omits its
subtitle on the Mac.

**Phone member forms.** Add Agent matches New Channel. Its Name row
has a visible "Name" label with "Required" as the field prompt, and the unlabeled Role field asks
"What is this agent's role in the channel?". Neither Add Agent nor Edit Agent shows a note above
the form, so the onboarding and "Member of" lines stay Mac-only. The identity footer reads
"Names are unique in this channel.", led by the live handle once there's a name. Add Agent's
confirm is the system checkmark (see Phone sheet semantics). Role's height, the model,
validation, focus, cancellation and write recovery follow the shared rules in this section. The
Mac sheets have subtitles, a role prompt and an Add Agent button.

New Channel, Edit Channel, Add Agent and Edit Agent share one sheet language:

- **Size.** 480 wide. The sheet fits its content, with no empty band above the buttons and no
  inner scroll view until it reaches the window's height. Initial focus is Name.
- **Header.** 20-point insets. A 40-point identity mark, 12 points, then a 15-point semibold title
  over one 12-point secondary line when the sheet has a subtitle. Edit Channel has only its
  title, vertically centered beside the mark with no empty subtitle line. No divider follows
  the header. Channel sheets use the
  channel's avatar at 40 points, and Create Channel the cyan `#` fallback (19-point semibold
  glyph). Edit Agent uses the agent's
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
  reason. A catalog 404 instead shows "Not Available" without Retry. The global catalog's footer
  explains that models aren't available on this server; a member catalog keeps the server's
  missing-resource details visible. Existing current-model and inheritance choices stay usable.
  Don't stack a warning, a message and a Reload button under the picker. A member's first choice
  reads "Workspace Default (Model Name)" when the default is known. Reasoning and Context contain
  only the server's real choices, with no synthetic Default row. Reasoning names match the pane,
  including "Extra High"; Context shows compact token windows such as "200K", "1M" and "936K",
  or the tier name when its window is unavailable. An absent reasoning value displays the model's
  declared default, then its first supported value. An absent context value displays the first
  tier. Unsupported stored values remain selected in a "(current)" row. Resolving these display
  values never changes the stored configuration or enables Save. Only changing an option writes it.
- **Progress.** Busy titles use the ellipsis character: "Creating…" and "Saving…".

Copy:

| Sheet | Subtitle | Section footers | Buttons |
| --- | --- | --- | --- |
| New Channel | The lead starts right away and adds specialists as needed. | Purpose prompt: "What should this team work toward? The lead reads this first." Directory prompt "Optional", footer: "A folder on the server. Leave it empty for a discussion-only channel." | Cancel, Create Channel |
| Edit Channel | None | Directory is a read-only row, middle-truncated and selectable. Footer: "Only the lead can change the directory. Model changes apply the next time the lead works." | Cancel, Save |
| Add Agent | Joins {channel} and starts onboarding right away. | Identity: "Mentioned as @handle. Names are unique in this channel." (live). Role prompt: "What this agent owns and how it works, including any persona." | Cancel, Add Agent |
| Edit Agent | Member of {channel} | Identity as Add Agent. Model: "Model changes apply the next time {name} works. Its history is kept." | Remove from Channel… (leading, destructive), Cancel, Save |

Names affect mentions, so the identity footer always shows the resulting handle. The server
validates unique handles and role requirements. The lead cannot be edited through the member
sheet. Deletion confirmations name the exact target and consequence:
deleting a channel removes its agents and private sessions, removing a member retains public
messages and reactions as Deleted agent, and deleting a routine stops future scheduled runs.
Cancel is the safe default. There is no fake Undo for irreversible server deletion.

On iPhone, Delete Channel, Remove Agent and Delete Routine ask only in a system alert over the
screen they came from, never a sheet: the sidebar, the channel's title menu, Team, Routines or
Edit Agent, where Cancel returns to the unchanged editor. The alert's title names the target,
its message is the consequence above, and it offers the destructive action and Cancel. The
action is disabled while disconnected or once the target is gone. It sends one request, removes
nothing optimistically and adds no pending UI. A rejection or offline failure follows with an
alert that explains it and offers OK. An uncertain failure checks the server first, then says
the target is gone, says it's still there and offers the deletion again, or says the check
failed and offers Check Again. Nothing is sent again before that check.

Settings uses a native scene with General and Notifications sections. The Mac adds a Servers tab
between them for the servers (see [Several servers](#several-servers)), each with its Server URL,
Test Connection and status. General includes the selected appearance (System by default). Validate HTTP(S), preserve path prefixes
and display actionable failures. Changing a server's address prompts before replacing its live
connections, namespaces drafts, then refreshes its catalog. On iPhone, each server shares
Welcome's Server URL card, with no separate Use Server action or confirmation. Return or Test
Connection runs the test, and success on a different address switches to it at once: while it
applies, the field and Close are disabled and the row reads Connecting…, then a green checkmark
marks the connected address. Testing the server in use only confirms it. A failed test changes
nothing and names the server still in use, and closing Settings drops an untested edit. A switch
that fails to load the catalog shows its error in the card. Notifications explains requests
and completions before asking system permission in response to an explicit enable action.
Permission denial shows Open System Settings, never repeated permission prompts. General also
holds Open at Login, Show in menu bar, the Quick Send shortcut recorder, and the two on-device
toggles specified under Settings additions.
Notifications has an "Allow notifications" toggle over "Requests for your response" and
"Completed tasks". Both apps default to requests on and completions off, without changing saved choices. On iPhone,
the request and completion switches are hidden while Allow notifications is off. On Mac they stay
visible and disabled. Turning notifications off preserves both choices.
Release builds also show Updates, with "Automatically check for updates" and "Automatically
download and install updates" bound to Sparkle's own settings. Automatic installation is disabled
while automatic checks are off or the updater disallows it. These controls are hidden without a
running updater. Only a bundle containing `SUFeedURL` outside snapshot mode starts the standard
Sparkle updater, so development, validation and test bundles cannot update themselves.

**Settings additions.** General has "Show in menu bar" (see Menu bar extra) and a group of two
toggles, both on by default. Each toggle's description sits in its row as secondary text under the
label, the way System Settings describes its toggles, rather than as a section footer:

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

## Beyond the window

These surfaces live outside the main window, on the Mac, the iPhone or both. Each section says
which. Each Mac feature here stays quiet until it has something true to say, and disappears rather
than degrading when the Mac can't support it. On-device work never sends message text or images
off the Mac.

Owners: Shell owns notifications, the menu bar extra and Settings. Intelligence owns the
model layer, Siri and Shortcuts and Spotlight. Transcript owns the catch-up
card, descriptions in tiles and the viewer, and Live Text. Designer reviews each one in
real-window captures in Dark, with VoiceOver and with Reduce Motion, adding Light when a change
touches colors.

### Notifications

Notification categories are pending requests and unread completions, deduplicated by channel and milestone
sequence. Ordinary chatter does not notify by default. Suppress notifications for the active key
channel, but never hide its request marker. Activating a notification opens the right channel and,
for a request, reveals its message. A reveal newer than the channel's loaded history waits for the
reconnect to catch up, then lands on it. Messages are never deleted, so no reveal says a message is
unavailable. A caught-up channel without the target lands as usual with no notice, and logs only in
DEBUG builds. An offline channel and a failed history page keep their own notices. Respect system notification permission and Focus.

**Mac.** A notification says what is being asked, and you can answer it without
opening the window.

| Part | Request | Completion |
| --- | --- | --- |
| Title | Channel name | Channel name |
| Subtitle | None | None |
| Body | The request's plain text (see below) | "All tasks completed" |
| Hidden previews placeholder | "Waiting for your reply" | "Tasks completed" |
| Category and actions | `request`, with Reply | `completion`, with no actions |
| Sound | Default | Default |
| Thread | `[server]:[channel ID]`, so Notification Center groups each channel | Same |
| Activation | Opens the channel and reveals the request | Opens the channel at its normal landing |

The request body is the message as a reader sees it, flattened to plain text. Drop the leading
mentions the transcript omits. Links become their text, code keeps its contents, list items keep
a "• " prefix, and paragraphs keep one line break. Cut at a word boundary to 400 characters with
"…" and let the system clamp the display. A request with only attachments says "Sent an image",
"Sent 3 images" or "Sent a file". Get the text from the catalog's `request`, and deliver at once
without waiting for anything. Without it, the body is "Your team is waiting for your reply." with
no subtitle. Agent avatars as the notification image need Communication Notifications and
are out of scope.

Reply is a `UNTextInputNotificationAction`: title "Reply", button "Send", placeholder "Reply". It
sends in the background without activating the app or opening a window. The text is addressed
exactly like the in-app Reply: prepend the requester's `@handle ` unless the reply already starts
with an @mention. A reply or choice goes to the app's outbox for the server that posted the
notification, answering that notification's request, and the notification clears. The outbox
delivers it and marks the channel read, as Sending describes, so the action never waits on the
network or posts a second notification. Empty or whitespace-only replies send nothing.

Notifications withdraw themselves. Remove a channel's delivered request notification as soon as
its `requestSequence` changes or clears, wherever it was answered. Remove a completion once
`seenThrough` reaches its sequence. Remove all of a channel's delivered notifications when it
becomes active in a key window. While the app is active, present requests from other channels as
banners with sound and send completions to Notification Center only, since the sidebar already
shows them. The active key channel still never notifies. Per-milestone deduplication and the two
Settings toggles apply throughout.

**Phone.** The phone's request and completion alerts arrive by push. Their text, badge, service
extension and routing are under Push and topic subscriptions, and their Lock Screen reply choices
are under Suggested replies. A Lock Screen reply or choice is addressed like the Mac's and goes to
the app's outbox for the server the alert came from, which the service extension records on the
alert, answering that alert's request. Only that notification clears. The reply finishes in the
background and marks the channel read, as Sending describes.

### Menu bar extra

The menu bar extra is Mac only.

One template image of the app icon's robot head tells you, from any app,
whether your team is working or waiting for you. It never animates, because a team can work
for hours, and it never uses color.

| State | Image | Accessibility value |
| --- | --- | --- |
| A channel is waiting for you | The robot's face with a solid badge at its top-right | "1 channel waiting for you" (plus the working count when nonzero) |
| Agents working, nothing waiting | Three dots in the visor instead of the face | "3 agents working" |
| Nothing active (Always only) | The robot's face | "No agents working" |
| Catalog unreachable | The robot's face | "Not connected" |

The label is "Toy Box". Waiting outranks working. Each image is a 17 by 16 point template drawn
from the icon's own head path, with the visor knocked out. The canvas always reserves the badge's
room, so the item never changes width. Images swap instantly. Show no count, because the Dock badge
already counts.

General settings has "Show in menu bar" as a pop-up with Always, When Active and Never. When
Active is the default, with the footer "When Active shows the icon while agents are working or a
channel is waiting for you." In When Active, the item appears as soon as anything is active,
stays 10 seconds after the last activity ends so short gaps between agent turns don't shift the
menu bar, and never leaves while its inbox is open.

Use `MenuBarExtra` with `.menuBarExtraStyle(.window)`. Its inbox uses the native window material,
shape and shadow, with no custom glass plate. It is 380 points wide and content-fit, capped at
640 points or the usable screen height minus 24, whichever is smaller. The body scrolls above a
fixed footer, with 16-point content insets.

| Inbox part | Specification |
| --- | --- |
| Needs Your Reply | 15-point semibold header with the live waiting count. Every pending channel is shown, newest request first on opening, between full-width dividers. Each row starts with the 13-point semibold channel name and a trailing 28-point Open control |
| Request | Wrapping 13-point quote aligned with the channel name, flattened from Markdown without dropping @mentions. A short request takes only its lines. A longer one scrolls within 160 points, and opening the inbox flashes its scroll indicator. While more is below, its bottom 24 points fade like a clamped transcript message, clearing over the last 24 points of scrolling. At either end of the request, the wheel carries on scrolling the inbox. The channel name and Open reveal the request in the main window. Reply, labeled "Reply in [channel]", expands an editor beneath the quote without moving the request's scroll position |
| Reply | One expanded editor at a time. Native 14-point text, three lines before scrolling, 12-point insets, 10-point corners and primary-at-5% fill. Attach Images, the canonical audience, Dictate and Send reuse the composer's components, without another glass surface |
| Working Now | Up to three channels with working agents and no pending request, most recently updated first, without a section heading or count. The 13-point medium channel name and the 11-point secondary working subtitle sit on the leading inset, with a trailing static 20-point avatar stack of up to three agents, lead first. Overflow opens the main window |
| Empty and unavailable | "All caught up" when nothing needs attention, "Connecting…" before the first catalog, "No channels yet" with the main-window route, and "Connect to Toy Box" with Settings for invalid configuration. Offline keeps cached rows, says requests may be out of date and offers Retry |
| Footer | A fixed Quick Send command with the configured shortcut, then Open Toy Box and Settings. Close the inbox before opening another surface. No Quit, because this is a regular Dock app |

An open inbox preserves its original request order and appends newly waiting channels. A reply
or choice turns its row Replied the moment the outbox saves it, and the editor folds away. Its
delivery shows in the channel, never in the inbox. Answered and Replied rows stay in place until
the next opening, when a Not sent answer brings its request back with its choices. A newer request
never silently
replaces the original quote. If an expanded request is answered or replaced, keep its editable
draft, disable sending and show the corresponding explanation with Open Channel. Reply drafts
are separate from main-window and Quick Send drafts, keyed by normalized server URL, channel and
request sequence. A new empty reply visibly seeds the requester's canonical @handle.

Waiting comes from the catalog's `waitingRequests` in ChannelClient, shared by the menu bar, Dock,
notifications and both platforms' widgets. It lists the sidebar's waiting channels newest request
first and quotes each from the catalog's `request`, or an open channel's store, whose own stream
can deliver a request first. Nothing reads history to find one.
Working must come from the one function the sidebar row uses, which reads the catalog's
`working`, so the menu bar, the sidebar and the Dock can never disagree. Render identities with `AgentAvatarView`. Opening the inbox does
not refresh the catalog. The catalog's stream already delivers each change as it happens.
Opening it, reading a quote and expanding Reply never mark a channel read.

### Dock

The Dock request menu and badge are Mac only.

The Dock badge counts channels needing attention once each, not message volume.

The Dock context menu uses native `NSMenuItem` rows, not custom cards or a second inbox. Build
it on opening from `MenuBarStatus.waiting`, preserving its newest-request-first order and
canonical request sequence. The menu never fetches history, changes selection or marks read.

| Order | Content |
| --- | --- |
| Waiting requests | One item per waiting channel: "[Channel]: [plain-text question]". Collapse whitespace and shorten the title at a word boundary to about 60 characters, including an ellipsis. Keep the complete quote, channel and requester in the item's help. While resolving the quote, use "[Channel]: Needs your reply" |
| No requests | A disabled "Nothing needs you" row instead of an empty region |
| Cached offline content | Keep cached request items, preceded by a disabled "May be out of date". Without usable content, show "Connect to Toy Box", not "Nothing needs you" |
| Commands | One separator, then "Quick Send…" and "New Channel…". These open the Quick Send panel and the `ManagementPresenter` New Channel flow |

A request opens its exact channel and message through the widget's validated navigation path.
Invalid or deleted targets show that path's unavailable state, never a different request.
Catch Me Up is deliberately absent: its current result is a system-hosted Siri card, not an
in-app destination for this menu. macOS retains its own standard Dock items.

Notifications Settings has "Bounce Dock icon for new requests", off by default, with
"Bounce once when a new request arrives while you're using another app." It is independent of
notification authorization. Use one `.informationalRequest` for a newly observed request while
Toy Box is inactive, never persistent attention or one bounce per agent. Deduplicate by server,
channel and request sequence. The first usable catalog after launch or a server switch establishes
a quiet baseline. Enabling the setting, losing focus, reopening the menu, resolving quote text
or reconnecting with an already-known request never bounces. Test, snapshot and benchmark
launches never request real Dock attention.

### Open at Login

Open at Login is Mac only.

General Settings has "Open at Login", off by default, with the secondary description
"Keep Toy Box ready in the Dock and menu bar without opening a window." Use the real
`SMAppService.mainApp` status, not a separately saved Boolean, and refresh it when Settings
becomes active. Enabling registers the main app and disabling unregisters it. A pending request
for approval must visibly say "Approval Required", followed by "Allow Toy Box in System Settings
to open at login." and "Open Login Items…". Keep the toggle off until enabled, with a secondary
"Cancel Request" action to unregister the pending request.
Never claim a pending or failed registration is enabled. Unavailable registration and failed
changes show an actionable inline explanation rather than silently resetting a checkmark.

An explicit `keyAELaunchedAsLogInItem` launch opens no window and restores no visible windows,
but remains a regular app with its Dock icon, badge, menu bar inbox and normal background
observation. Do not reuse the accessory-app launch path for background intents. A Dock click,
notification or explicit Open action opens the normal channel window. No login launch prompts
for notifications or microphone access. Merely opening Settings never registers anything.
Only the ordinary production identity may alter login registration. Test, snapshot, benchmark
and explicit demo-server launches use a disabled control and injected service in tests.

### Quick Send and Share

Quick Send and Send to Toy Box are Mac only. The phone takes shared content through its own share
extension, under Sharing to a channel on iPhone.

**Quick Send.** The app-menu command, inbox footer and configurable global shortcut present one
retained, non-activating, key-capable floating `NSPanel`. It uses one regular system-glass surface,
24-point continuous corners and the system shadow, without a title bar or nested glass composer.
It is 560 points wide, starts around 220 high and grows to at most 420, clamped to 24-point screen
margins. Each presentation centers it on the pointer's screen, with its top 22% below the usable
top. Content growth preserves that top edge. The host uses the system utility-window animation.
Appearance, Text Size, Increase Contrast and Reduce Transparency follow the app and system.

Content has 16-point padding, a 32-point channel row, a native transparent 16-point editor and a
32-point controls row. Command-L opens the searchable channel chooser. Its results are a
transparent native inset list over the popover's material, with the system selection highlight
and row metrics, no separators, and a height that fits its rows up to 252 points before
scrolling. The arrow keys move that selection, Return chooses it and Escape closes the chooser.
One click anywhere in a row chooses it, including the already highlighted row. Choices put up to
three recent channels, from any server, before the remaining alphabetical list. With several
servers, each server's other channels follow under its name in Settings order, and a server whose
list hasn't loaded shows its reason with Retry. Changing channels saves and restores
separate Quick Send drafts rather than borrowing the main-window draft. Target history spans
every server and prefers an unfinished Quick Send draft, then the last explicit Quick Send target,
the last main-window channel or the sole available channel. With no suitable target it offers
the chooser instead of selecting an urgent channel. No-server, no-channel and deleted-target
states offer Settings, the main window or Choose Channel. A channel list that can't load offers
Retry. An offline target keeps its note without Retry, because the channel reconnects on its own.

Return sends, Shift-Return inserts a newline and Command-Return sends and opens the channel. IME and mention completion consume Return first. Escape closes completion or a picker
before stopping dictation, then hides the panel. Command-W, another global shortcut press or a
click away also hide it, preserving the draft. Owned sheets and popovers are not outside clicks.
Images and dictation reuse the main composer's validation and permission handling. Opening Quick
Send never requests microphone permission, reads the general clipboard or marks messages read.

Both auxiliary editors send through the app's outbox, like the channel composer. Their Send
follows the channel list rather than the channel, so it never waits for a channel to connect and
is disabled only while the list is offline, with "Toy Box isn't connected". Saving clears the
draft and announces the send once. Quick Send then closes at once, or opens the channel for
Command-Return, and the message shows in its channel as Sending. A message that fails stays there
as Not sent with Retry, never in Quick Send or the inbox. Shared content that arrives while a send
saves opens in a fresh editor instead of closing the panel. Removing a server, or changing its
address, closes either surface showing one of its channels and never opens a channel from it.

General settings places the native Quick Send shortcut recorder below Show in menu bar. The
default is Control-Shift-Space. It records physical keys, displays the current keyboard layout,
rejects reserved combinations and shows registration failures explicitly. Recording suspends
the existing binding. A failed replacement restores it without changing the saved preference.
Escape cancels recording, unmodified Delete clears it, and a separate Clear control is available.
Clearing keeps both menu commands usable. Global registration uses Carbon without Accessibility
permission, and snapshot and benchmark launches never register or present these surfaces.

**Send to Toy Box.** The explicit Services action, system Share action and Dock file drops open
the same Quick Send panel, not another editor. They prefill content for review, never send,
answer a request or mark messages read automatically. Shared text and URLs append after a blank
line to the selected draft. Images append to its existing attachments. Neither replaces text or
images. The Services command accepts an explicitly supplied
selection of text, URLs, images or file URLs. The document declaration has `LSHandlerRank` None,
so Toy Box never claims to be a default file handler. Services never read or clear the general
clipboard.

While no channel is selected or a send is saving, incoming content is saved in a
separate server-scoped staging draft. Append it to the target only when that draft is editable.
Multiple invocations preserve all incoming content rather than replacing an earlier payload,
and consumption happens once so reopening the panel cannot duplicate it. Consumption clears only
the matching payload ID.

Images use the main composer's attachment validation. Other in-place regular files become
visible plain path text only when the server has a loopback host, so agents on this Mac can open
them. Those paths are text for the person to review before sending, not uploads or pretend
attachments. A remote server rejects non-image files with "Only images can be attached" and
preserves the existing draft. The Share extension has no editor or networking of its own. It hands
the explicitly shared content to the host's same prefill path. It copies image bytes before the
provider expires, but rejects temporary non-image files. Never give agents a path inside a sandbox
container. The Share extension's `toybox-desktop://quick-send?pasteboard=<name>` route accepts only
`dev.toybox.desktop.share.<UUID>` names. The host copies that named pasteboard and clears it,
including on failure.

For native validation only, `--validate-quick-send trace` logs panel visibility, key state,
geometry and accessibility role. `hold` additionally suppresses resign-key dismissal, not Escape,
Command-W or explicit dismissal. `TOY_BOX_QUICK_SEND_VALIDATION` accepts the same launch-only
values for a test bundle launched through Launch Services. The command-line value wins.
The mode is recorded only in the volatile argument domain, never saved as a preference, and
cannot be combined with snapshots or benchmarks. Normal launches leave it unset.

**Sharing to a channel on iPhone.** `PlugIns/ToyBoxMobileShare.appex` (`dev.toybox.mobile.share`) puts Toy Box in the system share
sheet for up to ten images or one web link. Anything else, or an image it can't read, shows
"Can't Share This" with the reason and Close. It reads the servers the app saved from the app
group's share history and never connects anywhere else. With none saved, it says "Open
Toy Box to connect first".

The app saves its servers whenever it connects and records each channel the user sends to, from
the app once the server confirms it or from the extension. That history keeps the 20 most recent channels across
every server and mirrors them as `INSendMessageIntent` donations, so the share sheet suggests them with the channel
mark. Each donation is grouped by its server and channel, and removing a server or its catalog
dropping a channel deletes its suggestion. A suggestion opens straight to its composer. Anything
else opens "Choose a Channel": up to three recent channels, then the rest A to Z through
ChannelKit's `choices(matching:recentIDs:)`, the same order as the Mac's Quick Send. With several
servers, recents span them, and each server's other channels follow under its name, where one that
hasn't loaded says so with Retry. Search, pull to refresh and
"Can't Load Channels" with Retry use the native list.

The composer shows the channel name with a chevron as the principal toolbar item to choose
another channel, the images or a link tile with the page title and host, an "Add a note" field
and the shared `AudiencePill` (ToyBoxUI). A link posts the note, a blank line and the URL, or the
URL alone. Images go through `ComposerDraft`'s encoding at 2048 pixels and 1.5 MB each, well inside
the server's limits, because iOS ends a share extension near 120 MB. Ten 24-megapixel photos at
8000 pixels peaked 247 MB above the extension's baseline, and at 2048 pixels 45 MB. Sending holds
the request about three times over, so the byte limit keeps ten images' request under 20 MB.

The header stays centered on the sheet in every state. Close and the trailing control are both
36-point circles: Send (arrow up), progress or Sent (checkmark). The channel button keeps 68 points clear of each edge, Close's measured 56
to 60 points plus 8, so a long name truncates instead of running under them. The header's text
stops growing at the Large text size, with the Large Content Viewer above it.

Send saves the message to the app's outbox and makes one attempt, as [Sending](#sending)
describes, so the sheet waits on the server once and never retries, even offline. Sending shows a
progress indicator until that attempt answers, and Sent shows a checkmark for 0.7 s before the
sheet closes.
From Send on, the composer is dimmed to 50% and locked, as is the channel button, and Close is
disabled. The message shows in its channel in the app as Sending, and a failure waits there as
Not sent. Swiping down with a note asks "Discard Note" or "Keep Editing".

### Catch-up summaries

The morning digest is Mac only. Both apps show the catch-up summary, and the rules below are
written for the Mac.

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
| Placement | Scroll content, not a message or glass. Directly above the New divider, and above a coinciding day label, with 12 points to the divider and the divider gap (16) above it, matching the space around the divider |
| Width and shape | Leading edge on the avatars' leading edge, trailing edge at min(lane, 804), the widest agent bubble's trailing edge. 12-point continuous corners. Fill primary at 3% in light and 5% in dark, with a 1-point inner hairline at 10% light, 14% dark and 40% under Increase Contrast. Padding 12 horizontal and 10 vertical |
| Header | 18 high. `text.line.3.summary` in 12-point medium secondary, 6 points, then "Summary of 42 new messages" in 12-point semibold secondary, counting messages from others. Trailing Dismiss: `xmark`, 10-point semibold tertiary, 28 x 28 hit area, help "Dismiss Summary" |
| Lines | 8 points below the header, 2 apart, each 3 points of vertical padding. A 16-point leading slot, 8 points, then 13-point primary text, wrapping up to 3 lines and then truncating, with the full line in help. The slot holds the 16-point avatar of the sender of the line's first source. When that source is a channel event, it holds the event row's own symbol and color at 13 points instead, such as the green `checkmark.circle.fill` of All tasks completed, never a generic `info.circle`. Text scales with Text Size |
| Needs you | The first line, only while a request is pending. The slot holds an orange 13-point `questionmark.bubble.fill`, and the text is medium weight. Once the transcript shows the request as Replied, the symbol becomes a secondary `checkmark` and the text turns secondary, in place, so the card never changes height. A later landing drops it |
| Line action | Each line is a button. Hover shows the hover fill in a 6-point rounded rectangle extending 6 points past the text horizontally and 3 vertically. Click, Return or Space reveals the first source through the transcript's Reveal. Help "Show Message" |
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

**Morning digest.** One quiet morning notification helps the user return to the teams, rather than adding another
live activity feed. It is enabled by default and scheduled for 8:00 AM in the Mac's local time.
Include each channel with messages from others since the last successful digest, looking back
at most 24 hours. Exclude the user's own messages and empty activity. If no channel qualifies,
post nothing. Deliver a missed morning at the first opportunity before noon after wake or launch,
at most once per local calendar day. Respect notification authorization and Focus. Enabling the
default preference never prompts for permission on launch.

The notification title is "Morning digest", with no subtitle or badge change and no added sound.
Its body has one plain-text line per qualifying channel, busiest first:
"Studio: Finished the layout and needs your review." Use the on-device catch-up path for
short, factual summaries. No praise, invented urgency or claim that the user has read
something. When Apple Intelligence is off, unavailable or fails, use the deterministic line
"Studio: 12 new messages", with correct singular/plural forms. Do not manufacture a summary or
make model availability a prerequisite for the digest. System notification truncation is allowed,
but the authored content retains one line per qualifying channel.

Activating the notification opens its busiest channel through the same navigation path as other
notifications, with a deterministic tie-break when activity counts tie. It offers no Reply action
and never posts, answers a request or marks a channel read in the background. Snapshot, benchmark
and validation launches never schedule or post a digest. An explicit test-bundle-only trigger may
present a demo banner for acceptance without changing the production daily-delivery record.

Settings > Notifications has a separate grouped section below the request and completion
alerts. Its rows are an on-by-default "Morning digest" toggle and a native time-only
morning picker labeled "Deliver at", initially 8:00 AM and formatted for the user's locale. The footer
reads "A daily recap of activity from your teams. Made on this Mac. If your Mac is asleep, it
arrives when you return before noon." Turning the digest off disables its time picker without
discarding the chosen time. Notification authorization is the master gate: denied permission
uses the Open System Settings explanation, never repeated prompts. The section fits in the native
Settings window in both appearances, with no custom card or artificial fixed-height spacer.

### Image descriptions and Live Text

Both apps describe images for VoiceOver and offer Live Text, and the rules below are written for
the Mac.

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
| Menus | A right-click on selected text shows the system text menu (Copy, Look Up, Translate, Share). Live Text adds no menu anywhere else |
| Accessibility | Recognized text is exposed as the overlay provides it. The image keeps its label and description value |

### Siri and Shortcuts

The intents and phrases below are Mac only. On both apps, Siri can read the channel or artifact
on screen, as **On-screen content** describes. Handoff works on both apps.

Ask what needs you, open a channel or send a message by voice, from
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

The app name is "Toy Box". The shortcut tile is navy, like the icon. Tile symbols are
`text.line.3.summary`, `bubble.left.and.bubble.right` and `paperplane`.

The Channel entity is identified by its server and channel ID, so the same channel on two servers
stays two channels, and displays the name, with `number` as its image
(the channel's avatar in Spotlight) and the sidebar's attention as its subtitle: "Needs your reply", "All
tasks completed" or "Unread messages". It has Name, Unread Count (`latestSequence - seenThrough`,
which counts channel events too), Needs Your Reply, Tasks Completed and Content properties, with
Content as **On-screen content** describes. Its query reads
the catalog fresh, suggests channels in sidebar order and matches names ignoring case, accents and
punctuation, exact names first, then prefixes, then substrings. The app refreshes the shortcuts'
parameters whenever the set of channel names changes, so Siri learns them.

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
request as Replied once it's no longer waiting, including while the app's answer to it is still
sending, and never connects a channel. The view is plain SwiftUI with
`AgentAvatarView`, because the system archives it, and its buttons are `Button(intent:)`, because
closures don't run in a snippet. Reply is a hidden background `ReplyIntent`. It asks "What do you
want to say to Lead?", confirms "Send “[text]” to Lead in Studio demo?", then sends "@lead [text]"
through Send Message's path, mentioning the asker as the transcript's Reply does, or no one if
they've left. It returns no dialog, so the card redraws as Replied.

Send Message trims the text and refuses an empty one before asking anything. It confirms with
`requestConfirmation(actionName: .send)` and "Send “[text]” to [channel]?", then saves the message
to the app's outbox. It never waits on the network, so delivery and failure show only in the
channel, as Sending describes. Siri finds channels in every server's channel list,
waiting for each server's first load when the app has just launched. Other errors: "Toy Box isn't connected to a
server. Choose one in Settings.", "Can't connect to your Toy Box server. Check that it's running,
then try again." and "That channel isn't on your Toy Box server anymore." Errors about the server
always say "your Toy Box server", since "Toy Box" alone also names the app.

When Catch Me Up, Send Message or the card's Reply launches the app, the system starts it hidden with activation
prohibited. That launch presents no window and runs as an accessory app outside the Dock, so the
system quits it once the intent finishes. Windows restored from the last session stay hidden, and
no extra window opens. Activation or a shown window, from a reopen, Open Channel, the menu bar
extra or a notification, makes it an ordinary app. Every other launch, Dock click and reopen is
an ordinary app launch.

`bun run build` generates `Contents/Resources/Metadata.appintents`, and a phone bundle whose
`ToyBoxMobile` declares App Intents generates `Toy Box.app/Metadata.appintents`, by running
Xcode's `appintentsmetadataprocessor` directly over the const values SwiftPM already emits, so both
need Xcode installed but never `xcodebuild`. Titles, phrases and parameter names must stay literals.
The system only indexes a bundle outside `/tmp` that has launched once, and parameterized phrases
need a team-signed build.

**Handoff.** A window that shows a channel makes it the window's user activity (`dev.toybox.desktop.channel`)
with `appEntityIdentifier` naming its Channel entity, or its Artifact entity while an artifact is
open over the conversation, and none while an image is. It's set through
`userActivity(_:element:_:)`, so the activity follows a switch or what the window shows. AppKit
makes the main window's activity current, so Siri and Apple Intelligence take "this channel" to
mean the one in front, and with no channel shown there's no activity. Phone and Mac declare the same activity type and carry only the exact channel identifier
in `userInfo.channelID`. Handoff is eligible while a channel is shown, except isolated Mac
snapshot, benchmark and explicit-server launches. Each receiving window resolves the identifier
in the first server, in Settings order, whose catalog lists it, joining catalog refreshes when
necessary. It never matches by name, or imports drafts or credentials. A native `Opening channel…` progress
state resolves to the channel or one native `Channel unavailable` state with
`This channel isn't available.` and `Show Channels`. New navigation or a server change discards
obsolete results. Local drafts survive Handoff and ordinary Back/sidebar navigation.
On the iPhone, the channel screen sets the same activity, naming the same entities.

**On-screen content.** Both apps declare a Channel entity and an Artifact entity. The user
activity names what's on screen, and Siri resolves it through the entities' queries, which give
text only for what you can see:

- **iPhone.** The foreground scene's channel or open artifact, nothing under Settings or Screens,
  and nothing in the background. Siri's overlay leaves the scene inactive, so the text follows the
  foreground rather than the active scene. Its entities have queries but no intents or phrases.
- **Mac.** The channel or artifact in the frontmost of the app's windows, while that window is
  visible and not minimized and the app isn't hidden. The app needn't be active, since Siri's panel
  may take that from it. Overview and management sheets leave the conversation in view, but an
  open image shows nothing, and so does any other window in front, like Settings. Panels such as
  Quick Send never count as in front. Siri reads the window's live store, so the channel on
  screen resolves without asking the server.

Any other channel resolves with only its name, and any other artifact resolves to nothing. Content
never reaches Spotlight: the phone's entities aren't indexed, the Mac's Channel entity gives
Spotlight only its name, purpose and icon, and the activity isn't eligible for Spotlight.

Both apps build Content in ChannelClient, so Siri reads the same text on each, and export it as
plain text. The Channel entity's Content is "Channel:
[name]" and its purpose, its tasks as an indented list with each status, then "Messages, oldest
first:" and the newest loaded messages as "You: …" or "[agent]: …". Markdown is flattened,
attachments are named, system events are left out and the waiting request is always included as
"[agent] (waiting for your reply): …". Content stops at 8,000 characters, about 2,000 tokens or
half the on-device model's window, so Siri keeps room for its instructions, the question and the
answer. Each message stops at 1,000 characters and the tasks at 2,000. On the phone the Channel
entity has only Name besides. The Artifact entity has Title, Kind and Content, which is a Markdown page's flattened text under the same limit. It's
empty for HTML, which is the raw page with its scripts, and for images and files.

Debug builds can launch with `TOY_BOX_HANDOFF_CHANNEL=<channel ID>` to invoke the same continuation
handler as native Handoff. For the phone simulator, pass it through
`SIMCTL_CHILD_TOY_BOX_HANDOFF_CHANNEL`. For Mac receiver checks, combine that hook with
`bun run snapshot --state handoff-match` or `--state handoff-unavailable` and the normal snapshot
arguments. Match becomes ready after the continuation selects the channel. Unavailable waits for
the receiver's unavailable presentation rather than a live conversation it intentionally never
opens. Both use the normal snapshot renderer without delaying Handoff lookup. These are
receiver-state proof hooks, not proof of native cross-device discovery or delivery, which requires
the signed phone and Mac on real devices.

### Spotlight

Spotlight is Mac only.

Every channel on the servers saved in Settings is in Spotlight by name, with the
first line of its purpose under it and the channel's avatar beside it, rendered by `ChannelMark`
as a 128 px PNG once its image loads, or with the `#` fallback if it can't.
Attention is left out, since Spotlight would keep it after it goes stale. Picking a channel runs
Open Channel. The Channel entity is an `IndexedEntity`, keyed by its server and channel ID in the
app's default index. Once every server has answered and at least one has loaded, the loaded
servers' channels replace whatever Spotlight held, and the last launch's channels stay until then. A server that
can't load leaves Spotlight until it does. After that the app indexes only renames, purpose
changes, avatar changes, additions and deletions. Removing a server, or changing its address, removes its channels
at once. A failed call makes the next catalog change replace
everything. Launches with `--server`, `TOY_BOX_SERVER_URL`, a snapshot or a benchmark never touch
the index. When Spotlight asks the app to reindex, it indexes the catalogs' channels and removes
identifiers they no longer have.

Waiting requests appear beside the channel results as their own `IndexedEntity`. Index requests from
`MenuBarStatus.waiting`, not a separate interpretation of unread messages.

Each resolved request displays its plain-text question as the title, "[Agent] · [Channel]" as
the secondary context and the requester's catalog avatar. Hold unresolved quotes or requester
identities out of the index until they resolve, rather than publishing placeholder search results.
Keep full text in the entity even when Spotlight truncates its visible row. Identity includes
the normalized server, channel ID and request sequence. Opening the result reveals that request
in the channel. It never automatically sends or answers it.

"Reply to Request" is discoverable in Spotlight's action pane with a parameter summary
"Reply to [Request] with [Message]". It asks for missing text, confirms the message, requester and
channel, then revalidates that the original request is still waiting on its server.
An answered, replaced or unavailable request explains the change without posting to a newer one.
It sends through Send Message's path with the in-app Reply's canonical mention, without opening a
window. Empty text sends nothing.

Remove indexed requests when answered, replaced, deleted or after a server switch. Follow
`ChannelSpotlight`'s production and server-override gating for indexing and cleanup. Background
indexing and reading a Spotlight result never mark read. Deterministic coverage must prove
identity isolation, withdrawal and a stale result's inability to send to a different request.

### Needs you widget

The WidgetKit extension is a glanceable view of the same waiting requests as the menu bar inbox,
not a second attention model. The host writes a small server-scoped snapshot from `MenuBarStatus`
to its Team-ID-prefixed app group and requests a timeline reload when that snapshot changes.
The catalog stream's keepalives, at most every 15 seconds, feed the snapshot's 15-minute heartbeat
even when nothing changed.
A stream that isn't delivering never advances its last-success time.
The Mac widget does not connect to a server, send a reply or mark anything read. Its signed,
sandboxed extension lives in `Contents/PlugIns`, shares the app's version/build and is omitted
from isolated test, snapshot and benchmark bundles like the Share extension.

Use system widget margins and `containerBackground`, never a custom glass surface, brand-colored
plate, orange request card or continuous animation. Requests start at the top, with no
app-owned "Needs you" heading, separate count or normal-state update time. On both platforms,
the gallery name is "Toy Box", with the description "See which channels need your attention."
Requests follow the menu bar's newest-first ordering.

| Family | Content |
| --- | --- |
| Small | The first request: channel name, a two-line quote and secondary request age |
| Medium | Up to two compact request rows, with 8 points between rows and a single-line quote per row |
| Large | Up to five request rows, with 12 points between rows and a single-line quote per row |

When more requests remain than fit, add one 11-point regular secondary footer, "2 more waiting",
counting only requests not shown. Otherwise omit the footer. Do not prefix the count with "+".
Reserve space for overflow and reduce complete rows to fit the native available height.

In Medium and Large, each request's content is one Open link, with a separate trailing Reply
target. WidgetKit gives Small one target for the whole tile, which opens its top request, with
no separate Reply. Each row starts at the leading margin with a 13-point semibold channel name,
a 12-point plain-text quote (one line in Medium and Large, up to two in Small), then an 11-point
secondary request age. Show no requester name, avatar or placeholder symbol. Age is based on the
request timestamp, not the last widget refresh. Keep visible text free of Markdown syntax and
preserve the full question in the link's accessibility label. A quote that is still resolving
says "Needs your reply", rather than appearing blank. Snapshots contain only channel identity,
request sequence, quote and request time, with no requester profile or rendered avatar data.

Medium and Large add a quiet 28 x 28 `arrowshape.turn.up.left` Reply button beside each request.
Use sibling Open and Reply targets, never a button nested in a link. Its help and accessibility
label are "Reply in [Channel]". It opens Quick Send with the request-scoped inbox draft and
canonical audience. Opening it never sends, marks read or borrows a main-window
draft. An answered or replaced request preserves editable text and explains why sending is
unavailable, rather than silently replying to its successor.
The strict route is `toybox-desktop://reply?server=<encoded-server>&channel=<encoded-ID>&sequence=<positive-request-sequence>`.
The plain `toybox-desktop://quick-send` route opens the usual channel chooser/draft selection.
The `quick-send?pasteboard=...` intake (see Quick Send and Share) and the request-reveal route
work independently of these.

Full Color, Tinted and Clear use the same layout and semantic hierarchy. Let WidgetKit supply
the background and style treatment, and apply `widgetAccentable` deliberately rather than
painting every text line with the accent. In Clear, let the system adapt or remove the material
without losing labels, request context or readable ink. Do not bake a desktop wallpaper or
simulated glass into the content.

The empty state is a centered quiet status, not a request row. Use a 16-point regular
`checkmark.circle`, a 6-point vertical gap, then "You're all caught up" at 13-point regular.
Both use secondary ink. Keep the sentence on one line, with no avatar, row styling or extra
sentence. The symbol sits above the text to preserve the sentence's width in Small.

After 30 minutes without fresh data, or immediately on a known disconnect, show
"May be out of date" and the last update, such as "Last update 8:02 AM". Time appears only
in this stale state, not in fresh Waiting or Empty. A previous zero is not a current all-clear.
Without a usable snapshot, say "Open Toy Box to connect" instead of claiming nothing needs attention.
Do not expose requests from a removed server.

Clicking a request opens Toy Box at that channel and request sequence through a validated URL route.
The empty Small tile opens the main app. In Medium and Large, the empty state, overflow
and background open the main app. A stale link never redirects to a
different channel or sends anything. Normal active-window read policy applies only after opening
the channel window, not while WidgetKit renders the snapshot or opens a reply panel.

The phone offers Home Screen Small, Medium and Large, plus Lock Screen Rectangular.
Its Home content reuses `ToyBoxWidgetViews`, with the Mac's text metrics and a 44-point sibling
Reply target. Reduce complete request rows to fit the
system-provided height, with overflow based on the rows actually shown. The phone's
Rectangular widget shows only "1 channel needs you" or "[N] channels need you", not a private
question or update time. Use 15-point regular primary text on up to two lines. Empty uses the
same centered checkmark and one-line "You're all caught up" status as Home and Mac. Stale shows
"May be out of date" and its last update. Not connected shows "Open Toy Box to connect".
There is no generic heading. Keep every line, including timestamp descenders, inside the
native 157 x 73.5-point rectangular host.
Both surfaces render waiting, empty, out-of-date and not-connected states from the phone's
App Group `NeedsYouSnapshot`. On timeline refresh, the phone widget extension fetches current
waiting requests from every saved server through the app publisher's HTTP and snapshot path,
within a ten-second total network deadline, then writes the shared snapshot. After a request or completion alert, the notification service
extension asks WidgetKit to reload this widget's timelines. WidgetKit schedules the refresh,
so this is not an immediate-delivery guarantee. A failed fetch keeps the saved snapshot and the
stale rule, without advancing its update time or claiming a fresh all-clear.
Out-of-date phone content says "May be out of date" and
shows its last update, never a current all-clear. A timeline entry at the shared 30-minute
freshness boundary makes this change without requiring the foreground app to run.
The widget never sends, marks read or changes a draft. Open and Reply
use the `NeedsYouRequestLink` routes. Native widget backgrounds, tint and
margins are system-owned, with no custom largest-text layout.

### Live Activities

Live Activities exist only on iPhone.

Channel Actions offers "Follow This Channel" after Find and before Open in Toy Box. When following
can't start, the item is disabled under a native section header that names the reason: "Channel was
deleted", "Channel can't be reached", "No tasks in progress" or "Push notifications couldn't be set
up". The first blocking condition in that order supplies the reason. An offline channel with no other
blocker stays a plain disabled item. iOS menus don't render two-line Label subtitles, so the header
carries the reason and the item's VoiceOver label repeats it. Notification permission never gates
following, so it is never a reason. The item uses one app-scoped controller, shows "Starting…" during
registration and "Stop Following" while active. Starting requires a
live snapshot with unfinished direct-root tasks, measured by `tasks.progress`. Stop
stays available offline and immediately removes the local Activity without confirmation or
changing the team's work. A failed start tears down its partial Activity and shows only the
native "Couldn't follow this channel" alert, "Try again." and OK.

The controller requests an ActivityKit push token and registers it with its channel's server's
acknowledged registration, inheriting its signing-derived push environment. The Activity's
immutable attributes preserve its original start time across relaunch and token rotation.
Registration writes are serialized per channel on its server, using that server's registration, so cleanup from an old follow cannot delete its
successor's registration. Initial content uses `ContentState(state:updatedAt:)`. Only server push
updates it afterward, including completion and task-list removal. Follow holds no channel connection,
observes no catalog or foreground content, and never marks read. Channel deletion ends through
the server with immediate dismissal. iOS ends the Activity at eight hours, and the server expires
its subscription using the original `startedAt`; the app has no separate lifetime timer.
Alert preferences do not start or stop an Activity.
The app wires Follow, widget publishing and notification withdrawal before awaiting notification authorization settings.
Activity content updates are non-alerting. A request's ordinary notification supplies its alert,
so updating the Activity never adds a second alert to force the Dynamic Island onscreen.

Lock Screen content uses native background, 16-point padding, an 8-point heading-to-summary gap
and 4-point related gaps. The channel name is subheadline semibold, state headline, task detail
footnote and update time caption2. The heading uses the full-color Toy Box app-icon mark.
Compact Dynamic Island uses the monochrome Toy Box robot and actual working count or state
symbol. Minimal uses the robot for working/quiet and the state symbols for request, completion,
ended and stale. Both marks use the original app icon's geometry. Expanded and the
small supplemental Activity family use the same hierarchy without progress animations,
percentages or an ETA.

Working and quiet content show actual working-agent and task counts. A current request says
"Needs your reply" and its tap carries the exact request sequence. After the shared 15-minute
stale date, content says "May be out of date" and "Last update", hides live counts and opens only
the channel. Completion takes precedence over stale/request content, ends with "All N tasks
completed", "Following ended" and its completion time, and may remain for 15 minutes. Other
automatic endings say only "Following ended" and the end time. The original eight-hour lifetime
is never extended. Channel deletion and server changes remove local content immediately.
Ended follows never restart automatically, and their menu action simply becomes available again
when the channel has live unfinished work.

### Controls

Controls are Mac only.

The widget extension offers two `ControlWidget` buttons, letting macOS host them in
Control Center and the menu bar. These are momentary actions, not on/off switches. Use system
control sizes, typography, shapes and tint. Do not add a custom glass capsule, persistent
animation, extra status dot or a second menu bar inbox implementation.

| Control | Symbol and label | Action |
| --- | --- | --- |
| Quick Send | `square.and.pencil`, "Quick Send" | Opens the Quick Send panel through its plain route. It never preloads clipboard data or sends automatically |
| Needs You | `questionmark.bubble`, "Needs You", with "1 waiting" or "[N] waiting" | Opens the menu bar inbox through `toybox-desktop://inbox`. If the menu bar icon is normally hidden, the action must still present that inbox |

Needs You reads the same app-group snapshot as the widget, with the same server scope and
freshness policy. Zero says "Nothing needs you". Without a usable snapshot, say
"Open Toy Box to connect". Known-stale content says "May be out of date" rather than presenting
a live-looking zero. Compact placements may omit the secondary value visually, but the
accessibility label retains the meaningful count or unavailable state.
Opening a control or the inbox never marks read, answers a request or changes the user's
Show in menu bar preference. If native inbox presentation fails, show an explicit error or
the normal app recovery surface, never silently report success.

The extension remains sandboxed with no network entitlement. Snapshot and validation bundles
omit these controls with the widget and never register replacement production controls.
Validate compiled control metadata and the host-opening action, not merely the presence of a
source declaration. Tests use injected actions, not clicks in the user's Control Center.
Actual Control Center/menu bar presentation, widget gallery styles and system tap-through
remain explicit installed-build checks when automation cannot observe those surfaces.

### App icon

The icon is the Toy Box robot's head as a speech bubble, alone and centered. It means your agents,
talking. It carries the brand's navy and robot face, the channel cyan in the eyes and a gold
antenna for one warm accent, and it never shows text or a hash mark.

| Part | Specification (1024 pt Icon Composer canvas) |
| --- | --- |
| Source | `Resources/Shared/AppIcon.icon`, an Icon Composer document with one 1024 x 1024 SVG per layer. It's the only artwork. Edit it in Icon Composer or as text |
| Background | Vertical linear gradient `#1C4090` to `#071937`. The dark specialization is `#122656` to `#040B1A` |
| Head group (back) | Speech bubble body x 193...831, y 305.2...778.2, corner radius 187, with its tail to x 261.2, y 879.4 at the lower left. The body is centered on x 512, and the whole robot, antenna to tail, on y 512. Antenna stem 39.6 x 121 at x 492.2, y 210.6. Fill `#F3EFE6`, `#E6E2DA` in dark. Glass on, translucency 0.3, neutral shadow 0.5 |
| Face group (front) | Visor 492.8 x 277.2 at x 265.6, y 402, radius 138.6, `#0A1530`, not glass. Eyes 61.6 x 110 capsules at x 391 and 571.4, y 468. Smile is a radius-66 arc from x 465.8 to 558.2 at y 617.6 with a 26.4 pt round stroke. Eyes and smile are `#67E8F9`. Antenna ball radius 50.6 at 512, 195.2 in gold `#FACC15`, glass |
| Shipped artwork | `Resources/Desktop/Assets.car` contains the layered icon and its system Dark, Clear and Tinted appearances, compiled with Xcode's `actool`. The gold antenna and cyan face stay in Default and Dark; the system derives Clear and Tinted from the same layers, without a second drawing. Both local and GitHub bundles ship this same committed file |
| Fallback | `Resources/Desktop/AppIcon.icns`, also committed. `bun run icon` renders the Default appearance with Icon Composer's `ictool` and places it on Apple's grid: an 824 pt body inset 100 pt, with a black 22% shadow offset 10 pt down and blurred 34 pt. That matches Apple's own `.icns` files within a pixel. The fallback output is byte-identical across runs |
| Builds | Local and GitHub bundles copy both outputs, set `CFBundleIconName` to AppIcon for the layered icon and keep `CFBundleIconFile` as the fallback. Neither build invokes Icon Composer or `actool`. Missing or empty artwork fails the build rather than silently shipping a generic icon |

Change the artwork only in the `.icon`, then run `bun run icon` and commit it with both outputs.
Check 16 and 32 px on light and dark before accepting a change. The 16 px icon must still read as a
navy tile with a white speech-bubble head.

## Quality bars

### Performance budgets

`bun run benchmark` checks these on a release build against `bun run demo:perf`, with 100
messages loaded and again with every older page loaded. Both live-message passes first follow the
latest message, so each new message is drawn and followed. Hover under a resting pointer adds to
what a message or a scroll costs, so the window opens away from the pointer, and the live-message
and scrolling passes run again with the transcript under the still pointer, against the same
budgets. It times the main run loop three ways:

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
| Steady scrolling up and down | 5 ms/s hitch time, from dropped display frames |
| First visible row during scrolling | At most 1 point of frame drift, in each direction and at each loaded count |
| Key window with 4, then 20, working agents | 3% process CPU over 15 s, so a continuous animation that updates views every frame fails it |

Launch and idle report the same figures with no budget.

The key-window CPU measurement requires an active app and a visible, uncovered, non-minimized key
window. It fails before or during measurement if that state is lost, rather than reporting a low CPU
result from a window that is not drawing. Activation diagnostics include the native state and the
window's WindowServer registration.

Scroll also reports actual main-thread CPU ms per 1,000 native points, and paging reports CPU ms
per older page. These are informational, not budgets. Compare CPU work when the Mac is
loaded, since run-loop wall time includes scheduling delays. Judge hitches only on a quiet
machine, with the same gesture, distance, loaded count and hover state in both builds.

Frame drift is the largest distance the first visible row moves away from that frame's scroll.
Each display callback schedules one late-run-loop sample, after layout. It compares the same row's
viewport position across consecutive samples with the wheel deltas delivered between them, not queued input or total native
scroll travel. On a row handoff it retains the previous first row, or uses the current first row
if the previous row was recycled. Missing shared first-row geometry fails the measurement rather
than reporting zero drift. Results include measured frame pairs, frames above 1 point, maximum
drift and total absolute drift. Both directions stay 1,000 points from the content edges, so end
clamping and rubber-banding are not mistaken for row drift.

The common driver uses precise **unphased** wheel events through the app-local event queue,
with a window-scoped local monitor counting delivery. The report names this path. Posted and
delivered event counts and total deltas must match, including the final zero-delta drain event.
Event creation, monitor installation or observation failures fail the run. This permission-free
driver is not the phased responsive-scroll path.

Every scroll run first checks the identical driver and sampler on a plain native table, up and
down for 15,000 points. The table must apply the full delivered distance, with no missing geometry
and at most 1 point of frame drift, before any transcript result is reported. A warm-up visits
1,000 points of the actual transcript. A short return within those already-measured rows must
also apply the full delivered distance. The transcript then returns to its end for measurement.
These controls run outside the timed transcript measurements.

`bun run benchmark trackpad` is a separate, opt-in native check using began/changed/ended phases
through WindowServer to the benchmark's own PID, never to the global input stream. A listen-only,
own-PID event tap counts delivery. This check requires Accessibility permission and fails explicitly
without it. The harness never requests or changes that permission. `NSApp.postEvent` does not
exercise responsive scrolling, and a local monitor does not see every event consumed by that path.
The check reports native travel after a one-second end drain. AppKit's interpolation can move
content beyond the raw delivered delta, so this is not a deterministic wheel baseline or a raw
wheel-relative row-drift gate.

The app has one transcript container. `TOY_BOX_TRANSCRIPT`, passed through `open --env`, only
labels the scroll output, `lazy` by default, except that `native-control` runs the plain-table
self-check described below. This is a benchmark option, not a product preference.
Hosted native tables are sampled relative to that outer scroll view's clip coordinates, including
the table's offset within the SwiftUI document. Discovery excludes independent nested scroll views
and never mounts cells to obtain row frames.
`TOY_BOX_BENCHMARK_SCROLL_DRIFT=0` disables the geometry producer and sampling for paired probe
overhead checks. It is also benchmark-only. Normal app launches install no geometry
provider and add no row callbacks.
The native-table producer reads existing row rects without mounting cells or forcing layout.
Scroll fixtures do not reorder rows during a gesture, so native row indices are stable for the
measurement. A row-count change invalidates the sample instead of comparing different rows.
`TOY_BOX_BENCHMARK_SCROLL_TRACE=1` runs only the first-page upward gesture, retains signed
per-frame samples in memory and prints them after CPU measurement. The trace includes the tracked
row and its two viewport positions, delivered wheel delta, signed residual, native top, document
height and event counts. Lazy samples also retain the row's callback-reported positions for
comparison with live native clipping.
Diagnostic traces also retain display-link samples for comparison with the late-run-loop phase the
measurement uses. Display-link residuals can include input-application lag and are not an acceptance
metric. `TOY_BOX_TRANSCRIPT=native-control bun run benchmark scroll` runs only the plain-table
self-check. It is not a product-container performance baseline.

### Native quality gates

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
| Evidence and closure | Check the actual user-facing build as a whole, not just the intended code change or an isolated fixture render. A screenshot closes only the visual state it shows. Missing interaction or accessibility evidence remains explicitly open |

**Accessibility coverage.** Keep these requirements and their regressions:

- Reaction chips, task disclosures, task artifact actions and attachment Remove have targets of at
  least 28 x 28.
- The reaction chip is a plain native Button. Activating it opens the reactors popover anchored to
  the chip, showing the reaction and reactor names.
- Each message group carries author, time, addressee and request labels, and the filename-bearing
  Quick Look button stays reachable and opens its panel. Image actions include filenames.
- Request and waiting text and adaptive diff counts keep their visual treatments. The non-default
  filter is distinguishable without color, and task progress and diff values expose exact semantics.
- The selected mention completion is exposed, and a newly active keyboard choice is announced
  without moving the insertion point.
- A system-link text contrast regression covers Aqua, Dark Aqua and both Increased Contrast
  appearances.
- Settings and composer errors use primary text with a red symbol. Overview, transcript and
  sidebar use the same Shared completion palette.
- Request announcements keep their baseline, deduplication and background and snapshot suppression.
- The missing-profile fallback initial uses primary ink on its cyan field. Rendered regressions keep
  the 4.5:1 floor for missing and invalid-mark profiles in both appearances. Supplied marks retain
  contrasting black or white ink.
- The real-history paging validator checks the same message after fresh-page layout and settling,
  with a 2-point displacement limit, at 1280 x 840 light, 760 x 760 dark and the 760 x 560 minimum
  in dark.
- The Team's typing ellipsis is checked under Reduce Motion. Sidebar activity doesn't animate or use
  a spinner, and there are no explicit animated transcript scrolls.
- Source checks don't substitute for a spoken screen-reader or runtime preference-switching check.

**Device and real-window proof.** Simulators, fixtures and snapshots can't prove these, so each
has its own check:

- On a real device, Settings resolves the notification authorization state promptly after launch.
- Routed alert proof in the Simulator uses the selected simulator's actual registration ID.
- `simctl push` does not invoke the notification service on the Simulator runtime, so service
  invocation is proven with real APNs on a device.
- Simulator checks prove real Follow start against the demo. Live Activity content updates and
  automatic endings require server APNs delivery and are proven on device.
- Shell checks the title menu's glass button and menu in the real glass toolbar.
- Deterministic regressions protect the phone image gallery's pager capsule and toolbar geometry.
- The Mac notification banner's two visible actions, Reply and the first choice, are confirmed on
  device.
- The phone Lock Screen's reply category registration and action counts are confirmed on a
  TestFlight build.
- Siri is checked with `bun run development`'s Toy Box Dev, since Siri's developer preview answers
  only development-signed builds.
- The Needs you widget is checked in Small, Medium and Large, in Light, Dark, full-color and the
  system's accented appearance, with long names, long quotes, empty and stale states. Off-screen
  Clear-equivalent or accented renders establish content layout only, not the system's actual
  desktop materials.

Every user-visible feature lands with its README update in the same pass. Designer keeps the
README grouped around the most compelling user outcomes, rather than appending a release log.
Feature owners provide the shipped behavior and any limits so it does not advertise a future
capability as already shipped.

Before calling the UI complete, inspect the running app in Dark at the default text size at
1280 x 840 and the 760 x 560 minimum. Add Light only when a change touches colors, and larger
text sizes only when it touches text sizing. Exercise a long purpose/name, no members, many
members, removed agent, nested
tasks, zero diffs, missing task artifact, attachments, request outside the loaded page, both
filters, offline/reconnect and terminal deletion against a scratch/fixture channel. Verify first
unread anchoring, no scroll jumps on paging or new reactions, selection and text-copy behavior,
keyboard-only composing, IME Return, VoiceOver grouping, Reduce Motion and Increase Contrast.
Screenshots are visual evidence, not a substitute for interaction checks. Public shared channels
remain read-only during this review.

## Exclusions

- Private agent sessions and tool logs. These never enter the channel, matching the pane.
