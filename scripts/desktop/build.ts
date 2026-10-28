import { copyFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { command, main, plist, root, scratchPath, text } from "../shared/support/lib.ts";
import { embedSparkle } from "./bundle/embed-sparkle.ts";
import { signApp } from "./bundle/sign-app.ts";
import { embedAppIcon } from "../shared/support/app-icon.ts";
import { embedShareExtension } from "./bundle/share-extension.ts";
import { embedWidgetExtension } from "./bundle/widget-extension.ts";
import { extractAppIntents } from "./bundle/app-intents.ts";

export async function buildApp(configuration = process.env.CONFIGURATION || "debug", scratch = scratchPath()) {
    const sdk = process.env.SDKROOT || await text(["xcrun", "--sdk", "macosx", "--show-sdk-path"]);
    const sdkVersion = await text(["xcrun", "--sdk", sdk, "--show-sdk-version"]);
    if (!/^\d+(?:\.\d+)*$/.test(sdkVersion) || Number(sdkVersion.split(".")[0]) < 27) {
        throw new Error("Toy Box requires macOS SDK 27 or later.");
    }
    const args = ["--package-path", root, "--scratch-path", scratch, "--configuration", configuration,
        "--sdk", sdk, "--arch", "arm64"];
    await command(["xcrun", "swift", "build", ...args]);
    const bin = await text(["xcrun", "swift", "build", ...args, "--show-bin-path"]);
    const app = join(scratch, "Toy Box.app");
    const binary = join(app, "Contents/MacOS/ToyBoxDesktop");
    const info = join(app, "Contents/Info.plist");
    await mkdir(join(app, "Contents/MacOS"), { recursive: true });
    await mkdir(join(app, "Contents/Resources"), { recursive: true });
    await copyFile(join(bin, "ToyBoxDesktop"), binary);
    await copyFile(join(root, "Resources/Info.plist"), info);
    await embedAppIcon(join(root, "Resources"), app);
    await plist(info, ["Add :CFBundleIconFile string AppIcon", "Add :CFBundleIconName string AppIcon"]);
    const minimumOS = await plist(info, ["Print :LSMinimumSystemVersion"]);
    await command(["xcrun", "vtool", "-set-build-version", "macos", minimumOS, sdkVersion,
        "-replace", "-output", binary, binary]);
    await embedSparkle(join(bin, "Sparkle.framework"), app, join(scratch, "checkouts/Sparkle/LICENSE"));
    await embedShareExtension(bin, app, sdkVersion, minimumOS);
    await embedWidgetExtension(bin, app, sdkVersion, minimumOS);

    await extractAppIntents(app, scratch, configuration, sdk, minimumOS);
    await signApp(app);
    return app;
}

if (import.meta.main) await main(async () => {
    const app = await buildApp();
    console.log(app);
    if (process.argv[2] !== "--no-open") await command(["open", "-n", app]);
});
