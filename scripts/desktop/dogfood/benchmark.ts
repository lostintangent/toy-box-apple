import { mkdir, realpath, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { bundleIdentity, command, machineLock, main, plist, required, root, temporary } from "../../shared/lib/lib.ts";
import { pidsFor } from "./validate.ts";
import { isolateIntegrations } from "./isolate.ts";

async function reachable(url: string, successful = false) {
    try {
        const response = await fetch(url, { signal: AbortSignal.timeout(1000) });
        await response.body?.cancel();
        return !successful || response.ok;
    } catch (error) {
        if (error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError"
            || ("code" in error && ["ECONNREFUSED", "ConnectionRefused", "ECONNRESET"].includes(String(error.code))))) return false;
        throw error;
    }
}

export function benchmarkLaunchCommand(options: {
    app: string; scenario: string; out: string; err: string; server: string; channel: string;
    transcript: string | undefined; scrollDrift?: string; scrollTrace?: string;
}) {
    const { app, scenario, out, err, server, channel, transcript } = options;
    return ["open", "-n", ...(scenario === "key" ? [] : ["-g"]), "-W",
        "--env", `TOY_BOX_TRANSCRIPT=${transcript ?? "lazy"}`,
        "--env", `TOY_BOX_BENCHMARK_SCROLL_DRIFT=${options.scrollDrift ?? "1"}`,
        "--env", `TOY_BOX_BENCHMARK_SCROLL_TRACE=${options.scrollTrace ?? "0"}`,
        "--stdout", out, "--stderr", err, app, "--args", "--server", server, "--channel", channel,
        "--benchmark", scenario, "-ApplePersistenceIgnoreState", "YES"];
}

