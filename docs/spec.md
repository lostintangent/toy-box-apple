# Toy Box Channels for Mac: spec

A native macOS client for Toy Box Channels. It gives the user the full Channel pane experience
(transcript, composer, overview) in an app that feels first-party on macOS. Toy Box keeps owning
Channels, agents, sessions and durable work. This app is a presentation and input surface over the
same public Channel protocol that the Minecraft client uses.

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

- Swift 6 and SwiftUI on macOS 15 or later, using AppKit only where SwiftUI falls short (text input,
  for example). The project is a Swift package built with `swift build` from Command Line Tools,
  so it needs no Xcode project or Xcode license. A script assembles and launches a signed-ad-hoc
  `.app` bundle.
- **Targets:** `ChannelKit` is the pure domain: Codable wire types, the reducer, transcript rows,
  audience, tasks, presence and the SVG avatar path parser. `ChannelClient` handles transport:
  HTTP, SSE, the observer and the catalog. `ToyBoxChannels` is the app. Tests live in
  `ChannelKitTests` and `ChannelClientTests`.
- **State:** each open channel has one `@Observable` store, which owns its `ChannelState`, connection
  phase, unread boundary and paging. The catalog store owns the channel list and refreshes it on
  launch, on app activation, on demand, and on a timer: about 5 seconds while the app is active, and
  about 15 seconds in the background so requests still reach the Dock badge and notifications.
- **Wire rules:**
  - Decode leniently, so unknown system message kinds and fields degrade to a generic row instead
    of failing the stream.
  - Resource URLs (artifacts, attachments) resolve against the configured server base URL, which may
    include a path prefix.

## Protocol (v1)

| Request | Use |
| --- | --- |
| `GET /api/v1/channels` | Catalog `{version, channels, members, working}` for the sidebar. `working` lists running agent IDs (added for this app) |
| `GET /api/v1/channels/:id` (SSE) | `snapshot`, then live events. With `after`/`Last-Event-ID`: replay, then `resumed` with full presence. `presence` is sparse and merges. `deleted` is terminal |
| `GET /api/v1/channels/:id/messages?before=N` | Older page of up to 100 messages `{version, revision, messages}` |
| `POST /api/v1/channels/:id/messages` | `{id, content, attachments?}` with a client UUID. 201 returns the message. 409 means a duplicate. Never auto-retry |
| `POST /api/v1/channels/:id/read` | `{sequence}` monotonic read, which acknowledges completion but never a request |

Management routes (added to Toy Box for this app, documented in its Channels `AGENTS.md`):

| Request | Use |
| --- | --- |
| `GET /api/v1/models` | `{version, models, defaultModel}` for model pickers |
| `POST /api/v1/channels` | Create `{name, purpose?, directory?, model}`. 201 `{version, channel}` |
| `PATCH /api/v1/channels/:id` | Edit `{name?, purpose? (null clears), model?}`. Returns `{version, channel}` |
| `DELETE /api/v1/channels/:id` | Delete the channel (204). The stream then sends `deleted` |
| `POST /api/v1/channels/:id/members` | Create a member `{name, role?, model?}`. 201 `{version, member}` |
| `PATCH /api/v1/channels/:id/members/:agentId` | Edit `{name?, role?, model? (null inherits)}`. Returns `{version, member}` |
| `DELETE /api/v1/channels/:id/members/:agentId` | Remove a member (204) |
| `POST /api/v1/channels/:id/routines/:routineId/run` | Run a routine now (204) |
| `DELETE /api/v1/channels/:id/routines/:routineId` | Delete a routine (204) |

Errors return `{error}`. A malformed body is 400, a missing channel, member or routine is 404,
and a domain rejection such as a taken mention is 422 with a user-facing message.

Attachments are `{name, url}` or inline `{mimeType, base64}`. Avatars are SVG path data in a
24×24 viewBox plus a hex color. The lead's avatar is intrinsic.

## Parity checklist

### Sidebar (channel list)

- [ ] Channels from the catalog, ordered like the browser and showing the lead and member avatars
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
      count badges
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
- A Settings scene for the server URL (default `http://localhost:3100`) and connection test
- A Dock badge counting channels that need attention, plus user notifications for requests and
  completions in channels that aren't currently focused
- Multiple windows, state restoration, and accent color and vibrancy that respect system settings

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

### Window and navigation

All dimensions are logical points, not pixels.

