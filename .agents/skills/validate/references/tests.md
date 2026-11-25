# Tests

## Opt-in suites

The default suite never needs these. Each runs with `SCRATCH_PATH=/tmp/tbm-<you> bun run test`
and the setting shown.

| Suite | Setting and filter | Notes |
| --- | --- | --- |
| Demo integration | `TOY_BOX_DEMO_URL=http://127.0.0.1:3210` | Against `bun run demo`, or a fresh one on its own `TOY_BOX_DEMO_PORT` |
| History integration | `TOY_BOX_HISTORY_DEMO_URL=http://127.0.0.1:3211`, `--filter HistoryFixtureTests` | Against a freshly started history demo |
| Real dictation | `TOY_BOX_REAL_DICTATION_TESTS=1`, `--filter ComposerTests/theRealTranscriberHearsARecordingThroughTheAudioSourceProtocol` | Needs the on-device English dictation model and synthesized audio, not microphone access. The normal suite never queries speech-model assets |
| Transcript timing | `TOY_BOX_TEST_TRANSCRIPT_TIMING=1`, `--filter 'Transcript\|ImageViewer'` | Native Transcript frame-timing and VisionKit selection-layer checks. Run locally before changes to landing, paging, following arrivals or native image text selection |
| Image-strip wheel | `TOY_BOX_TEST_IMAGE_STRIP_SCROLLING=1`, `--filter ComposerTests/imageStripOverflowRespondsToWheelInput` | Keep the Mac awake and unlocked. Equal height, hidden scrollers, overflow and synchronous native clip scrolling stay in the default suite |
| Live Text interaction | `TOY_BOX_TEST_LIVE_TEXT_INTERACTION=1`, `--filter pressesOnTextReachLiveTextAndEverythingElseReachesTheViewer` | Native press and drag routing in an ordered off-screen window. WindowServer events can stop the runner's outer run loop. Geometry and routing-policy checks and VisionKit analysis gating stay in the default suite |
| HTML origin probe | `TOY_BOX_TEST_ARTIFACT_HTML_ORIGIN_PROBE=1` | Quarantined. See [docs/quarantined-tests.md](../../../../docs/quarantined-tests.md) |
| Artifact TOC navigation | `TOY_BOX_TEST_ARTIFACT_TOC_NAVIGATION=1` | Quarantined. See [docs/quarantined-tests.md](../../../../docs/quarantined-tests.md) |

## iPhone tests

`SCRATCH_PATH=/tmp/tbm-<you> bun run test:mobile` builds the iOS tests and runs the ToyBoxClient,
ToyBoxUI, ToyBoxMobileIntegrations, ToyBoxMobileWidget and ToyBoxMobile suites on the iOS Simulator
through Apple's `xctest` host. ToyBoxKit and mocked Intelligence run on the Mac only, but compile
in the iOS build.

- It rejects interrupted, failed and empty Swift Testing runs.
- A suite silent for three minutes is stopped and fails, naming the tests that never finished. Only
  CI samples it first, for the reason under the iPhone reference's **Never attach a debugger**. A
  suite's launch waits on the simulator rather than the tests, so the three minutes start at its
  first output, and one that prints nothing for ten minutes after it launches is stopped the same
  way. A sample that fails is noted, and the stall stays the error.
- A suite that fails or stalls on a simulator that's no longer booted, or whose runtime is gone, is
  reported as the simulator going down, not as the tests failing. It prints the device's state, its
  runtime's images and whether they're still mounted, crash reports, and what CoreSimulator logged
  about the shutdown since the run started, and keeps the host log of the services that mount
  runtimes in `mobile-test-watchdog/host.log`. CoreSimulator writes its own log only with its
  `DebugLogging` default on, which CI sets, and CI uploads it with the watchdog folder and crash
  reports when the job fails.
- Existing opt-ins stay off. Prefix one with `SIMCTL_CHILD_` to pass it to the simulator, like
  `SIMCTL_CHILD_TOY_BOX_TEST_ARTIFACT_PHONE_EXTERNAL_LINK=1` for the quarantined phone external-link
  test in [docs/quarantined-tests.md](../../../../docs/quarantined-tests.md).
- It boots the simulator only once the build finishes, because a CI runner's simulator can shut
  down during the build. It prints how long the simulator took to be ready and each suite took to
  start.
- On CI, it boots without system widget timelines, push and Apple Intelligence indexing. A
  runner's device is new, and that first-boot work starved the first suite's launch. A local
  simulator keeps them, because `bun run simulator` shares it.
- On CI, between the build and the boot, it deletes every runtime image but the simulator's own and
  prints what it deleted. The runner's image registers some runtimes twice, and CoreSimulator
  re-adds those every ten minutes, unmounting a volume SimLaunchHost still has a library from,
  which crashed SimLaunchHost and the simulator with it. A local run never deletes a runtime.
- It shuts down the simulator only if it booted it. One that's already off, which a crash can
  cause, is noted rather than failing, so the run's own error is the one reported.

## CI

- Main and pull-request CI builds the phone app, its extensions and the shared modules for the
  Simulator and verifies the extensions' signatures. It runs the iOS suites only with an installed
  iOS 27+ runtime, and otherwise skips them explicitly.
- Tags and manual release dry runs skip iOS.
- The Mac runs ToyBoxClient once under the strict cooperative pool, then the remaining suites.
- Bundle, Siri and signing checks run only in the release job.
- Workflow shell checks gate warnings and errors, not style hints.

