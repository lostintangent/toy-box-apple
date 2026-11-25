#!/usr/bin/env bun
// A disposable Toy Box server with a real shell on 3212, for a terminal pane to attach to. Our demo
// servers don't speak the terminal protocol. It runs Thrush's serve-pty.py, which builds the Toy Box
// revision it pins from ~/Desktop/toy-box without changing that checkout, then serves it on loopback
// with a private home and an empty working directory, from a fresh data directory this removes on
// exit. The script comes from the Thrush revision the phone's lockfile pins, so the server speaks
// the protocol our Thrush does. The first run for each revision builds Toy Box, which takes a few
// minutes, into a cache every checkout shares.
//
// Usage: bun run terminal-server [serve-pty.py options], such as --port 3300, --shell /bin/sh or
// --toy-box PATH.
import { chmod, mkdir, mkdtemp, rename, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { main, root } from "./lib/index.ts";

const port = 3212;

await main(async () => {
    const lockfile = await Bun.file(join(root, "Package.mobile.resolved")).json() as {
        pins: { identity: string; state: { revision: string } }[];
    };
    const thrushRevision = lockfile.pins.find(pin => pin.identity === "thrush")?.state.revision ?? "";
    if (!/^[0-9a-f]{40}$/.test(thrushRevision)) throw new Error("Package.mobile.resolved doesn't pin a Thrush revision.");
    // serve-pty.py caches its build beside its own folder, so it runs from ours.
    const thrush = join(homedir(), "Library/Caches/toy-box-apple/terminal-server", thrushRevision);
    const script = join(thrush, "scripts/serve-pty.py");
    if (!(await Bun.file(script).exists())) {
        const response = await fetch(`https://raw.githubusercontent.com/lostintangent/thrush/${thrushRevision}/scripts/serve-pty.py`);
        if (!response.ok) throw new Error(`Downloading serve-pty.py failed (HTTP ${response.status}).`);
        await mkdir(join(thrush, "scripts"), { recursive: true });
        const download = `${script}.${process.pid}`;
        await Bun.write(download, response);
        await chmod(download, 0o755);
        await rename(download, script);
    }
    const data = await mkdtemp(join(process.env.TMPDIR || tmpdir(), "toy-box-terminal-"));
    console.log(`Serving a disposable Toy Box on http://127.0.0.1:${port} once it's built. Ctrl-C stops it.`);
    const server = Bun.spawn(["python3", script, "--toy-box", join(homedir(), "Desktop/toy-box"),
        "--port", String(port), "--data-dir", data, ...process.argv.slice(2)], { stdio: ["inherit", "inherit", "inherit"] });
    const stop = (signal: NodeJS.Signals) => server.kill(signal);
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    try { process.exitCode = await server.exited; }
    finally { await rm(data, { recursive: true, force: true }); }
});
