# 🧸 Toy Box

A native Mac and iPhone app for your [Toy Box](https://github.com/lostintangent/toy-box) agent teams. Know who needs you, answer without switching context, and keep up while your teams work.

Connect to your own Toy Box server. The Mac app needs macOS 27 on Apple Silicon, and the iPhone companion needs iOS 27.

> _Try it out:_ [Download for Mac](https://github.com/lostintangent/toy-box-apple/releases/latest)

<img width="1000" src="docs/hero-dark.png" alt="Toy Box in dark mode. The sidebar lists six channels with working agents and attention markers. The Launch site conversation shows Pixel sharing two hero designs and Lead asking which one to ship, with a Reply button. The Overview inspector shows the team and its tasks." />

## Features

- **Know who needs you:** Find waiting requests in the menu bar inbox and Mac or iPhone widgets, with a Dock badge for channels needing a reply.
- **Answer from anywhere:** Request and completion alerts reach Mac and iPhone, with native Reply from notifications, the Lock Screen or Apple Watch.
- **Mac and iPhone:** Read, reply and manage channels on iPhone, then use Handoff to continue the same channel on your Mac.
- **Send without switching:** Reply in the menu bar inbox or press ⌃⇧Space for Quick Send, with @mentions, images and on-device dictation.
- **Catch up fast:** Apple Intelligence summarizes busy channels on your Mac with links to source messages, and a quiet morning digest starts your day.
- **See the work:** Keep tasks, diffs, artifacts and routines beside the conversation, with built-in document readers and ⌘F search across channel history.
- **Follow along:** Follow a channel in a Live Activity to see working agents, task progress and requests on your iPhone's Lock Screen and Dynamic Island.
- **Native by design:** Liquid Glass, keyboard navigation and multiple windows feel at home, with signed, notarized Mac releases that update in place.
- **Siri and Shortcuts:** Find requests in Spotlight, ask Siri to catch you up, or use Shortcuts to send messages after confirmation on Mac.

## Developing

1. Clone this repo and install [Bun](https://bun.sh) 1.4.4, Swift 6.4 Command Line Tools and Xcode.
2. `bun install --frozen-lockfile`
3. `bun run build`

See [scripts/README.md](scripts/README.md) for commands, and [AGENTS.md](AGENTS.md) for platform guidance.
