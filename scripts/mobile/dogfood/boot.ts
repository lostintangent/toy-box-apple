import { existsSync, readdirSync, statSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { command, scratchPath, text } from "../../shared/lib/index.ts";
import { mobileEnvironment, mobileMinimumOS, reaches } from "../bundle/index.ts";

type DeviceType = { identifier: string; productFamily: string };
type Runtime = { identifier: string; version: string; isAvailable: boolean; supportedDeviceTypes: DeviceType[] };
type Simulator = {
    udid: string; name: string; state: string; isAvailable: boolean; availabilityError?: string;
    deviceTypeIdentifier: string;
};
type RuntimeImage = {
    identifier: string; runtimeIdentifier: string; build: string; state: string; deletable: boolean;
    parentIdentifier?: string; runtimeBundlePath?: string;
};

/** The simulator with `udid` and the identifier of the runtime it runs. */
async function device(udid: string) {
    for (const [runtime, devices] of Object.entries(await simulators())) {
        const found = devices.find(device => device.udid === udid);
        if (found) return { ...found, runtime };
    }
}

async function state(udid: string) { return (await device(udid))?.state; }

async function simulators() {
    const { devices }: { devices: Record<string, Simulator[]> } = JSON.parse(
        await text(["xcrun", "simctl", "list", "devices", "-j"], { env: mobileEnvironment }));
    return devices;
}

export async function prepareMobileSimulator(duo: boolean, ifAvailable = false) {
    const udid = await chooseMobileSimulator(duo, ifAvailable);
    return udid && await bootMobileSimulator(udid);
}

/** The UDID of the simulator to use, created if it's missing, without booting it. Undefined only with
 * `ifAvailable` on a Mac without a runtime for the app's minimum iOS. */
export async function chooseMobileSimulator(duo: boolean, ifAvailable = false) {
    const { runtimes }: { runtimes: Runtime[] } = JSON.parse(
        await text(["xcrun", "simctl", "list", "runtimes", "-j"], { env: mobileEnvironment }));
    const minimumOS = await mobileMinimumOS();
    const supported = runtimes.filter(runtime => runtime.isAvailable && runtime.identifier.includes(".iOS-")
        && reaches(runtime.version, minimumOS))
        .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }));
    if (!supported.length && ifAvailable) {
        console.log(`Skipping iOS tests: this runner has no installed iOS ${minimumOS}+ Simulator runtime.`);
        return undefined;
    }
    const devices = await simulators();
    const requested = process.env.MOBILE_SIMULATOR;
    let simulator: Simulator | undefined;
    if (requested) {
        simulator = supported.flatMap(runtime => devices[runtime.identifier] ?? [])
            .find(device => device.udid === requested && device.isAvailable);
        if (!simulator) throw new Error(`MOBILE_SIMULATOR must name an available iOS ${minimumOS}+ simulator UDID.`);
    } else {
        const duoType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo";
        const runtime = supported.find(item => item.supportedDeviceTypes.some(type => type.identifier === duoType))
            ?? (duo ? undefined : supported[0]);
        const type = runtime?.supportedDeviceTypes.find(item => item.identifier === duoType)
            ?? runtime?.supportedDeviceTypes.find(item => item.productFamily === "iPhone");
        if (!runtime || !type) {
            throw new Error(duo ? `Install an iOS ${minimumOS}+ runtime supporting iPhone Duo, or set MOBILE_SIMULATOR.`
                : `Install an iOS ${minimumOS}+ Simulator runtime before running mobile tests.`);
        }
        const name = "Toy Box Mobile";
        simulator = devices[runtime.identifier]?.find(device =>
            device.name === name && device.deviceTypeIdentifier === type.identifier && device.isAvailable);
        if (!simulator) {
            const udid = await text(["xcrun", "simctl", "create", name, type.identifier, runtime.identifier],
                { env: mobileEnvironment });
            simulator = { udid, name, state: "Shutdown", isAvailable: true, deviceTypeIdentifier: type.identifier };
        }
    }
    return simulator.udid;
}

