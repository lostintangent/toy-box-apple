import { dirname, join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { Subprocess } from "bun";
import { checkTestCompletion, CommandFailure, command, machineLock, main, scratchPath, text } from "../shared/lib/index.ts";
import { buildMobile, mobileEnvironment } from "./bundle/index.ts";
import { prepareMobileSimulator } from "./dogfood/boot.ts";

export const mobileTestProducts = [
    "ChannelClientTests", "ToyBoxUITests",
    "ToyBoxMobileIntegrationsTests", "ToyBoxMobileWidgetTests", "ToyBoxMobileTests",
];

/** Swift Testing prints as each test starts and finishes, so this much silence means what's left is stuck. */
const stallMinutes = 3;

export function checkMobileTestCompletion(log: string) {
    checkTestCompletion(log);
    if (!/Test run with [1-9][0-9]* tests? .*passed after /.test(log)
        || /Test run with [0-9]+ tests? .*failed after /.test(log)) {
        throw new Error("iOS tests did not finish with a nonempty passing Swift Testing summary.");
    }
}

/** The suites and tests a Swift Testing log shows starting without finishing, in the order they started. */
function unfinishedTests(log: string) {
    const running = new Map<string, number>();
    for (const line of log.split("\n")) {
        const started = line.match(/^\S+ ((?:Test|Suite) (?!case |run ).+) started\.$/)?.[1];
        const ended = line.match(/^\S+ ((?:Test|Suite) (?!case |run ).+?)(?: with \d+ test cases?)? (?:passed|failed) after /)?.[1]
            ?? line.match(/^\S+ ((?:Test|Suite) (?!case |run ).+?) skipped/)?.[1];
        if (started) running.set(started, (running.get(started) ?? 0) + 1);
        else if (ended && running.has(ended)) {
            const count = running.get(ended)! - 1;
            if (count) running.set(ended, count);
            else running.delete(ended);
        }
    }
    return [...running.keys()];
}

/** Samples the stalled xctest process for the log, keeping the full sample in scratch, then ends it and its
 * `simctl spawn`, so the simulator is left to shut down or run the next suite. */
async function stopStalledSuite(child: Subprocess, agent: string, bundle: string, name: string) {
    const tests = (await text(["ps", "-axww", "-o", "pid=,command="])).split("\n")
        .map(line => line.trim().match(/^(\d+) (.*)$/))
        .find(match => match?.[2]?.startsWith(agent) && match[2].includes(bundle));
    if (tests) {
        const pid = Number(tests[1]);
        const path = join(scratchPath(), "mobile-test-watchdog", `${name}.sample.txt`);
        await mkdir(dirname(path), { recursive: true });
        const sampled = await command(["sample", String(pid), "3", "-file", path], { quiet: true, allowFailure: true });
        // The call graph shows where each thread is stuck. The binary image list after it is the bulk.
        if (!sampled.exitCode) console.error((await Bun.file(path).text()).split("\nBinary Images:")[0]);
        try { process.kill(pid, "SIGKILL"); }
        catch (error) {
            if (!(error instanceof Error) || !("code" in error) || error.code !== "ESRCH") throw error;
        }
    }
    child.kill("SIGKILL");
    await child.exited;
}

async function runSuite(udid: string, developer: string, bin: string, name: string) {
    const agent = join(developer, "Library/Xcode/Agents/xctest");
    const bundle = join(bin, `${name}.xctest`);
    const child = Bun.spawn(["xcrun", "simctl", "spawn", udid, agent, bundle], {
        env: {
            ...mobileEnvironment,
            SIMCTL_CHILD_DYLD_FRAMEWORK_PATH: join(developer, "Library/Frameworks"),
            SIMCTL_CHILD_DYLD_LIBRARY_PATH: join(developer, "usr/lib"),
        },
        stdout: "pipe", stderr: "pipe",
    });
    const logs = ["", ""];
    const stalled = Promise.withResolvers<undefined>();
    const timer = setTimeout(() => stalled.resolve(undefined), stallMinutes * 60_000);
    async function collect(stream: ReadableStream<Uint8Array>, index: number) {
        const decoder = new TextDecoder();
        for await (const data of stream) {
            logs[index] += decoder.decode(data, { stream: true });
            timer.refresh();
        }
        logs[index] += decoder.decode();
    }
    const finished = Promise.all([collect(child.stdout, 0), collect(child.stderr, 1), child.exited]);
    const code = await Promise.race([finished.then(([, , code]) => code), stalled.promise])
        .finally(() => clearTimeout(timer));
    const log = logs.join("\n");
    if (code === undefined) {
        await stopStalledSuite(child, agent, bundle, name);
        const unfinished = unfinishedTests(log);
        throw new Error(`error: ${name} printed nothing for ${stallMinutes} minutes, so it was stopped. `
            + (unfinished.length ? `Started and never finished:\n${unfinished.map(item => `  ${item}`).join("\n")}`
                : "No test had started."));
    }
    if (code) {
        process.stdout.write(log);
        throw new CommandFailure(code, `xctest failed (exit ${code}).`);
    }
    return log;
}

if (import.meta.main) await main(async () => {
    const options = process.argv.slice(2);
    if (options.some(option => option !== "--if-available")) {
        throw new Error("Usage: bun run test:mobile [--if-available]");
    }
    const unlock = await machineLock("mobile-simulator");
    try {
        const simulator = await prepareMobileSimulator(false, options.includes("--if-available"));
        if (!simulator) return;
        try {
            const { bin } = await buildMobile(false, true);
            const developer = join(mobileEnvironment.DEVELOPER_DIR, "Platforms/iPhoneSimulator.platform/Developer");
            for (const name of mobileTestProducts) {
                const log = await runSuite(simulator.udid, developer, bin, name);
                checkMobileTestCompletion(log);
                console.log(`${name}: ${log.match(/Test run with [^\n]+/)?.[0]}`);
                const skipped = [...log.matchAll(/Test .+ skipped\./g)].length;
                if (skipped) console.log(`  ${skipped} existing opt-in tests skipped.`);
            }
        } finally {
            if (simulator.bootedHere) {
                await command(["xcrun", "simctl", "shutdown", simulator.udid], { env: mobileEnvironment });
            }
        }
    } finally { unlock(); }
});
