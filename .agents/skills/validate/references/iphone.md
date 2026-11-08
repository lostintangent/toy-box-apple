# The iPhone

## The simulator

`SCRATCH_PATH=/tmp/tbm-<you> bun run simulator` builds, bundles, installs and launches
`dev.toybox.mobile` on the shared **Toy Box Mobile** iPhone Duo. It never opens or focuses Device
Hub (`com.apple.dt.Devices`). Select that device there to use its native hinge-posture slider.

| Option | What it does |
| --- | --- |
| `--hold` | Keeps the lease for manual checks. Ctrl-C or the 15-minute expiry shuts down and releases it |
| `--server <URL>` | Wins over a stale launch environment without saving Settings. Launches always pass `--server`, defaulting to `TOY_BOX_SERVER_URL` or `http://127.0.0.1:3210` |
| `--screenshot <file.png>` | Captures under the same lease. With `--hold`, it captures the current pose at lease end, before shutdown |
| `--displays` | Lists native display IDs |
| `--display <ID>` | Picks the screenshot display, including the Duo's secondary one. Otherwise it captures display `1`, the folded LCD |
| `--content-size <category>` | UIKit's process-only preferred category: `extraSmall`, `small`, `medium`, `large`, `extraLarge`, `extraExtraLarge`, `extraExtraExtraLarge`, `accessibilityMedium`, `accessibilityLarge`, `accessibilityExtraLarge`, `accessibilityExtraExtraLarge`, `accessibilityExtraExtraExtraLarge` |
| `--appearance light\|dark` | Passes `-appearance` in the app's process-only argument domain, ahead of saved Settings. It changes neither saved appearance nor the simulator's, so nothing needs restoring. It's app-only, not the Home Screen, Lock Screen or widget host |
| `--drive <steps.json>` | Runs a drive script, below |
| `--build-only` | Makes the Simulator bundle without booting |
| `--shutdown` | Shuts the simulator down |

- **One agent at a time.** Every simulator command takes a machine-wide `flock`, waits, and prints
  the holder's PID, command and worktree. Never boot another simulator or run `simctl` by hand.
  `MOBILE_SIMULATOR=<UDID>` selects an agreed shared device, not one per agent.
- Build-only, capture-only, display-list-only and shutdown-only commands reject launch options.
- Wait for visible drawing before ending the lease, not merely a launch PID.
- Simulator tests always build debug, and Simulator apps default to debug. Use
  `CONFIGURATION=release` for native performance comparisons. Output states the configuration and
  optimization.

### Drive scripts

`--drive <steps.json>` runs a DEBUG-only accessibility script under the lease, then shuts down on
completion or failure. Release builds have neither the startup hook nor the driver, and no script
runs without the explicit per-launch environment. It drives accessibility activation, native
control primary actions and text insertion, not finger touch. Reruns repeat sends, so use demo
servers for any script that writes. Never skip or retry actions.

| Step | Contract |
| --- | --- |
| `{"tap":"exact label or identifier"}` | Exact label or identifier, or the exact accessibility value of an unlabeled element such as native Search |
| `{"type":"text"}` | Text insertion |
| `{"wait":"label or value fragment"}` | `absent: true` waits for disappearance |
| `{"screenshot":"name","display":1}` | Captures only after settled accessibility and layout |
| `{"back":true}` | Native Back, including the restored stack's trait-less Back control through its primary action, then public window accessibility escape only if activation is unhandled. Disabled Back never falls through. `ifPresent: true` allows an explicitly optional initial return from restored navigation. Wait for the channel name, then optional Back, before tapping its row |
| `{"action":"Reply","on":"message-12"}` | A named accessibility custom action on one exact label or identifier |
| `{"posture":"unfolded","timeout":60}` | Waits for the measured scene, not hinge movement |
| `{"menuAction":"Edit Channel"}` | Visible-menu action dispatch, not a tap. See below |
| `{"scroll":"down","on":"scrollable-list"}` | One public accessibility scroll on that exact unique identifier, `up`, `down`, `left` or `right`. Missing targets wait within the step deadline. Ambiguous or unhandled actions fail without retries or direct content-offset changes. Some SwiftUI Forms decline this, so it isn't finger scrolling |
| `{"drag":"up","on":"conversation-transcript"}` | Moves the unique UIScrollView's content offset across 80% of its visible size over 24 frames, clamped to content, between delegate begin and end-dragging callbacks. Geometry and scroll phases drive older paging, but there's no pan gesture, deceleration, rubber-banding or drag dismissal of the keyboard |
| `{"zoom":2,"on":"screen-canvas"}` | Moves the unique UIScrollView's zoom scale to that scale over 24 frames, clamped to its limits and keeping the visible center in place, between delegate begin- and end-zooming callbacks. There's no pinch gesture, bounce or anchor under fingers |

