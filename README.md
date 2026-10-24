# 🧸 Toy Box

A native Mac app for your [Toy Box](https://github.com/lostintangent/toy-box) agent teams. Know who needs you, answer without switching context, and catch up fast while your teams keep working.

<img width="1000" src="docs/hero-dark.png" alt="Toy Box in dark mode. The sidebar lists six channels with working agents and attention markers. The Launch site conversation shows Pixel sharing two hero designs and Lead asking which one to ship, with a Reply button. The Overview inspector shows the team and its tasks." />

## Features

Your teams can work in the background without making you watch a browser tab. Toy Box brings their questions, progress and results into the places you already use on your Mac.

### Know who needs you, anywhere on your Mac

The **menu bar inbox** and **desktop widget** show what your teams are asking, not just an unread count. Right-click the **Dock icon** to open a waiting request, or add **Needs You** to Control Center or the menu bar to reach your inbox. The Dock badge counts channels needing a reply. An optional bounce can catch your attention when a new request arrives.

In the app, the sidebar distinguishes requests, finished work and ordinary new activity.

### Answer without switching context

Reply right beneath a question in the **menu bar inbox**, or use a widget's **Reply** button to open a draft for that request. **Spotlight** finds channels and waiting requests. Choose **Reply to Request** to confirm and send an answer without opening a window. Enable notifications to reply from a macOS notification, too.

For a new thought, press **⌃⇧Space** to open **Quick Send** over whatever you're doing. Choose a channel, @mention an agent, type or dictate a message on device, and send without raising a channel window. Images paste or drop straight in, and unfinished drafts stay with their channel. Change the shortcut, or add Quick Send to Control Center or the menu bar.

**Send to Toy Box** in Services, the system Share menu and image drops on the Dock icon feed the same panel. Review the content, add a line and choose where it goes before anything is sent.

### Catch up fast

**On-device catch-up summaries** turn a busy channel into a short account of what changed, what was decided and what needs your answer. Each line links back to its source message. Apple Intelligence makes the summary on your Mac, not through another cloud service.

The **morning digest** brings one quiet daily notification with a line per active team. Choose its morning delivery time in Notifications settings. When Apple Intelligence is unavailable, message counts keep it useful.

Ask **Siri** to "Catch me up in Toy Box" and see what needs you without marking anything read. Open the channel or reply from the result. **Shortcuts** can catch you up, open a channel or send a message after confirmation.

### See the work, not just the chat

Keep the team's **tasks, diffs, artifacts and routines** beside the conversation in the Overview inspector. The **artifact viewer** opens shared work right in the channel: read Markdown plans, try HTML prototypes, inspect SVG diagrams and view images. Move between files in one gallery, then return to the conversation and draft you left.

**⌘F** searches channel history and highlights every occurrence, so you can move between matching messages without hunting through the text.

Images and **SVG attachments** open in the built-in image gallery, with zoom and keyboard navigation. **Live Text** lets you select and copy text from screenshots or follow a link.

### A Mac app, all the way through

**Liquid Glass**, light and dark appearances, multiple windows, full menus and keyboard navigation make this a workspace, not a page fitted into a window. Widgets adapt to your desktop in Full Color, Tinted or Clear. Create channels, choose models and shape agent roles without leaving the app. VoiceOver reaches the interface, with optional image descriptions made on your Mac.

Enable **Open at Login** to keep Toy Box ready in the Dock and menu bar without opening a window. Signed, notarized releases **update in place**: the app checks automatically, and you choose when to install.

## Coming next

**An iPhone companion** to check your channels and answer your teams when you're away from your Mac.

## Getting started

1. Install and start the [Toy Box server](https://github.com/lostintangent/toy-box) with `npm install -g @lostintangent/toy-box`, then run `toy-box`.
1. Download the latest zip from [Releases](https://github.com/lostintangent/toy-box-apple/releases/latest), unzip it and drag the app into Applications. It needs macOS 27 on an Apple Silicon Mac.
1. Open it. The app connects to `http://localhost:3000`. If your server lives somewhere else, change it in Settings (⌘,).

## Building from source

Install Bun 1.4.4 and Swift 6.4 Command Line Tools, then run `bun install --frozen-lockfile`.
Use `bun run app` to build and open the app, `bun run test` for Swift tests, and
`bun run test:release` for the credential-free tooling checks.

Scripts live in `scripts/dev/`, `scripts/release/` and `scripts/fixtures/`, with commands in
`package.json`. See [AGENTS.md](AGENTS.md) for isolated builds, demo servers and release setup.
