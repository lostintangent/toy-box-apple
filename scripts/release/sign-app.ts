import { join } from "node:path";
import { command, main, root } from "../lib.ts";

export async function signApp(app: string, options = ["--force", "--timestamp=none", "--sign", "-"]) {
    const framework = join(app, "Contents/Frameworks/Sparkle.framework");
    for (const component of [
        join(framework, "Versions/Current/Autoupdate"),
        join(framework, "Versions/Current/Updater.app"), framework,
    ]) {
        await command(["codesign", ...options, component]);
        await command(["codesign", "--verify", "--strict", component]);
    }
    await command(["codesign", ...options, "--entitlements", join(root, "Resources/Release.entitlements"), app]);
    await command(["codesign", "--verify", "--strict", app]);
}

if (import.meta.main) await main(async () => {
    const [app, ...options] = process.argv.slice(2);
    if (!app) throw new Error("Usage: bun run sign-app APP [codesign options]");
    await signApp(app, options.length ? options : undefined);
});
