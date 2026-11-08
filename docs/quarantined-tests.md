# Quarantined tests

Each test here is out of the merge gate behind an opt-in, under AGENTS.md's
[Test reliability](../AGENTS.md#test-reliability) rules. An entry names its opt-in and owner, and
records the failed run, the diagnosis so far and what restoring the test needs. A passing rerun doesn't
restore one. Delete the entry when its test returns to the gate, since git history keeps
closed incidents.

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

## Artifact HTML origin probe

- `ArtifactViewerTests.HTMLKeepsAnOpaqueOriginAndCanLoadOnlyTheServersFileResources` is quarantined
  behind `TOY_BOX_TEST_ARTIFACT_HTML_ORIGIN_PROBE=1` in t605. Owner: Overview. Its assertions and its
  15-second `wait(until:)` are unchanged. Unquarantined, it passed in 0.449 seconds, and the default
  run skips it with its reason.
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
  `sameDocumentTOCLinksAndHashChangesStayInsideTheSandbox` and `HTMLUnderlapsTheBarsAndRestoresItsReadingPosition`
  use the same 15-second wait and stay in the default gate. They failed only under the artificial
  burner load, alongside unrelated suites, which isn't evidence of a defect. Quarantine one only if it
  fails in CI or a full run without artificial load.
