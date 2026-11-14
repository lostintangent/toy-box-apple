# Toy Box for Apple

Native SwiftUI clients for Toy Box Channels: a Mac app and an iPhone companion, built from one
shared core in Swift 6.4 and SwiftPM, with no Xcode project. Both target the 27 releases on Apple
Silicon and talk to Toy Box's public `/api/v1` HTTP and SSE routes.

This file is how we work together, following a change from the user's request to its hand-off. It
applies our [Coding Agent Culture](https://gist.github.com/lostintangent/fe01cdf38ff1a370fcb08711a698ecfa)
to this project and wins where they differ. [docs/spec.md](docs/spec.md) is what we build, the
source of truth for parity, protocol and design.

It holds only what every member needs on every task. Work that one role does, or that comes up only
sometimes, lives where it loads when you need it:

| Read | Before |
| --- | --- |
| [docs/spec.md](docs/spec.md) | Changing behavior, protocol or design. Read its Design section, and your surface's section under Surfaces, before changing any view |
| The [validate](.agents/skills/validate/SKILL.md) skill | Proving a change in the running Mac app or the simulator, or running a benchmark or an opt-in suite |
| [scripts/README.md](scripts/README.md) | Running or changing a command |
| [docs/quarantined-tests.md](docs/quarantined-tests.md) | Quarantining a test, or touching a quarantined one |
| The [release](.agents/skills/release/SKILL.md) skill | Merging, release notes, shipping, or changing toolchains, bundles, signing, updates or TestFlight |
| `~/Desktop/toy-box` | Checking the server or web pane. It's a read-only reference, so never modify it |

## The team

- **The user** sets direction, picks between designs, approves every release and runs the checks
  that need a real phone or a signing key.
- **Lead** frames each change, writes it into the spec, gives each task one owner, then reviews,
  merges and ships. Lead writes no product code, so review stays independent, and only Lead asks
  the user for decisions.
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
| `ChannelKit` | The domain: Toy Box's nouns as values, with their rules as members, like channels, messages, requests, tasks and routines. Pure and synchronous, with no I/O |
| `ChannelClient` | The live subsystems both apps run, like each server's connection and catalog, a channel's store, the outbox, the composer and cards. Each holds state over time and draws nothing |
| `ChannelIntelligence` | On-device Foundation Models |
| `ToyBoxUI` | Shared SwiftUI, without AppKit or UIKit, in two tiers: `Design`, the identity and primitives any surface uses, and a folder per surface that composes them. Code that draws nothing belongs in ChannelClient or ChannelKit |
| `ToyBoxDesktop`, `ToyBoxMobile` | Each app and its native platform integration, with AppKit or UIKit where SwiftUI falls short |
| `ToyBoxControlIntents`, `ToyBoxMobileIntegrations` | What each app shares with its extensions, which live under `Extensions` |

Each module is organized by subsystem, never by layer. A folder is named for the noun it owns and
a file for its main type, so there's no grab-bag folder like `Stores`, `Sending` or `Shared`, no
file at a module's root, and no `Presentation` suffix on a type.

Both apps share one implementation of every rule. Views never reimplement reducer, audience,
task, attention or transcript-grouping rules, and the sidebar's rows and footer, channel search,
transcript Markdown, composer drafts and browser URLs are already shared, so look in ChannelKit,
ChannelClient and ToyBoxUI first. If what you need is missing, ask Core to add it there.

Surfaces meet at these seams:

| Seam | Contract |
| --- | --- |
| `AppModel` | Each app's environment: the server URL, `ChannelCatalogStore` and its `ChannelAPI` |
| `ChannelStore` | One per channel, passed in and shared by every window that shows it |
| `ChannelInteraction` | One per channel window, for what one surface asks of another, like Reply, Reveal or Jump to Latest. Any owner may add a narrow intent and announce it in the channel |
| `ManagementPresenter` | One per window. Every surface calls `present(_:)`, and Overview implements the flows |
| `ChannelConnections` | Views change on `phase.isUnavailable`, never a timer, and actions wait for `phase.isConnected` |
| Identity and color | The avatars, `ChannelMark`, `ChannelColors`, `ChannelTaskColors`, `TranscriptSurface` and `Channel.Attention`'s symbol and color keep the Mac's identity on both apps. Typography, navigation and layout stay platform-native |

## 1. Frame the change

- **Start from an outcome the user will feel,** like "sending scrolls you to the bottom". Lead
  writes the decision into the spec before anyone builds it, and opens one task with one owner.
  The spec holds current rules, never history.
- **Choose the simplest design that meets it.** Use what Apple's platforms ship, in its idiomatic
  form, and build your own only for behavior Toy Box needs and the platform lacks. Add no cache,
  retry, abstraction or option until a measurement or a second case asks for one.
- **Keep to what was asked.** Post anything else you notice as a follow-up instead of doing it.

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
- **When a fix needs a fix, stop.** Find the cause, or post what you know. Never stack correction
  loops, retries, timers or extra layout passes on a symptom.
- **Leave credentials to the user.** Agents never create accounts, profiles or secrets, accept
  agreements, read keys or passwords, or run real credential setup.

### Swift

- **Use `@ViewState`, never `@State`.** The macOS 27 Command Line Tools SDK exports an unusable
  `@State` macro, so `@ViewState` aliases `SwiftUI.State` once in `ToyBoxUI/Shared`.
- **Declare environment values with an `EnvironmentKey`,** not `@Entry`, in code that builds for
  the Mac. Command Line Tools lack the SwiftUIMacros plugin.
- **Put rules on their nouns.** Write members such as `channel.attention` and
  `state.applying(event)`, not free functions. Name a type for the thing itself, nesting a part
  under its owner (`Channel.Attention`), and avoid Manager, Helper, Support, Context and
  Projection. Keep the vocabulary small: reuse a noun or verb the code already has before adding
  one, so both apps share the same few words.
- **Keep a feature's rules out of the app targets.** Put them in a UI-free ChannelClient model
  with its animation, waits and announcements passed in, like `TalkRecorder`, and prove them with
  Mac tests. `simulator --build-only` checks the phone compiles, and the simulator is only for
  what you need to see.
- **Adapt to the phone's scene** with SwiftUI's safe areas, layout margins, size classes and
  adaptive navigation. Never hard-code a safe-area inset, device size or Duo fold width, and never
  copy a mockup's canvas measurements into code.

### Client rules

- **Channels are live server state, not local-first data.** Show stale data as stale, keep
  connection status apart from activity, and resume from the last applied revision. Only what the
  user writes, like a draft, is saved locally first.
- **Every send goes through `ChannelOutbox`,** a deliberate guard for the user's words. It gives
  each message a UUID and reuses it on every attempt and Send Again, so the server never posts one
  twice.
- **Optimistic writes are idempotent upserts into the store.** A send keeps its UUID, a read only
  raises its marker and a bookmark sets its state, so repeating a write or receiving its echo
  changes nothing. Until the server answers, show a write by reading the store through it, like
  the outbox's sends or a bookmark in flight, so a stale update can't hide it and a failure leaves
  nothing to undo. Once the server answers, upsert it into the store. Report a failure only when
  the user would otherwise think it saved, like a bookmark.
- **Management writes are sent once.** A failure shows its error and keeps what the user entered,
  and the live store shows whether it landed anyway. Never retry one on its own or add a check
  step.
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
  other, so never boot another simulator, run `simctl` by hand or poll.

## 4. Prove it

- **Done means demonstrated, scaled to the change.** A symbol, constant or spacing change needs a
  build, the touched suite and one capture of the result. Behavior, layout and concurrency changes
  get a full pass, and the release build covers the rest.
- **Validate in Dark at the default text size,** which is how the user runs both apps. Add Light
  only when a change touches color values, materials or contrast, and larger sizes only when it's
  about text sizing. Never hard-code a color or size that would break the others.
- **A change made for speed proves it against main** with its benchmark before it merges.
- **Test each promise once,** at the lowest layer that proves it, so shared code is tested in its
  own module and only native behavior in an app's tests.
- **Some test machinery is deliberate.** SwiftPM can't host XCUITest, so the phone's DEBUG-only
  drive scripts and the Mac's snapshot states and benchmarks stand in for UI and performance
  tests. Add to them only for a check nothing else can make.

### The running app

The validate skill says how to capture and drive either app. These limits always hold:

- **Mac:** use Computer Use only on `dev.toybox.desktop.test` ("Toy Box Test"), from
  `bun run validate`. The user's `dev.toybox.desktop` permits reads, never clicks. Confirm
  `studio-demo` before acting, never act in a window listing live channels, and `kill <pid>` your
  instance when you finish.
- **iPhone:** use the shared simulator under its lease. Check on a real phone only through
  TestFlight, never a direct install, so development never replaces the user's app or its data.

### Test reliability

- **CI asserts settled end states** over deterministic inputs such as measured frames, never
  per-frame timing. Frame-timing and WindowServer checks stay opt-in and run locally.
- **Client tests wait with `eventually`,** through Observation and the mock's own request,
  held-response and stop signals, never polling or elapsed time. A wait for a signal that might
  never come needs its own deadline, because Swift Testing's time limit won't end it.
- **Test gates and hooks suspend,** never block a cooperative worker. CI enforces it with
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`.
- **Quarantine an unexplained failure the same day,** as
  [docs/quarantined-tests.md](docs/quarantined-tests.md) describes, instead of rerunning CI until
  it passes.
- **Never run synthetic CPU burners on the shared Mac.** They starve every agent's builds and the
  simulator, so judge load-sensitive failures from CI or ordinary full runs.

## 5. Hand off

- **Hand off with your proof.** Say what you verified, what you didn't, and what still needs a
  real device, server or signing key. Attach channel images from your session `files/` folder,
  never `/tmp`, because posts keep their original paths.
- **Lead reviews, merges and ships** every change with the release skill. Owners never merge to
  `main` or push tags.

## Keeping this current

When the user corrects how we work, the rule changes here the same day, at the stage where it
applies, replacing what it supersedes. A rule belongs here only if every member needs it and we'd
otherwise relearn it, and anything one role does, or that comes up only sometimes, goes in a skill
under `.agents/skills/` or a doc in the Read table. The channel purpose and member roles never
restate these rules.