/** Boots the simulator unless it's already running, and waits until it's ready. A boot here leaves the launchd
 * jobs in `disabledJobs` off. */
export async function bootMobileSimulator(udid: string, disabledJobs: string[] = []) {
    const bootedHere = await state(udid) !== "Booted";
    const startedAt = performance.now();
    if (bootedHere) {
        await command(["xcrun", "simctl", "boot", udid, ...disabledJobs.map(job => `--disabledJob=${job}`)],
            { env: mobileEnvironment });
    }
    await command(["xcrun", "simctl", "bootstatus", udid, "-b"], { env: mobileEnvironment, quiet: true });
    if (bootedHere) console.log(`The simulator was ready ${seconds(startedAt)} after booting.`);
    return { udid, bootedHere };
}

/** The time since `start`, a `performance.now()`, for a progress line. */
export function seconds(start: number) { return `${((performance.now() - start) / 1000).toFixed(1)}s`; }

/** Shuts the simulator down. One that's already off, which a crash can cause, is noted instead of failing, so
 * the error from the run it cut short is the one that's reported. */
export async function shutDownMobileSimulator(udid: string) {
    if (await state(udid) === "Shutdown") {
        console.error("The simulator had already shut down.");
        return;
    }
    await command(["xcrun", "simctl", "shutdown", udid], { env: mobileEnvironment });
}

/** The Mac's simulator runtime images, or none when simctl can't list them. */
async function runtimeImages(): Promise<RuntimeImage[]> {
    return Object.values(JSON.parse(await text(["xcrun", "simctl", "runtime", "list", "-j"],
        { env: mobileEnvironment, allowFailure: true }) || "{}"));
}

/** Deletes every runtime image except the ones the simulator runs on and the images they patch, for a CI runner,
 * whose runtimes no later step uses. Its image registers some runtimes twice, and CoreSimulator re-adds those
 * every ten minutes, unmounting the volume each replaces while SimLaunchHost still has a library from it loaded.
 * SimLaunchHost then crashes on its next load and takes every booted simulator with it. */
export async function deleteUnusedSimulatorRuntimes(udid: string) {
    const runtime = (await device(udid))?.runtime;
    if (!runtime) throw new Error(`The simulator ${udid} is gone.`);
    const images = await runtimeImages();
    const used = images.filter(image => image.runtimeIdentifier === runtime);
    const kept = new Set(used.flatMap(image => [image.identifier, image.parentIdentifier]));
    const unused = images.filter(image => image.deletable && !kept.has(image.identifier));
    const startedAt = performance.now();
    // Keeps each image's MobileAsset, since simctl fails to delete an image whose asset another image still uses.
    for (const image of unused) {
        await command(["xcrun", "simctl", "runtime", "delete", image.identifier, "--keep-asset"],
            { env: mobileEnvironment, quiet: true });
    }
    const names = unused.map(image => `${image.runtimeIdentifier.split(".").at(-1)} ${image.build}`);
    console.log(`Deleted ${unused.length} runtime images the tests don't use in ${seconds(startedAt)}`
        + (names.length ? `: ${names.join(", ")}.` : "."));
}

/** Whether the simulator is still booted with its runtime, so a suite that failed on it failed on its own. */
export async function mobileSimulatorIsUp(udid: string) {
    const found = await device(udid);
    return found?.state === "Booted" && found.isAvailable;
}

/** CoreSimulator's own log, which it writes only while its `DebugLogging` default is on, as CI turns it on. It's
 * the one record of why CoreSimulator shut a device down, like its runtime's volume unmounting. */
const coreSimulatorLog = join(homedir(), "Library/Logs/CoreSimulator/CoreSimulator.log");

/** The CoreSimulator lines that explain a device going down: a runtime's volume leaving, a shutdown and who asked
 * for it, the device's launchd_sim ending, and errors. */
