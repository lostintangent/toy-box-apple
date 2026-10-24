import { copyFile, mkdir, rm } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { command, executable, main, plist, root, scratchPath, text } from "../lib.ts";
import { embedSparkle } from "../release/embed-sparkle.ts";
import { signApp } from "../release/sign-app.ts";
import { embedAppIcon } from "./icon.ts";

export async function buildApp(configuration = process.env.CONFIGURATION || "debug", scratch = scratchPath()) {
    const sdk = process.env.SDKROOT || await text(["xcrun", "--sdk", "macosx", "--show-sdk-path"]);
    const sdkVersion = await text(["xcrun", "--sdk", sdk, "--show-sdk-version"]);
    if (!/^\d+(?:\.\d+)*$/.test(sdkVersion) || Number(sdkVersion.split(".")[0]) < 27) {
        throw new Error("Toy Box Desktop requires macOS SDK 27 or later.");
    }
    const args = ["--package-path", root, "--scratch-path", scratch, "--configuration", configuration,
        "--sdk", sdk, "--arch", "arm64"];
    await command(["xcrun", "swift", "build", ...args]);
    const bin = await text(["xcrun", "swift", "build", ...args, "--show-bin-path"]);
    const app = join(scratch, "Toy Box Desktop.app");
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

    let processor = process.env.APP_INTENTS_PROCESSOR;
    if (!processor) {
        const found = await command(["xcrun", "--find", "appintentsmetadataprocessor"],
            { quiet: true, allowFailure: true });
        processor = found.exitCode ? undefined : found.stdout.toString().trim();
    }
    processor ||= "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor";
    if (!await executable(processor)) {
        throw new Error("Siri and Shortcuts need Xcode's appintentsmetadataprocessor. Install Xcode 27 or set APP_INTENTS_PROCESSOR.");
    }
    const toolchain = resolve(dirname(processor), "../..");
    const buildVersion = await command(["/usr/libexec/PlistBuddy", "-c", "Print :ProductBuildVersion",
        resolve(toolchain, "../../../version.plist")], { quiet: true, allowFailure: true });
    const xcodeBuild = buildVersion.exitCode
        ? await text(["xcrun", "--sdk", sdk, "--show-sdk-build-version"])
        : buildVersion.stdout.toString().trim();
    const intents = join(scratch, "appintents");
    const objects = join(scratch, "out/Intermediates.noindex/ToyBoxDesktop.build",
        configuration === "release" ? "Release" : "Debug", "ToyBoxDesktop-p.build/Objects-normal/arm64");
    await mkdir(intents, { recursive: true });
    const sources = (await Array.fromAsync(new Bun.Glob("**/*.swift").scan({
        cwd: join(root, "Sources/ToyBoxDesktop"), absolute: true,
    }))).sort();
    await Bun.write(join(intents, "sources.txt"), sources.join("\n") + "\n");
    const stems = new Set(sources.map(source => basename(source, ".swift")));
    const values = (await Array.fromAsync(new Bun.Glob("*.swiftconstvalues").scan({ cwd: objects, absolute: true })))
        .filter(path => basename(path, ".swiftconstvalues") === "ToyBoxDesktop-primary"
            || stems.has(basename(path, ".swiftconstvalues"))).sort();
    if (!values.length) throw new Error(`The compiler wrote no const values to ${objects}.`);
    await Bun.write(join(intents, "const-values.txt"), values.join("\n") + "\n");
    await Bun.write(join(intents, "dependency-metadata.txt"), "");
    await rm(join(app, "Contents/Resources/Metadata.appintents"), { recursive: true, force: true });
    const result = await command([processor, "--toolchain-dir", toolchain, "--module-name", "ToyBoxDesktop",
        "--sdk-root", sdk, "--xcode-version", xcodeBuild, "--platform-family", "macOS",
        "--deployment-target", minimumOS, "--bundle-identifier", await plist(info, ["Print :CFBundleIdentifier"]),
        "--output", join(app, "Contents/Resources"), "--target-triple", `arm64-apple-macos${minimumOS}`,
        "--binary-file", binary, "--dependency-file", join(intents, "ToyBoxDesktop.d"),
        "--stringsdata-file", join(intents, "ExtractedAppShortcutsMetadata.stringsdata"),
        "--source-file-list", join(intents, "sources.txt"), "--swift-const-vals-list", join(intents, "const-values.txt"),
        "--metadata-file-list", join(intents, "dependency-metadata.txt"),
        "--static-metadata-file-list", join(intents, "dependency-metadata.txt"),
        "--force", "--compile-time-extraction", "--deployment-aware-processing", "--no-app-shortcuts-localization"],
    { quiet: true, allowFailure: true });
    const log = result.stdout.toString() + result.stderr.toString();
    await Bun.write(join(intents, "processor.log"), log);
    if (result.exitCode) throw new Error(log || "App Intents metadata extraction failed.");
    for (const line of log.split("\n").filter(line => /warning|error/i.test(line))) console.error(line);
    if (!Bun.file(join(app, "Contents/Resources/Metadata.appintents/extract.actionsdata")).size) {
        throw new Error(`${log}\nNo App Intents metadata was written.`);
    }
    await signApp(app);
    return app;
}

if (import.meta.main) await main(async () => {
    const app = await buildApp();
    console.log(app);
    if (process.argv[2] !== "--no-open") await command(["open", "-n", app]);
});
