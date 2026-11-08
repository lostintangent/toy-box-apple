# Toolchains and bundles

What each build needs and what each bundle contains. Read it before changing the build, bundle or
signing scripts.

## Toolchains

| | Mac | iPhone |
| --- | --- | --- |
| Toolchain | Command Line Tools only | Xcode's toolchain and SDK through SwiftPM, never `xcodebuild` |
| Requires | Swift tools 6.4+ and the macOS 27+ SDK on Apple Silicon | Swift 6.4, an iOS 27+ SDK, and a Duo runtime for the app or another iPhone's 27+ runtime for tests |
| Developer dir | `/Library/Developer/CommandLineTools` | `/Applications/Xcode.app/Contents/Developer`, or set `DEVELOPER_DIR` to another installed Xcode |

- Use native `bun check` for the TypeScript tooling, without installing TypeScript. Platform
  script folders never import each other.
- `bun run build` invokes Xcode's `appintentsmetadataprocessor` for Siri and Shortcuts, so Xcode
  must be installed, though its license needn't be accepted.
- `bun run build` stamps the real SDK before signing. Use that bundle for native visual checks,
  not SwiftPM's unstamped executable. `bun run validate` rejects recorded SDKs below macOS 27.
- Mobile commands set `TOY_BOX_MOBILE=1` for the package's mobile graph and build in
  `mobile-simulator` or `mobile-testflight` under `SCRATCH_PATH`. Each links the same manifest,
  sources and tests into a dependency-free workspace. Leave the default graph, the Mac build and
  tests and the Sparkle lockfile unchanged. Never export the flag globally, run that graph in the
  repository root or share scratch paths across builds.
- Never download simulator runtimes.

## Bundle contents

### iPhone

- Before signing, the build stamps and verifies the selected iOS SDK in `LC_BUILD_VERSION`,
  keeping the plist's deployment minimum and the device or Simulator platform. `DTSDKName` alone
  isn't enough. Every executable's real SDK stamp is verified.
- Before signing, it extracts the `ToyBoxMobile` module's App Intents metadata into
  `Metadata.appintents` with Xcode's `appintentsmetadataprocessor`, as `bun run build` does on the
  Mac. A module with no App Intents gets no metadata, and the bundle continues without it.
- It compiles `Resources/Shared/AppIcon.icon` with the selected platform's `actool`, embedding
  layered appearances, PNG fallbacks and generated metadata. There's no separate phone artwork or
  iOS asset catalog.
- It embeds `PlugIns/ToyBoxMobileWidget.appex` (`dev.toybox.mobile.widget`),
  `PlugIns/ToyBoxMobileNotification.appex` (`dev.toybox.mobile.notification`) and
  `PlugIns/ToyBoxMobileShare.appex` (`dev.toybox.mobile.share`) with SwiftPM
  application-extension safety. All enter through a verified `_NSExtensionMain`, which establishes
  context before WidgetKit's generated Swift main, the service or the share sheet.
- Simulator capabilities link into `__TEXT,__entitlements` and `__TEXT,__ents_der`, including all
  four bundles' `group.dev.toybox.mobile`. Ad-hoc signatures carry no restricted device
  entitlements. Simulator extensions are signed before the host, without device profiles or
  credentials.

### Mac

- The app has audio-input permission and, when Developer ID signed with its widget, the
  `RHFNBL7EG4.dev.toybox.desktop` app group.
- `Contents/PlugIns/ToyBoxDesktopWidget.appex` has App Sandbox, the same Team-ID-prefixed group
  and no networking. Its ID is the app's plus `.widget`, with matching version and build. Ad-hoc
  builds have no group entitlement or snapshot publishing, and isolated validation, snapshot and
  benchmark copies remove widget and group metadata. Register the containing app with
  LaunchServices before probing WidgetKit registration.
- The Quick Send and Needs You controls share that extension. Both executables include
  foreground intents from `ToyBoxControlIntents` through `AppIntentsPackage`. `bun run build`
  extracts the package metadata, merges it into the host and extension, then signs. Controls open
  host routes and never send from the extension.
- `ToyBoxDesktopShare.appex` builds through SwiftPM and `_NSExtensionMain`, without Xcode or a
  storyboard, and never auto-sends or connects to a server. Test, validation, benchmark and
  development clones and snapshots omit Share, Services, URL schemes and document handlers, so check
  `pluginkit -m -v -i dev.toybox.desktop.share` on a normal bundle, not an isolated clone.
- `scripts/desktop/bundle/sign.ts` signs Sparkle's components inside out before the app, never
  with `--deep`. Keep Sparkle's license in the bundle.

## App icon

After changing `Resources/Shared/AppIcon.icon`, run `bun run icon` and commit it with
`Resources/Desktop/AppIcon.icns` and `Resources/Desktop/Assets.car`. Generation needs Icon
Composer and Xcode's `actool`. Mac builds only copy the outputs, so Command Line Tools and Mac CI
need neither. `CFBundleIconName` selects the layered dark, clear and tinted appearances, and the
Mac `.icns` and generated phone PNGs remain fallbacks.
