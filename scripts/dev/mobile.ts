import { copyFile, lstat, mkdir, readlink, symlink, unlink } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { command, machineLock, main, plist, root, scratchPath, text } from "../lib.ts";
import { prepareMobileDrive, runMobileDrive, simulatorDriveHost } from "./mobile-drive.ts";

export const mobileEnvironment = {
    ...process.env,
    DEVELOPER_DIR: process.env.DEVELOPER_DIR || "/Applications/Xcode.app/Contents/Developer",
    TOY_BOX_MOBILE: "1",
};
export const mobileBundleID = "dev.toybox.mobile";

export async function linkMobileWorkspace(sourceRoot: string, workspace: string) {
    await mkdir(workspace, { recursive: true });
    for (const name of ["Package.swift", "Sources", "Tests"]) {
        const target = join(sourceRoot, name);
        const link = join(workspace, name);
        try {
            await symlink(target, link);
        } catch (error) {
            if (!(error instanceof Error) || !("code" in error) || error.code !== "EEXIST") throw error;
            if (!(await lstat(link)).isSymbolicLink()) {
                throw new Error(`Refusing to replace ${link}: the mobile workspace entry is not a symlink.`);
            }
            if (await readlink(link) !== target) {
                await unlink(link);
                await symlink(target, link);
            }
        }
    }
}

export async function buildMobile(device = false, tests = false) {
    const platform = device ? "iphoneos" : "iphonesimulator";
    const sdk = await text(["xcrun", "--sdk", platform, "--show-sdk-path"], { env: mobileEnvironment });
    const version = await text(["xcrun", "--sdk", platform, "--show-sdk-version"], { env: mobileEnvironment });
    if (Number(version.split(".")[0]) < 27) throw new Error("Toy Box Mobile requires iOS SDK 27 or later.");
    const scratch = join(scratchPath(), device ? "mobile-device" : "mobile-simulator");
    const workspace = join(scratch, "package");
    await linkMobileWorkspace(root, workspace);
    const args = ["xcrun", "swift", "build", "--package-path", workspace, "--scratch-path", scratch,
        "--sdk", sdk, "--triple", `arm64-apple-ios27.0${device ? "" : "-simulator"}`, "--jobs", "4"];
    await command([...args, ...(tests ? ["--build-tests"] : ["--product", "ToyBoxMobile"])],
        { env: mobileEnvironment });
    const bin = await text([...args, "--show-bin-path"], { env: mobileEnvironment });
    return { bin, scratch, version };
}

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

export async function bundleMobile(device = false) {
    const { bin, scratch, version } = await buildMobile(device);
    const app = join(scratch, "Toy Box.app");
    await mkdir(app, { recursive: true });
    await copyFile(join(bin, "ToyBoxMobile"), join(app, "ToyBoxMobile"));
    await copyFile(join(root, "Resources/Mobile/Info.plist"), join(app, "Info.plist"));
    await plist(join(app, "Info.plist"), [
        "Add :CFBundleSupportedPlatforms array",
        `Add :CFBundleSupportedPlatforms:0 string ${device ? "iPhoneOS" : "iPhoneSimulator"}`,
        `Add :DTSDKName string ${device ? "iphoneos" : "iphonesimulator"}${version}`,
    ]);
    if (!device) await command(["codesign", "--force", "--sign", "-", app]);
    return app;
}

