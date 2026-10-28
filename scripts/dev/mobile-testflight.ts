import { copyFile, mkdir, readdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { command, plist, root, scratchPath, temporary, text } from "../lib.ts";
import { version as buildVersion } from "../release/check-update-version.ts";
import { bundleMobile, mobileBundleID, mobileEnvironment, mobileExtensions } from "./mobile.ts";
import { mobileSigning, signMobileBundles } from "./mobile-device.ts";

export type TestFlightVersion = { version: string; build: string };
export type TestFlightAuthentication = { username: string; appID: string; passwordReference: string };

export function testFlightAuthentication(env: NodeJS.ProcessEnv = process.env): TestFlightAuthentication {
    const username = env.APP_STORE_CONNECT_USERNAME ?? env.NOTARY_APPLE_ID;
    const appID = env.APP_STORE_CONNECT_APP_ID;
    if (!username?.trim() || !appID || !/^[1-9]\d*$/.test(appID)) {
        throw new Error("Set APP_STORE_CONNECT_USERNAME and the numeric APP_STORE_CONNECT_APP_ID. "
            + "The user creates the App Store Connect app.");
    }
    if (!env.NOTARY_APP_PASSWORD?.trim()) throw new Error("Export NOTARY_APP_PASSWORD for TestFlight validation or upload.");
    return { username, appID, passwordReference: "@env:NOTARY_APP_PASSWORD" };
}

export async function testFlightMetadata() {
    const developer = mobileEnvironment.DEVELOPER_DIR;
    const xcode = join(developer, "../Info.plist");
    const [sdk, sdkBuild, xcodeVersion, xcodeBuild, osBuild] = await Promise.all([
        text(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], { env: mobileEnvironment }),
        text(["xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"], { env: mobileEnvironment }),
        plist(xcode, ["Print :DTXcode"]), plist(xcode, ["Print :DTXcodeBuild"]),
        text(["sw_vers", "-buildVersion"]),
    ]);
    if (!/^\d+(?:\.\d+)*$/.test(sdk) || Number(sdk.split(".")[0]) < 27
        || !/^\d{4}$/.test(xcodeVersion) || !sdkBuild || !xcodeBuild || !osBuild) {
        throw new Error("TestFlight needs complete metadata from Xcode 27+ and its selected iPhoneOS SDK.");
    }
    return { DTCompiler: "com.apple.compilers.llvm.clang.1_0", DTXcode: xcodeVersion,
        DTXcodeBuild: xcodeBuild, DTSDKName: `iphoneos${sdk}`, DTSDKBuild: sdkBuild,
        DTPlatformName: "iphoneos", DTPlatformVersion: sdk, DTPlatformBuild: sdkBuild,
        BuildMachineOSBuild: osBuild };
}

export async function prepareTestFlightBundle(app: string, release: TestFlightVersion,
    metadata: Awaited<ReturnType<typeof testFlightMetadata>>) {
    if (!/^\d+\.\d+\.\d+$/.test(release.version)) throw new Error("The iPhone version must be X.Y.Z.");
    buildVersion(release.build);
    for (const component of [
        { bundle: app, executable: "ToyBoxMobile", privacy: "PrivacyInfo.xcprivacy" },
        ...mobileExtensions.map(extension => ({
            bundle: join(app, "PlugIns", `${extension.executable}.appex`), executable: extension.executable,
            privacy: extension.info.replace("-Info.plist", "-PrivacyInfo.xcprivacy"),
        })),
    ]) {
        const info = join(component.bundle, "Info.plist");
        const value: unknown = JSON.parse(await text(["plutil", "-convert", "json", "-o", "-", info]));
        if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid mobile Info.plist.");
        const prepared = {
            ...value, ...metadata, CFBundleVersion: release.build,
            CFBundleShortVersionString: release.version, CFBundleInfoDictionaryVersion: "6.0",
            ITSAppUsesNonExemptEncryption: false,
            UIDeviceFamily: [1], LSRequiresIPhoneOS: true, UIRequiredDeviceCapabilities: ["arm64"],
            ...(component.bundle === app ? { ToyBoxPushEnvironment: "production" } : {}),
        };
        if ("ToyBoxDefaultServerURL" in prepared) delete prepared.ToyBoxDefaultServerURL;
        await writeFile(info, JSON.stringify(prepared));
        await command(["plutil", "-convert", "binary1", info]);
        const privacy = join(component.bundle, "PrivacyInfo.xcprivacy");
        await copyFile(join(root, "Resources/Mobile", component.privacy), privacy);
        await command(["plutil", "-lint", privacy], { quiet: true });
        if ((await readdir(component.bundle)).includes("Frameworks")) {
            throw new Error(`${component.executable} contains unexpected embedded frameworks.`);
        }
        const symbols = await text(["xcrun", "nm", "-a", join(component.bundle, component.executable)], { env: mobileEnvironment });
        if (symbols.includes("MobileAutomation")) {
            throw new Error("TestFlight must not include the DEBUG automation code.");
        }
        if (await text(["lipo", "-archs", join(component.bundle, component.executable)]) !== "arm64") {
            throw new Error(`${component.executable} must be arm64 only.`);
        }
    }
}

