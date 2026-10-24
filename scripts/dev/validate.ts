import { mkdir, mkdtemp, realpath, rename, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { bundleIdentity, command, isMissing, main, plist, required, root, text } from "../lib.ts";
import { signApp } from "../release/sign-app.ts";

async function installBundle(staged: string, destination: string) {
    const old = await mkdtemp(join(dirname(destination), ".old."));
    let moved = false;
    try { await rename(destination, join(old, "previous.app")); moved = true; }
    catch (error) { if (!isMissing(error)) throw error; }
    try {
        await rename(staged, destination);
    } catch (error) {
        if (moved) await rename(join(old, "previous.app"), destination);
        await rm(old, { recursive: true, force: true });
        throw error;
    }
    await rm(old, { recursive: true, force: true });
}

export async function pidsFor(binary: string) {
    const escaped = binary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const result = await command(["pgrep", "-f", `^${escaped}`], { quiet: true, allowFailure: true });
    if (result.exitCode > 1) throw new Error(result.stderr.toString() || "Could not inspect app processes.");
    return result.stdout.toString().trim().split(/\s+/).filter(Boolean).map(Number);
}

if (import.meta.main) await main(async () => {
    const scratch = resolve(required("SCRATCH_PATH"));
    const server = process.env.SERVER_URL || "http://127.0.0.1:3210";
    const app = join(root, ".build/validation/Toy Box Desktop.app");
    const testName = "Toy Box Desktop Test";
    const testID = `${bundleIdentity}.test`;
    const testApp = join(root, ".build/agents", `${testName}.app`);
    await command([process.execPath, join(root, "scripts/dev/run.ts"), "--no-open"], {
        env: { CONFIGURATION: "release", SCRATCH_PATH: scratch }, quiet: true,
    });
    const buildVersion = await text(["xcrun", "vtool", "-show-build",
        join(scratch, "Toy Box Desktop.app/Contents/MacOS/ToyBoxDesktop")]);
    const versions = [...buildVersion.matchAll(/^\s*sdk\s+(\S+)/gm)].map(match => match[1]);
    if (!versions.length || versions.some(value => !/^\d+(?:\.\d+)*$/.test(value) || Number(value.split(".")[0]) < 27)) {
        throw new Error(`Validation requires a bundle stamped with macOS SDK 27 or later.\n${buildVersion}`);
    }
    for (const [destination, test] of [[app, false], [testApp, true]] as const) {
        await mkdir(dirname(destination), { recursive: true });
        const stage = await mkdtemp(join(dirname(destination), ".stage."));
        try {
            const staged = join(stage, "Toy Box Desktop.app");
            await command(["ditto", join(scratch, "Toy Box Desktop.app"), staged]);
            if (test) {
                await plist(join(staged, "Contents/Info.plist"), [
                    `Set :CFBundleIdentifier ${testID}`, `Set :CFBundleName ${testName}`,
                    `Set :CFBundleDisplayName ${testName}`,
                ]);
                await signApp(staged);
            }
            await installBundle(staged, destination);
        } finally { await rm(stage, { recursive: true, force: true }); }
    }
    await command(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f", testApp]);
    const approvals = Bun.file(join(required("HOME"), ".copilot/computer-use/approvals.json"));
    const approved = await approvals.exists() && (await approvals.text()).includes(`"${testID}"`);
    const launchApp = approved ? testApp : app;
    const launchID = approved ? testID : bundleIdentity;
    if (!approved) console.error(`${testID} isn't approved for Computer Use yet, so this launches the shared bundle.`);
    const binary = await realpath(join(launchApp, "Contents/MacOS/ToyBoxDesktop"));
    const before = new Set(await pidsFor(binary));
    await command(["open", "-n", "-g", launchApp, "--args", "--server", server,
        "-ApplePersistenceIgnoreState", "YES", ...process.argv.slice(2)]);
    for (let attempt = 0; attempt < 50; attempt++) {
        const pid = (await pidsFor(binary)).find(pid => !before.has(pid));
        if (pid !== undefined) {
            console.log(`Launched pid ${pid} against ${server} as ${launchID}. Find its window with list_apps, and kill ${pid} when done.`);
            return;
        }
        await Bun.sleep(100);
    }
    throw new Error("The app did not launch.");
});