if (import.meta.main) await main(async () => {
    const { values } = parseArgs({ args: process.argv.slice(2), options: {
        "build-only": { type: "boolean" }, device: { type: "boolean" }, shutdown: { type: "boolean" },
        screenshot: { type: "string" }, hold: { type: "boolean" }, display: { type: "string" },
        displays: { type: "boolean" }, server: { type: "string" },
        drive: { type: "string" },
    } });
    if (values.drive && (values.hold || values.screenshot || values.displays || values.shutdown)) {
        throw new Error("--drive owns its captures and simulator lifetime; do not combine it with --hold, --screenshot, --displays or --shutdown.");
    }
    if (values.display && !values.screenshot) throw new Error("--display requires --screenshot.");
    if (values.device || values["build-only"]) {
        if (values.shutdown || values.screenshot || values.hold || values.displays || values.server || values.drive) {
            throw new Error("Build-only commands cannot use a simulator or set launch arguments.");
        }
        console.log(await bundleMobile(values.device));
        return;
    }
    const unlock = await machineLock("mobile-simulator");
    let drivenSimulator: string | undefined;
    const interruption = new AbortController();
    const interrupt = () => interruption.abort();
    if (values.drive) {
        process.once("SIGINT", interrupt);
        process.once("SIGTERM", interrupt);
    }
    try {
        const simulator = await prepareMobileSimulator(true);
        if (!simulator) throw new Error("No iPhone simulator is available.");
        if (values.drive) drivenSimulator = simulator.udid;
        if (values.displays) {
            const ports = await text(["xcrun", "simctl", "io", simulator.udid, "enumerate"],
                { env: mobileEnvironment });
            const displays = ports.split(/(?=^Port:\n)/m)
                .find(port => /^\s+Class: DisplayAdapter$/m.test(port));
            if (!displays) throw new Error("The simulator did not report its native display adapter.");
            console.log(displays.trim());
            if (!values.hold) return;
        }
        if (values.shutdown) {
            await command(["xcrun", "simctl", "shutdown", simulator.udid], { env: mobileEnvironment });
            return;
        }
        const capture = async () => {
            if (!values.screenshot) return;
            await command(["xcrun", "simctl", "io", simulator.udid, "screenshot",
                ...(values.display ? [`--display=${values.display}`] : []), values.screenshot],
                { env: mobileEnvironment });
        };
        if (values.screenshot && !values.hold) {
            await capture();
            return;
        }
        const app = await bundleMobile();
        console.log(app);
        await command(["xcrun", "simctl", "install", simulator.udid, app], { env: mobileEnvironment });
        const server = values.server ?? process.env.TOY_BOX_SERVER_URL ?? "http://127.0.0.1:3210";
        const drive = values.drive ? await prepareMobileDrive(values.drive,
            await text(["xcrun", "simctl", "get_app_container", simulator.udid, mobileBundleID, "data"],
                { env: mobileEnvironment }), join(scratchPath(), "mobile-drive", crypto.randomUUID())) : undefined;
        await command(["xcrun", "simctl", "launch", "--terminate-running-process", simulator.udid, mobileBundleID,
            "--server", server],
            { env: { ...mobileEnvironment, ...(drive ? { SIMCTL_CHILD_TOY_BOX_AUTOMATION_SCRIPT: drive.script } : {}) } });
        console.log(`Running on ${simulator.udid}, server ${server}`);
        console.log(`App data: ${await text(["xcrun", "simctl", "get_app_container", simulator.udid, mobileBundleID, "data"],
            { env: mobileEnvironment })}`);
        if (drive) {
            await runMobileDrive(drive, simulatorDriveHost(simulator.udid, mobileEnvironment), interruption.signal);
            return;
        }
        if (values.hold) {
            console.log("Simulator lock held for UI checks for at most 15 minutes. Ctrl-C releases it and shuts down.");
            if (values.screenshot) console.log(`The current pose will be captured to ${values.screenshot} before shutdown.`);
            await new Promise<void>(resolve => {
                const finish = () => {
                    clearTimeout(timer);
                    process.removeListener("SIGINT", finish);
                    process.removeListener("SIGTERM", finish);
                    resolve();
                };
                const timer = setTimeout(() => {
                    console.log("The 15-minute simulator lease expired.");
                    finish();
                }, 15 * 60 * 1000);
                process.once("SIGINT", finish);
                process.once("SIGTERM", finish);
            });
            try { await capture(); }
            finally {
                await command(["xcrun", "simctl", "shutdown", simulator.udid], { env: mobileEnvironment });
            }
        }
    } finally {
        process.removeListener("SIGINT", interrupt);
        process.removeListener("SIGTERM", interrupt);
        try {
            if (drivenSimulator) {
                await command(["xcrun", "simctl", "shutdown", drivenSimulator], { env: mobileEnvironment });
            }
        } finally { unlock(); }
    }
});
