import { command, text } from "../../shared/lib/index.ts";
import { mobileEnvironment } from "../bundle/index.ts";

type DeviceType = { identifier: string; productFamily: string };
type Runtime = { identifier: string; version: string; isAvailable: boolean; supportedDeviceTypes: DeviceType[] };
type Simulator = { udid: string; name: string; state: string; isAvailable: boolean; deviceTypeIdentifier: string };

async function state(udid: string) {
    return Object.values(await simulators()).flat().find(device => device.udid === udid)?.state;
}

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
 * `ifAvailable` on a Mac without an iOS 27+ runtime. */
export async function chooseMobileSimulator(duo: boolean, ifAvailable = false) {
    const { runtimes }: { runtimes: Runtime[] } = JSON.parse(
        await text(["xcrun", "simctl", "list", "runtimes", "-j"], { env: mobileEnvironment }));
    const supported = runtimes.filter(runtime => runtime.isAvailable && runtime.identifier.includes(".iOS-")
        && Number(runtime.version.split(".")[0]) >= 27)
        .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }));
    if (!supported.length && ifAvailable) {
        console.log("Skipping iOS tests: this runner has no installed iOS 27+ Simulator runtime.");
        return undefined;
    }
    const devices = await simulators();
    const requested = process.env.MOBILE_SIMULATOR;
    let simulator: Simulator | undefined;
    if (requested) {
        simulator = supported.flatMap(runtime => devices[runtime.identifier] ?? [])
            .find(device => device.udid === requested && device.isAvailable);
        if (!simulator) throw new Error("MOBILE_SIMULATOR must name an available iOS 27+ simulator UDID.");
    } else {
        const duoType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo";
        const runtime = supported.find(item => item.supportedDeviceTypes.some(type => type.identifier === duoType))
            ?? (duo ? undefined : supported[0]);
        const type = runtime?.supportedDeviceTypes.find(item => item.identifier === duoType)
            ?? runtime?.supportedDeviceTypes.find(item => item.productFamily === "iPhone");
        if (!runtime || !type) {
            throw new Error(duo ? "Install an iOS 27+ runtime supporting iPhone Duo, or set MOBILE_SIMULATOR."
                : "Install an iOS 27+ Simulator runtime before running mobile tests.");
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

/** Boots the simulator unless it's already running, and waits until it's ready. */
export async function bootMobileSimulator(udid: string) {
    const bootedHere = await state(udid) !== "Booted";
    if (bootedHere) await command(["xcrun", "simctl", "boot", udid], { env: mobileEnvironment });
    await command(["xcrun", "simctl", "bootstatus", udid, "-b"], { env: mobileEnvironment, quiet: true });
    return { udid, bootedHere };
}

/** Shuts the simulator down. One that's already off, which a crash can cause, is noted instead of failing, so
 * the error from the run it cut short is the one that's reported. */
export async function shutDownMobileSimulator(udid: string) {
    if (await state(udid) === "Shutdown") {
        console.error("The simulator had already shut down.");
        return;
    }
    await command(["xcrun", "simctl", "shutdown", udid], { env: mobileEnvironment });
}
