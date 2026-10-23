# Toy Box Channels for Mac

A native SwiftUI client for the public Toy Box Channels API. Requires macOS 26 or later and
Swift 6.2 or later Command Line Tools. No Xcode project or Xcode license is needed.

```sh
./script/run
```

The script builds with Command Line Tools, assembles and ad-hoc signs
`.build/Toy Box Channels.app`, and opens it. Use `./script/run --no-open` to build the bundle only.
Before signing, it records the actual SDK version in the bundled executable's Mach-O build
command so macOS enables its native Liquid Glass behavior instead of compatibility styling.
`script/validate` refuses to swap or launch a bundle whose recorded SDK is below macOS 26.
The server defaults to `http://localhost:3100` and is configurable in Settings.

```sh
SCRATCH_PATH=/tmp/tbm-core ./script/test
```

`ChannelKit` owns the Codable public domain, canonical reducer, transcript grouping, audience
policy, task math, attention, presence, and SVG paths. `ChannelClient` owns HTTP commands,
SSE framing, observation, reconnect, and observable detail/catalog stores. `ToyBoxChannels`
is the SwiftUI presentation. Its pure parsing, input and viewport rules are covered by the
executable-dependent `ToyBoxChannelsTests` target alongside the two foundation test targets.

The conformance fixtures are copied unchanged from the read-only Minecraft reference client.
Opt-in integration tests use its isolated demo server, never the live server:

```sh
# In a separate terminal, from this repository:
bun script/demo.mjs

# Then:
TOY_BOX_DEMO_URL=http://127.0.0.1:3210 SCRATCH_PATH=/tmp/tbm-core ./script/test
```

The wrapper serves the reference fixture with the required catalog lead profile. To preserve an
existing demo during a relaunch, `TOY_BOX_DEMO_SNAPSHOT` can name an exported snapshot JSON file.
Its messages, read boundary, request and timestamps are retained.

For isolated long-history checks, `bun script/history-demo.mjs` imports the Minecraft factory
without modifying its checkout and serves `history-demo` at `http://127.0.0.1:3211`. It has 480
messages across almost seven days, seen-through 450 and pending request 480. Its initial 100
messages and four older pages use the real v1 route's exclusive `before` query, ascending order,
response shape and 100-message limit. Read receipts work there, but message sends are disabled.
The shared `studio-demo` fixture on 3210 stays untouched. Its opt-in test expects a fresh server:

```sh
TOY_BOX_HISTORY_DEMO_URL=http://127.0.0.1:3211 SCRATCH_PATH=/tmp/tbm-core \
  ./script/test --filter HistoryFixtureTests
```

Management APIs are exposed by `ChannelAPI`. They require the v1 routes added to Toy Box for
this client. Message sends are single-attempt and carry a caller-owned UUID. Reconnection
resumes from the last applied durable revision, including revision zero. Reading does not
answer a pending request.

The global `/api/v1/models` route is owned by Providers, with its existing v1 wire format.
A member catalog's `defaultModel: null` means there is no compatible workspace default, not
that inheritance is forbidden. `EditMemberInput(model: .clear)` always sends `"model": null`;
the returned member and member event omit the cleared override while the server preserves
the established session provider and native history. Empty model choices do not forbid clearing.

Management writes are never automatically retried. A 422 is a domain rejection, while a 500
may follow a committed change, including deletion. Call
`ChannelCatalogStore.reconcileManagementWrite(channelId:)` before reviewing another submission.
It returns fresh catalog/detail data and an authoritative `channelWasDeleted` flag, updates the
shared stores, and throws rather than substituting cached data when reconciliation fails.
Pass no channel ID to review the catalog after an uncertain create without guessing by name.
Reconciliation performs GETs only and does not move read receipts.

The currently running port-3100 server has an older cached route configuration, so a 404 from
its global models endpoint is expected until its next user-approved restart. Do not restart it
or install a compatibility shim to hide that response.

