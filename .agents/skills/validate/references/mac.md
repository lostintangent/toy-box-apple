# The Mac app

## Snapshots

```sh
SCRATCH_PATH=/tmp/tbm-<you> bun run snapshot --server http://127.0.0.1:3210 \
  --channel studio-demo --appearance light|dark --size 1280x840 --snapshot <file.png> [--state <name>]
```

Snapshot mode never marks read, saves settings or posts notifications. It uses the normal SwiftUI
scene, disables restoration only in the volatile argument domain, refuses application-state saving
and restoration, and renders attached sheets' layers into the PNG.

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
- Quit your instance with `kill <pid>` when you finish.

## Launching your own build

```sh
open -n -g "/tmp/tbm-<you>/Toy Box.app" --args --server http://127.0.0.1:3210 -ApplePersistenceIgnoreState YES
```

Use the bundle `bun run build` makes, which carries the real SDK stamp, never SwiftPM's unstamped
executable. `-g` avoids taking focus. `--server` and `TOY_BOX_SERVER_URL` are session-only. Keep
`-ApplePersistenceIgnoreState YES` even with the restored-zero-window fallback, so test instances
neither restore nor overwrite the shared saved window state.

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

