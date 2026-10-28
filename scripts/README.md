# Commands

`desktop/` and `mobile/` each contain one-time `setup-secrets.ts`, Swift `test.ts`,
`bundle/` for building and signing, `dogfood/` for running and measuring development builds,
and release tooling. A command with helpers has an `index.ts` entry point.
The phone's release command is a single `mobile/release.ts` file.

`demo-server/` serves sample channels so either app can send, edit and delete during development
without touching real channels. `shared/` contains common commands, with their helpers in `lib/`.
Mirrored platform filenames are intentional. Names do not collide within a platform.
Script tests are omitted. Bundle or release changes require both real release dry runs.

| Command | File | What it's for | Who runs it |
| --- | --- | --- | --- |
| `bun run setup-secrets SHA1 APPLE_ID TEAM_ID [OWNER/REPO]` | `desktop/setup-secrets.ts` | Configure Developer ID, notarization and Sparkle secrets once per certificate or Mac | Certificate owner only |
| `bun run test` | `desktop/test.ts` | Run Mac Swift tests, reject missing summaries and sample hung tests before failing | Contributors, agents, CI |
| `bun run build` | `desktop/bundle/index.ts` | Build, bundle, ad-hoc sign and open the Mac app. `--no-open` builds only | Contributors, agents, CI |
| `bun run validate` | `desktop/dogfood/validate.ts` | Build and launch an optimized, isolated Toy Box Test app on the demo | Agents |
| `bun run snapshot` | `desktop/dogfood/snapshot.ts` | Render a window state to a PNG without taking focus | Agents |
| `bun run benchmark` | `desktop/dogfood/benchmark.ts` | Check performance budgets against an isolated performance demo | Contributors, agents |
| `bun run release vX.Y.Z` | `desktop/release/index.ts` | Sign, notarize, staple and zip the Mac app | Release owner, CI |
| `bun run setup-secrets:mobile SHA1 APP_STORE_CONNECT_APP_ID [OWNER/REPO]` | `mobile/setup-secrets.ts` | Configure App Store signing secrets once per certificate or Mac | Certificate owner only |
| `bun run test:mobile` | `mobile/test.ts` | Run iOS Simulator tests | Contributors, agents, CI |
| `bun run simulator` | `mobile/dogfood/index.ts` | Build, install and launch on the shared Duo, with hold, drive and screenshot options. `--build-only` bundles without booting | Contributors, agents, CI |
| `bun run testflight --build-number N` | `mobile/release.ts` | Sign, validate and upload to TestFlight. `--validate-only` never uploads, `--build-only` needs no credentials | Release owner, CI |
| `bun run demo` | `demo-server/index.ts` | Serve studio-demo and push routes on 3210 for write tests and screenshots | Contributors, agents |
| `bun run demo:history` | `demo-server/history.ts` | Serve 480 messages on 3211 for paging and read checks | Contributors, agents |
| `bun run demo:perf` | `demo-server/perf.ts` | Serve the performance fixture on 3292 | Benchmark command |
| `bun run icon` | `shared/icon.ts` | Regenerate committed icon outputs with Icon Composer | Icon author |
| `bun run release-notes TAG [OUTPUT.md]` | `shared/release-notes.ts` | Extract one platform's release notes from CHANGELOG.md | Release owner, CI |
| `bun run cron-fixtures` | `shared/cron-fixtures.ts` | Regenerate ChannelKit cron fixtures from the read-only reference | Core contributors, agents |
| `bun run lint:workflows` | none | Run actionlint, gating ShellCheck warnings and errors, not style | Contributors, agents, CI |
