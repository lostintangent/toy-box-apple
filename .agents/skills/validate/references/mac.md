# The Mac app

## Snapshots

```sh
SCRATCH_PATH=/tmp/tbm-<you> bun run snapshot --server http://127.0.0.1:3210 \
  --channel studio-demo --appearance light|dark --size 1280x840 --snapshot <file.png> [--state <name>]
```

Only debug builds carry the harness, so the command always builds debug, and a release build
refuses `--snapshot` and `--state`. A view poses its part of a state with `.snapshotPose`, which
returns true once the window shows it or throws to fail the snapshot, and release builds compile it
out. Snapshot mode never marks read, saves settings or posts notifications. It uses the normal SwiftUI
scene, disables restoration only in the volatile argument domain, refuses application-state saving
and restoration, and captures the window as the window server composites it, attached sheets
included. Without Screen Recording the snapshot fails instead of writing a blank PNG.

`composer-dictation-recording` needs `TOYBOX_DICTATION_AUDIO_FILE` set to a spoken recording, such
as one from `say -o /tmp/tbm-<you>/dictation.aiff "Draft a reply"`, and fails right away without it.

It's layout evidence only. It has no native interaction, WindowServer shadows or corner masks, or
correct 27+ Liquid Glass and sidebar selection. Verify materials, selection and scroll-edge effects
in a real window.

## Computer Use

- Computer Use takes bundle IDs, not paths. The user's app is `dev.toybox.desktop`, and agents use
  `dev.toybox.desktop.test` ("Toy Box Test"). Shared IDs permit reads, not clicks. Computer Use
  still asks for its own approval.
- It resolves the test ID through LaunchServices, which never resolves a copy under `/tmp` and
  otherwise picks among every registered copy. Any other copy is rejected with "no longer belongs
  to the approved app".
- So `SCRATCH_PATH=/tmp/tbm-<you> bun run validate` installs into the main checkout's
  `.build/agents/Toy Box Test.app` from any worktree and unregisters every other copy of the ID.
  It never falls back to a shared bundle. It always builds `CONFIGURATION=release`, swaps the
  optimized build into that bundle without disturbing running instances, and launches it against
  the demo in the background. Judge feel there, not in quick `bun run build` debug builds.
- Only one instance can hold the test ID for clicks. On "no perception baseline for this pid", wait
  for the other agent's instance to quit. Reads still work through `list_apps` with your own
  `window`.
- Confirm `studio-demo` before acting, and never act in a window listing live channels.
- One agent at a time can arm Computer Use's Escape stop. Reset your session with `exec_js_reset`
  when you finish, and say so, so the next agent can start.
- It can't move the pointer, so nothing hovers, and its captures show only the app's window, so a
  menu never appears. Prove a hover with a snapshot state that lights it. A menu rests on review,
  so name the user's check in the release as what's left.
- Quit your instance with `kill <pid>` when you finish.

## Launching your own build

Launch only Toy Box Test, through `bun run validate`. Never `open` the bundle `bun run build`
makes: it's the user's `dev.toybox.desktop`, so it shares their permissions, settings, drafts and
outbox, and macOS asks the user about it.

```sh
SERVER_URL=http://127.0.0.1:3211 SCRATCH_PATH=/tmp/tbm-<you> bun run validate
```

It defaults to the demo on 3210, launches in the background without taking focus, passes later
arguments to the app and adds `-ApplePersistenceIgnoreState YES`, so test instances neither
restore nor overwrite the shared saved window state. The server it's given is session-only. For
several servers, start the demo with `TOY_BOX_DEMO_PEERS`, which lists the others as its peers
(see [scripts/README.md](../../../../scripts/README.md)). Each run re-signs Toy Box Test, which
resets its microphone grant, so hold it while another agent's microphone check is running. A check
that needs a cold process with its grants kept relaunches the installed copy without rebuilding:

```sh
open -n -g "<main checkout>/.build/agents/Toy Box Test.app" --args --server http://127.0.0.1:3210 -ApplePersistenceIgnoreState YES
```

## Development-signed build

Siri's developer preview answers only development-signed builds, so Siri is checked with
`bun run development`. It builds an optimized Toy Box Dev (`dev.toybox.desktop.dev`), signs it
with the Apple Development certificate and a macOS development profile, installs it as
`~/Applications/Toy Box Dev.app`, quits a copy that's already running and opens it. Arguments
after the command pass to the app.

- It runs beside the installed app without touching its data. Its own bundle ID gives it its own
  settings, so pick a server in Settings. Like the test copy, it has no widget, Share, Services,
  URL scheme or document handlers, and the Spotlight, Open at Login, Dock menu and morning digest
  integrations stay with `dev.toybox.desktop`. It has no update feed.
- Isolated copies save drafts and the outbox under Application Support in a folder named for their
  bundle ID, through `ToyBoxDataFolder` in Info.plist, rather than in the `ToyBoxDesktop` folder
  that the installed app and `bun run build` share.
- The **user** creates the profile: an explicit App ID `dev.toybox.desktop.dev` with no
  capabilities, then a macOS App Development profile with the current Apple Development certificate
  and this Mac, downloaded through Xcode's Settings, Accounts, Download Manual Profiles. The
  command finds it there or in `~/Library/MobileDevice/Provisioning Profiles`, and prints these
  steps with this Mac's Device ID when none matches.
- It signs with the user's key, so the first run may ask to allow `codesign` to use it.

