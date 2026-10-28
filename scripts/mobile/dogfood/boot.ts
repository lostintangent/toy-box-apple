import { command, text } from "../../shared/lib/lib.ts";
import { mobileEnvironment } from "../bundle/index.ts";

type DeviceType = { identifier: string; productFamily: string };
type Runtime = { identifier: string; version: string; isAvailable: boolean; supportedDeviceTypes: DeviceType[] };
type Simulator = { udid: string; name: string; state: string; isAvailable: boolean; deviceTypeIdentifier: string };

export async function prepareMobileSimulator(duo: boolean, ifAvailable = false) {
    const { runtimes }: { runtimes: Runtime[] } = JSON.parse(
        await text(["xcrun", "simctl", "list", "runtimes", "-j"], { env: mobileEnvironment }));
    const supported = runtimes.filter(runtime => runtime.isAvailable && runtime.identifier.includes(".iOS-")
        && Number(runtime.version.split(".")[0]) >= 27)
        .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }));
    if (!supported.length && ifAvailable) {
        console.log("Skipping iOS tests: this runner has no installed iOS 27+ Simulator runtime.");
        return undefined;
    }
    const { devices }: { devices: Record<string, Simulator[]> } = JSON.parse(
        await text(["xcrun", "simctl", "list", "devices", "-j"], { env: mobileEnvironment }));
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
    const bootedHere = simulator.state !== "Booted";
    if (bootedHere) await command(["xcrun", "simctl", "boot", simulator.udid], { env: mobileEnvironment });
    await command(["xcrun", "simctl", "bootstatus", simulator.udid, "-b"], { env: mobileEnvironment, quiet: true });
    return { udid: simulator.udid, bootedHere };
}
