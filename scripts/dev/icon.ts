import { copyFile, mkdir, readdir } from "node:fs/promises";
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

async function compileAppIcon(source: string, directory: string,
    platform: "macosx" | "iphoneos" | "iphonesimulator", minimumOS: string,
    env: NodeJS.ProcessEnv = process.env) {
    if (!await Bun.file(join(source, "icon.json")).exists()) throw new Error("AppIcon.icon source is missing.");
    const developer = platform === "macosx" ? "/Applications/Xcode.app/Contents/Developer"
        : env.DEVELOPER_DIR || "/Applications/Xcode.app/Contents/Developer";
    const compiler = env.ACTOOL || join(developer, "usr/bin/actool");
    if (!await executable(compiler)) throw new Error("actool not found. Install Xcode 27 or set ACTOOL.");
    const metadata = join(directory, "icon.plist");
    await command([compiler, source, "--compile", directory, "--platform", platform,
        "--minimum-deployment-target", minimumOS, "--target-device", platform === "macosx" ? "mac" : "iphone",
        "--app-icon", "AppIcon", "--output-partial-info-plist", metadata,
        "--output-format", "human-readable-text"], { env, quiet: true });
    return metadata;
}

export async function embedMobileAppIcon(resources: string, app: string, device: boolean, minimumOS: string,
    env: NodeJS.ProcessEnv = process.env) {
    await temporary("toy-box-mobile-icon.", async directory => {
        const metadata = await compileAppIcon(join(resources, "AppIcon.icon"), directory,
            device ? "iphoneos" : "iphonesimulator", minimumOS, env);
        const names = (await readdir(directory)).filter(name => name === "Assets.car" || /^AppIcon.*\.png$/.test(name));
        if (!names.includes("Assets.car") || names.length < 2
            || names.some(name => !Bun.file(join(directory, name)).size)
            || await plist(metadata, ["Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName"]) !== "AppIcon") {
            throw new Error("actool did not produce the iPhone AppIcon assets and metadata.");
        }
        for (const name of names) await copyFile(join(directory, name), join(app, name));
        await plist(join(app, "Info.plist"), [`Merge "${metadata}"`]);
    });
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
    await temporary("toy-box-icon.", async directory => {
        const metadata = await compileAppIcon(source, directory, "macosx",
            await plist(join(root, "Resources/Info.plist"), ["Print :LSMinimumSystemVersion"]));
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
