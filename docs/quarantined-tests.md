# Quarantined tests

A test that fails on main without an identified code cause moves behind an explicit opt-in the
same day, rather than staying in the merge gate while CI reruns or timing races get patched in
place. Its entry here names the opt-in and an owner, and records the failed run, the diagnosis so
far and a follow-up task. Quarantine changes gating, not responsibility for the failure.

A test returns to the gate only with its cause found and deterministic coverage, never by loosening
assertions or adding retries, and a passing rerun doesn't restore one. Delete its entry then, since
git history keeps closed incidents.

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
  visibility, display sleep and session lock state. Composer owns both cases. The wheel-input case
  stays opt-in, because native wheel animation needs an awake, unlocked Mac.

## Paging after a window drag

- `TranscriptTests.pagingDownAfterADragHandsThePlaceBackToTheHold` is quarantined in t1259, behind
  `TOY_BOX_TEST_TRANSCRIPT_DRAG_PAGING=1`. Owner: Transcript. Its assertions are unchanged, and the
  default run skips it with its reason.
- First seen in CI on #152's Mac `test` job,
  [run 44408393445](https://github.com/lostintangent/toy-box-apple/actions/runs/44408393445), on
  `aa08fc950`, which touches only the artifact viewer. Page Down moved, then Page Up didn't:
  "Paging up went from 2306.0 back to 2306.0" (`TranscriptTests.swift:708`), after 15.9 seconds.
- The cause is not established. t1259 follows whether a reader's Page Up after a window drag can do
  nothing in the app, since that would be a bug shipped in Mac 0.1.48. Restoration needs the cause
  found, with deterministic coverage.

## Artifact HTML origin probe

- `ArtifactViewerTests.HTMLKeepsAnOpaqueOriginAndCanLoadOnlyTheServersFileResources` is quarantined
  behind `TOY_BOX_TEST_ARTIFACT_HTML_ORIGIN_PROBE=1` in t605. Owner: Overview. Its assertions are
  unchanged. Its 15-second `wait(until:)` became the shared `waitUntil` in t1131, which has a
  60-second deadline. Unquarantined, it passed in 0.449 seconds, and the default run skips it with its
  reason.
- First seen by Shell in a local full Mac run for t598 on the shared Mac, under ordinary multi-agent
  load, failing at the same `#require` (`ArtifactViewerTests.swift:705`). It has not failed in CI, so
  no CI run is cited.
- Under ten CPU-burner loops on the shared Mac, load about 630 to 770, two of three full Mac runs on
  `ab4af66` failed at the test's `wait(until:)` `#require` (`ArtifactViewerTests.swift:705`). The
  probe message never arrived, and `web.error` was nil. In the first of those runs, three other
  Artifact viewer tests also failed at that helper, and many unrelated suites hit the 60-second time
  limit. An unstressed full run passed in 4.1 seconds.
- A replacement that waited for the probe with no clock hung the whole suite. Under the same load,
  the 12-minute watchdog in `scripts/desktop/test.ts` fired while the test was still waiting, and its
  sample showed the wait parked after 12 minutes. The replacement was reverted. The Swift Testing time
  limit did not bound that wait, so a wait needs its own deadline.
- The cause is not established. Unmeasured candidates include WebKit delaying the `postMessage`
  probe, the content process launch, and the `fetch` of `/api/v1/channels` or the `pixel.svg` image
  load never settling.
- t607 instruments the probe without changing its assertions or waits. A pass-through navigation
  delegate records each callback WebKit reached: start, commit, finish, fail, failed provisional
  navigation and content process termination. The page posts progress marks after its API fetch,
  alias fetch and image load, and those marks go to a separate array, so the probe's result is
  unchanged. On a miss the test prints the trace, the marks, the renderer and web view state, and the
  fixture's requests before it rethrows. One instrumented run finished in 0.58 seconds. Three full Mac
  runs with the opt-in passed at load of about 330 to 390, and the probe finished in 0.8 to 1.5
  seconds. No miss occurred, so the test stays quarantined and the cause is still not established.
- Restoration needs the stalled step identified, with deterministic regression coverage. Restore it
  without loosening the assertions or adding retries. `arrivalsKeepTheSelectedIdentityAndRemovalDoesNotSubstituteANeighbor`,
  `sameDocumentResourceLinksAndHashChangesStayInsideTheSandbox` and
  `HTMLUnderlapsTheBarsAndRestoresItsReadingPosition` used the same 15-second wait, now the shared
  `waitUntil`, and stay in the default gate. They failed only under the artificial burner load, alongside unrelated suites, which
  isn't evidence of a defect. Quarantine one only if it fails in CI or a full run without artificial
  load.

## Artifact same-document navigation

- The `"toc"` case of `ArtifactViewerTests.sameDocumentTOCLinksAndHashChangesStayInsideTheSandbox`
  is quarantined in t1131 as `sameDocumentTOCLinksStayInsideTheSandbox`, behind
  `TOY_BOX_TEST_ARTIFACT_TOC_NAVIGATION=1`. Owner: Overview. Its assertions are unchanged, and the
  default run skips it with its reason. The `"resource"` and
  `"hash"` cases never missed, and they stay in the gate as
  `sameDocumentResourceLinksAndHashChangesStayInsideTheSandbox`, sharing the same body.
- First seen by Composer on 2026-11-14 in a local full Mac run for t1130 on the shared Mac, under
  ordinary multi-agent load with no burner. The `"toc"` case failed at the helper's `#require`
  (`ArtifactViewerTests.swift:724` on `ef5a561`): "The artifact did not reach its expected settled
  state." It has not failed in CI, so no CI run is cited.
- That helper took no source location, so the miss doesn't say whether the page never finished
  loading or its scroll message never arrived. Since t1131 the test waits with the shared
  `waitUntil` and its 60-second deadline, in two named steps, "the page finished loading" and "the
  scroll message arrived", so the next miss names its step. Like the origin probe, the test loads an HTML artifact
  from the fixture server and waits for a `postMessage`, so t607 follows both. Restoration needs the
  stalled step identified, with deterministic coverage, never a longer deadline or a retry.

## Artifact external links on the phone

- `ArtifactWebRendererTests.externalLinksOpenTheBrowserInsteadOfReplacingTheEmbeddedDocument` is
  quarantined on the iPhone simulator in t1131, behind `TOY_BOX_TEST_ARTIFACT_PHONE_EXTERNAL_LINK=1`.
  Owner: Overview. Its assertions are unchanged, and the phone run skips it with its reason. Both misses were on the simulator, so the Mac runs the same shared test
  in the gate, and an external link opening the browser stays covered there.
- On 2026-11-10, under load averages of 59 to 170, the simulator's WebKit took 5.9 seconds to ask
  for the root document's policy and 8.7 seconds to start it, so the link opened after the
  then 15-second deadline. The deadline became 60 seconds in `1ce24856`.
- On 2026-11-14, CI's iOS foundation job in
  [run 43632443145](https://github.com/lostintangent/toy-box-apple/actions/runs/43632443145) stopped
  while this test was running, but the test didn't cause it. The CI simulator went down under the
  suite, one of six such losses since 11-10, which `test:mobile` now reports as a simulator loss, so that run doesn't count against it.
- The same day it missed the 60-second deadline in Overview's local full phone run for t1131, on the
  shared Mac at load averages of about 390 to 455 from ordinary agent builds and a freshly booted
  simulator, with no burner. It failed at the helper's `#require` (`ArtifactWebRendererTests.swift:40`,
  unchanged since `d53a8d9`): "The artifact did not reach its expected settled state."
- In the local 11-14 miss, the load returned, but the helper doesn't say whether the page never finished
  loading or the link never reached the navigation policy. Neither is measured. Since t1131 the test runs `load` in its own task and waits with the
  shared `waitUntil` in two named steps, each with a 60-second deadline. "The content rules compiled
  and the page started loading" covers the compile, and "the link opened the browser" reports
  whether the page was still loading. t607 follows it with the other WebKit settle misses. Restoration needs
  the stalled step identified, with deterministic coverage, never a longer deadline or a retry.
