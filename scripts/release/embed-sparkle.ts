import { mkdir, rm, rename, chmod } from "node:fs/promises";
import { join } from "node:path";
import { command, main, text } from "../lib.ts";

export async function embedSparkle(source: string, app: string, license: string) {
    const framework = join(app, "Contents/Frameworks/Sparkle.framework");
    if (!await Bun.file(join(source, "Sparkle")).exists() || !Bun.file(license).size) {
        throw new Error("Sparkle framework or license is missing.");
    }
    await mkdir(join(app, "Contents/Frameworks"), { recursive: true });
    await mkdir(join(app, "Contents/Resources"), { recursive: true });
    await rm(framework, { recursive: true, force: true });
    await command(["ditto", source, framework]);
    await command(["install", "-m", "644", license, join(app, "Contents/Resources/Sparkle-LICENSE")]);
    for (const component of ["XPCServices", "Headers", "PrivateHeaders", "Modules"]) {
        await rm(join(framework, component), { recursive: true, force: true });
        await rm(join(framework, "Versions/Current", component), { recursive: true, force: true });
    }
    for (const executable of [
        "Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
    ].map(path => join(framework, "Versions/Current", path))) {
        if (await text(["xcrun", "lipo", "-archs", executable]) !== "arm64") {
            await command(["xcrun", "lipo", executable, "-thin", "arm64", "-output", `${executable}.arm64`]);
            await rename(`${executable}.arm64`, executable);
            await chmod(executable, 0o755);
        }
    }
}

if (import.meta.main) await main(async () => {
    const [source, app, license] = process.argv.slice(2);
    if (!source || !app || !license) throw new Error("Usage: bun run embed-sparkle FRAMEWORK APP LICENSE");
    await embedSparkle(source, app, license);
});
