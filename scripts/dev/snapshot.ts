import { parseArgs } from "node:util";
import { join } from "node:path";
import { CommandFailure, command, main, root, scratchPath } from "../lib.ts";
import { isolateIntegrations } from "./isolate-integrations.ts";
import { signApp } from "../release/sign-app.ts";

if (import.meta.main) await main(async () => {
    const args = process.argv.slice(2);
    const { values } = parseArgs({ args, strict: false, allowPositionals: true, options: {
        server: { type: "string" }, snapshot: { type: "string" }, help: { type: "boolean" },
    } });
    const usage = "Usage: bun run snapshot --server <url> --channel <id> --appearance light|dark "
        + "--size 1280x840 --snapshot <file.png> [--state <name>]";
    if (values.help) { console.log(usage); return; }
    if (!values.server || !values.snapshot) {
        throw new CommandFailure(64, `${usage}\nSnapshot rendering requires an explicit server and PNG destination.`);
    }
    const result = await command([process.execPath, join(root, "scripts/dev/run.ts"), "--no-open"], { quiet: true });
    process.stderr.write(result.stdout);
    process.stderr.write(result.stderr);
    const app = join(scratchPath(), "Toy Box.app");
    await isolateIntegrations(app);
    await signApp(app);
    await command([join(scratchPath(), "Toy Box.app/Contents/MacOS/ToyBoxDesktop"), ...args]);
});