- **Timeouts** are in seconds, 12 by default and 60 at most. Cancellation or a deadline stops drag
  and zoom steps but balances started end callbacks, never reporting completion.
- **Modal views.** Like VoiceOver, the tree skips the siblings beneath a visible
  `accessibilityViewIsModal` view, so a sheet hides the screen it covers and its own controls
  stay unambiguous.
- **Captures.** The host acknowledges a capture only with a settled app accessibility and layout
  snapshot and both `<name>.png` and `<name>.json` under `SCRATCH_PATH/mobile-drive/`, holding its
  step, state, labels and viewport. A later `status.json` can't erase it. The host bounds each
  capture or control child by the step timeout from the app's ready signal and always
  acknowledges. `simctl` can exit seconds after writing the image, so the app waits that timeout
  plus five seconds with its own step deadline paused. Children share the interruption signal, and
  cancellation kills the exact child and awaits its exit before shutdown and release.
- **Traits.** DEBUG status reports loaded content's `traits.contentSizeCategory` and
  `traits.interfaceStyle`, or `traitsError`. Active presented content takes priority, and visible
  controllers must agree. Never force view loading or substitute screen or requested launch traits
  for measured content. A drive verifies effective native traits before captures and completion.
- **Menus.** Dispatch needs one active menu in the current scene and one enabled, visible matching
  leaf. The driver tags its public accessibility identifier in UIKit's returned copy, requires the
  exact fresh tag on a measured native candidate, and restores the original identifier before
  dispatch or on failure. Same-title background controls don't establish ownership, and missing
  tags fail. Hidden items and unopened submenus are excluded. It dismisses through UIKit, waits for
  dismissal and settled layout within the same deadline, then performs the retained leaf through
  public `UIMenuLeaf`. Missing, dismissed, ambiguous or changed-scene menus fail explicitly. This
  proves neither finger selection, menu accessibility nor hardware-key delivery.
- **Dictation.** The Simulator has no speech model, so
  `SIMCTL_CHILD_TOYBOX_DICTATION_SCRIPT="<words>"` makes DEBUG dictation speak those words about
  three a second with a voice-like level, finalizing at each punctuation mark, then fall silent.
  It proves the recorder's layout and send path, not speech recognition.

### Duo posture

- Posture needs Computer Use on Device Hub while the driver holds the lease. Confirm its window and
  selected device identify the leased simulator before using the native posture controls.
- The SDK 27.1 fixture waits for settled **466x678-point folded** and **669x951-point unfolded**
  proof scenes, not general device or hinge detection. Timeouts report the expected and measured
  scenes and stop without retrying.
- Observed: native Open, then Rotate Right, reached unfolded. Display **1** is the folded LCD
  (1398x2034) and **3** the unfolded LCD (2007x2853), both 3x. **2** is TVOut, not unfolded.
  Re-enumerate after runtime or device changes, and never infer IDs from posture.
- Slider **0** was folded. The unfolded value is unverified, because Computer Use refused setting
  it and its advertised increment. A requested value is not a measured result.
- Legacy `{"fold":false}` fails with native diagnostics. Never use display power: it didn't change
  the scene and can crash SpringBoard.

| Script | What it checks |
| --- | --- |
| `scripts/mobile/dogfood/drives/posture.json` | Folded, unfolded, then folded, without sending or editing a draft |
| `scripts/mobile/dogfood/drives/reply.json` | A real reply and send with both display captures. It needs message-row identifiers and baseline request sequence 15, sends on every run, and needs the same live Device Hub posture actions |

## On a real iPhone

- Install through TestFlight. Direct local device installs are retired, so development never
  replaces the user's TestFlight app or its data.
- There's no bundled server or Bonjour default. Never save launch overrides in Settings.
- Both apps accept user-selected HTTP or HTTPS servers, including fully qualified Tailscale names.
  ATS uses `NSAllowsArbitraryLoads` alone, not `NSAllowsLocalNetworking`, which defeats the
  opt-out. Local-network permission is separate, and HTTPS keeps normal certificate validation.
- Simulator push injection never invokes the notification service. Prove real APNs-to-service
  wake on a device.
