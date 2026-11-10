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

## iPhone tests

`SCRATCH_PATH=/tmp/tbm-<you> bun run test:mobile` builds the iOS tests and runs the ChannelClient,
ToyBoxUI, ToyBoxMobileIntegrations, ToyBoxMobileWidget and ToyBoxMobile suites on the iOS Simulator
through Apple's `xctest` host. ChannelKit and mocked Intelligence run on the Mac only, but compile
in the iOS build.

- It rejects interrupted, failed and empty Swift Testing runs.
- A suite silent for three minutes is sampled, stopped and fails, naming the tests that never
  finished.
- Existing opt-ins stay off.
- It boots the simulator only once the build finishes, because a CI runner's simulator can shut
  down during the build.
- It shuts down the simulator only if it booted it. One that's already off, which a crash can
  cause, is noted rather than failing, so the run's own error is the one reported.

## CI

- Main and pull-request CI builds the phone app, its extensions and the shared modules for the
  Simulator and verifies the extensions' signatures. It runs the iOS suites only with an installed
  iOS 27+ runtime, and otherwise skips them explicitly.
- Tags and manual release dry runs skip iOS.
- The Mac runs ChannelClient once under the strict cooperative pool, then the remaining suites.
- Bundle, Siri and signing checks run only in the release job.
- Workflow shell checks gate warnings and errors, not style hints.

