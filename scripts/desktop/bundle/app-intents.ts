import { join } from "node:path";
import { plist } from "../../shared/lib/index.ts";
import { appIntentsExtractor, swiftBuildObjects } from "../../shared/lib/app-intents.ts";
import { validateControlMetadata, widgetExtension } from "./widget-extension.ts";

export async function extractAppIntents(app: string, scratch: string, configuration: string,
    sdk: string, minimumOS: string) {
    const extract = await appIntentsExtractor({ family: "macOS", sdk, deploymentTarget: minimumOS,
        triple: `arm64-apple-macos${minimumOS}` }, scratch);
    const variant = configuration === "release" ? "Release" : "Debug";
    async function extractModule(module: string, sources: string, target: string, bundle: string, binaryName: string,
        output: string, dependencies: string[]) {
        const metadata = await extract({ module, sources, objects: swiftBuildObjects(scratch, variant, target),
            bundleIdentifier: await plist(join(bundle, "Contents/Info.plist"), ["Print :CFBundleIdentifier"]),
            binary: join(bundle, "Contents/MacOS", binaryName), output, dependencies });
        validateControlMetadata(await Bun.file(metadata).text());
        return metadata;
    }

    const shared = await extractModule("ToyBoxControlIntents", "Sources/Desktop/ToyBoxControlIntents",
        "ToyBoxControlIntents-t", app, "ToyBoxDesktop", join(scratch, "appintents/ToyBoxControlIntents/output"), []);
    await extractModule("ToyBoxDesktop", "Sources/Desktop/ToyBoxDesktop", "ToyBoxDesktop-p", app, "ToyBoxDesktop",
        join(app, "Contents/Resources"), [shared]);
    const widget = widgetExtension(app);
    await extractModule("ToyBoxDesktopWidget", "Sources/Desktop/Extensions/ToyBoxDesktopWidget", "ToyBoxDesktopWidget-p",
        widget, "ToyBoxDesktopWidget", join(widget, "Contents/Resources"), [shared]);
}