if (import.meta.main) await main(async () => {
    const { values, positionals } = parseArgs({ allowPositionals: true,
        options: { summaries: { type: "boolean", default: false } } });
    const scenarios = positionals.length ? positionals : ["launch", "switch", "messages", "paging", "scroll"];
    for (const scenario of scenarios) {
        if (!["launch", "switch", "messages", "paging", "scroll", "trackpad", "key", "idle"].includes(scenario)) {
            throw new Error(`Unknown scenario: ${scenario}. Use launch, switch, messages, paging, scroll, trackpad, key or idle.`);
        }
    }
    const build = resolve(required("SCRATCH_PATH").replace(/\/$/, "") + "-benchmark");
    const reference = process.env.TOY_BOX_REFERENCE || resolve(root, "../toy-box-Minecraft");
    const port = process.env.TOY_BOX_PERF_PORT || "3292";
    const server = `http://127.0.0.1:${port}`;
    const name = "Toy Box Benchmark";
    const identity = `${bundleIdentity}.benchmark`;
    const app = join(build, `${name}.app`);
    const unlock = await machineLock("benchmark");
    try {
        if (await reachable(server)) throw new Error(`Port ${port} is already in use. Set TOY_BOX_PERF_PORT to a free port.`);
        await mkdir(build, { recursive: true });
        const binary = join(await realpath(build), `${name}.app/Contents/MacOS/ToyBoxDesktop`);
        await temporary("toy-box-benchmark.", async logs => {
            let fixture: ReturnType<typeof Bun.spawn> | undefined;
            const stopFixture = async () => {
                if (!fixture) return;
                fixture.kill();
                await fixture.exited;
                fixture = undefined;
            };
            let cleaning: Promise<void> | undefined;
            const cleanup = () => cleaning ??= (async () => {
                await stopFixture();
                for (const pid of await pidsFor(binary)) {
                    try { process.kill(pid); }
                    catch (error) { if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) throw error; }
                }
            })();
            const interrupt = () => { void cleanup().then(() => process.exit(130), error => {
                console.error(error); process.exit(1);
            }); };
            process.once("SIGINT", interrupt);
            process.once("SIGTERM", interrupt);
            try {
                console.log(`Building a release bundle in ${build}`);
                const result = await command([process.execPath, join(root, "scripts/desktop/bundle/index.ts"), "--no-open"],
                    { env: { CONFIGURATION: "release", SCRATCH_PATH: build }, quiet: true, allowFailure: true });
                await Bun.write(join(logs, "build.log"), Buffer.concat([result.stdout, result.stderr]));
                if (result.exitCode) {
                    throw new Error((result.stdout.toString() + result.stderr.toString()).split("\n").slice(-40).join("\n"));
                }
                await rm(app, { recursive: true, force: true });
                await command(["ditto", join(build, "Toy Box.app"), app]);
                await isolateIntegrations(app);
                await plist(join(app, "Contents/Info.plist"), [`Set :CFBundleIdentifier ${identity}`,
                    `Set :CFBundleName ${name}`, `Set :CFBundleDisplayName ${name}`]);
                await command(["codesign", "--force", "--sign", "-", app], { quiet: true });
                let over = 0, failed = 0;
                if (values.summaries) console.log("Catch-up summaries are on");
                for (const scenario of scenarios) {
                    const channel = ["switch", "key"].includes(scenario) ? "studio-demo"
                        : ["scroll", "trackpad"].includes(scenario) ? "scroll-demo" : "history-demo";
                    const deletion = await command(["defaults", "delete", identity], { quiet: true, allowFailure: true });
                    if (deletion.exitCode && !/not found|does not exist/i.test(deletion.stderr.toString())) {
                        throw new Error(deletion.stderr.toString() || "Could not reset benchmark preferences.");
                    }
                    await command(["defaults", "write", identity, "summarizeNewMessages", "-bool", values.summaries ? "YES" : "NO"]);
                    fixture = Bun.spawn([process.execPath, join(root, "scripts/demo-server/perf.ts"), reference], {
                        env: { ...process.env, TOY_BOX_PERF_PORT: port },
                        stdout: Bun.file(join(logs, "fixture.log")), stderr: Bun.file(join(logs, "fixture.err")),
                    });
                    let ready = false;
                    for (let attempt = 0; attempt < 100; attempt++) {
                        if (await reachable(`${server}/api/v1/channels`, true)) { ready = true; break; }
                        if (fixture.exitCode !== null) break;
                        await Bun.sleep(100);
                    }
                    if (!ready) {
                        throw new Error(`The fixture didn't start on port ${port}.\n`
                            + await Bun.file(join(logs, "fixture.log")).text()
                            + await Bun.file(join(logs, "fixture.err")).text());
                    }
                    const out = join(logs, `${scenario}.out`), err = join(logs, `${scenario}.err`);
                    await Bun.write(out, ""); await Bun.write(err, "");
                    await command(benchmarkLaunchCommand({ app, scenario, out, err, server, channel,
                        transcript: process.env.TOY_BOX_TRANSCRIPT,
                        scrollDrift: process.env.TOY_BOX_BENCHMARK_SCROLL_DRIFT,
                        scrollTrace: process.env.TOY_BOX_BENCHMARK_SCROLL_TRACE }));
                    await stopFixture();
                    const stdout = await Bun.file(out).text(), stderr = await Bun.file(err).text();
                    for (const line of stdout.split("\n").filter(line => /^(Benchmark |  )/.test(line) && !line.startsWith("Benchmark failed"))) {
                        console.log(line);
                    }
                    if (/^Benchmark failed/m.test(stderr)) {
                        console.error(stderr.split("\n").filter(line => line.startsWith("Benchmark failed")).join("\n"));
                        failed++;
                    } else if (!/^Benchmark /m.test(stdout)) {
                        console.error(`Benchmark failed: ${scenario} printed no results\n${stderr.split("\n").slice(-20).join("\n")}`);
                        failed++;
                    }
                    over += [...stdout.matchAll(/ OVER$/gm)].length;
                }
                if (failed || over) throw new Error(`${over} over budget, ${failed} failed`);
                console.log("Every result is within budget");
            } finally {
                process.removeListener("SIGINT", interrupt); process.removeListener("SIGTERM", interrupt);
                await cleanup();
            }
        });
    } finally { unlock(); }
});
