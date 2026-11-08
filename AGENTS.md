# Toy Box for Apple

Native SwiftUI clients for Toy Box Channels: a Mac app and an iPhone companion, built from one
shared core in Swift 6.4 and SwiftPM, with no Xcode project. Both target the 27 releases on Apple
Silicon and talk to Toy Box's public `/api/v1` HTTP and SSE routes.

This file is how we work together, following a change from the user's request to its release. It
applies our [Coding Agent Culture](https://gist.github.com/lostintangent/fe01cdf38ff1a370fcb08711a698ecfa)
to this project and wins where they differ. [docs/spec.md](docs/spec.md) is what we build, the
source of truth for parity, protocol and design.

| Read | Before |
| --- | --- |
| [docs/spec.md](docs/spec.md) | Changing behavior, protocol or design. Read its Design section, and your surface's section under Surfaces, before changing any view |
| [docs/development.md](docs/development.md) | Opt-in tests, benchmarks, the simulator, drive scripts, validation builds or bundle contents |
| [scripts/README.md](scripts/README.md) | Running or changing a command |
| [docs/releases.md](docs/releases.md) | Changing signing, updates, TestFlight or release tooling |
| [docs/quarantined-tests.md](docs/quarantined-tests.md) | Touching a quarantined test |
| `~/Desktop/toy-box` | Checking the server or web pane. It's a read-only reference, so never modify it |

## The team

- **The user** sets direction, picks between designs, approves every release and runs the checks
  that need a real phone or a signing key.
- **Lead** frames each change, writes it into the spec, gives each task one owner, reviews and
  merges every change and ships. Lead writes no product code, so review stays independent, and
  only Lead asks the user for decisions.
- **Designer** owns how both apps look and behave, mocks up options and reviews what's built
  against the spec's Design section.
- **Owners** each own one part of both apps: Core the shared foundation, and Shell, Transcript,
  Composer, Overview and Intelligence a surface each.

Messages lead with the outcome, in plain words. Post before slow work, so nobody waits in silence,
and after an interruption or restart, read everything before acting.

### Ownership

Edit only what you own, and ask the owner in the channel for anything else. App folders are under
`Sources/Desktop/ToyBoxDesktop/` and `Sources/Mobile/ToyBoxMobile/`.

| Owner | Owns |
| --- | --- |
| Core | `Sources/Shared/ChannelKit/` and `ChannelClient/`, `Tests/` except the files below, `scripts/`, `Package.swift` and `package.json`. On the Mac, `Sources/Desktop/ToyBoxControlIntents/` and `Sources/Desktop/Extensions/ToyBoxDesktopShare/`. On the phone, `Sources/Mobile/ToyBoxMobileIntegrations/`, the app's `Automation`, `Sources/Mobile/Extensions/ToyBoxMobileNotification/` and `ToyBoxMobileShare/`, and `Resources/Mobile/` |
| Core, with the originating UI owner | `Sources/Shared/ToyBoxUI/` |
| Shell | `App`, `Shell`, `Sidebar`, `Channel`, `Notifications`, `Intents`, `Settings` and `Shared` in both apps, and the Mac's `MenuBar` and `QuickSend` |
| Transcript | `Transcript` in both apps, and `Tests/Desktop/ToyBoxDesktopTests/TranscriptTests.swift` |
| Composer | `Composer`, the composer and its tray, in both apps, the phone's `Cards` (the list's talk and Needs You cards), and `Tests/Desktop/ToyBoxDesktopTests/ComposerTests.swift` |
| Overview | `Overview`, `Artifacts`, `Management` and `Screens` in both apps, the phone's `LiveActivities`, and the widgets: `Sources/Shared/ToyBoxWidgetViews/`, `Sources/Desktop/Extensions/ToyBoxDesktopWidget/`, `Sources/Mobile/Extensions/ToyBoxMobileWidget/` and `Tests/Mobile/Extensions/ToyBoxMobileWidgetTests/` |
| Intelligence | `Sources/Shared/ChannelIntelligence/` and `Tests/Shared/ChannelIntelligenceTests/` |
| Designer | `Resources/Shared/AppIcon.icon` |

A UI owner may add one `Tests/Desktop/ToyBoxDesktopTests/<Surface>Tests.swift` for their surface.

## How the code fits together

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
| `ComposerDraft`, `ComposerImage` | ChannelClient | Each app supplies its image-readability check: lazy `NSImage` validation on Mac, `UIImage` on iPhone. Persistence keys stay unchanged |
| `ChannelConnections` | ChannelClient | The spec's Connections invariants: one notice and one verb, Retry, per scope. Views change on `phase.isUnavailable`, never a timer, and actions wait for `phase.isConnected`. Refresh means only the channel list, and background work never lights the footer spinner |
| `SidebarFooter` | ToyBoxUI | Turns the catalog phase into the shared footer and names its server |
| `ChannelSidebarPresentation` | ChannelClient | Takes the catalog and the host's `openChannelIDs`. Its `channel`, `status`, `agents`, `working` and `catalogAgents` methods keep the Mac's live-versus-catalog rules and granular observation |
| `channel.matches(_:)` | ChannelKit | Matches name, purpose and directory. Callers keep their own query normalization and ordering |
| `ChannelAPI.channelURL(channelID:files:)` | ChannelClient | Builds browser routes, preserving deployment prefixes |