| Surface | Default | Limits and behavior |
| --- | --- | --- |
| Main window | 1280 x 840 | Minimum 760 x 560. Restore size, selected channel, sidebar, filter and inspector per window |
| Sidebar | 248 wide | Resizable 220...320. Standard source-list selection and full-height material |
| Conversation | Remaining width | At least 420. Transcript and composer share one centered lane, max 760 wide, 24 horizontal inset |
| Inspector | 312 wide | Resizable 280...400. Do not squeeze conversation below 420 |
| Toolbar | System height, approximately 52...60 | Unified native toolbar, traffic lights and normal window dragging |
| Narrow window | Below 1000 wide | Inspector opens as a native sheet, preferred width 360, rather than stealing transcript width |

Use `NavigationSplitView` for sidebar and conversation, and a trailing `.inspector` when there is
room. The inspector is initially visible at the default width. Remember its desired visibility
when temporarily adapting to a narrow window. Do not automatically hide a user-opened sidebar.
With the sidebar hidden, the transcript stays centered rather than stretching its bubbles.

The sidebar toolbar holds the sidebar toggle, title "Channels" and New Channel (`plus`).
The detail toolbar shows the channel name, without a decorative hash prefix, and a one-line
secondary purpose subtitle where the system supports it. Trailing controls are the working
summary, Message View (`line.3.horizontal.decrease`), Channel Actions (`ellipsis`), and Overview
(`sidebar.trailing`). Put Open in Toy Box in Channel Actions and the menu bar, not another
permanent toolbar button. Standard toolbar overflow handles constrained widths. Hide the purpose
subtitle before truncating the title, then reduce the activity summary to its count.

Opening a channel selects it in the current window. Command-click or Open in New Window creates a
separate window for that channel. Windows share the same channel store and draft. Only a key,
visible conversation actively acknowledges reading. Restoring a window must not send a message or
silently mark its unseen content as read.

### Visual system

Use SF Pro through system fonts and semantic weights. No custom typeface, hard-coded all-caps
section headings, gradients on messages, dashboard cards around every section, or decorative
drop shadows. Use an 8-point spacing rhythm, with 4-point adjustments inside compact controls.

| Token | Native treatment |
| --- | --- |
| Conversation background | `textBackgroundColor`, opaque in both appearances |
| Agent message surface | `controlBackgroundColor`, subtle `separatorColor` hairline |
| Navigation and inspector | System sidebar and inspector materials, no manual blur stacking |
| Floating controls and popovers | Native toolbar, popover and control materials |
| Text | `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor` by hierarchy |
| Selection and focus | System accent, source-list selection and focus ring. Respect user accent |
| Toy Box identity | Intrinsic lead star and its exact `#0891b2` avatar fill. Do not recolor it to the accent |
| Unread | Semantic system blue, 1-point New rule. Blue does not mean working |
| Requests | Semantic system orange/amber with a question symbol and text |
| Completion and additions | Semantic system green plus checkmark or explicit `+` sign |
| Error, blocked and removals | Semantic system red plus symbol, label or explicit `-` sign |

On macOS 27, let the system render its current Liquid Glass toolbar and navigation controls.
Custom glass is limited to the small floating Jump to Latest control, and only if the build SDK
provides the appropriate availability-gated API. macOS 15 uses native material equivalents.
No visual behavior depends on glass support. Reduce Transparency makes material backgrounds
opaque. Increase Contrast strengthens separators and control outlines, not saturation alone.

| Content | Size and weight | Layout |
| --- | --- | --- |
| Sidebar channel title | 13, medium | One line, tail truncation |
| Sidebar detail and timestamps | 11, regular | Secondary, tabular digits for time/counts |
| Message body and composer | 14, regular | Approximately 20 line height. Never compress line height to fit |
| Message author | 12, semibold | Timestamp and addressee 11, regular |
| Inspector section heading | 12, semibold | Count badge 11, regular, no forced uppercase |
| Inspector body | 13, regular | Approximately 18 line height |
| Inline code and diff counts | System monospaced, 12 / 11 | Code blocks scroll horizontally |

Honor the system accessibility text size where available and a native View > Text Size control
(Smaller, Default, Larger). Scale content text, row height and wrapping together. Keep toolbar and
standard controls at native sizes. At the largest size, no critical text truncates without an
accessible full value or an expansion action.

### Sidebar

