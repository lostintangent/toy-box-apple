import { basename, dirname, join, resolve } from "node:path";
import { bundleIdentity, command, main, plist, required, root, text } from "../../shared/lib/index.ts";
import { signApp } from "../bundle/sign.ts";
import { validateShareExtension } from "../bundle/share-extension.ts";
import { isolateIntegrations } from "./isolate.ts";
import { installCopy, launch, registerOnly } from "./install.ts";
import { validateWidgetExtension } from "../bundle/widget-extension.ts";

// Computer Use resolves the test ID through LaunchServices, which never resolves a copy under
// /tmp and otherwise picks among every registered copy. So every worktree installs into the main
// checkout, the path the user approved, and other copies are unregistered.
async function testAppPath(name: string) {
    const common = await text(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], { allowFailure: true });
    const checkout = basename(common) === ".git" ? dirname(common) : root;
    return join(checkout, ".build/agents", `${name}.app`);
}

if (import.meta.main) await main(async () => {
    const scratch = resolve(required("SCRATCH_PATH"));
    const server = process.env.SERVER_URL || "http://127.0.0.1:3210";
    const testName = "Toy Box Test";
    const testID = `${bundleIdentity}.test`;
    const testApp = await testAppPath(testName);
    await command([process.execPath, join(root, "scripts/desktop/bundle/index.ts"), "--no-open"], {
        env: { CONFIGURATION: "release", SCRATCH_PATH: scratch }, quiet: true,
    });
    const buildVersion = await text(["xcrun", "vtool", "-show-build",
        join(scratch, "Toy Box.app/Contents/MacOS/ToyBoxDesktop")]);
    const versions = [...buildVersion.matchAll(/^\s*sdk\s+(\S+)/gm)].map(match => match[1]);
    if (!versions.length || versions.some(value => !/^\d+(?:\.\d+)*$/.test(value) || Number(value.split(".")[0]) < 27)) {
        throw new Error(`Validation requires a bundle stamped with macOS SDK 27 or later.\n${buildVersion}`);
    }
    await validateShareExtension(join(scratch, "Toy Box.app"));
    await validateWidgetExtension(join(scratch, "Toy Box.app"));
    await installCopy(join(scratch, "Toy Box.app"), testApp, async staged => {
        await plist(join(staged, "Contents/Info.plist"), [
            `Set :CFBundleIdentifier ${testID}`, `Set :CFBundleName ${testName}`,
            `Set :CFBundleDisplayName ${testName}`,
        ]);
        await isolateIntegrations(staged);
        await signApp(staged);
    });
    await registerOnly(testApp, testID);
    const pid = await launch(testApp, ["--server", server, "-ApplePersistenceIgnoreState", "YES",
        ...process.argv.slice(2)], ["-g"]);
    console.log(`Launched pid ${pid} against ${server} as ${testID}. Find its window with list_apps, and kill ${pid} when done.`);
});
