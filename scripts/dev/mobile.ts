import { copyFile, lstat, mkdir, readlink, symlink, unlink } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { command, machineLock, main, plist, root, scratchPath, text } from "../lib.ts";
import { prepareMobileDrive, runMobileDrive, runMobileSimulatorCommand, simulatorDriveHost } from "./mobile-drive.ts";

export const mobileEnvironment = {
    ...process.env,
    DEVELOPER_DIR: process.env.DEVELOPER_DIR || "/Applications/Xcode.app/Contents/Developer",
    TOY_BOX_MOBILE: "1",
};
export const mobileBundleID = "dev.toybox.mobile";

const contentSizeCategories = {
    extraSmall: "UICTContentSizeCategoryXS", small: "UICTContentSizeCategoryS",
    medium: "UICTContentSizeCategoryM", large: "UICTContentSizeCategoryL",
    extraLarge: "UICTContentSizeCategoryXL", extraExtraLarge: "UICTContentSizeCategoryXXL",
    extraExtraExtraLarge: "UICTContentSizeCategoryXXXL",
    accessibilityMedium: "UICTContentSizeCategoryAccessibilityM",
    accessibilityLarge: "UICTContentSizeCategoryAccessibilityL",
    accessibilityExtraLarge: "UICTContentSizeCategoryAccessibilityXL",
    accessibilityExtraExtraLarge: "UICTContentSizeCategoryAccessibilityXXL",
    accessibilityExtraExtraExtraLarge: "UICTContentSizeCategoryAccessibilityXXXL",
};
type Appearance = "light" | "dark";
type SimulatorCommand = (args: string[], signal: AbortSignal) =>
    Promise<{ exitCode: number; stdout: string; stderr: string }>;

export function mobileLaunchOptions(contentSize?: string, appearance?: string): {
    contentSize: string | undefined; appearance: Appearance | undefined; arguments: string[];
} {
    const category = Object.entries(contentSizeCategories).find(([name]) => name === contentSize)?.[1];
    if (contentSize !== undefined && !category) {
        throw new Error(`--content-size must be one of: ${Object.keys(contentSizeCategories).join(", ")}.`);
    }
    if (appearance !== undefined && appearance !== "light" && appearance !== "dark") {
        throw new Error("--appearance must be light or dark.");
    }
    return { contentSize: category, appearance,
        arguments: category ? ["-UIPreferredContentSizeCategoryName", category] : [] };
}

export async function withMobileAppearance<T>(simulator: string, appearance: Appearance | undefined,
    run: SimulatorCommand, signal: AbortSignal, body: () => Promise<T>): Promise<T> {
    if (!appearance) return body();
    const invoke = async (args: string[], signal: AbortSignal) => {
        const result = await run(["ui", simulator, "appearance", ...args], signal);
        if (result.exitCode) throw new Error(`Simulator appearance command failed: ${result.stderr.trim()}`);
        return result.stdout.trim();
    };
    const operation = AbortSignal.any([signal, AbortSignal.timeout(15_000)]);
    const previous = await invoke([], operation);
    if (previous !== "light" && previous !== "dark") {
        throw new Error(`Cannot preserve the simulator's unknown appearance: ${JSON.stringify(previous)}.`);
    }
    let failed = false;
    let failure: unknown;
    try {
        await invoke([appearance], operation);
        if (await invoke([], operation) !== appearance) throw new Error("The requested simulator appearance was not applied.");
        return await body();
    } catch (error) {
        failed = true;
        failure = error;
        throw error;
    } finally {
        try {
            const cleanup = AbortSignal.timeout(15_000);
            await invoke([previous], cleanup);
            if (await invoke([], cleanup) !== previous) throw new Error("The restored appearance did not match.");
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            if (failed) {
                throw new AggregateError([failure, error],
                    `Native run failed (${failure instanceof Error ? failure.message : String(failure)}). `
                    + `Simulator appearance restoration failed (${message}).`);
            }
            throw new Error(`Simulator appearance restoration failed: ${message}`, { cause: error });
        }
    }
}

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
    if (!/^\d+(?:\.\d+)*$/.test(version) || Number(version.split(".")[0]) < 27) {
        throw new Error("Toy Box Mobile requires iOS SDK 27 or later.");
    }
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