Place a native channel search field directly below the toolbar, inset 12. It filters the local
catalog by channel name, purpose or directory without making a network search request. Preserve
the selected channel while filtering. The list remains one "Channels" group in server order.
Do not reorder it for presence or attention. Refresh preserves scroll and selection.

Each row is at least 64 high, with 8 horizontal and 7 vertical content padding, an 8-point corner
radius supplied by native selection, and an 8-point gap between a 28-point cyan-tinted `number`
tile and the text. The first line holds name and trailing attention. The second line holds the
directory's last component or relative updated time, plus a lead-first avatar stack at the right.
Avatars are 16, overlap by 4, show at most three, then `+N`. No directory means time occupies the
detail slot, never an empty label. Full path and timestamp are available as help and accessibility
values. Selected and inactive-window rows use standard source-list appearance.

Attention occupies a reserved 18-point trailing slot so titles do not jump:

| Priority | Indicator | Help and accessibility |
| --- | --- | --- |
| Pending request | Orange `questionmark.bubble.fill` | "Waiting for your response". Remains visible while open |
| Unread completion | Green `checkmark.circle.fill` | "All tasks completed". Suppressed for an open channel |
| Ordinary unread | Blue 6-point dot | "Unread messages". Suppressed for an open channel |
| Working, without attention | Small activity ring beside avatar stack | Names of agents working. Not an unread badge |

The avatar stack exists independently of attention, so a working team and pending question can
coexist. Closed channels use catalog activity only if the protocol actually supplies it. Never
invent presence or keep stale work animations after losing observation. Context menu: Open in
New Window, Open in Toy Box, Edit Channel, Reveal Working Directory when applicable, then Delete
Channel. Delete is separated and destructive, never triggered by the unmodified Delete key.

**Catalog activity:** the catalog now includes `working`, the IDs of leads and members whose
sessions are running. This is the same fact the browser reads from workspace session state and
the stream uses for presence. Sidebar rows for closed channels use it, while an open channel uses
its live presence. Activity can lag by one catalog refresh. It must clear when observation is lost
rather than keep animating.

### Transcript

Use the canonical row projection unchanged. Avatar column is 32, gap is 12, and body begins 44
points into the lane. Runs have 20 points between them, 8 between entries in a run and 4 between
header and body. A header only repeats when `showHeader` says it does. Agent bubbles have 12-point
corners, 12 horizontal and 10 vertical padding, and no tail. They fit their content up to the lane
width. The user's message aligns trailing, max 80% of the lane, with a low-intensity accent-tinted
surface and normal label text. Do not use white body text on a saturated brand color.

Agent avatars are circular, with the exact supplied background and path. Draw the 24-unit path
at 64% of the avatar, stroke 2.25 units, round caps and joins. Choose black or white path ink by
measured contrast. A missing profile uses the name's initial on a subtle cyan field. A removed
agent uses `person.crop.circle.badge.xmark`, neutral fill and the name "Deleted agent" everywhere,
including reactions and task owners. Historical text stays intact. The lead keeps its star.

The addressee follows the author with a muted right arrow. Known leading mentions are omitted
only according to the canonical helper. In-body mentions are selectable text with a small tinted
background and accessible agent name. Unknown mentions remain literal, not a false agent chip.
Links have normal native link affordances. Render headings, emphasis, lists, blockquotes, fenced
code, inline code and tables, with selectable text. Code blocks offer Copy Code, and tables may
scroll horizontally. Never execute HTML, scripts or embedded remote content from Markdown.

Only coordination entries marked collapsible truncate, at 160 points of body text, with a subtle
24-point bottom fade and Show More. Show Less returns to that same anchored row. Messages for the
user and all flagged requests always remain expanded. User-initiated expansion is preserved while
rows update. The copy action copies the original full message, including its leading mentions.

Pending requests have a 1.5-point orange outline and a header label "Needs your reply" with
`questionmark.bubble`. A later committed user message changes that historical label to a checkmark
and "Replied". Neither reading nor an optimistic send clears a request. Do not pulse the outline.
Reply and Copy Message appear on hover or keyboard focus and in the context menu. Reply prepends
the agent's mention once, preserves the draft and focuses the composer. Deleted agents cannot
be replied to. Keep message selection, link selection and context menus usable independently.

System rows align their 14-point symbol in the avatar column and use 12-point secondary text.
They have a minimum 28-point hit area and 8 points of surrounding vertical space. Matching
membership events and same-agent artifact shares merge only where the canonical projection does.

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

