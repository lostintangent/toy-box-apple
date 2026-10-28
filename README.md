# 🧸 Toy Box

A native Mac and iPhone app for your [Toy Box](https://github.com/lostintangent/toy-box) agent teams. Connect to your Toy Box server, and then know who needs you, answer without switching context, and keep up while your work progresses.

> _Try it out:_ [Download for Mac](https://github.com/lostintangent/toy-box-apple/releases/latest)

<img width="1000" src="docs/hero-dark.png" alt="Toy Box in dark mode. The sidebar lists six channels with working agents and attention markers. The Launch site conversation shows Pixel sharing two hero designs and Lead asking which one to ship, with a Reply button. The Overview inspector shows the team and its tasks." />

## Features

- **Get pinged the moment you're needed:** When an agent asks you something or a channel finishes its work, your iPhone gets the alert even when Toy Box is closed, and so do your Mac and Apple Watch. Reply right from the notification, Lock Screen or watch, and your team keeps moving while you're away from your desk.
- **Pick up where you left off on any device:** Read, reply and manage channels on iPhone or Mac, and Handoff carries the exact channel you're in between them. Sit down at your desk and click the Handoff icon in your Dock to continue on your Mac, or pick it up on your iPhone as you head out.
- **Follow the work from your Lock Screen:** Follow a channel to see a Live Activity on your iPhone's Lock Screen and Dynamic Island showing which agents are working, how many tasks are done and when someone needs your reply. It stays current while your phone is in your pocket.
- **See what's waiting at a glance:** Needs You widgets on iPhone and Mac, the menu bar inbox and app icon badges count the channels waiting on you, so you know whether to step in without opening a window.
- **Answer without switching apps:** Press ⌃⇧Space for Quick Send anywhere on your Mac, reply straight from the menu bar inbox, or share text and images into a channel from any Mac app. Write with @mentions, images and on-device dictation.
- **Catch up in seconds:** Return to a busy channel and Apple Intelligence summarizes what you missed, privately on your iPhone or Mac, with links to the source messages. A morning digest on your Mac lists the channels that moved since yesterday.
- **See the work, not just the chat:** Tasks, diffs, artifacts and routines sit beside the conversation, with built-in document readers and ⌘F search across the whole channel history.
- **Siri, Spotlight and Shortcuts:** Ask Siri to catch you up, find waiting requests in Spotlight, or send messages from Shortcuts after you confirm on your Mac.
- **Native by design:** Liquid Glass, keyboard navigation and multiple windows feel at home, with signed, notarized Mac releases that update in place.

## Developing

1. Clone this repo and install [Bun](https://bun.sh) 1.4.4, Swift 6.4 Command Line Tools and Xcode.
2. `bun install --frozen-lockfile`
3. `bun run build`

See [scripts/README.md](scripts/README.md) for commands, and [AGENTS.md](AGENTS.md) for platform guidance.
