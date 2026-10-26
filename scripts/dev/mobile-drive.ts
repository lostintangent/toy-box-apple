import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { basename, isAbsolute, join, resolve } from "node:path";
import { isMissing, root } from "../lib.ts";

type Timed = { timeout?: number };
export type MobileDriveStep = Timed & (
    { tap: string } | { type: string } | { wait: string; absent?: boolean } | { screenshot: string; display: string }
    | { back: true; ifPresent?: boolean } | { fold: boolean } | { action: string; on: string }
);
export type MobileDriveTraits = { contentSizeCategory: string; interfaceStyle: string };
type Status = { state: "running" | "ready" | "completed" | "failed"; step: number;
    labels: string[]; viewport: number[]; error?: string; traits?: MobileDriveTraits; traitsError?: string };

function record(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseMobileDrive(value: unknown): MobileDriveStep[] {
    if (!Array.isArray(value) || !value.length) throw new Error("The drive script must be a nonempty array.");
    return value.map((step: unknown, index) => {
        const fail = (message: string): never => { throw new Error(`Drive step ${index + 1}: ${message}`); };
        if (!record(step)) return fail("expected an action object.");
        const actions = ["tap", "type", "wait", "screenshot", "back", "fold", "action"].filter(key => key in step);
        if (actions.length !== 1) return fail("expected exactly one of tap, type, wait, screenshot, back, fold or action.");
        const action = actions[0]!;
        const allowed = new Set([action, "timeout", ...(action === "screenshot" ? ["display"] : []),
            ...(action === "back" ? ["ifPresent"] : []), ...(action === "action" ? ["on"] : []),
            ...(action === "wait" ? ["absent"] : [])]);
        if (Object.keys(step).some(key => !allowed.has(key))) return fail("unknown action option.");
        const timeout = step.timeout;
        if (timeout !== undefined && (typeof timeout !== "number" || !Number.isFinite(timeout)
            || timeout <= 0 || timeout > 60)) return fail("timeout must be greater than 0 and at most 60 seconds.");
        const timed: Timed = timeout === undefined ? {} : { timeout };
        if (action === "back") {
            if (step.back !== true) return fail("back must be true.");
            if (step.ifPresent !== undefined && typeof step.ifPresent !== "boolean") return fail("ifPresent must be a boolean.");
            return { back: true, ...timed, ...(step.ifPresent === undefined ? {} : { ifPresent: step.ifPresent }) };
        }
        if (action === "fold") {
            if (typeof step.fold !== "boolean") return fail("fold must be a boolean.");
            return { fold: step.fold, ...timed };
        }
        const label = step[action];
        if (typeof label !== "string" || !label.length) return fail(`${action} needs nonempty text.`);
        if (action === "tap") return { tap: label, ...timed };
        if (action === "type") return { type: label, ...timed };
        if (action === "wait") {
            if (step.absent !== undefined && typeof step.absent !== "boolean") return fail("absent must be a boolean.");
            return { wait: label, ...timed, ...(step.absent === undefined ? {} : { absent: step.absent }) };
        }
        if (action === "action") {
            if (typeof step.on !== "string" || !step.on.length) return fail("action needs a nonempty on target.");
            return { action: label, on: step.on, ...timed };
        }
        const display = step.display ?? 1;
        if ((typeof display !== "number" && typeof display !== "string") || !/^[1-9][0-9]*$/.test(String(display))) {
            return fail("display must be a positive native display ID.");
        }
        return { screenshot: label, display: String(display), ...timed };
    });
}

export function parseMobileDriveStatus(value: unknown): Status {
    if (!record(value) || !["running", "ready", "completed", "failed"].includes(String(value.state))
        || typeof value.step !== "number" || !Number.isInteger(value.step) || value.step < 0
        || !Array.isArray(value.labels) || !value.labels.every(item => typeof item === "string")
        || !Array.isArray(value.viewport) || !value.viewport.every(item => typeof item === "number")
        || (value.error !== undefined && typeof value.error !== "string")
        || (value.traitsError !== undefined && typeof value.traitsError !== "string")
        || value.traits !== undefined && value.traitsError !== undefined) {
        throw new Error("The app published an invalid drive status.");
    }
    let traits: MobileDriveTraits | undefined;
    if (value.traits !== undefined) {
        if (!record(value.traits) || typeof value.traits.contentSizeCategory !== "string"
            || !value.traits.contentSizeCategory.length || typeof value.traits.interfaceStyle !== "string"
            || !value.traits.interfaceStyle.length) throw new Error("The app published invalid effective content traits.");
        traits = { contentSizeCategory: value.traits.contentSizeCategory, interfaceStyle: value.traits.interfaceStyle };
    }
    return { state: value.state as Status["state"], step: value.step,
        labels: value.labels, viewport: value.viewport, ...(value.error === undefined ? {} : { error: value.error }),
        ...(traits === undefined ? {} : { traits }),
        ...(value.traitsError === undefined ? {} : { traitsError: value.traitsError }) };
}

async function atomicJSON(path: string, value: unknown) {
    const pending = `${path}.pending`;
    await writeFile(pending, JSON.stringify(value));
    await rename(pending, path);
}

export type MobileDrive = { steps: MobileDriveStep[]; directory: string; script: string; output: string };

export async function prepareMobileDrive(path: string, data: string, output: string): Promise<MobileDrive> {
    const steps = parseMobileDrive(JSON.parse(await readFile(resolve(path), "utf8")));
    const directory = join(data, "Documents", "Automation", crypto.randomUUID());
    await mkdir(directory, { recursive: true });
    await mkdir(output, { recursive: true });
    const script = join(directory, "steps.json");
    await atomicJSON(script, steps);
    return { steps, directory, script, output };
}

export type DriveHost = {
    // Abort must terminate and reap the operation's child before its promise settles.
    capture(path: string, display: string, signal: AbortSignal): Promise<void>;
    fold(closed: boolean, signal: AbortSignal): Promise<void>;
};

type DriveProcess = {
    exited: Promise<number>;
    stdout: ReadableStream<Uint8Array>;
    stderr: ReadableStream<Uint8Array>;
    kill(signal: "SIGKILL"): void;
};

export async function runMobileDriveCommand(args: string[], env: NodeJS.ProcessEnv, signal: AbortSignal,
    spawn: (args: string[], signal: AbortSignal) => DriveProcess = (args, signal) => Bun.spawn(args, {
        cwd: root, env, signal, killSignal: "SIGKILL", stdin: "ignore", stdout: "pipe", stderr: "pipe",
    })) {
    signal.throwIfAborted();
    const child = spawn(args, signal);
    try {
        const [exitCode, stdout, stderr] = await Promise.all([
            child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
        ]);
        signal.throwIfAborted();
        return { exitCode, stdout, stderr };
    } catch (error) {
        child.kill("SIGKILL");
        throw error;
    } finally { await child.exited; }
}

export async function runMobileSimulatorCommand(args: string[], env: NodeJS.ProcessEnv, signal: AbortSignal) {
    const tool = await runMobileDriveCommand(["xcrun", "--find", "simctl"], env, signal);
    if (tool.exitCode || !tool.stdout.trim()) throw new Error(`Could not locate simctl: ${tool.stderr.trim()}`);
    return runMobileDriveCommand([tool.stdout.trim(), ...args], env, signal);
}

export class MobileDriveSession {
    readonly screenshots: string[] = [];
    completed = false;
    private acknowledged = new Set<number>();
    private hostError: string | undefined;

    constructor(private drive: MobileDrive, private host: DriveHost,
        private expectedTraits: Partial<MobileDriveTraits> = {}) {}

    private requireTraits(status: Status) {
        if (!Object.values(this.expectedTraits).some(value => value !== undefined)) return;
        if (status.traitsError) throw driveFailure(status, `Effective app traits are unavailable: ${status.traitsError}`);
        if (!status.traits || status.viewport.length !== 2 || status.viewport.some(value => !Number.isFinite(value) || value <= 0)) {
            throw driveFailure(status, "The app did not report effective content traits for its measured viewport.");
        }
        for (const key of ["contentSizeCategory", "interfaceStyle"] as const) {
            const expected = this.expectedTraits[key];
            if (expected !== undefined && status.traits[key] !== expected) {
                throw driveFailure(status, `App ${key} is ${JSON.stringify(status.traits[key])}, expected ${JSON.stringify(expected)}. `
                    + (key === "interfaceStyle" ? "A saved app override may differ from the requested simulator appearance."
                        : "Check whether the app applies a content-size override."));
            }
        }
    }

    async accept(status: Status, signal?: AbortSignal, deadline?: AbortSignal): Promise<{ step: number; error?: string } | undefined> {
        const step = this.drive.steps[status.step];
        if (!step) throw driveFailure(status, "The app reported an unknown step.");
        if (status.state === "failed") throw driveFailure(status, status.error ?? "The app failed.");
        const required = this.drive.steps.slice(0, status.step).findIndex((step, index) =>
            ("screenshot" in step || "fold" in step) && !this.acknowledged.has(index));
        if (required !== -1) throw driveFailure(status, `The app skipped host acknowledgement for step ${required + 1}.`);
        if (status.state === "completed") {
            if (status.step !== this.drive.steps.length - 1
                || (("screenshot" in step || "fold" in step) && !this.acknowledged.has(status.step))) {
                throw driveFailure(status, "The app completed before every scripted action finished.");
            }
            if (this.hostError !== undefined) throw driveFailure(status, this.hostError);
            this.requireTraits(status);
            this.completed = true;
            return;
        }
        if (status.state !== "ready" || this.acknowledged.has(status.step)) return;
        this.requireTraits(status);
        const operation = AbortSignal.any([
            ...(signal ? [signal] : []), ...(deadline ? [deadline] : []),
            AbortSignal.timeout((step.timeout ?? 12) * 1_000),
        ]);
        let error: string | undefined;
        try {
            operation.throwIfAborted();
            if ("screenshot" in step) {
                const name = step.screenshot.endsWith(".png") ? step.screenshot : `${step.screenshot}.png`;
                const path = isAbsolute(name) ? name : join(this.drive.output, name);
                await this.host.capture(path, step.display, operation);
                operation.throwIfAborted();
                this.screenshots.push(path);
                console.log(`Captured ${basename(path)}, display ${step.display}.`);
            } else if ("fold" in step) {
                await this.host.fold(step.fold, operation);
                operation.throwIfAborted();
            } else {
                throw new Error("The app requested a host action for an app-only step.");
            }
        } catch (failure) { error = failure instanceof Error ? failure.message : String(failure); }
        this.acknowledged.add(status.step);
        this.hostError ??= error;
        return { step: status.step, ...(error === undefined ? {} : { error }) };
    }
}

export async function runMobileDrive(drive: MobileDrive, host: DriveHost, signal?: AbortSignal,
    expectedTraits: Partial<MobileDriveTraits> = {}) {
    let latest: Status | undefined;
    let deadline = Date.now() + 60_000;
    const session = new MobileDriveSession(drive, host, expectedTraits);
    while (Date.now() < deadline) {
        if (signal?.aborted) {
            throw latest ? driveFailure(latest, "Drive interrupted.") : new Error("Drive interrupted before app startup.");
        }
        let value: unknown;
        try { value = JSON.parse(await readFile(join(drive.directory, "status.json"), "utf8")); }
        catch (error) {
            if (!isMissing(error)) throw error;
            await Bun.sleep(100);
            continue;
        }
        const status = parseMobileDriveStatus(value);
        if (!latest || latest.step !== status.step || latest.state !== status.state) {
            const step = drive.steps[status.step];
            if (!step) throw new Error(`The app reported unknown step ${status.step + 1}.`);
            deadline = Date.now() + ((step.timeout ?? 12) + 5) * 1_000;
            console.log(`Drive step ${status.step + 1}/${drive.steps.length}: ${status.state}, scene ${status.viewport.join("×")}`);
        }
        latest = status;
        const acknowledgement = await session.accept(status, signal,
            AbortSignal.timeout(Math.max(0, deadline - Date.now())));
        if (session.completed) {
            if (Object.values(expectedTraits).some(value => value !== undefined)) {
                console.log(`Verified effective app traits: ${JSON.stringify(status.traits)}`);
            }
            console.log(`Drive complete. Screenshots: ${drive.output}`);
            return session.screenshots;
        }
        if (acknowledgement) await atomicJSON(join(drive.directory, "ack.json"), acknowledgement);
        await Bun.sleep(100);
    }
    throw latest ? driveFailure(latest, "Host timed out waiting for the app.")
        : new Error("Drive startup timed out. The app never published accessibility labels.");
}

function driveFailure(status: Status, reason: string) {
    return new Error(`Drive step ${status.step + 1} failed: ${reason}\nVisible accessibility labels:\n`
        + (status.labels.length ? status.labels.map(label => `  ${label}`).join("\n") : "  (none)"));
}

export function simulatorDriveHost(udid: string, env: NodeJS.ProcessEnv): DriveHost {
    return {
        async capture(path, display, signal) {
            await mkdir(resolve(path, ".."), { recursive: true });
            const result = await runMobileSimulatorCommand(["io", udid, "screenshot", `--display=${display}`, path], env, signal);
            if (result.exitCode) throw new Error(`Simulator screenshot failed: ${result.stderr.trim()}`);
        },
        async fold(_closed, signal) {
            const helpResult = await runMobileSimulatorCommand(["io", udid, "screenConfig", "--help"], env, signal);
            const help = (helpResult.stdout + helpResult.stderr).trim();
            throw new Error("Automated Duo folding is unavailable: screenConfig display power did not resize the app scene "
                + "and is not a native posture control. No fold continuity proof was produced. "
                + "Use Device Hub's native posture control for a separately observed check.\n"
                + `Native display-control help:\n${help}`);
        },
    };
}