Day rules use 11-point secondary labels ("Today", "Yesterday", localized full date). The unread
rule is blue with "New" at the trailing edge. If day and unread coincide, combine them into one
rule. Capture the unread boundary only after snapshot or replay completes, and never move it as
the user reads. This boundary is not an extra synthetic message.

Land on the first unread row, otherwise the end. Follow incoming messages only while within
48 points of the end, or immediately after the user's own successful post. If scrolled away, a
small material Jump to Latest button appears 12 points above the tray. It does not obscure a
message. Preserve the visible top message and its offset while prepending history. At the top,
show a small loading row, "Beginning of conversation", or "Couldn't load older messages" with
Retry. A filtered view must continue paging even when a page contains no visible rows.

The Message View menu is a native radio-choice menu: All Messages and Your Messages. A non-default
filter gives its toolbar button an active tint and label/help. It does not change the composer
audience or channel-wide read policy. Read only committed visible sequences in the active window.
Opening an inspector, reading a preview popover or watching a background window does not mark
unseen messages read.

Attachments appear below their own message, with 8-point spacing and corners. Image thumbnails
fit within 240 x 160, never crop away essential content, and open native Quick Look on click or
Space when focused. Videos have a poster, duration when known, and an explicit Play action.
Other files show document icon, name and Open. Resolve resources against the server base URL.
An unavailable file keeps its name and an explicit retryable error, not a blank thumbnail.
Opening remote URLs must not assume a matching local filesystem path.

Reactions are display-only in this client, matching the user pane. Use the existing emoji for
done, agree, celebrate, love and laugh. Also show the projected looking/working reactions while
the agent's live presence and matching status target permit them. Group by reaction, then show up
to three 14-point reactor avatars and `+N`. Chips are 24 high with a subtle border. Hover, keyboard
focus or activation reveals every reactor name. Do not make a reaction chip look like an enabled
"add reaction" button. The working row after the last message has 20-point avatars, "Name is
working" or "N agents are working", and expanded status text on activation. Waiting belongs in
the inspector, not this row.

### Composer and tray

Dock a solid composer region using the conversation's bottom safe-area inset. It has a hairline
top separator, 12 top and 16 bottom padding. Keep the shared 24-point lane insets. Do not float a
second glass panel behind the whole composer.

The composer is a single rounded rectangle, radius 12, with a separator-colored border and native
focus ring. Text is inset 12, starts at one 20-point line and grows through three lines before
scrolling internally. The controls row is 28 high, with 8 points between controls. Baseline height
is approximately 80, max approximately 120 before attachment thumbnails. Attach Image
(`photo.badge.plus`, 28-point hit target) is leading, then audience, then Input Needed. Send is a
28-point circular `arrow.up` trailing button using system accent. Empty content is sendable only
when at least one valid attachment exists.

Return sends. Shift-Return inserts a newline. Command-Return also sends. Do not submit an IME
marked-text composition or while a completion menu is consuming Return. Escape dismisses
completion or a popover without destroying text. Standard selection, undo, spelling, dictation,
writing-direction and accessibility behavior must work through native text input.

Mentions remain plain `@handle` text. The completion popover anchors to the caret, opens above the
composer when needed, is 300 wide and at most 320 high, and scrolls its own list. Order: Everyone,
Lead, alphabetically matching members, then Create [Name] where canonical matching permits it.
Rows are at least 44 high with 24-point avatars, name and one-line role. Up/Down select, Return or
Tab accept, Escape cancels. Accepting inserts one trailing space and restores the caret. A
member's secondary Edit action opens a sheet without accepting the mention. A Create action
explicitly says it creates and starts a new agent. During creation show progress on that row,
disable duplicate acceptance, preserve typed text on failure and show the error in the popover.

The audience pill reads "To Lead", the canonical audience label, or "No one will be notified" in
amber. At narrow widths, show avatars plus a count and preserve the full names in help and
accessibility. This is a preview of delivery, not a manually selected recipient control.
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
rather than using disabled controls alone. A stale snapshot must never determine a new send's
audience without reconnection.

Submitting creates one optimistic row with "Sending". A committed echo replaces it by UUID.
On a definite rejection, retain the draft and mark the row "Not sent". On timeout or lost response,
say "Delivery not confirmed" rather than falsely claiming failure. Expose Edit and explicit Send
Again, never an automatic retry. Keep the original UUID when verifying or explicitly repeating
that attempted send so a 409 cannot deliver it twice. Do not clear a newer draft when an older
send eventually succeeds.

