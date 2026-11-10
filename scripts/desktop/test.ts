import { dirname, join } from "node:path";
import { mkdir, rm, stat } from "node:fs/promises";
import { CommandFailure, command, developerEnvironment, main, root, scratchPath, text } from "../shared/lib/index.ts";

/** Fails unless every Swift Testing run that started also ended. A test process can stop partway and still exit 0,
 * for example when a WindowServer event stops the main run loop under an async main, so its remaining tests never
 * run. This reads the event stream each test process writes to its own file, never the console. SwiftPM 6.4 relays
 * the console in 4 KB reads and drops any read that splits a multi-byte character, so a run's first or last line
 * can go missing from a green run (swiftlang/swift-package-manager#10636). */
function checkRunCompletion(events: string) {
    const kinds = events.split("\n").flatMap(line => {
        const record = line ? JSON.parse(line) : undefined;
        return record?.kind === "event" ? [record.payload.kind] : [];
    });
    const started = kinds.filter(kind => kind === "runStarted").length;
    const ended = kinds.filter(kind => kind === "runEnded").length;
    if (!ended || started !== ended) {
        throw new Error("error: a test run stopped before it ended, so its remaining tests never ran "
            + `(${ended} of ${started} Swift Testing runs ended)`);
    }
}

function testProcessTree(source: string, parentPID: number) {
    const rows = source.split("\n").flatMap(line => {
        const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
        return match ? [{ pid: Number(match[1]), parent: Number(match[2]), command: match[3] }] : [];
    });
    const pids = new Set([parentPID]);
    while (true) {
        const before = pids.size;
        for (const row of rows) if (pids.has(row.parent)) pids.add(row.pid);
        if (pids.size === before) break;
    }
    return rows.filter(row => pids.has(row.pid));
}

async function sampleAndStopTests(pid: number) {
    const directory = join(scratchPath(), "mac-test-watchdog");
    await mkdir(directory, { recursive: true });
    const descendants = testProcessTree(await text(["ps", "-axo", "pid=,ppid=,comm="]), pid);
    await Bun.write(join(directory, "processes.txt"), JSON.stringify(descendants, null, 2));
    try {
        for (const row of descendants) {
            if (row.command.includes("swiftpm-testing") || row.command.includes("xctest")) {
                const path = join(directory, `${row.pid}.sample.txt`);
                await command(["sample", String(row.pid), "3", "-file", path]);
                console.error(await Bun.file(path).text());
            }
        }
    } finally {
        for (const row of descendants.reverse()) {
            try { process.kill(row.pid, "SIGTERM"); }
            catch (error) {
                if (!(error instanceof Error) || !("code" in error) || error.code !== "ESRCH") throw error;
            }
        }
    }
}

if (import.meta.main) await main(async () => {
    const toolchain = dirname(dirname(await text(["xcrun", "--find", "swiftc"])));
    const plugins = join(toolchain, "lib/swift/host/plugins/testing");
    const args = ["xcrun", "swift", "test", "--package-path", root, "--scratch-path", scratchPath()];
    const directory = await stat(plugins).catch(error => {
        if (error.code === "ENOENT") return undefined;
        throw error;
    });
    if (directory?.isDirectory()) args.push("-Xswiftc", "-plugin-path", "-Xswiftc", plugins);
    const events = join(scratchPath(), "mac-test-events.jsonl");
    await rm(events, { force: true });
    args.push("--event-stream-output-path", events, "--event-stream-version", "0");
    const child = Bun.spawn([...args, ...process.argv.slice(2)], {
        cwd: root, env: developerEnvironment, stdin: "inherit", stdout: "inherit", stderr: "inherit",
    });
    const deadline = Promise.withResolvers<undefined>();
    const timer = setTimeout(() => deadline.resolve(undefined), 12 * 60 * 1_000);
    const code = await Promise.race([child.exited, deadline.promise]).finally(() => clearTimeout(timer));
    if (code === undefined) {
        await sampleAndStopTests(child.pid);
        throw new Error("Mac tests exceeded the twelve-minute watchdog. See the process samples.");
    }
    if (code) throw new CommandFailure(code, `Swift tests failed (exit ${code}).`);
    const file = Bun.file(events);
    checkRunCompletion(await file.exists() ? await file.text() : "");
});
