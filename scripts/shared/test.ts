import { dirname, join } from "node:path";
import { stat } from "node:fs/promises";
import { CommandFailure, developerEnvironment, main, root, scratchPath, text } from "./lib.ts";

export function checkTestCompletion(log: string) {
    const count = (pattern: RegExp) => [...log.matchAll(pattern)].length;
    const started = count(/Test run started\./g);
    const finished = count(/Test run with [0-9]+ tests? .*(passed|failed) after /g);
    const suitesStarted = count(/Test Suite '(All|Selected) tests' started/g);
    const suitesFinished = count(/Test Suite '(All|Selected) tests' (passed|failed)/g);
    if (started !== finished || suitesStarted !== suitesFinished) {
        throw new Error("error: a test run stopped before printing its summary, so its remaining tests never ran "
            + `(Swift Testing ${finished} of ${started} finished, XCTest ${suitesFinished} of ${suitesStarted})`);
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
    const logs = await Promise.all([forward(child.stdout, process.stdout), forward(child.stderr, process.stderr)]);
    const code = await child.exited;
    if (code) throw new CommandFailure(code, `Swift tests failed (exit ${code}).`);
    checkTestCompletion(logs.join("\n"));
});
