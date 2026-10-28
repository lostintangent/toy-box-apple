# Commands

| Command | File | What it does |
| --- | --- | --- |
| `bun run build` | `desktop/build.ts` | Builds, bundles, ad-hoc signs and opens the Mac app. `--no-open` builds only |
| `bun run test` | `desktop/test.ts` | Runs Mac Swift tests, rejects missing summaries and samples hung tests before failing |
| `bun run validate` | `desktop/validate.ts` | Agents only. Builds and launches an optimized, isolated Toy Box Test app on the demo |
| `bun run snapshot` | `desktop/snapshot.ts` | Agents only. Renders a window state to a PNG without taking focus |
| `bun run benchmark` | `desktop/benchmark.ts` | Checks performance budgets against an isolated performance demo |
| `bun run release vX.Y.Z` | `desktop/release.ts` | Signs, notarizes, staples and zips the Mac app |
| `bun run setup-secrets SHA1 APPLE_ID TEAM_ID [OWNER/REPO]` | `desktop/setup-secrets.ts` | User only. Configures Developer ID, notarization and Sparkle signing secrets |
| `bun run simulator` | `mobile/simulator.ts` | Builds, installs and launches on the shared Duo, with hold, drive and screenshot options |
| `bun run test:mobile` | `mobile/test.ts` | Runs iOS Simulator tests |
| `bun run testflight --build-number N` | `mobile/testflight.ts` | Signs, validates and uploads to TestFlight. `--validate-only` never uploads, `--build-only` needs no credentials |
| `bun run setup-secrets:mobile SHA1 APP_STORE_CONNECT_APP_ID [OWNER/REPO]` | `mobile/setup-secrets.ts` | User only. Configures App Store signing secrets |
| `bun run demo` | `demo/server.ts` | Serves studio-demo on 3210 for write tests and screenshots |
| `bun run demo:history` | `demo/history.ts` | Serves 480 messages on 3211 for paging and read checks |
| `bun run demo:perf` | `demo/perf.ts` | Serves the performance fixture on 3292 |
| `bun run icon` | `shared/icon.ts` | Regenerates committed icon outputs with Icon Composer |
| `bun run release-notes TAG [OUTPUT.md]` | `shared/release-notes.ts` | Extracts one platform's release notes from CHANGELOG.md |
| `bun run cron-fixtures` | `shared/cron-fixtures.ts` | Regenerates ChannelKit cron fixtures from the read-only reference |
| `bun run lint:workflows` | none | Runs actionlint, gating ShellCheck warnings and errors, not style |
