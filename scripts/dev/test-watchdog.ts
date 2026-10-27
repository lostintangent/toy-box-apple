import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { command, main, root, scratchPath, text } from "../lib.ts";

export function testProcessTree(source: string, parentPID: number) {
    const rows = source.split("\n")
        .flatMap(line => {
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

if (import.meta.main) await main(async () => {
    const child = Bun.spawn([process.execPath, "run", "test", ...process.argv.slice(2)], {
        cwd: root, stdin: "inherit", stdout: "inherit", stderr: "inherit",
    });
    const deadline = Promise.withResolvers<undefined>();
    const timer = setTimeout(() => deadline.resolve(undefined), 12 * 60 * 1_000);
    const result = await Promise.race([child.exited.then(code => ({ code })), deadline.promise]);
    clearTimeout(timer);
    if (result) {
        process.exitCode = result.code;
        return;
    }

    const directory = join(scratchPath(), "mac-test-watchdog");
    await mkdir(directory, { recursive: true });
    const descendants = testProcessTree(await text(["ps", "-axo", "pid=,ppid=,comm="]), child.pid);
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
    throw new Error("Mac tests exceeded the twelve-minute watchdog. See the process samples.");
});
