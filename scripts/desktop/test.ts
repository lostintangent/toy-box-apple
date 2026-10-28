import { dirname, join } from "node:path";
import { mkdir, stat } from "node:fs/promises";
import { checkTestCompletion, CommandFailure, command, developerEnvironment, main, root, scratchPath, text } from "../shared/lib/index.ts";

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
    const child = Bun.spawn([...args, ...process.argv.slice(2)], {
        cwd: root, env: developerEnvironment, stdin: "inherit", stdout: "pipe", stderr: "pipe",
    });
    async function forward(stream: ReadableStream<Uint8Array>, destination: NodeJS.WriteStream) {
        const decoder = new TextDecoder();
        let log = "";
        for await (const data of stream) {
            destination.write(data);
            log += decoder.decode(data, { stream: true });
        }
        return log + decoder.decode();
    }
    const deadline = Promise.withResolvers<undefined>();
    const timer = setTimeout(() => deadline.resolve(undefined), 12 * 60 * 1_000);
    const result = await Promise.race([
        Promise.all([forward(child.stdout, process.stdout), forward(child.stderr, process.stderr), child.exited]),
        deadline.promise,
    ]).finally(() => clearTimeout(timer));
    if (!result) {
        await sampleAndStopTests(child.pid);
        throw new Error("Mac tests exceeded the twelve-minute watchdog. See the process samples.");
    }
    const [stdout, stderr, code] = result;
    if (code) throw new CommandFailure(code, `Swift tests failed (exit ${code}).`);
    checkTestCompletion(stdout + "\n" + stderr);
});