export async function packageTestFlightIPA(app: string, destination: string): Promise<void> {
    await mkdir(dirname(destination), { recursive: true });
    await temporary("toy-box-testflight-payload-", async directory => {
        const payload = join(directory, "Payload");
        await mkdir(payload);
        await command(["ditto", app, join(payload, "Toy Box.app")], { quiet: true });
        await command(["ditto", "-c", "-k", "--norsrc", "--keepParent", payload, destination], { quiet: true });
    });
}

export function testFlightProcessingIsValid(value: unknown): boolean {
    if (!value || typeof value !== "object") return false;
    return Object.entries(value).some(([key, item]) =>
        (/processing[-_ ]?(?:state|status)/i.test(key) && item === "VALID")
        || (typeof item === "object" && testFlightProcessingIsValid(item)));
}

export async function deliverTestFlightIPA(ipa: string, release: TestFlightVersion,
    auth: TestFlightAuthentication, validateOnly: boolean) {
    const env = mobileEnvironment;
    const options = ["--username", auth.username, "--password", auth.passwordReference, "--output-format", "json"];
    await command(["xcrun", "altool", "--validate-app", ipa, ...options], { env, quiet: true });
    console.log("App Store validation passed.");
    if (validateOnly) { console.log(`Validated only, not uploaded: ${ipa}`); return; }
    await command(["xcrun", "altool", "--upload-package", ipa, "--wait", ...options], { env, quiet: true });
    const status = await text(["xcrun", "altool", "--build-status", "--apple-id", auth.appID,
        "--bundle-version", release.build, "--bundle-short-version-string", release.version,
        "--platform", "ios", "--wait", ...options], { env });
    const result: unknown = JSON.parse(status);
    if (!testFlightProcessingIsValid(result)) {
        console.log(status);
        throw new Error("Upload finished, but Apple has not reported processing VALID. Check this build in App Store Connect.");
    }
    console.log(`Apple processing VALID: Toy Box ${release.version} (${release.build}). Check the TestFlight group for tester availability.`);
}

export async function runTestFlight(options: { buildOnly?: boolean; validateOnly?: boolean; version?: string; build?: string }) {
    const requestedBuild = options.build ?? process.env.BUILD_NUMBER;
    if (!options.buildOnly && !requestedBuild) {
        throw new Error("TestFlight validation and upload require --build-number N or BUILD_NUMBER. Choose an unused build number in App Store Connect.");
    }
    const info = join(root, "Resources/Mobile/Info.plist");
    const release = {
        version: options.version ?? process.env.MOBILE_VERSION
            ?? await plist(info, ["Print :CFBundleShortVersionString"]),
        build: requestedBuild ?? await plist(info, ["Print :CFBundleVersion"]),
    };
    if (!/^\d+\.\d+\.\d+$/.test(release.version)) throw new Error("The iPhone version must be X.Y.Z.");
    buildVersion(release.build);
    const auth = options.buildOnly ? undefined : testFlightAuthentication();
    const signing = options.buildOnly ? undefined : await mobileSigning(true);
    const app = await bundleMobile(true, true);
    await prepareTestFlightBundle(app, release, await testFlightMetadata());
    console.log(`TestFlight ${release.version} (${release.build}), release arm64, no bundled server.`);
    if (!signing) { console.log(`Unsigned build only: ${app}`); return; }
    await signMobileBundles(app, signing, true);
    const ipa = join(scratchPath(), `ToyBox-iPhone-${release.version}-${release.build}.ipa`);
    await packageTestFlightIPA(app, ipa);
    console.log(`Signed IPA: ${ipa}`);
    if (!auth) throw new Error("TestFlight upload authentication is missing.");
    await deliverTestFlightIPA(ipa, release, auth, options.validateOnly ?? false);
}
