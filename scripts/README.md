# Commands

`desktop/` and `mobile/` each contain one-time `setup-secrets.ts`, Swift `test.ts`,
`bundle/` for building and signing, `dogfood/` for running and measuring development builds,
and release tooling. A command with helpers has an `index.ts` entry point.
The phone's release command is a single `mobile/release.ts` file.

`demo-server/` serves sample channels so either app can send, edit and delete during development
without touching real channels. `shared/` contains common commands, with their helpers in `lib/`.
Mirrored platform filenames are intentional. Names do not collide within a platform.
Script tests are omitted, so check a script change with `bun check` and
`bun run lint:workflows`. Bundle or release changes require both real release dry runs.

| Command | File | What it's for | Who runs it |
| --- | --- | --- | --- |
| `bun run setup-secrets SHA1 APPLE_ID TEAM_ID [OWNER/REPO]` | `desktop/setup-secrets.ts` | Configure Developer ID, notarization and Sparkle secrets once per certificate or Mac | Certificate owner only |
| `bun run test` | `desktop/test.ts` | Run Mac Swift tests, reject a run that stops before it ends and sample hung tests before failing | Contributors, agents, CI |
| `bun run build` | `desktop/bundle/index.ts` | Build, bundle, ad-hoc sign and open the Mac app. `--no-open` builds only | Contributors, agents, CI |
| `bun run validate` | `desktop/dogfood/validate.ts` | Build and launch an optimized, isolated Toy Box Test app on the demo | Agents |
| `bun run development` | `desktop/dogfood/development.ts` | Build, development-sign and open Toy Box Dev beside the installed app, for Siri's developer preview | User, contributors |
| `bun run snapshot` | `desktop/dogfood/snapshot.ts` | Render a window state to a PNG without taking focus | Agents |
| `bun run benchmark` | `desktop/dogfood/benchmark.ts` | Check performance budgets against an isolated performance demo | Contributors, agents |
| `bun run release vX.Y.Z` | `desktop/release/index.ts` | Sign, notarize, staple and zip the Mac app | Release owner, CI |
| `bun run setup-secrets:mobile SHA1 APP_STORE_CONNECT_APP_ID [OWNER/REPO]` | `mobile/setup-secrets.ts` | Configure App Store signing secrets once per certificate or Mac | Certificate owner only |
| `bun run test:mobile` | `mobile/test.ts` | Run iOS Simulator tests | Contributors, agents, CI |
| `bun run simulator` | `mobile/dogfood/index.ts` | Build, install and launch on the shared Duo, with hold, drive and screenshot options. `--build-only` bundles without booting | Contributors, agents, CI |
| `bun run testflight --build-number N` | `mobile/release.ts` | Sign, validate and upload to TestFlight. `--validate-only` never uploads, `--build-only` needs no credentials | Release owner, CI |
| `bun run demo` | `demo-server/index.ts` | Serve studio-demo and push routes on 3210 for write tests and screenshots. A user's message reads the channel through itself, as Toy Box 0.4.5 does. `TOY_BOX_DEMO_REPLIES` set to 0, 2, 4 or `short` changes the request's choices (`short` serves `Yes` and `Not yet`, which fit in one row beside Reply). `TOY_BOX_DEMO_BOOKMARKS` set to `empty` starts without bookmarks. `TOY_BOX_DEMO_AVATAR` set to `image` gives the channel a served project icon, and `mark` a mark on its color. `POST /demo/avatar` changes it as the lead does, appending the `channel_avatar_changed` message. `?avatar=image` or `mark` picks one, and otherwise it switches between them, while each older message's image keeps loading. Its synthetic screens prove screen control without a real host: Demo Canvas paints where it's pressed, by button, and scrolls its checkerboard, and Won't Take Focus refuses control. `GET /demo/screens/input` lists the input the canvas accepted, and `DELETE` clears it with the paint. Its server runs 0.4.0 as Studio Demo, with the id `studio-demo-<port>`. An update installs 0.4.1 after 2 s, and a restart answers, drops every connection and is back 3 s later running the installed release. `TOY_BOX_DEMO_SERVER` set to `pending` starts with 0.4.1 installed, `gone` does too but exits on restart and never comes back, `unmanaged` has no installed release and rejects both, and `failing` rejects updates. `PATCH /api/v1/server` renames it in memory, answering 400 "Invalid request." for a name over 64 UTF-16 units, and an empty name gives back Studio Demo. Both demos answer every rename with the whole server, and empty `peers` unless `TOY_BOX_DEMO_PEERS` lists origins separated by commas, so `TOY_BOX_DEMO_PEERS=http://127.0.0.1:3211 bun run demo` with `bun run demo:history` running shows both once the app connects to 3210 | Contributors, agents |
| `bun run demo:history` | `demo-server/history.ts` | Serve 480 messages on 3211 for paging and read checks, as History Demo, with the id `history-demo-<port>` and no installed release, so it offers no update. `TOY_BOX_DEMO_PORT` moves it | Contributors, agents |
| `bun run demo:perf` | `demo-server/perf.ts` | Serve the performance fixture on 3292 | Benchmark command |
| `bun run icon` | `shared/icon.ts` | Regenerate committed icon outputs with Icon Composer | Icon author |
| `bun run release-notes TAG [OUTPUT.md]` | `shared/release-notes.ts` | Extract one platform's release notes from CHANGELOG.md | Release owner, CI |
| `bun run cron-fixtures` | `shared/cron-fixtures.ts` | Regenerate ToyBoxKit cron fixtures from the read-only reference | Core contributors, agents |
| `bun run lint:workflows` | none | Run actionlint, gating ShellCheck warnings and errors, not style | Contributors, agents, CI |

For long Markdown reader captures, start an isolated demo with
`TOY_BOX_DEMO_PORT=3459 TOY_BOX_DEMO_LONG_MARKDOWN=1 bun run demo`.
The existing **Interaction notes** artifact serves the longer sample, with H1/H2,
hard-wrapped paragraphs and a wrapped list item. The existing `fixture-progress` message also gets
H1/H2 and a short list for comparing transcript rendering. Without the switch,
the shared 3210 fixture is unchanged.