export function checkMobileBuildVersion(output: string, device: boolean, minimumOS: string, sdkVersion: string) {
    if (output.match(/^\s*cmd LC_BUILD_VERSION\s*$/gm)?.length !== 1) {
        throw new Error("Toy Box Mobile must have exactly one LC_BUILD_VERSION command.");
    }
    const normalize = (value: string) => /^\d+(?:\.\d+)*$/.test(value)
        ? value.replace(/(?:\.0)+$/, "") : undefined;
    for (const [field, expected] of Object.entries({
        platform: device ? "IOS" : "IOSSIMULATOR", minos: minimumOS, sdk: sdkVersion,
    })) {
        const values = [...output.matchAll(new RegExp(`^\\s*${field}\\s+(\\S+)\\s*$`, "gm"))]
            .map(match => match[1]);
        const actual = values.length === 1 ? values[0] : undefined;
        if (actual === undefined || (field === "platform" ? actual !== expected
            : normalize(expected) === undefined || normalize(actual) !== normalize(expected))) {
            throw new Error(`Toy Box Mobile executable ${field}: expected ${expected}, found ${values.join(", ") || "no value"}.`);
        }
    }
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
    const binary = join(app, "ToyBoxMobile");
    const minimumOS = await plist(join(app, "Info.plist"), ["Print :MinimumOSVersion"]);
    await command(["xcrun", "vtool", "-set-build-version", device ? "ios" : "iossim", minimumOS, version,
        "-replace", "-output", binary, binary], { env: mobileEnvironment });
    checkMobileBuildVersion(await text(["xcrun", "vtool", "-show-build", binary], { env: mobileEnvironment }),
        device, minimumOS, version);
    if (!device) await command(["codesign", "--force", "--sign", "-", app]);
    return app;
}

