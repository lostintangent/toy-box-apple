# Test reliability history

Incident records moved from AGENTS.md on 2026-10-27, with their evidence and restoration boundaries preserved. Current gates and instructions are in [AGENTS.md](../AGENTS.md#test-reliability). A passing rerun does not close an incident or restore a quarantined test.

## Phone audience-capsule rendering

- `ToyBoxMobileTests/ComposerTests.audienceCapsuleIsSeparateFromIts44PointRowAndGrowsWithText`
  is quarantined behind `TOY_BOX_TEST_MOBILE_AUDIENCE_RENDERING=1`. On 2026-10-28, main
  `8316411` failed the iOS job in [run 40760049648, attempt 1](https://github.com/lostintangent/toy-box-apple/actions/runs/40760049648/attempts/1).
  The light / `.large` case reached `ComposerTests.swift:449` with `filledRows == []`, so the
  center column had no nontransparent pixels. The image existed and passed its minimum-height
  check. Neither the full image's alpha coverage nor its dimensions were logged. The other
  three argument cases passed. The Mobile suite finished with 233 tests and one issue.
- The retained log is `ci-40760049648-ios-failed.log` in Lead's session files. It records
  `IOSurfaceClientSetSurfaceNotify failed e00002c7` during the preceding placeholder-render
  test, which passed, before the capsule failure at 20:16:29 UTC. That message does not
  establish why the capsule's center was transparent. The test dates to `236f404`, and the
  failing merge changed the Live Activity logo, not the composer or this test. No production
  cause or first-render race has been identified. The requested CI rerun is evidence only,
  not a restoration condition.
- Core owns t465, `mobile-audience-capsule-rendering`: distinguish an incomplete or blank
  `ImageRenderer` result from misplaced badge geometry, identify the cause and add deterministic
  regression coverage before restoring the merge gate. Future failures record appearance,
  Dynamic Type, image dimensions, sampled center and total nontransparent pixel count.
  The four original cases and all visual/geometry thresholds remain unchanged behind the
  opt-in. No sleeps, retries or production changes were added. The other composer tests remain
  in the default suite, but do not replace this visual capsule contract.
- After quarantine, `SCRATCH_PATH=/tmp/tbm-core-t465 bun run test:mobile` passed all five
  suites. The 233-test Mobile suite reported the capsule probe as its single opt-in skip.
  Core retained the output as `t465-mobile-gate.log`. This verifies the default gate and
  compilation of the quarantined body, not the cause of the original failure.

## Mobile icon tooling

- The Simulator fake-compiler icon case in `scripts/shared/mobile-icon.test.ts` was quarantined behind
  `TOY_BOX_TEST_MOBILE_ICON_TIMING=1`. On 2026-10-26, the device-release tooling check on `ec34039`
  plus the configuration-only change exceeded Bun's unchanged 5,000 ms test watchdog at 5,005.64 ms.
  The device counterpart and all other 29 tooling cases passed. No icon code changed and no cause
  is established. Core owns `mobile-icon-tooling-readiness`: identify the stalled command and add
  deterministic completion coverage before restoring it. Do not retry the same candidate to green.
  The approved t464 cleanup later removed development-tool tests, including this probe and its
  opt-in row, rather than restoring them. The real icon compiler and bundle-output checks still
  fail explicitly. Removal does not identify the original hang's cause.

## Live Text analysis

- `ImageViewerLiveTextTests.onlyTheSettledCurrentImageIsAnalyzedAndTheWindowRemembersIt` is
  quarantined behind `TOY_BOX_TEST_LIVE_TEXT_ANALYSIS=1`. On 2026-10-26, Composer's full Mac run on
  `9bada33` plus test-gating changes (`image-strip-quarantined-mac-gate.log` in Composer's session
  files, lines 2523–2526) waited the unchanged 30s at `TranscriptTests.swift:1615` for the first
  image's Live Text, at a five-minute load average near 99. No viewer code changed and no cause is
  established. The saved log can't tell whether VisionKit's analysis threw, never returned or found
  no text, so a timeout now records those states and the load. Transcript owns restoring it:
  identify the cause and add deterministic analysis-gating coverage first. Don't retry it to green.

## Image-strip wheel input

- Composer's t412 image-strip failure was synthetic wheel input during display sleep.
  Core's 2026-10-26 foundation Mac gate, based on `9bada33`
  with no Mac/view changes, failed at `ComposerTests.swift:1468` after 31.199 seconds:
  "Timed out waiting until the overflowing strip scrolls sideways" (373 desktop tests, one issue).
  The failed run is `r2-foundation-mac-gate.log` in Core's session files, preserved in Composer's
  session as `image-strip-scroll-readiness-failed-9bada33.log`. The original log's birth and
  modification times bound the run to 23:32:36-23:36:11 PDT. System power logs record the display
  off from 22:37:54 until 23:43:59, covering the whole run. Transcript already guards against
  this AppKit limitation. `t412-incident-display-timing.log` in Composer's session preserves
  those timestamps. `imageStripKeepsOneHeightWhenItsImagesOverflowAndStillScrolls` now covers
  both scroller styles, equal height, real overflow, constrained native clip scrolling to the
  trailing edge and back, and trailing-edge visibility synchronously in CI. The unchanged
  wheel-input assertions and 30-second deadline remain in `imageStripOverflowRespondsToWheelInput`,
  behind `TOY_BOX_TEST_IMAGE_STRIP_SCROLLING=1`. Failure diagnostics include geometry, window
  visibility, display sleep and session lock state. Composer owns both cases.

## Main-actor probes, reconnect readiness and thumbnail decoding

- On 2026-10-29, t483 removed the three `MainActorTurnTests` probes, `ReconnectReadinessTests`,
  `ReadinessTests`, `MockTransport`'s lifecycle recording and readiness diagnostics, and the
  internal observation trace, with the spec's Connection words. `bun run benchmark launch` measures
  launch network work for real, and `TransportTests` keeps both reconnect cases in the gate. This
  closes t340's actor-probe item. The history below explains why they existed.
- The three `MainActorTurnTests` occupancy probes remain quarantined behind
  `TOY_BOX_TEST_MAIN_ACTOR_TIMING=1 bun run test --filter MainActorTurnTests`.
  The 2026-10-26 Mac run of `c4c761d` recorded nine Client readiness failures in
  `t338-full-mac.log`. The probes deliberately sleep and wait synchronously on the shared main actor
  while other suites' three-second readiness deadlines keep running. Run them locally before
  changing launch network work. Core owns t340 (`client-test-actor-isolation`): isolate these probes
  and replace timing-dependent readiness with controlled events before restoring their merge-gate
  coverage. No functional assertion or deadline was changed.
  The former outbox-order probe is now `SendAttemptTests.restoredAttemptsReconcileWithTheFirstSnapshot`.
  It controls the journal read and observes the store receiving the decoded snapshot before releasing
  that read, rather than assuming a 300 ms sleep establishes the order. The opposite restore-first
  order is covered too. Neither case blocks the main actor or asserts an elapsed-time threshold.
- `TransportTests.storeReconnectsFromAppliedRevisionZero` and
  `recoverySnapshotReplacesCachedHistory` were quarantined behind `TOY_BOX_TEST_RECONNECT_TIMING=1`.
  Both again exceeded the unchanged three-second readiness deadline in the 2026-10-26 full Mac
  run of `51935f4`, after the actor probes were disabled (`t338-isolated-full-mac.log`).
  They returned to the default gate on 2026-10-27 after a causal watchdog comparison. With a
  controlled 3.5-second main-actor stall at reconnect scheduling, the former three-second
  readiness watchdog failed both cases at 3.525 seconds. Event-driven readiness passed the
  identical stalls and unchanged protocol assertions at 7.039 seconds. This isolates the
  watchdog's false-failure mechanism, not every source of contention in the historical run. Logs are
  `t340-controlled-legacy-stall.log` and `t340-controlled-event-stall.log` in Core's session.
  Both cases retain their immediate-delivery path and add a controlled held-response path that
  checks the retained state and stale phase before releasing the resumed
  event or recovery snapshot. The three actor occupancy probes remain opt-in.
- Client readiness waits use Observation and explicit per-mock request, held-response and stop
  signals, not polling or an elapsed-time assertion. Their suites have a one-minute Swift Testing
  hang limit. This deliberately replaces the shared three-second watchdog with the lead's approval
  in channel message 2590, not a product latency assertion or a retry policy change. Keep actual
  heartbeat/backoff checks unchanged. The actor occupancy gate remains opt-in.
  Further 2026-10-26 failures include the driver gate on `555d015` (20 Client cases at load 436),
  the composer gate on `2fbdbb6` (28 issues at load 300), and Overview's `c83c7a5` run in
  `/tmp/tbm-overview-mobile-webkit-full-mac.log` (`staleStateRemainsVisibleAndCannotSend`,
  `deletionIsTerminal`, `aRejectedEventClosesItsStreamBeforeReconnecting`). All failed the old
  `MockTransport.swift:142` watchdog. Passing diagnostic reruns do not erase those failures.
  The earlier cross-owner evidence is Core's `t338-full-mac.log` and `t338-isolated-full-mac.log`,
  Composer's `files/mobile/full-mac-28e45b7-failed.log`, and Lead's
  `/tmp/lead-mac-main-cc-1.log`. Core's actor-excluded controls,
  `t340-no-actor-diagnostic-1.log` and `t340-no-actor-diagnostic-2.log`, respectively passed and
  failed revision-zero reconnect. Core owns the remaining actor-probe restoration under t340. A green
  readiness gate alone did not establish the reconnect failures' cause. The controlled watchdog
  comparison above shows how the former deadline can reject a healthy reconnect, without changing
  production reconnect behavior or claiming to identify every historical source of contention.
  `ReconnectReadinessTests` separately protects both reconnect contracts with immediate EOF and
  an explicit stream completion after the first snapshot applies. The controlled recovery case
  also loads older history before EOF and checks that the recovery snapshot replaces it.
  These input-order regressions supplement the restored reconnect cases, not the actor timing probes.
  The original reconnect cases record mock callback submissions with monotonic elapsed
  times. A failed readiness wait includes those calls and the store's final phase, applied revision,
  presence and transport counters before disconnecting. Callback submission does not prove that
  URLSession or the event iterator consumed it. Diagnostic state is read only after the wait fails,
  outside readiness Observation tracking, so it cannot add dependencies that mask a missed wakeup.
  Opt-in traces also distinguish the client's received HTTP response, decoded SSE event, store
  receive/apply and scheduled/requested reconnect. Those stages are separate from submitted URL
  callbacks. The trace is an internal per-API sink, unset in ordinary clients, and recording it
  does not send mock readiness notifications. This closes a diagnostic gap, not the historical
  reconnect incident or its quarantine.
  The store's detached consumer records event-handled and reconnect-pending immediately before
  hopping back to the main actor. Compare these with event-applied and reconnect-scheduled to
  distinguish a delayed consumer turn from a delayed main-actor turn after an already-decoded EOF.
  Reconnect-delay-elapsed also separates the backoff sleeper's resumed turn from the main-actor
  turn that issues the next request.
  The 2026-10-26 sampled Client run (`t340-sampled-official-run.log` and
  `t340-sampled-official-stacks.txt` in Core's session files) identified synchronous production
  `ComposerDraft.thumbnail(for:)` ImageIO/HEIC decoding on the main actor during draft tests.
  Thumbnail lookup is now cache-only. Both native strips await `loadThumbnail(for:)`, which
  coalesces background decodes and rejects removed or replaced images' late results.
  Their retained bitmaps go through the draft's lookup too, so a later preparation failure
  invalidates the displayed thumbnail and restores reattachment rather than showing stale success.
  A controlled regression covers an attempted draft's loaded thumbnail followed by failed
  normalization after editing, including the observation that updates both native tiles.
  `ComposerThumbnailTests` holds a decoder off the main actor and requires the connected store
  to apply a recovery snapshot before releasing it. This establishes that specific defect and
  protects the fix, but does not by itself close the historical reconnect incidents. Their
  reconnect cases are now restored as described above. The actor timing probes remain opt-in.

## Artifact scope replacement and removal

- `ChannelArtifactSessionTests.switchingScopeDiscardsTheVisitAndCancelsItsPendingLoad` is quarantined
  behind `TOY_BOX_TEST_ARTIFACT_SCOPE_TIMING=1`. Its `changingServer: false` argument failed the
  unchanged private three-second polling helper at line 81 in the 2026-10-26 Client diagnostic run
  (`reconnect-diagnostics-mac.log` in Core's session files, based on `db3b71d` with failure tracing).
  The test body matches main `f2eff6b`; no production cause or failed wait stage is established.
  Core owns `artifact-scope-readiness` under t340: capture the stalled stage, identify its cause and
  add deterministic scope-replacement coverage before restoring this case. Both argument bodies
  and the deadline remain unchanged. Do not clear the incident by retrying the original candidate.
- `ChannelArtifactSessionTests.removingAnArtifactDuringLoadingRetainsItsIdentityWithoutPublishingTheResponse`
  is also quarantined behind `TOY_BOX_TEST_ARTIFACT_SCOPE_TIMING=1`. It failed the unchanged
  three-second polling helper at line 82 in the 2026-10-26 Mac integration run of `a65267d`
  (`/tmp/lead-int8-mac.log`, issue at line 2088, failure after 7.537 seconds at line 2130).
  Core preserved that run as `artifact-removal-readiness-failed-a65267d.log` in its session files.
  An iOS build was compiling concurrently, but neither the cause nor the failed wait stage is
  established. Core owns `artifact-removal-readiness` under t340: capture the stalled stage,
  identify its cause and add deterministic removal-during-load coverage before restoring this case.
  The test body and deadline are unchanged. Do not restore it based on passing reruns.
  Separately, the default `anObsoleteLoadCannotEndOrReplaceItsSuccessorsPendingVisit` contract
  covers channel changes, server changes and removal using signaled download requests and actual
  load-task completion, without readiness polling. It releases the obsolete request while its
  successor is still held, checking both the selected content and loading state. This adds
  controlled coverage, but does not establish either historical failure's cause or lift its gate.