## 1. Frame the change

- **Start from an outcome the user will feel,** like "sending scrolls you to the bottom". Lead
  writes the decision into the spec before anyone builds it, and opens one task with one owner.
  The spec holds current rules, never history.
- **Choose the simplest design that meets it.** Use what Apple's platforms ship, in its idiomatic
  form, and build your own only for behavior Toy Box needs and the platform lacks. Add no cache,
  retry, abstraction or option until a measurement or a second case asks for one, and keep to
  what the user asked.

## 2. Show it first

- **A new visible feature starts as a picture.** The owner, Designer or Lead posts a mockup within
  about 10 minutes, often a quick edit of a real screenshot, with options when the choice is open.
  Building starts after the user picks, because a written spec alone isn't agreement.
- **A simple change goes straight to code,** like a symbol, constant, copy, spacing or a fix.
- **Nothing visible goes 30 minutes unseen.** If it does, or a small change starts growing, stop
  and show what exists.

## 3. Build it

- **Work in isolation.** Each task gets its own branch, named `<owner>/<task>-<slug>`, its own
  worktree and its own scratch path, so parallel builds never share `.build`. Take the simulator
  and benchmark through their lease, and quit the instances you launch.
- **Never touch real data.** Tests that write use the [demo servers](#commands). Read the live
  server on 3100 freely, but never post or mutate there without the Lead's approval of a specific
  scratch channel, and leave its process running.
- **Fix the cause, not the symptom.** Never paper over a bug with correction loops, retries,
  timers or extra layout passes.
- **Leave credentials to the user.** Agents never create accounts, profiles or secrets, accept
  agreements, read keys or passwords, or run real credential setup.

### Swift

- **Use `@ViewState`, never `@State`.** The macOS 27 Command Line Tools SDK exports an unusable
  `@State` macro, so `@ViewState` aliases `SwiftUI.State` once in `ToyBoxUI/Shared`.
- **Declare environment values with an `EnvironmentKey`,** not `@Entry`, in code that builds for
  the Mac. Command Line Tools lack the SwiftUIMacros plugin.
- **Put rules on their nouns.** Write members such as `channel.attention`, `agent.handle` and
  `state.applying(event)`, not free functions. Name a type for the thing itself, nesting a part
  under its owner (`Channel.Attention`, `ChannelTask.Timing`), and avoid Manager, Helper, Support,
  Context and Projection.
- **Keep a feature's rules out of the app targets.** Put them in a UI-free ChannelClient model
  with its animation, waits and announcements passed in, like `TalkRecorder`, and prove them with
  Mac tests. `simulator --build-only` checks the phone compiles, and the simulator is only for
  what you need to see.
- **Adapt to the phone's scene.** Mobile views use SwiftUI's safe areas, layout margins, size
  classes and adaptive navigation. Never hard-code a safe-area inset, device size or Duo fold
  width. Mockup canvas measurements are not implementation constants.

### Client rules

- **Channels are live server state, not local-first data.** Show stale data as stale, keep
  connection status apart from activity, and resume from the last applied revision. Only what the
  user writes, like a draft, is saved locally first.
- **Every send goes through `ChannelOutbox`,** a deliberate guard for the user's words. It gives
  each message a UUID and reuses it on every attempt and Send Again, so the server never posts one
  twice.
- **Management writes are never retried.** A 422 is a rejection, but a 500, timeout or lost
  connection may have committed, so call `reconcileManagementWrite(channelId:)` before offering
  another attempt. Can't connect, offline and bad-host failures stay ordinary retryable errors.
- **Reading never answers a request.**
- **The catalog's `lead` profile is required.** Treat a missing one as a protocol error, and never
  substitute client art.

### Commands

Use Bun 1.4.4: run `bun install --frozen-lockfile`, then the root `package.json` commands.

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

- **SwiftPM builds everything, with no Xcode project.** The Mac builds with Command Line Tools
  only, and the phone with Xcode's toolchain through SwiftPM. Use the `bun run` commands, never
  `xcodebuild`, `xcresulttool` or `devicectl`, and never download simulator runtimes.
- **The simulator and the benchmark run one at a time** on this Mac. Their commands wait for each
  other, so never boot another simulator, run `simctl` by hand or poll. Warn the user before
  `bun run benchmark key`, which takes focus for about 45 seconds.
- **Changes to bundle or release tooling need both real release dry runs.** There are no script
  tests.

## 4. Prove it

- **Done means demonstrated,** in the fastest way that still proves the change: a focused test
  run, a screenshot or a short recording.
- **Scale validation to the change.** A symbol, constant or spacing change needs a build, the
  touched suite and one capture of the result, not a light/dark and size matrix. Save full passes
  for behavior, layout or concurrency changes, and leave the rest to the release build.
- **Validate in Dark at the default text size,** which is how the user runs both apps. Add Light
  only when a change touches color values, materials or contrast, and larger sizes only when it's
  about text sizing. Both appearances and every size must still work, so never hard-code a color
  or size that would break them.
- **Test each promise once,** at the lowest layer that can prove it, and watch a new test fail
  before it passes.
- **Some test machinery is deliberate.** SwiftPM can't host XCUITest, so the phone's DEBUG-only
  drive scripts, and the Mac's snapshot states and benchmarks, stand in for UI and performance
  tests. Release phone builds carry no driver. Add to them only for a check nothing else can make.

### The running app

- **Mac:** use Computer Use only on `dev.toybox.desktop.test` ("Toy Box Test"), which
  `bun run validate` builds optimized and launches against the demo. The user's
  `dev.toybox.desktop` permits reads, never clicks. Confirm `studio-demo` before acting, never act
  in a window listing live channels, and `kill <pid>` your instance when you finish.
  `bun run snapshot` is layout evidence only, so verify materials, selection and scroll-edge
  effects in a real window.
- **iPhone:** capture with `bun run simulator --screenshot` or a drive script under the lease.
  Check on a real phone only through TestFlight, never a direct install, so development never
  replaces the user's app or its data.

### Test reliability

- **Quarantine an unexplained failure the same day.** A test that fails on main without an
  identified code cause moves behind an explicit opt-in. Don't leave it in the merge gate while
  rerunning CI or patching timing races in place. Record the failed run, test case and
  diagnostics in [docs/quarantined-tests.md](docs/quarantined-tests.md), with an owner and a
  follow-up task. Quarantine changes gating, not responsibility for the failure.
- **Restore it only with its cause and deterministic coverage.** Never loosen assertions or add
  retries to turn an unexplained failure green. Then delete its entry.
- **CI protects decisions with deterministic tests** over inputs such as measured frames. Native
  window tests in CI assert settled end states, never per-frame timing. Frame-timing and
  WindowServer-event checks stay opt-in and run locally before changes to their behavior.
- **Test gates and hooks suspend,** never block a cooperative worker. CI runs ChannelClient with
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` to enforce this.
- **Client tests wait with `eventually`,** through Observation and the mock's own request,
  held-response and stop signals, never polling or an elapsed-time assertion. Their suites have a
  one-minute Swift Testing hang limit.
- **A wait for a signal that might never come needs its own deadline.** Swift Testing's time
  limit doesn't end it, so one hung wait stalls the whole suite.
- **Never run synthetic CPU burners on the shared Mac.** They starve every agent's builds and the
  simulator. Judge load-sensitive failures from CI or ordinary full runs.

## 5. Hand off and merge

- **Hand off with your proof.** Say what you verified, what you didn't, and what still needs a
  real device, server or signing key. Attach channel images from your session `files/` folder,
  never `/tmp`, because posts keep their original paths.
- **Lead reviews every change** against its outcome and the spec, merges it into `main` with
  `git merge --no-ff` once main's CI is green, and adds its [release note](#release-notes).

## 6. Release

- **Tags need the user's approval.** `vX.Y.Z` ships the Mac to GitHub Releases, and
  `mobile-vX.Y.Z` ships the phone to TestFlight. A manual workflow run on `main` is a dry run.
  Signing, notarization, updates and TestFlight are in [docs/releases.md](docs/releases.md).
- **Workflow actions stay pinned** to full commit hashes with readable version comments.
  Dependabot checks them weekly.
- **Never alter the user's installed validation bundle** or microphone permission state to test a
  release.

### Release notes

- **They're written at merge time.** The merge that lands a user-facing change adds its bullet to
  that platform's next unreleased `## Mac X.Y.Z` or `## iPhone X.Y.Z` entry in `CHANGELOG.md`,
  under `### Features` or `### Bugs/Polish`, creating the entry if the newest one has shipped. A
  release is then only a tag.
- **Each bullet leads with what the user gains, in plain words.** Name the moment they'll notice
  it and why it matters, never how it works. If a reader who never saw the code couldn't say why
  they'd care, rewrite it.

  | Not | But |
  | --- | --- |
  | Quick Send, menu bar replies and notification replies now finish the moment you send, and a message that can't go out waits in its channel. | Sending from Quick Send, the menu bar or a notification is now instant, and if your connection drops or your server is asleep, Toy Box sends your message as soon as it can, so nothing you send gets lost. |
  | A request waiting for you can now be read aloud, from the channel list or the conversation. | A request waiting for you can now be read aloud, so you can hear it while you do something else, even with your phone locked. |

- **Leave out internals and mechanics.** No internal names such as the outbox, and no placement,
  glyphs, colors, counts or gestures unless they're the point.
- **Write one bullet per gain,** folding changes that serve the same one together. Each
  platform's notes stand on their own, never compared to the web or the other app.
- **The Lead rereads every unreleased bullet** against these rules before asking for a tag.

## Keeping this current

When the user corrects how we work, the rule changes here the same day, at the stage where it
applies, replacing what it supersedes. The channel purpose says what we're building and each
member's role says what they're accountable for, so neither restates these rules.
