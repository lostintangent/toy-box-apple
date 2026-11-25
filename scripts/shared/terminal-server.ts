#!/usr/bin/env bun
// A disposable terminal server with a real shell on 3212, for a terminal pane to attach to. Our demo
// servers don't speak the terminal protocol. It runs Thrush's ThrushServer from the revision the
// phone's lockfile pins, so the server speaks the protocol our Thrush does, with a private home and
// an empty working directory in a fresh data directory this removes on exit. The first run for each
// revision fetches and builds it, which takes a couple of minutes, into a cache every checkout shares.
//
// Usage: bun run terminal-server [ThrushServer options], such as --shell /bin/bash.
import { mkdir, mkdtemp, rename, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { command, main, root } from "./lib/index.ts";

const port = 3212;

await main(async () => {
    const lockfile = await Bun.file(join(root, "Package.mobile.resolved")).json() as {
        pins: { identity: string; state: { revision: string } }[];
    };
    const thrushRevision = lockfile.pins.find(pin => pin.identity === "thrush")?.state.revision ?? "";
    if (!/^[0-9a-f]{40}$/.test(thrushRevision)) throw new Error("Package.mobile.resolved doesn't pin a Thrush revision.");
    const cache = join(homedir(), "Library/Caches/toy-box-apple/terminal-server", thrushRevision);
    const executable = join(cache, "build/release/ThrushServer");
    if (!(await Bun.file(executable).exists())) {
        const source = join(cache, "source");
        if (!(await Bun.file(join(source, "Package.swift")).exists())) {
            const download = `${source}.${process.pid}`;
            await mkdir(cache, { recursive: true });
            await command(["git", "init", "-q", download]);
            await command(["git", "-C", download, "fetch", "-q", "--depth", "1",
                "https://github.com/lostintangent/thrush", thrushRevision]);
            await command(["git", "-C", download, "checkout", "-q", "FETCH_HEAD"]);
            await rename(download, source);
        }
        await command(["swift", "build", "-c", "release", "--product", "ThrushServer",
            "--package-path", source, "--scratch-path", join(cache, "build")]);
    }
    const data = await mkdtemp(join(process.env.TMPDIR || tmpdir(), "toy-box-terminal-"));
    console.log("Starting a disposable terminal server. Ctrl-C stops it.");
    const server = Bun.spawn([executable, "--port", String(port), "--data-dir", data,
        ...process.argv.slice(2)], { stdio: ["inherit", "inherit", "inherit"] });
    const stop = (signal: NodeJS.Signals) => server.kill(signal);
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    try { process.exitCode = await server.exited; }
    finally { await rm(data, { recursive: true, force: true }); }
});
