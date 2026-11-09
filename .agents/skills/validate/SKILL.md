---
name: validate
description: Prove a change in the running Mac app or on the iPhone simulator. Use when capturing a screenshot, driving Toy Box Test with Computer Use, running the simulator or a drive script, running a benchmark, an opt-in or iPhone test suite, or a development-signed build, or picking a demo server for a check.
---

# Validate

Pick the cheapest evidence that proves the change, then read its reference before running it.

| To prove | Use | Read |
| --- | --- | --- |
| The code compiles | `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path /tmp/tbm-<you>` | |
| Mac layout at a size or appearance | `bun run snapshot` | [The Mac app](references/mac.md#snapshots) |
| Mac materials, selection, scroll edges, interaction or feel | Computer Use on Toy Box Test, from `bun run validate` | [The Mac app](references/mac.md#computer-use) |
| A Mac hover or menu | A snapshot state that lights a hover. A menu rests on review and the user's check | [The Mac app](references/mac.md#computer-use) |
| Siri on the Mac | `bun run development` | [The Mac app](references/mac.md#development-signed-build) |
| Phone layout, a pose or a flow | `bun run simulator --screenshot`, or a drive script | [The iPhone](references/iphone.md) |
| Speed | `bun run benchmark`, against main | [Benchmarks](references/benchmarks.md) |
| Native timing, live servers, phone-only code or CI | An opt-in suite or `bun run test:mobile` | [Tests](references/tests.md) |

Every command takes your own `SCRATCH_PATH=/tmp/tbm-<you>`.

## Servers

Set the server with `TOY_BOX_SERVER_URL` or Settings. Launch overrides are session-only and never
replace saved Settings.

| Server | Port | Use it for |
| --- | --- | --- |
| `bun run demo` | 3210 | `studio-demo`, the isolated fixture server with the required catalog lead profile. Write tests and the shared screenshot baseline. Messages 9 and 15 start bookmarked |
| `bun run demo:history` | 3211 | `history-demo`: 480 messages, canonical 100-message older pages and isolated read receipts. Paging and key-window read checks, without disturbing 3210. Message 250, two pages back, and 466 start bookmarked |
| `bun run demo:perf` | 3292 | The benchmark fixture, started fresh by `bun run benchmark`. `TOY_BOX_PERF_PORT` changes it |
| Live Toy Box | 3100 | Reading only. Posting or mutating needs the Lead's approval of a specific scratch channel. Leave its process running |

`TOY_BOX_DEMO_BOOKMARKS=empty` starts either demo with no bookmarks.