if (import.meta.main) await main(async () => {
    const { values } = parseArgs({ args: process.argv.slice(2), options: {
        "build-only": { type: "boolean" }, device: { type: "boolean" }, "device-id": { type: "string" },
        shutdown: { type: "boolean" },
        screenshot: { type: "string" }, hold: { type: "boolean" }, display: { type: "string" },
        displays: { type: "boolean" }, server: { type: "string" },
        drive: { type: "string" }, "content-size": { type: "string" }, appearance: { type: "string" },
    } });
    const launch = mobileLaunchOptions(values["content-size"], values.appearance);
    if (values["device-id"] && !values.device) throw new Error("--device-id requires --device.");
    if (values["device-id"] && values["build-only"]) throw new Error("--device-id cannot be used with --build-only.");
    if (values.drive && (values.hold || values.screenshot || values.displays || values.shutdown)) {
        throw new Error("--drive owns its captures and simulator lifetime; do not combine it with --hold, --screenshot, --displays or --shutdown.");
    }
    if (values.display && !values.screenshot) throw new Error("--display requires --screenshot.");
    if (values["build-only"] || values.device) {
        if (values.shutdown || values.screenshot || values.hold || values.displays || values.drive
            || values["content-size"] || values.appearance || values["build-only"] && values.server) {
            throw new Error("Build-only/device commands cannot use simulator options; only device launches accept --server.");
        }
        if (values.device && !values["build-only"]) {
            const { runMobileDevice } = await import("./mobile-device.ts");
            await runMobileDevice(values["device-id"], values.server ?? process.env.TOY_BOX_SERVER_URL);
        } else {
            console.log(await bundleMobile(values.device));
        }
        return;
    }
    if (values.appearance && !(values.hold || values.drive)) {
        throw new Error("--appearance requires --hold or --drive so its prior simulator setting can be restored.");
    }
    if ((values["content-size"] || values.appearance)
        && (values.shutdown || (values.screenshot || values.displays) && !values.hold)) {
        throw new Error("Content size and appearance require launching the app, not a capture/list/shutdown-only command.");
    }
    const unlock = await machineLock("mobile-simulator");
    let leasedSimulator: string | undefined;
    let runFailed = false;
    let runFailure: unknown;
    const interruption = new AbortController();
    const interrupt = () => interruption.abort();
    if (values.drive || values.hold) {
        process.on("SIGINT", interrupt);
        process.on("SIGTERM", interrupt);
    }
    try {
        const simulator = await prepareMobileSimulator(true);
        if (!simulator) throw new Error("No iPhone simulator is available.");
        if ((values.drive || values.hold) && !values.shutdown) leasedSimulator = simulator.udid;
        interruption.signal.throwIfAborted();
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
            const result = await runMobileSimulatorCommand(["io", simulator.udid, "screenshot",
                ...(values.display ? [`--display=${values.display}`] : []), values.screenshot],
                mobileEnvironment, AbortSignal.timeout(15_000));
            if (result.exitCode) throw new Error(`Simulator capture failed: ${result.stderr.trim()}`);
        };
        if (values.screenshot && !values.hold) {
            await capture();
            return;
        }
        const app = await bundleMobile();
        interruption.signal.throwIfAborted();
        console.log(app);
        await command(["xcrun", "simctl", "install", simulator.udid, app], { env: mobileEnvironment });
        interruption.signal.throwIfAborted();
        const server = values.server ?? process.env.TOY_BOX_SERVER_URL ?? "http://127.0.0.1:3210";
        const data = await text(["xcrun", "simctl", "get_app_container", simulator.udid, mobileBundleID, "data"],
            { env: mobileEnvironment });
        const drive = values.drive ? await prepareMobileDrive(values.drive, data,
            join(scratchPath(), "mobile-drive", crypto.randomUUID())) : undefined;
        interruption.signal.throwIfAborted();
        await withMobileAppearance(simulator.udid, launch.appearance,
            (args, signal) => runMobileSimulatorCommand(args, mobileEnvironment, signal), interruption.signal, async () => {
            const result = await runMobileSimulatorCommand([
                "launch", "--terminate-running-process", simulator.udid, mobileBundleID,
                "--server", server, ...launch.arguments,
            ], { ...mobileEnvironment, ...(drive ? { SIMCTL_CHILD_TOY_BOX_AUTOMATION_SCRIPT: drive.script } : {}) },
            AbortSignal.any([interruption.signal, AbortSignal.timeout(30_000)]));
            if (result.exitCode) throw new Error(`Mobile launch failed: ${result.stderr.trim()}`);
            console.log(result.stdout.trim());
            console.log(`Running on ${simulator.udid}, server ${server}`);
            console.log(`App data: ${data}`);
            if (drive) {
                await runMobileDrive(drive, simulatorDriveHost(simulator.udid, mobileEnvironment), interruption.signal, {
                    ...(launch.contentSize ? { contentSizeCategory: launch.contentSize } : {}),
                    ...(launch.appearance ? { interfaceStyle: launch.appearance } : {}),
                });
                return;
            }
            if (values.hold) {
                console.log("Simulator lock held for UI checks for at most 15 minutes. Ctrl-C releases it and shuts down.");
                if (values.screenshot) console.log(`The current pose will be captured to ${values.screenshot} before shutdown.`);
                await new Promise<void>(resolve => {
                    const finish = () => {
                        clearTimeout(timer);
                        interruption.signal.removeEventListener("abort", finish);
                        resolve();
                    };
                    const timer = setTimeout(() => {
                        console.log("The 15-minute simulator lease expired.");
                        finish();
                    }, 15 * 60 * 1000);
                    interruption.signal.addEventListener("abort", finish, { once: true });
                    if (interruption.signal.aborted) finish();
                });
                await capture();
            }
        });
    } catch (error) {
        runFailed = true;
        runFailure = error;
        throw error;
    } finally {
        try {
            if (leasedSimulator) {
                const result = await runMobileSimulatorCommand(["shutdown", leasedSimulator], mobileEnvironment,
                    AbortSignal.timeout(15_000));
                if (result.exitCode) throw new Error(`Simulator shutdown failed: ${result.stderr.trim()}`);
            }
        } catch (error) {
            if (runFailed) {
                throw new AggregateError([runFailure, error],
                    `Native run failed (${runFailure instanceof Error ? runFailure.message : String(runFailure)}). `
                    + `Simulator shutdown failed (${error instanceof Error ? error.message : String(error)}).`);
            }
            throw error;
        } finally {
            process.removeListener("SIGINT", interrupt);
            process.removeListener("SIGTERM", interrupt);
            unlock();
        }
    }
});
