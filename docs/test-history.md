# Test reliability history

Incident records moved from AGENTS.md on 2026-10-27, with their evidence and restoration boundaries preserved. Current gates and instructions are in [AGENTS.md](../AGENTS.md#test-reliability). A passing rerun does not close an incident or restore a quarantined test.

## Phone waiting-cue rendering

- `ToyBoxMobileTests/OverviewTests.waitingCueStaysCenteredOnTheFirstLineWhileTheReasonWraps` was
  quarantined behind `TOY_BOX_TEST_MOBILE_WAITING_CUE_RENDERING=1` on 2026-10-29. Main `194dcb1`
  (t505's merge) failed the iOS foundation job in
  [run 40902466732](https://github.com/lostintangent/toy-box-apple/actions/runs/40902466732).
  Only the first of its 24 cases failed, light / `.xSmall`, at `OverviewTests.swift:232` with
  `cueRows == []`: no row had the orange `pause.fill` cue's color. The other 23 passed, and the
  Mobile suite finished with 238 tests and one issue. t505 changed the composer, transcript Find
  and spec, not Overview. The test dates to `1ce521d` (2026-10-26). None of the failed main runs
  from 2026-10-28 on recorded an issue in it, though cancelled runs may have stopped before iOS tests.
- That evidence doesn't establish that only the cue was missing. The pixel reader draws into a
  zeroed buffer, so a fully transparent image reads as black, which counts as text on the light
  background. A blank image therefore passes the light case's text check and fails at the cue, as
  here, while in dark mode it would fail at the text check instead. Image dimensions and coverage
  weren't logged. The log records `IOSurfaceClientSetSurfaceNotify failed e00002c7` as the test
  started, which t465 found in every local run too.
- Two hypotheses remain unproven: a cold `pause.fill` symbol on the first render, or t465's
  deferred `ImageRenderer.uiImage` rasterization coming back empty, since this test still reads
  pixels through `uiImage?.cgImage`. No production cause or first-render race has been identified.
- Overview owns t510, `mobile-waiting-cue-rendering`: distinguish a blank render from a missing cue,
  identify the cause and add deterministic regression coverage before restoring the merge gate.
  Failure messages now record appearance, Dynamic Type, image dimensions, nontransparent pixel
  count and text and cue row counts. All 24 cases and thresholds are unchanged behind the opt-in.
  No sleeps, retries or production changes were added. No other default test covers the cue's
  alignment with the reason's first line.
- `simctl spawn` forwards only `SIMCTL_CHILD_`-prefixed variables to the test process, so a bare
  `TOY_BOX_TEST_MOBILE_WAITING_CUE_RENDERING=1` would never reach it. Run the opt-in as
  `SIMCTL_CHILD_TOY_BOX_TEST_MOBILE_WAITING_CUE_RENDERING=1 SCRATCH_PATH=/tmp/tbm-<you> bun run test:mobile`.
  On `7b20f9f` plus the quarantine, the default run and a bare-variable run both passed all five
  suites, with the probe as the 238-test Mobile suite's single opt-in skip. The prefixed run passed
  with no Mobile skip, so all 24 cases ran. That verifies the gate and its delivery, not the cause
  of the original failure.
- Restored by t510 on 2026-10-29. The failing read came from where the pixels are produced. The test
  drew `ImageRenderer.uiImage`'s CGImage, an image-provider image (`(IP)`) whose pixels are produced
  only when it's first drawn. A temporary probe ran first in a local Mobile process and rendered all
  24 cases both ways. `IOSurfaceClientSetSurfaceNotify failed e00002c7` appeared exactly once,
  between obtaining the first `uiImage` and drawing it (23 ms, then about 8 ms for later draws), and
  never during the synchronous render just before it. So the provider rasterizes through an
  IOSurface, and the message marks the process's first such rasterization. The synchronous render
  before it was the process's first render of the cue, and it drew the cue, which argues against a
  cold `pause.fill` symbol. On CI the message appeared as this test started. No earlier test in that
  process had triggered it, so the failing light / `.xSmall` case was the process's first IOSurface
  rasterization. t465's capsule
  failure also read `uiImage` pixels, and its first case failed shortly after the same message. Why
  that rasterization lost the cue on CI once can't be reproduced locally: all 24 local provider
  renders were fully opaque, with the cue in place.
- The test now renders through `ImageRenderer.render(rasterizationScale:renderer:)` into its own
  bitmap, so none of the pixels it reads come from a deferred provider or an IOSurface. The status
  fills an opaque background, so the test first requires every pixel to be opaque. An incomplete
  render now fails as one, instead of a transparent image reading as black text with no cue.
  `waitingCueProbeTellsABlankRenderFromAMissingCue` pins both outcomes in light and dark: a
  transparent image is rejected as incomplete, and the disconnected status renders completely, with
  text rows and no cue rows. All 24 cases and the centering and wrapping thresholds are unchanged.
  Locally the synchronous render put the cue and first line within a row of `uiImage`'s, for example
  cue rows 9...30 against 10...31 at `.xSmall`, with every pixel opaque. The probe's output is
  `probe-sync-vs-uiImage.log` in Overview's session files, beside the CI log.
- The artifact-action ink test, the file's other `uiImage` pixel read, shares the new helper with
  unchanged thresholds. `TaskRowsTests.segmentedGuidesRenderExactlyLikeOneContinuousGuide` and
  `SidebarAttentionTests` still read pixels from `uiImage`. On `2439914` plus t510,
  `test:mobile` passed all five suites, with 241 Mobile tests and no Mobile opt-in skip.

## Catalog failure grace

- On 2026-10-29, every main run that finished, from t485's merge `6195ffd` (run 40813614411) through
  `11b36bd` (run 40831447179) failed the strict-pool ChannelClient step at
  `CatalogTests.onlyConsecutiveFailingPollsCountTowardTheGrace(recovering: false)`, at both
  `phase.failure == nil` expectations. The grace runs from when the failing poll starts. The test
  held each response open and used a 0.5-second grace, so releasing a held response on the
  strict single cooperative worker could take longer than the grace and report the first
  failure at once.
- Holding each response 700 ms before release reproduced both failures locally under
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. Fixed rather than quarantined: `ChannelCatalogStore`
  takes a defaulted `now` clock, unchanged in production, and the test moves it explicitly. The
  test now also checks that the first failure stays quiet and that two consecutive failures past
  the grace report. It passes with the same 700 ms delay.

## Phone audience-capsule rendering

- `ToyBoxMobileTests/ComposerTests.audienceCapsuleIsSeparateFromIts44PointRowAndGrowsWithText`
  was quarantined behind `TOY_BOX_TEST_MOBILE_AUDIENCE_RENDERING=1`. On 2026-10-28, main
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
- Restored by t465 on 2026-10-29. The blank image came from where the pixels are produced, not
  from layout. `ImageRenderer.uiImage` returns a CGImage backed by an image provider (`(IP)` in
  its description): it returns in about 1.5 ms with its size already fixed by layout, and the
  pixels are rasterized only when the test first draws it (3–10 ms, then about 10 times faster on a
  second draw). So a correctly sized image with no drawn pixels, as on CI, points to that deferred
  rasterization rather than misplaced badge geometry. Why that rasterization came back empty on the CI
  simulator once is not provable from one run. The IOSurface message appears in every local run
  too, so it isn't evidence either way. 240 local renders under the full suite were all complete.
- The composer tests' `render` helper now draws with `ImageRenderer.render(rasterizationScale:renderer:)`
  into the test's own bitmap before returning, so no pixel read waits on a deferred provider. That
  path gave the same center column (24 rows from row 10 at `.large`, 60 at accessibility5) and the
  same coverage as `uiImage`. The placeholder, hint, attachment and context tests share the helper.
  All four cases and thresholds are unchanged. Removing the capsule background makes all four fail,
  so the probe still guards the visible badge. `test:mobile` passes with no Mobile opt-in skips.
  Other suites' pixel tests still read `uiImage` or `cgImage`.

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

- `ImageViewerLiveTextTests.onlyTheSettledCurrentImageIsAnalyzedAndTheWindowRemembersIt` was
  quarantined behind `TOY_BOX_TEST_LIVE_TEXT_ANALYSIS=1`. On 2026-10-26, Composer's full Mac run on
  `9bada33` plus test-gating changes (`image-strip-quarantined-mac-gate.log` in Composer's session
  files, lines 2523–2526) waited the unchanged 30s at `TranscriptTests.swift:1615` for the first
  image's Live Text, at a five-minute load average near 99. No viewer code changed.
- Cause (t503): the test's 30s polling deadline, not the viewer. Each analysis runs out of process in
  `mediaanalysisd`, whose latency scales with machine load. Instrumented runs on 2026-10-29 measured
  0.2–1s per analysis unloaded and in a full Mac run, 5.5s and 8.7s for the first image under 40 and
  100 busy loops, and 27.2s for one image under 30 background-QoS busy loops on the two efficiency
  cores. VisionKit never threw and always found the text. A run past 30s wasn't reproduced, so load
  near 99 exceeding it is inferred from that scaling.
- Restored to the default local suite. The test now awaits the viewer's own load and analysis tasks
  (`loads`, `analysisTask`) instead of a deadline, so a slow analysis waits and a missing one fails
  at once by name. A two-minute Swift Testing hang limit bounds it. It also asserts gating directly:
  no analysis task before the opening settles, a paged-past image's task is cancelled, and a reopen
  starts no task. Removing the settle guard, the paging cancel or remembering each failed it at the
  matching assertion. CI still skips it through `.readsTextInImages`, since GitHub's runners never
  read text, and no other default test covers this gating.

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

- `ChannelArtifactSessionTests.switchingScopeDiscardsTheVisitAndCancelsItsPendingLoad` was quarantined
  behind `TOY_BOX_TEST_ARTIFACT_SCOPE_TIMING=1`. Its `changingServer: false` argument failed the
  unchanged private three-second polling helper at line 81 in the 2026-10-26 Client diagnostic run
  (`reconnect-diagnostics-mac.log` in Core's session files, based on `db3b71d` with failure tracing).
  The test body matches main `f2eff6b`; no production cause or failed wait stage is established.
  Core owns `artifact-scope-readiness` under t340: capture the stalled stage, identify its cause and
  add deterministic scope-replacement coverage before restoring this case. Both argument bodies
  and the deadline remain unchanged. Do not clear the incident by retrying the original candidate.
- `ChannelArtifactSessionTests.removingAnArtifactDuringLoadingRetainsItsIdentityWithoutPublishingTheResponse`
  was also quarantined behind `TOY_BOX_TEST_ARTIFACT_SCOPE_TIMING=1`. It failed the unchanged
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
- Resolved by t340 on 2026-10-29. No artifact-session stage stalled. Both failures were the
  helper's final `#expect(await condition())` after its three-second wall-clock deadline, polling
  every 5 ms on the main actor. Around each failure, dozens of trivial, unrelated ChannelClient tests
  finished together after 3.3 to 7.6 seconds (lines 1170–1211 of the diagnostic run and 2060–2125 of
  `a65267d`), so parallel suite work held the shared main actor past the deadline. When it was
  released, the expired loop's last check could run before the load task's main-actor continuation
  published. A temporary reproduction queued a 3.5-second synchronous main-actor block before each
  original wait. Both scope arguments and the removal case failed at that same final expectation,
  while the signal-based rewrite passed under the same blocks (`t340-main-actor-repro.log` in
  Core's session files). The fix is in the tests' readiness, not production.
- `switchingScopeDiscardsTheVisitAndCancelsItsPendingLoad` is deleted rather than restored. The
  default `anObsoleteLoadCannotEndOrReplaceItsSuccessorsPendingVisit` channel and server cases make
  the same configuration changes, closing the visit, cancelling the obsolete load and opening a
  successor, and are stricter: they release the obsolete response while the successor is still held.
- The removal case is restored to the default gate under its name, waiting only on the mock's request
  signal and the load task's completion. It is the one case where the removed artifact stays
  presented with an unchanged token, so only cancellation and the `!isUnavailable` guard keep the late
  response out. Dropping both fails this case (`obsolete.isCancelled`, `content == nil`) while the
  successor contract still passes (`t340-removal-mutation.log`). The helper and the opt-in are gone.
