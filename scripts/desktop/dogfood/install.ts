import { mkdir, mkdtemp, realpath, rename, rm } from "node:fs/promises";
import { dirname, isAbsolute, join } from "node:path";
import { command, isMissing, text } from "../../shared/lib/index.ts";

const lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";

function registeredCopies(dump: string, identifier: string) {
    const paths = new Set<string>();
    for (const record of dump.split(/^-{2,}$/m)) {
        if (record.match(/^identifier:[ \t]+(.+)$/m)?.[1].trim() !== identifier) continue;
        const path = record.match(/^path:[ \t]+(.+?)(?:[ \t]+\(0x[\da-f]+\))?[ \t]*$/im)?.[1];
        if (path && isAbsolute(path)) paths.add(path);
    }
    return [...paths];
}

/** Registers the app and unregisters every other copy, so LaunchServices resolves the identifier to it. */
export async function registerOnly(app: string, identifier: string) {
    const kept = await realpath(app);
    for (const path of registeredCopies(await text([lsregister, "-dump"]), identifier)) {
        if (path === kept) continue;
        const result = await command([lsregister, "-u", path], { quiet: true, allowFailure: true });
        if (result.exitCode) console.warn(`Could not unregister ${path}, so LaunchServices may resolve ${identifier} to it.`);
    }
    await command([lsregister, "-f", app]);
}

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

/** Copies a built app beside the destination, prepares the copy, then swaps it into place. */
export async function installCopy(source: string, destination: string, prepare: (staged: string) => Promise<void>) {
    await mkdir(dirname(destination), { recursive: true });
    const stage = await mkdtemp(join(dirname(destination), ".stage."));
    try {
        const staged = join(stage, "Toy Box.app");
        await command(["ditto", source, staged]);
        await prepare(staged);
        await installBundle(staged, destination);
    } finally { await rm(stage, { recursive: true, force: true }); }
}

export async function pidsFor(binary: string) {
    const escaped = binary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const result = await command(["pgrep", "-f", `^${escaped}`], { quiet: true, allowFailure: true });
    if (result.exitCode > 1) throw new Error(result.stderr.toString() || "Could not inspect app processes.");
    return result.stdout.toString().trim().split(/\s+/).filter(Boolean).map(Number);
}

/** Opens a new instance and returns its pid. */
export async function launch(app: string, args: string[], openOptions: string[] = []) {
    const binary = await realpath(join(app, "Contents/MacOS/ToyBoxDesktop"));
    const before = new Set(await pidsFor(binary));
    await command(["open", "-n", ...openOptions, app, "--args", ...args]);
    for (let attempt = 0; attempt < 50; attempt++) {
        const pid = (await pidsFor(binary)).find(pid => !before.has(pid));
        if (pid !== undefined) return pid;
        await Bun.sleep(100);
    }
    throw new Error("The app did not launch.");
}