The tray sits 8 points above the composer, one compact 28-point row. Lead with the newest shared
artifact as a document pill, then `+N` for remaining artifacts. Trailing controls are Tasks with
direct-root `done/total` and a 3-point progress track, and Preview when set. Zero-content controls
are absent. When space is insufficient, collapse artifact names before hiding Tasks or Preview,
and use a native overflow menu rather than a horizontally scrolling toolbar. Artifacts and Tasks
open anchored native popovers, preferred 360 wide, max 420 high. Task rows are the same projection
as the inspector. URL Preview opens the configured URL in the default browser. Screen Preview
opens that channel in Toy Box, with an explicit label, never a fictitious local live screen.

### Overview inspector and readers

Title the inspector "Overview" in its native top region with a close control. Use 16-point content
insets, 24 points between sections, 8 between heading and content, and no nested card containers.
Order: purpose/directory/preview, Team, Tasks, Artifacts, Routines. Count badges are compact and
neutral. Empty sections show one quiet explanatory sentence and never disappear unexpectedly.

Purpose is 13-point text, three lines initially, with Show More. Missing purpose reads "No purpose
set" with Edit Channel. Directory is a middle-truncated path row with `folder` and a full-path help
value. Reveal in Finder is offered only when the configured server is local and the path exists
on this Mac. Otherwise offer Copy Path and Open in Toy Box. Never claim a remote path was opened.
Preview uses its typed URL or screen presentation, consistent with the tray.

Team is lead-first, then alphabetical members. Rows are at least 48 high, avatar 28, gap 10.
Name is 13 medium, the second line is status text while active or role while idle. A 1.5-point
working ring or dashed waiting ring sits 3 points outside the avatar. Working includes a text
label, not just motion. Waiting includes "Waiting for [reason]" and, if scheduled, "Checks again
in 8 min". Update the countdown at minute boundaries, show the absolute local time in help, and
use "Check due" after it passes rather than inventing a new wake. Idle is not Waiting. Opening a
member's details shows the full role and status in a native popover/sheet, never private session
contents. Member menu offers Reply, Edit Member and Remove Member. Lead offers Reply only,
because its identity is intrinsic. Add Agent is a subdued plus row at the end.

Task status is read-only: pending empty circle, in-progress partial ring, blocked
`exclamationmark.circle`, done `checkmark.circle.fill`. Never render these as user-toggleable
checkboxes. Indent children 16 points. The disclosure is independently clickable and keyboard
operable. Titles wrap. Done titles use secondary text, not strikethrough, and owner colors and
diff counts retain their normal contrast. Owner avatars are 16. A parent badge is direct-child
`done/total`, and the section/tray count uses direct roots, exactly as the pane. Completion
attention still requires every descendant done. Aggregate reported diffs recursively without
double counting. Pending rows omit counts. Measured zero is distinct from absent, and compact
numbers have exact accessible values. A task's artifact action opens only that task's artifact,
does not toggle disclosure and stays visible when collapsed. Missing referenced artifacts keep a
disabled document icon with "Artifact unavailable".

Artifacts are document rows, at least 40 high, with title, file kind and shared time. The inspector
retains canonical order, while the tray is explicitly newest-first. Markdown opens a native
reader sheet/window with a selectable body, title, path, Open in Toy Box and Share/Copy Link.
Other supported types use Quick Look or the default application. Show actual fetching and error
states, and do not open a blank success-shaped reader. Reader content is loaded from the server
resource URL, not by assuming the server file exists locally.

Routines have a 32-point title row and a second schedule line. Disclosure reveals the literal
prompt, cron expression and next local occurrence. An invalid/unavailable next-run calculation
shows the cron expression and "Next run unavailable", not a guessed date. Run Routine is an
explicit menu action, disables while pending and reports "Run requested" on success, never a
synthetic transcript post. Delete Routine has a native confirmation. The user does not create or
edit routines here, matching the pane.

### Management and Settings

All management uses the approved v1 endpoints, not browser RPC or filesystem writes. New/Edit
Channel is a native sheet, preferred 520 wide, with 20-point insets and native form spacing.
Fields: name (required, server's 100-character limit), purpose (optional, multiline, server's
12,000-character limit), lead model, and working directory. Directory is selectable only on
creation, read-only on edit. Offer inherited/default model explicitly when allowed. Restrict
model choices to the current provider where required, with help that changes apply on the next
execution. Never invent a model when the catalog is unavailable. Use real validation messages,
Cancel and the default Create Channel/Save button. Command-Return submits a valid sheet, Escape
cancels. A failed mutation leaves all fields and the sheet intact.

