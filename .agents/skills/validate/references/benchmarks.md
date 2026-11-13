# Benchmarks

`SCRATCH_PATH=/tmp/tbm-<you> bun run benchmark [--summaries] [switch|messages|paging|scroll|key ...]`
builds the release `dev.toybox.desktop.benchmark` app, runs each scenario on a fresh
`bun run demo:perf`, prints each result against its budget and exits 1 if any is over. The spec's
Performance budgets define busy time, saturated spans and frame gaps.

- Leave the window uncovered, and leave the pointer still, away from the edges of its screen. The
  window opens away from the pointer, and `messages` and `scroll` also measure with the transcript
  moved under it, where a person reading or scrolling rests it. Their results say which case each
  line is.
- `key` runs only when named. It takes focus for about 45 seconds and measures key-window CPU with
  4, then 20, working agents to expose continuous animation. Warn the user first.
- Catch-up summaries stay off unless you pass `--summaries`.
- Only one benchmark runs at a time on this Mac. Others wait for it, so never poll for one yourself.
- Under load, compare main-thread CPU. Scroll's CPU ms per 1,000 native points and paging's CPU ms
  per older page are informational. Judge wall-clock hitches only on a quiet machine, since busy
  time includes scheduling delays.