const shutdownEvidence = new RegExp(["VolumeManager:", "Unloading runtime", "Shutdown requested", "device_shutdown",
    "port died", "launchd_sim termination", "<(?:Error|Fault)>"].join("|"));

/** What CoreSimulator logs routinely: every simctl's idle volume check, volumes it ignores, and a boot's errors. */
const routine = /IdleTrampoline|Appeared|Ignoring|Could not register service/;

/** The host processes that run simulators and mount, update and unmount their runtimes. */
const runtimeServices = `(process IN {"com.apple.CoreSimulator.CoreSimulatorService", "launchd_sim", "simdiskimaged", `
    + `"cryptexd", "diskarbitrationd"} OR (process == "mobileassetd" AND eventMessage CONTAINS "SimulatorRuntime") `
    + `OR (process == "kernel" AND (eventMessage CONTAINS[c] "unmount" `
    + `OR eventMessage CONTAINS "memorystatus: killing"))) AND NOT subsystem == "com.apple.xpc"`;

export type SimulatorLogMark = { time: number; coreSimulator: number };

/** Where the Mac's simulator logs stand now, so a report reads only what came after. */
export function markSimulatorLogs(): SimulatorLogMark {
    return { time: Date.now(), coreSimulator: existsSync(coreSimulatorLog) ? statSync(coreSimulatorLog).size : 0 };
}

/** Prints what the Mac recorded since `since` about a simulator that went down under a run: the device, its
 * runtime's images, crash reports, and CoreSimulator's account of why. The host log of the services that mount
 * runtimes goes to scratch, beside the stalled suites' samples. */
export async function reportMobileSimulatorLoss(udid: string, since: SimulatorLogMark) {
    const found = await device(udid);
    const lines = [!found ? `The simulator ${udid} is gone.` : found.isAvailable ? `${found.name} is ${found.state}.`
        : `${found.name} is ${found.state} and unavailable: ${found.availabilityError}.`];
    for (const image of await runtimeImages()) {
        if (image.runtimeIdentifier !== found?.runtime) continue;
        const mounted = image.runtimeBundlePath && existsSync(image.runtimeBundlePath) ? "mounted" : "unmounted";
        lines.push(`Its runtime image ${image.build} is ${image.state} and ${mounted}.`);
    }

    const reports = join(homedir(), "Library/Logs/DiagnosticReports");
    const crashes = existsSync(reports) ? readdirSync(reports)
        .filter(name => name.endsWith(".ips") && statSync(join(reports, name)).birthtimeMs >= since.time) : [];
    lines.push(crashes.length ? `Crash reports: ${crashes.join(", ")}.` : "No crash reports.");

    if (existsSync(coreSimulatorLog)) {
        const file = Bun.file(coreSimulatorLog);
        const added = await file.slice(file.size < since.coreSimulator ? 0 : since.coreSimulator).text();
        const evidence = added.split("\n")
            .filter(line => shutdownEvidence.test(line) && !routine.test(line));
        lines.push(evidence.length
            ? `CoreSimulator logged:\n${evidence.slice(-40).map(line => `    ${line}`).join("\n")}`
            : "CoreSimulator logged nothing about it.");
    } else lines.push("CoreSimulator kept no log, since its DebugLogging default is off.");

    const path = join(scratchPath(), "mobile-test-watchdog", "host.log");
    await mkdir(dirname(path), { recursive: true });
    const minutes = Math.ceil((Date.now() - since.time) / 60_000);
    const host = await command(["log", "show", "--last", `${minutes}m`, "--info", "--style", "compact",
        "--predicate", runtimeServices], { quiet: true, allowFailure: true });
    await Bun.write(path, host.stdout);
    lines.push(`The host log of the services that mount runtimes is in ${path}.`);

    console.error(`What the Mac recorded since the run started:\n${lines.map(line => `  ${line}`).join("\n")}`);
}