Add Agent starts with a name and clearly says the agent starts onboarding immediately. Edit
Member is 520 wide with identity, name, multiline role and optional model. Names affect mentions,
so show that help. Preserve server validation for unique handles and role requirements. The lead
cannot be edited through this sheet. Deletion confirmations name the exact target and consequence:
deleting a channel removes its agents and private sessions, removing a member retains public
messages and reactions as Deleted agent, and deleting a routine stops future scheduled runs.
Cancel is the safe default. There is no fake Undo for irreversible server deletion.

Settings uses a native scene with General and Notifications sections. General includes Server
URL, Test Connection, status, and the selected appearance (System by default). Validate HTTP(S),
preserve path prefixes and display actionable failures. Changing servers prompts before replacing
live connections, namespaces drafts, then refreshes the catalog. Notifications explains requests
and completions before asking system permission in response to an explicit enable action.
Permission denial shows Open System Settings, never repeated permission prompts.

### Menu and keyboard model

Use native About, Settings (`Cmd-,`), Services, Hide, Quit, Edit, Window and Help menus. Standard
text-editing shortcuts retain their native meaning. Commands below disable when inapplicable.
Focus Composer does not discard selection or any existing draft.

| Menu | Command | Shortcut |
| --- | --- | --- |
| File | New Channel | `Cmd-N` |
| File | Open Channel in New Window | `Cmd-Shift-N` |
| File | Open in Toy Box | `Cmd-Shift-O` |
| Edit | Find Channel | `Cmd-Option-F` |
| View | Show/Hide Sidebar | `Ctrl-Cmd-S` |
| View | Show/Hide Overview | `Cmd-Option-0` |
| View | All Messages / Your Messages | `Cmd-1` / `Cmd-2` |
| View | Refresh | `Cmd-R` |
| View | Text Size: Larger / Smaller / Default | `Cmd-+` / `Cmd--` / `Cmd-0` |
| Channel | Next / Previous Channel | `Ctrl-Tab` / `Ctrl-Shift-Tab` |
| Channel | Next Channel Needing Attention | `Cmd-Shift-U` |
| Channel | Focus Composer | `Cmd-L` |
| Channel | Jump to Latest / Input Needed | `Cmd-J` / `Cmd-Shift-J` |

Space previews a focused attachment, Return opens a focused artifact, and Right/Left expand or
collapse a focused task or routine. Sidebar arrows select without stealing first responder to the
composer. Switching channels by click may focus the composer after connection, but keyboard
navigation keeps list focus until explicitly moving into the conversation.

### Loading, empty, error and stale states

| State | Presentation and available actions |
| --- | --- |
| First catalog load | Three static placeholder rows, no fabricated channel names. Show native progress only if loading exceeds 300 ms |
| No channels | Source-list empty state: "Your channels live here", New Channel button, server shown in secondary text |
| Search has no matches | "No channels match [query]", Clear Search. Do not show the no-channels creation state |
| Nothing selected | Centered `bubble.left.and.bubble.right` symbol, "Choose a channel", concise navigation hint |
| First channel snapshot | Static message placeholders and "Connecting". Composer shell remains present, Send unavailable |
| New empty channel | "Your lead is getting started", "Send a message or type @ to add an agent". Keep composer and working status visible |
| Filter has no messages | "No messages for you yet", Show All Messages. Keep paging older history until exhausted |
| Reconnecting with cached state | Keep transcript and scroll intact. A 32-point inline banner below toolbar says "Reconnecting. Messages may be out of date" with Retry. Disable delivery, not editing |
| Disconnected without any state | `wifi.exclamationmark`, "Can't connect to Toy Box", server host, readable failure, Retry and Settings |
| Catalog refresh fails | Keep existing rows, mark them stale and show one sidebar footer error. Never replace them with "No channels" |
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
180...240 ms, but initial landing and history anchoring must be immediate. A working ring rotates
slowly, about 2 seconds per revolution. Reduce Motion replaces it with a static segmented ring
and "Working". Requests never animate. No looping shimmering skeletons or large empty-state art.

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
for a request, reveals its message. Respect system notification permission and Focus.

### Implementation review gates

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
