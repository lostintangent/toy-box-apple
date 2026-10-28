import { copyFile, lstat, mkdir, readlink, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { command, plist, root, scratchPath, text } from "../../shared/lib/index.ts";
import { embedMobileAppIcon } from "../../shared/lib/app-icon.ts";

export const mobileEnvironment = {
    ...process.env,
    DEVELOPER_DIR: process.env.DEVELOPER_DIR || "/Applications/Xcode.app/Contents/Developer",
    TOY_BOX_MOBILE: "1",
};
export const mobileBundleID = "dev.toybox.mobile";
export const mobileAppGroup = "group.dev.toybox.mobile";
export const mobileExtensions = [
    { executable: "ToyBoxMobileWidget", suffix: "widget", point: "com.apple.widgetkit-extension", info: "Widget-Info.plist" },
    { executable: "ToyBoxMobileNotification", suffix: "notification", point: "com.apple.usernotifications.service",
        info: "Notification-Info.plist" },
] as const;

export function mobileEntitlements(bundleID: string, distribution = false) {
    if (![mobileBundleID, ...mobileExtensions.map(extension => `${mobileBundleID}.${extension.suffix}`)].includes(bundleID)) {
        throw new Error(`Unknown mobile bundle: ${bundleID}.`);
    }
    return {
        "com.apple.security.application-groups": [mobileAppGroup],
        ...(bundleID === mobileBundleID ? { "aps-environment": distribution ? "production" : "development" } : {}),
        ...(distribution ? { "beta-reports-active": true } : {}),
    };
}

export function mobileSimulatorEntitlements(bundleID: string) {
    return { ...mobileEntitlements(bundleID), "application-identifier": bundleID };
}

export function mobilePushEnvironment(entitlements: Record<string, unknown>) {
    switch (entitlements["aps-environment"]) {
        case "development": return "sandbox";
        case "production": return "production";
        default: throw new Error("The mobile host needs a validated APNs signing environment.");
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

export function mobileBuildConfiguration(device: boolean, tests: boolean, requested = process.env.CONFIGURATION) {
    if (device) return "release";
    if (tests) return "debug";
    const configuration = requested || "debug";
    if (configuration !== "debug" && configuration !== "release") {
        throw new Error("CONFIGURATION must be debug or release for a Simulator app build.");
    }
    return configuration;
}

export async function buildMobile(device = false, tests = false) {
    const configuration = mobileBuildConfiguration(device, tests);
    console.log(`Building iOS ${device ? "device" : "Simulator"} ${tests ? "tests" : "app"} `
        + `(${configuration}${tests ? "" : configuration === "release" ? ", optimized" : ", unoptimized; not for performance review"}).`);
    const platform = device ? "iphoneos" : "iphonesimulator";
    const sdk = await text(["xcrun", "--sdk", platform, "--show-sdk-path"], { env: mobileEnvironment });
    const version = await text(["xcrun", "--sdk", platform, "--show-sdk-version"], { env: mobileEnvironment });
    if (!/^\d+(?:\.\d+)*$/.test(version) || Number(version.split(".")[0]) < 27) {
        throw new Error("Toy Box Mobile requires iOS SDK 27 or later.");
    }
    const scratch = join(scratchPath(), device ? "mobile-testflight" : "mobile-simulator");
    const workspace = join(scratch, "package");
    await linkMobileWorkspace(root, workspace);
    const simulated = join(scratch, "simulated-entitlements");
    const environment = { ...mobileEnvironment, TOY_BOX_SIMULATOR_ENTITLEMENTS: device ? undefined : simulated };
    if (!device) {
        await mkdir(simulated, { recursive: true });
        for (const bundleID of [mobileBundleID, ...mobileExtensions.map(extension => `${mobileBundleID}.${extension.suffix}`)]) {
            const path = join(simulated, `${bundleID}.plist`);
            await writeFile(path, JSON.stringify(mobileSimulatorEntitlements(bundleID)));
            await command(["plutil", "-convert", "xml1", path]);
            await command(["xcrun", "derq", "query", "-f", "xml", "-i", path, "-o", `${path}.der`, "--raw"],
                { env: mobileEnvironment });
        }
    }
    const args = ["xcrun", "swift", "build", "--package-path", workspace, "--scratch-path", scratch,
        "--configuration", configuration,
        "--sdk", sdk, "--triple", `arm64-apple-ios27.0${device ? "" : "-simulator"}`, "--jobs", "4"];
    await command([...args, ...(tests ? ["--build-tests"] : [])],
        { env: environment });
    const bin = await text([...args, "--show-bin-path"], { env: environment });
    return { bin, scratch, version };
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

export function checkMobileExtensionEntryPoint(commands: string, symbols: string) {
    const loads = commands.split(/(?=Load command \d+)/);
    const text = loads.filter(load => /^\s*segname __TEXT$/m.test(load) && /^\s*cmd LC_SEGMENT_64$/m.test(load));
    const main = loads.filter(load => /^\s*cmd LC_MAIN$/m.test(load));
    const address = text.length === 1 ? text[0]?.match(/^\s*vmaddr (0x[\da-f]+)$/mi)?.[1] : undefined;
    const offset = main.length === 1 ? main[0]?.match(/^\s*entryoff (\d+)$/m)?.[1] : undefined;
    const fileOffset = text[0]?.match(/^\s*fileoff (\d+)$/m)?.[1];
    const stubs = symbols.split(/(?=Indirect symbols for )/)
        .find(table => table.startsWith("Indirect symbols for (__TEXT,__stubs)"));
    const bootstrap = [...(stubs ?? "").matchAll(/^\s*(0x[\da-f]+)\s+\d+\s+_NSExtensionMain$/gmi)];
    if (address === undefined || offset === undefined || fileOffset === undefined
        || !bootstrap.some(match => BigInt(match[1]!) === BigInt(address) + BigInt(offset) - BigInt(fileOffset))) {
        throw new Error("Mobile extensions must enter through _NSExtensionMain before their Swift entry point.");
    }
}

export async function bundleMobile(device = false) {
    const { bin, scratch, version } = await buildMobile(device);
    const app = join(scratch, "Toy Box.app");
    await rm(app, { recursive: true, force: true });
    await mkdir(app, { recursive: true });
    await copyFile(join(bin, "ToyBoxMobile"), join(app, "ToyBoxMobile"));
    await copyFile(join(root, "Resources/Mobile/Info.plist"), join(app, "Info.plist"));
    await plist(join(app, "Info.plist"), [
        "Add :CFBundleSupportedPlatforms array",
        `Add :CFBundleSupportedPlatforms:0 string ${device ? "iPhoneOS" : "iPhoneSimulator"}`,
        `Add :DTSDKName string ${device ? "iphoneos" : "iphonesimulator"}${version}`,
        `Set :ToyBoxPushEnvironment ${mobilePushEnvironment(mobileEntitlements(mobileBundleID))}`,
    ]);
    const binary = join(app, "ToyBoxMobile");
    const minimumOS = await plist(join(app, "Info.plist"), ["Print :MinimumOSVersion"]);
    await embedMobileAppIcon(join(root, "Resources"), app, device, minimumOS, mobileEnvironment);
    await command(["xcrun", "vtool", "-set-build-version", device ? "ios" : "iossim", minimumOS, version,
        "-replace", "-output", binary, binary], { env: mobileEnvironment });
    checkMobileBuildVersion(await text(["xcrun", "vtool", "-show-build", binary], { env: mobileEnvironment }),
        device, minimumOS, version);
    for (const extension of mobileExtensions) {
        const bundle = join(app, "PlugIns", `${extension.executable}.appex`);
        await rm(bundle, { recursive: true, force: true });
        await mkdir(bundle, { recursive: true });
        const executable = join(bundle, extension.executable);
        const info = join(bundle, "Info.plist");
        await copyFile(join(bin, extension.executable), executable);
        checkMobileExtensionEntryPoint(
            await text(["xcrun", "otool", "-l", executable], { env: mobileEnvironment }),
            await text(["xcrun", "otool", "-Iv", executable], { env: mobileEnvironment }));
        await copyFile(join(root, "Resources/Mobile", extension.info), info);
        for (const key of ["CFBundleVersion", "CFBundleShortVersionString", "MinimumOSVersion"]) {
            await plist(info, [`Set :${key} ${await plist(join(app, "Info.plist"), [`Print :${key}`])}`]);
        }
        await plist(info, [
            "Add :CFBundleSupportedPlatforms array",
            `Add :CFBundleSupportedPlatforms:0 string ${device ? "iPhoneOS" : "iPhoneSimulator"}`,
            `Add :DTSDKName string ${device ? "iphoneos" : "iphonesimulator"}${version}`,
        ]);
        await command(["xcrun", "vtool", "-set-build-version", device ? "ios" : "iossim", minimumOS, version,
            "-replace", "-output", executable, executable], { env: mobileEnvironment });
        checkMobileBuildVersion(await text(["xcrun", "vtool", "-show-build", executable], { env: mobileEnvironment }),
            device, minimumOS, version);
        if (await text(["lipo", "-archs", executable]) !== "arm64") {
            throw new Error(`${extension.executable} must contain only arm64.`);
        }
        for (const [key, expected] of Object.entries({
            CFBundleIdentifier: `${mobileBundleID}.${extension.suffix}`,
            CFBundleExecutable: extension.executable,
            "NSExtension:NSExtensionPointIdentifier": extension.point,
        })) {
            if (await plist(info, [`Print :${key}`]) !== expected) {
                throw new Error(`${extension.executable} has an unexpected ${key}.`);
            }
        }
        if (!device) await signMobileSimulatorBundle(bundle);
    }
    if (!device) await signMobileSimulatorBundle(app);
    return app;
}

async function signMobileSimulatorBundle(bundle: string) {
    await command(["codesign", "--force", "--sign", "-", bundle]);
    await command(["codesign", "--verify", "--strict", bundle]);
}
