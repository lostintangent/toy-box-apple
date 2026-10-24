import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { command, executable, main, root, temporary } from "../lib.ts";

if (import.meta.main) await main(async () => {
    const source = join(root, "Resources/AppIcon.icon");
    const output = join(root, "Resources/AppIcon.icns");
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
        await command([tool, source, "--export-image", "--output-file", join(directory, "master.png"),
            "--platform", "macOS", "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1"],
        { quiet: true });
        await mkdir(join(directory, "AppIcon.iconset"));
        await command(["xcrun", "swiftc", "-O", join(root, "scripts/dev/icon-grid.swift"), "-o", join(directory, "grid")]);
        await command([join(directory, "grid"), join(directory, "master.png"), join(directory, "AppIcon.iconset")]);
        await command(["iconutil", "-c", "icns", "-o", output, join(directory, "AppIcon.iconset")]);
    });
    console.log(output);
});
