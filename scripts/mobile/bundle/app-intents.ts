import { join } from "node:path";
import { plist } from "../../shared/lib/index.ts";
import { appIntentsExtractor, swiftBuildObjects } from "../../shared/lib/app-intents.ts";

/** Writes `Metadata.appintents` for the phone's App Intents, if it declares any. */
export async function extractMobileAppIntents(app: string, scratch: string, device: boolean, configuration: string,
    sdk: string, minimumOS: string, environment: NodeJS.ProcessEnv) {
    const platform = device ? "iphoneos" : "iphonesimulator";
    const extract = await appIntentsExtractor({ family: "iOS", sdk, deploymentTarget: minimumOS,
        triple: `arm64-apple-ios${minimumOS}${device ? "" : "-simulator"}`, environment }, scratch);
    await extract({ module: "ToyBoxMobile", sources: "Sources/Mobile/ToyBoxMobile",
        objects: swiftBuildObjects(scratch, `${configuration === "release" ? "Release" : "Debug"}-${platform}`, "ToyBoxMobile-p"),
        bundleIdentifier: await plist(join(app, "Info.plist"), ["Print :CFBundleIdentifier"]),
        binary: join(app, "ToyBoxMobile"), output: app, dependencies: [], optional: true });
}
