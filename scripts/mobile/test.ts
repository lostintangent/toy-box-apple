import { dirname, join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { Subprocess } from "bun";
import { CommandFailure, command, machineLock, main, scratchPath, text } from "../shared/lib/index.ts";
import { buildMobile, mobileEnvironment } from "./bundle/index.ts";
import { bootMobileSimulator, chooseMobileSimulator, seconds, shutDownMobileSimulator } from "./dogfood/boot.ts";

export const mobileTestProducts = [
    "ToyBoxClientTests", "ToyBoxUITests",
    "ToyBoxMobileIntegrationsTests", "ToyBoxMobileWidgetTests", "ToyBoxMobileTests",
];

/** Swift Testing prints as each test starts and finishes, so this much silence means what's left is stuck. */
const stallMinutes = 3;

/** How long a suite has to print anything at all. Its launch waits on the simulator rather than the tests, and a
 * new device's first-boot work kept CI's first launch silent for over a minute after `bootstatus` returned. */
const launchMinutes = 10;

/** The system jobs a CI runner's simulator boots without. Its device is new, and on a first boot these start
 * every system widget's first timeline, push and Apple Intelligence indexing, which held the 3-core runner's load
 * in the hundreds long after `bootstatus` and kept the first suite from launching. The tests use none of them.
 * A local simulator keeps them, since `bun run simulator` shares it. */
const ciDisabledJobs = ["com.apple.chronod", "com.apple.apsd", "com.apple.intelligenceplatformd"];

/** Fails unless every run in a suite's log printed its summary and Swift Testing's passed with at least one test.
 * The log comes straight from `xctest`, not through `swift test`'s relay, which can drop lines. */
export function checkMobileTestCompletion(log: string) {
    const count = (pattern: RegExp) => [...log.matchAll(pattern)].length;
    const started = count(/Test run started\./g);
    const finished = count(/Test run with [0-9]+ tests? .*(passed|failed) after /g);
    const suitesStarted = count(/Test Suite '(All|Selected) tests' started/g);
    const suitesFinished = count(/Test Suite '(All|Selected) tests' (passed|failed)/g);
    if ((!finished && !suitesFinished) || started !== finished || suitesStarted !== suitesFinished) {
        throw new Error("error: a test run stopped before printing its summary, so its remaining tests never ran "
            + `(Swift Testing ${finished} of ${started} finished, XCTest ${suitesFinished} of ${suitesStarted})`);
    }
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

/** Prints where each thread of the stalled xctest process is stuck, keeping the full sample in scratch. A sample
 * that fails is reported instead, so the stall stays the error. */
async function sampleStalledSuite(pid: number, name: string) {
    const path = join(scratchPath(), "mobile-test-watchdog", `${name}.sample.txt`);
    await mkdir(dirname(path), { recursive: true });
    const sampled = await command(["sample", String(pid), "3", "-file", path], { quiet: true, allowFailure: true });
    // A CI runner's `sample` can exit cleanly without writing its file.
    const file = Bun.file(path);
    if (sampled.exitCode || !await file.exists()) {
        console.error(`sample couldn't record ${name} (exit ${sampled.exitCode}). ${sampled.stderr.toString().trim()}`);
        return;
    }
    // The call graph shows where each thread is stuck. The binary image list after it is the bulk.
    console.error((await file.text()).split("\nBinary Images:")[0]);
}

/** Samples the stalled xctest process for the log, then ends it and its `simctl spawn`, so the simulator is left
 * to shut down or run the next suite. */
async function stopStalledSuite(child: Subprocess, agent: string, bundle: string, name: string) {
    const tests = (await text(["ps", "-axww", "-o", "pid=,command="])).split("\n")
        .map(line => line.trim().match(/^(\d+) (.*)$/))
        .find(match => match?.[2]?.startsWith(agent) && match[2].includes(bundle));
    if (tests) {
        const pid = Number(tests[1]);
        await sampleStalledSuite(pid, name)
            .catch(error => console.error(`sample couldn't record ${name}. ${error instanceof Error ? error.message : error}`));
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
    const launchedAt = performance.now();
    let startedIn: string | undefined;
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
    let timer = setTimeout(() => stalled.resolve(undefined), launchMinutes * 60_000);
    function heard() {
        if (startedIn) {
            timer.refresh();
            return;
        }
        startedIn = seconds(launchedAt);
        clearTimeout(timer);
        timer = setTimeout(() => stalled.resolve(undefined), stallMinutes * 60_000);
    }
    async function collect(stream: ReadableStream<Uint8Array>, index: number) {
        const decoder = new TextDecoder();
        for await (const data of stream) {
            logs[index] += decoder.decode(data, { stream: true });
            heard();
        }
        logs[index] += decoder.decode();
    }
    const finished = Promise.all([collect(child.stdout, 0), collect(child.stderr, 1), child.exited]);
    const code = await Promise.race([finished.then(([, , code]) => code), stalled.promise])
        .finally(() => clearTimeout(timer));
    const log = logs.join("\n");
    if (code === undefined) {
        await stopStalledSuite(child, agent, bundle, name);
        if (!startedIn) throw new Error(`error: ${name} printed nothing in the ${launchMinutes} minutes after it `
            + "launched, so it was stopped.");
        const unfinished = unfinishedTests(log);
        throw new Error(`error: ${name} printed nothing for ${stallMinutes} minutes, so it was stopped. `
            + (unfinished.length ? `Started and never finished:\n${unfinished.map(item => `  ${item}`).join("\n")}`
                : "No test had started."));
    }
    if (code) {
        process.stdout.write(log);
        throw new CommandFailure(code, `xctest failed (exit ${code}).`);
    }
    return { log, startedIn };
}

if (import.meta.main) await main(async () => {
    const options = process.argv.slice(2);
    if (options.some(option => option !== "--if-available")) {
        throw new Error("Usage: bun run test:mobile [--if-available]");
    }
    const unlock = await machineLock("mobile-simulator");
    try {
        const udid = await chooseMobileSimulator(false, options.includes("--if-available"));
        if (!udid) return;
        // Boot only once the build is done, since a CI runner's simulator can shut down during a long build.
        const { bin } = await buildMobile(false, true);
        const simulator = await bootMobileSimulator(udid, process.env.CI ? ciDisabledJobs : []);
        try {
            const developer = join(mobileEnvironment.DEVELOPER_DIR, "Platforms/iPhoneSimulator.platform/Developer");
            for (const name of mobileTestProducts) {
                const { log, startedIn } = await runSuite(simulator.udid, developer, bin, name);
                checkMobileTestCompletion(log);
                console.log(`${name}: started in ${startedIn}. ${log.match(/Test run with [^\n]+/)?.[0]}`);
                const skipped = [...log.matchAll(/Test .+ skipped\./g)].length;
                if (skipped) console.log(`  ${skipped} existing opt-in tests skipped.`);
            }
        } finally {
            if (simulator.bootedHere) await shutDownMobileSimulator(simulator.udid);
        }
    } finally { unlock(); }
});