`ChannelStore.sendAttempts` is separate from the committed transcript. It preserves the original
UUID, text, images and delivery state in an atomic per-server/channel outbox under Application
Support. Uncertain sends survive relaunch without automatic retries. Explicit Send Again uses
the original UUID, so a conflict confirms prior acceptance without duplicate delivery. Outbox
errors are surfaced, and a new send cannot leave before its UUID is safely recorded. Reusing
an existing attempt or loaded committed message ID with changed text or images is rejected.

`ChannelStore.lastSendFailure` is a transient event shared by channel windows. Every failed
explicit delivery, including an unchanged-UUID retry, has a new event ID alongside its original
message ID, failure phase and error. Presentation deduplicates announcements by the event ID,
not the delivery UUID. Journal restoration emits no event, and retry, confirmation or successful
discard clears the previous failure.

The catalog exposes running agent IDs and polls every 5 seconds while active and 15 seconds in
the background. `setActive(_:)` changes that cadence without cancelling an in-flight refresh or
discarding cached channels. An activity change wakes a sleeping poll, and cancelled refreshes
leave the last successful catalog and any existing failure unchanged.
`ChannelCatalogStore.state` retains the last complete, successfully decoded catalog.
`failure` retains the original refresh or reconciliation error alongside its display string,
`error`, so callers can distinguish HTTP authorization failures. Both clear on a successful catalog application.
The `lead` profile is required and supplies unopened channels with the server's name, role and
avatar. Missing or malformed profiles are protocol errors, not a reason to substitute client art.
Our demo scripts add the canonical fixture lead to their catalog responses without modifying the
Minecraft reference. `AgentAvatar.ink` is optional, and `resolvedAvatarInk(for:)` uses valid
six-digit ink at 3:1 or better against the unlit sRGB background, otherwise the stronger of black
and white. Invalid backgrounds have no resolved ink and retain the initial fallback.

`script/test` supplies the installed Swift Testing macro plugin path explicitly because the
current Command Line Tools build driver can omit it on incremental builds.

App-owned static rendering uses the same build and signed bundle:

```sh
SCRATCH_PATH=/tmp/tbm-core ./script/snapshot \
  --server http://127.0.0.1:3210 --channel studio-demo \
  --appearance light --size 1280x840 --snapshot /tmp/studio-light.png \
  --state transcript-request
```

The server and PNG destination are required. The app waits for live channel state and layout,
captures the normal SwiftUI scene rather than a separate window host, and exits nonzero on
failure. Restoration is ignored only in the process's volatile argument domain, and snapshot
runs refuse application-state saving/restoration. They do not persist preferences or mark
messages read.

Attached native sheets are included by rendering their own layer trees into the parent image.
These are app-owned static renders, not WindowServer captures of window shadows or corner masks,
and complement rather than replace native interaction checks.
With the macOS 26+ SDK behavior enabled, offscreen rendering also does not faithfully reproduce
Liquid Glass, sidebar selection or scroll-edge effects. Use these PNGs as layout evidence only,
and assess materials and selection in the real window.

`nextCronOccurrence(_:from:timeZone:)` follows cron-parser 5.10.2's Gregorian local-time
semantics, including DST and bounded search. It throws on invalid or unsatisfiable schedules.
Lists, ranges, steps, names, aliases, `L`, `#`, `?` and hashed `H` forms are supported. `W` is
rejected by that reference version. An optional `hashSeed` makes hashed schedules deterministic.

`cronSummary(_:locale:)` uses that same parser and describes hourly, daily, weekday and
single-weekday schedules with native locale-aware wall-clock times. Other valid schedules
retain their literal expression, including hashed schedules. Invalid expressions throw.
`transcriptDayLabel` uses its supplied calendar and time zone: Today, Yesterday, weekdays
for two through six days ago, then a full date, with the year outside the current year.

`channelArtifactShares(_:)` projects loaded `artifact_shared` messages by canonical file ID.
The highest-sequence event supplies the actor, share timestamp and Reveal sequence together.
It does not change the artifact's original `sharedAt` or invent metadata for unloaded history.

Regenerate the reference date/error fixtures without modifying the Toy Box checkout:

```sh
node script/generate-cron-fixtures.mjs ../toy-box
```

The parity and native interaction design are in [docs/spec.md](docs/spec.md).
