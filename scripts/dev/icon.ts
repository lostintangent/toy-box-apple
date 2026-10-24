import { copyFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { command, executable, main, plist, root, temporary } from "../lib.ts";

export async function embedAppIcon(resources: string, app: string) {
    const names = ["AppIcon.icns", "Assets.car"];
    for (const name of names) {
        if (!Bun.file(join(resources, name)).size) {
            throw new Error(`${name} is missing or empty. Run bun run icon.`);
        }
    }
    const destination = join(app, "Contents/Resources");
    await mkdir(destination, { recursive: true });
    for (const name of names) await copyFile(join(resources, name), join(destination, name));
}

if (import.meta.main) await main(async () => {
    const source = join(root, "Resources/AppIcon.icon");
    const output = join(root, "Resources/AppIcon.icns");
    const assets = join(root, "Resources/Assets.car");
    if (!await Bun.file(join(source, "icon.json")).exists()) throw new Error("AppIcon.icon source is missing.");
    let tool = process.env.ICTOOL;
    if (!tool) {
        for (const candidate of [
            "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool",
            "/Applications/Icon Composer.app/Contents/Executables/ictool",
        ]) if (await executable(candidate)) { tool = candidate; break; }
    }
    if (!tool || !await executable(tool)) throw new Error("ictool not found. Install Icon Composer or set ICTOOL.");
    const compiler = process.env.ACTOOL || "/Applications/Xcode.app/Contents/Developer/usr/bin/actool";
    if (!await executable(compiler)) throw new Error("actool not found. Install Xcode 27 or set ACTOOL.");
    await temporary("toy-box-icon.", async directory => {
        const metadata = join(directory, "icon.plist");
        await command([compiler, source, "--compile", directory, "--platform", "macosx",
            "--minimum-deployment-target", await plist(join(root, "Resources/Info.plist"), ["Print :LSMinimumSystemVersion"]),
            "--target-device", "mac", "--app-icon", "AppIcon", "--output-partial-info-plist", metadata,
            "--output-format", "human-readable-text"], { quiet: true });
        if (!Bun.file(join(directory, "Assets.car")).size
            || await plist(metadata, ["Print :CFBundleIconName"]) !== "AppIcon") {
            throw new Error("actool did not produce the AppIcon appearance assets.");
        }
        await command([tool, source, "--export-image", "--output-file", join(directory, "master.png"),
            "--platform", "macOS", "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1"],
        { quiet: true });
        await mkdir(join(directory, "AppIcon.iconset"));
        await command(["xcrun", "swiftc", "-O", join(root, "scripts/dev/icon-grid.swift"), "-o", join(directory, "grid")]);
        await command([join(directory, "grid"), join(directory, "master.png"), join(directory, "AppIcon.iconset")]);
        await command(["iconutil", "-c", "icns", "-o", output, join(directory, "AppIcon.iconset")]);
        await copyFile(join(directory, "Assets.car"), assets);
    });
    console.log(`${output}\n${assets}`);
});
