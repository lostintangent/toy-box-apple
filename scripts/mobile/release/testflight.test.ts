import { expect, spyOn, test } from "bun:test";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import * as tools from "../../shared/lib.ts";
import {
    deliverTestFlightIPA, prepareTestFlightBundle, runTestFlight, testFlightAuthentication,
    testFlightProcessingIsValid,
} from "./testflight.ts";
import { mobileBundleID, mobileEntitlements, mobileExtensions } from "../mobile.ts";
import * as mobile from "../mobile.ts";
import { mobileSigningIdentities, selectMobileSigning, signMobileBundles, type MobileProvisioningProfile } from "../device.ts";

const fingerprint = "1234567890ABCDEF1234567890ABCDEF12345678";
const identity = { fingerprint, name: "Apple Distribution: Test (TEAM)" };
const release = { version: "0.1.0", build: "42.1" };
const metadata = {
    DTCompiler: "com.apple.compilers.llvm.clang.1_0", DTXcode: "2710", DTXcodeBuild: "27A123",
    DTSDKName: "iphoneos27.1", DTSDKBuild: "24A123", DTPlatformName: "iphoneos",
    DTPlatformVersion: "27.1", DTPlatformBuild: "24A123", BuildMachineOSBuild: "27A456",
};

function profiles(): MobileProvisioningProfile[] {
    return [mobileBundleID, ...mobileExtensions.map(extension => `${mobileBundleID}.${extension.suffix}`)].map(bundleID => ({
        path: `/${bundleID}.mobileprovision`, name: bundleID, uuid: bundleID, team: "TEAM", prefix: "TEAM",
        applicationIdentifier: `TEAM.${bundleID}`, expires: "2099-01-01T00:00:00Z",
        devices: [], certificates: [fingerprint], distribution: true,
        entitlements: mobileEntitlements(bundleID, true),
    }));
}

test("App Store signing reuses exact profile-set matching without accepting development, ad hoc or wildcard profiles", () => {
    const valid = profiles();
    expect(selectMobileSigning(valid, [identity], true).map(value => value.bundleID)).toHaveLength(3);
    for (const index of [0, 1, 2]) {
        for (const change of [
            { distribution: false }, { devices: ["phone"] }, { expires: "2000-01-01" },
            { applicationIdentifier: "TEAM.*" }, { certificates: [] },
            { entitlements: { ...valid[index]!.entitlements, "get-task-allow": true } },
            { entitlements: { ...valid[index]!.entitlements, "com.apple.security.application-groups": [] } },
        ]) {
            const invalid = valid.map((profile, n) => n === index ? { ...profile, ...change } : profile);
            expect(() => selectMobileSigning(invalid, [identity], true)).toThrow("No compatible");
        }
    }
    expect(() => selectMobileSigning(valid.map((profile, index) => index ? profile
        : { ...profile, entitlements: mobileEntitlements(mobileBundleID) }), [identity], true)).toThrow("No compatible");
    const output = `  1) ${fingerprint} "${identity.name}"\n  2) ${fingerprint} "Apple Development: Test"`;
    expect(mobileSigningIdentities(output, true)).toEqual([identity]);
});

test.each([undefined, "true"])("upload authentication always passes only an environment reference (CI=%s)", CI => {
    const env = {
        CI,
        APP_STORE_CONNECT_USERNAME: "test@example.test",
        APP_STORE_CONNECT_APP_ID: "123456789",
        NOTARY_APP_PASSWORD: "fake-upload-password",
    };
    const auth = testFlightAuthentication(env);
    expect(auth.passwordReference).toBe("@env:NOTARY_APP_PASSWORD");
    expect(auth).not.toHaveProperty("password");
    expect(JSON.stringify(auth)).not.toContain(env.NOTARY_APP_PASSWORD);
    expect(testFlightAuthentication({ CI, APP_STORE_CONNECT_APP_ID: "123",
        NOTARY_APPLE_ID: "test@example.test", NOTARY_APP_PASSWORD: env.NOTARY_APP_PASSWORD }).passwordReference)
        .toBe("@env:NOTARY_APP_PASSWORD");
    for (const NOTARY_APP_PASSWORD of [undefined, "", " "]) {
        expect(() => testFlightAuthentication({ ...env, NOTARY_APP_PASSWORD })).toThrow("Export NOTARY_APP_PASSWORD");
    }
    expect(() => testFlightAuthentication({})).toThrow("APP_STORE_CONNECT_USERNAME");
});

test("build-only reaches bundling without upload credentials", async () => {
    const previous = process.env.NOTARY_APP_PASSWORD;
    delete process.env.NOTARY_APP_PASSWORD;
    const bundle = spyOn(mobile, "bundleMobile").mockRejectedValue(new Error("credential-free build reached"));
    try {
        await expect(runTestFlight({ buildOnly: true, version: release.version, build: release.build }))
            .rejects.toThrow("credential-free build reached");
        expect(bundle).toHaveBeenCalledWith(true, true);
    } finally {
        bundle.mockRestore();
        if (previous === undefined) delete process.env.NOTARY_APP_PASSWORD;
        else process.env.NOTARY_APP_PASSWORD = previous;
    }
});

test("Apple processing is distinct from upload acceptance", () => {
    expect(testFlightProcessingIsValid({ data: { processingState: "VALID" } })).toBe(true);
    for (const state of ["PROCESSING", "FAILED", "INVALID"]) {
        expect(testFlightProcessingIsValid({ data: { processingState: state } })).toBe(false);
    }
    expect(testFlightProcessingIsValid({ message: "UPLOAD SUCCEEDED" })).toBe(false);
});

test.skipIf(process.platform !== "darwin")("all three bundles preserve HTTP access with release metadata and privacy manifests but no server default", async () => {
    await tools.temporary("toy-box-testflight-metadata-", async directory => {
        const app = join(directory, "Toy Box.app");
        const components = [{ bundle: app, info: "Info.plist" }, ...mobileExtensions.map(extension => ({
            bundle: join(app, "PlugIns", `${extension.executable}.appex`), info: extension.info,
        }))];
        for (const { bundle, info } of components) {
            await mkdir(bundle, { recursive: true });
            const template = JSON.parse(await tools.text(["plutil", "-convert", "json", "-o", "-",
                join(tools.root, "Resources/Mobile", info)]));
            await writeFile(join(bundle, "Info.plist"), JSON.stringify({
                ...template, ToyBoxDefaultServerURL: "http://private.local:3100",
            }));
        }
        const original = tools.text;
        const text = spyOn(tools, "text").mockImplementation(async (args, options) => {
            if (args[0] === "lipo") return "arm64";
            if (args[0] === "xcrun" && args[1] === "nm") return "_main";
            return original(args, options);
        });
        try {
            await prepareTestFlightBundle(app, release, metadata);
            for (const { bundle } of components) {
                const info = await Bun.file(join(bundle, "Info.plist")).arrayBuffer();
                expect(new Uint8Array(info).byteLength).toBeGreaterThan(0);
                const parsed = JSON.parse(await original(["plutil", "-convert", "json", "-o", "-", join(bundle, "Info.plist")]));
                expect(parsed).toMatchObject({ ...metadata, CFBundleVersion: release.build,
                    CFBundleShortVersionString: release.version, ITSAppUsesNonExemptEncryption: false,
                    UIDeviceFamily: [1], LSRequiresIPhoneOS: true, UIRequiredDeviceCapabilities: ["arm64"] });
                expect(parsed).not.toHaveProperty("ToyBoxDefaultServerURL");
                expect(parsed.NSUserActivityTypes ?? []).not.toContain("INSendMessageIntent");
                expect(parsed.NSAppTransportSecurity).toEqual({ NSAllowsArbitraryLoads: true });
                expect(await Bun.file(join(bundle, "PrivacyInfo.xcprivacy")).exists()).toBe(true);
            }
        } finally { text.mockRestore(); }
    });
});

test("validation must succeed before upload, and validate-only never uploads", async () => {
    const calls: string[][] = [];
    const success = await tools.command(["true"], { quiet: true });
    const execute = spyOn(tools, "command").mockImplementation(async args => {
        calls.push(args);
        return success;
    });
    const result = spyOn(tools, "text").mockImplementation(async args => {
        calls.push(args);
        return JSON.stringify({ data: { processingState: "VALID" } });
    });
    const auth = { username: "test@example.test", appID: "123", passwordReference: "@env:NOTARY_APP_PASSWORD" };
    try {
        await deliverTestFlightIPA("/fake.ipa", release, auth, true);
        expect(calls).toHaveLength(1);
        expect(calls[0]).toContain("--validate-app");
        calls.length = 0;
        await deliverTestFlightIPA("/fake.ipa", release, auth, false);
        expect(calls.map(args => args[2])).toEqual(["--validate-app", "--upload-package"]);
        expect(calls[1]).toContain("--wait");
        expect(calls[1]).toContain("--output-format");
        expect(calls.every(args => args[args.indexOf("--password") + 1] === "@env:NOTARY_APP_PASSWORD")).toBe(true);
        expect(calls.flat()).not.toContain("--auth-string");
        execute.mockRejectedValue(new Error("Apple rejected the bundle"));
        calls.length = 0;
        await expect(deliverTestFlightIPA("/fake.ipa", release, auth, false)).rejects.toThrow("Apple rejected");
        expect(calls).toEqual([]);
    } finally { execute.mockRestore(); result.mockRestore(); }
});

test.each(["PROCESSING", "FAILED", "INVALID"])("upload returning %s never claims processing success or retries", async state => {
    const calls: string[][] = [];
    const success = await tools.command(["true"], { quiet: true });
    const execute = spyOn(tools, "command").mockImplementation(async args => {
        calls.push(args);
        return success;
    });
    const result = spyOn(tools, "text").mockImplementation(async args => {
        calls.push(args);
        return JSON.stringify({ data: { processingState: state } });
    });
    const auth = { username: "test@example.test", appID: "123", passwordReference: "@env:NOTARY_APP_PASSWORD" };
    try {
        await expect(deliverTestFlightIPA("/fake.ipa", release, auth, false)).rejects.toThrow("before retrying");
        expect(calls.map(args => args[2])).toEqual(["--validate-app", "--upload-package"]);
    } finally { execute.mockRestore(); result.mockRestore(); }
});

test.skipIf(process.platform !== "darwin")("distribution signs extensions before the host and verifies the actual signed production entitlements", async () => {
    await tools.temporary("toy-box-testflight-signing-", async directory => {
        const app = join(directory, "Toy Box.app");
        const valid = profiles();
        await mkdir(app);
        await writeFile(join(app, "Info.plist"), JSON.stringify({ ToyBoxPushEnvironment: "sandbox" }));
        await tools.command(["plutil", "-convert", "xml1", join(app, "Info.plist")], { quiet: true });
        for (const [index, profile] of valid.entries()) {
            profile.path = join(directory, `${index}.mobileprovision`);
            await writeFile(profile.path, "public profile fixture");
        }
        for (const extension of mobileExtensions) {
            await mkdir(join(app, "PlugIns", `${extension.executable}.appex`), { recursive: true });
        }
        const calls: string[] = [];
        let entitlements = "";
        const original = tools.text;
        const execute = spyOn(tools, "text").mockImplementation(async (args, options) => {
            if (args[0] !== "codesign") return original(args, options);
            if (args.includes("--sign")) {
                calls.push(args.at(-1)!);
                entitlements = await readFile(args[args.indexOf("--entitlements") + 1]!, "utf8");
                expect(entitlements).not.toContain("get-task-allow");
                expect(entitlements).not.toContain("com.apple.developer.usernotifications.communication");
                expect(entitlements).toContain("beta-reports-active");
            }
            return args.includes("--display") ? entitlements : "";
        });
        try {
            await signMobileBundles(app, selectMobileSigning(valid, [identity], true), true);
            expect(calls).toEqual([
                join(app, "PlugIns/ToyBoxMobileWidget.appex"),
                join(app, "PlugIns/ToyBoxMobileNotification.appex"), app,
            ]);
            expect(await original(["plutil", "-extract", "ToyBoxPushEnvironment", "raw", "-o", "-", join(app, "Info.plist")]))
                .toBe("production");
        } finally { execute.mockRestore(); }
    });
});

test("TestFlight rejects local-launch flags before reading signing or upload assets", async () => {
    for (const args of [
        ["--server", "http://private.local"], ["--device"], ["--hold"], ["--drive", "steps.json"],
        ["--appearance", "dark"],
        ["--validate-only", "--build-only"],
    ]) {
        const child = Bun.spawn([process.execPath, join(import.meta.dir, "../mobile.ts"), "--testflight", ...args], {
            stdout: "pipe", stderr: "pipe", env: { ...process.env },
        });

        const stderr = await new Response(child.stderr).text();
        expect(await child.exited).toBe(1);
        expect(stderr).toContain("--testflight accepts only");
    }
});

test("validation and upload require an explicit build before accessing signing assets", async () => {
    for (const args of [[], ["--validate-only"]]) {
        const child = Bun.spawn([process.execPath, join(import.meta.dir, "../mobile.ts"), "--testflight", ...args], {
            stdout: "pipe", stderr: "pipe", env: { ...process.env, BUILD_NUMBER: undefined },
        });
        const stderr = await new Response(child.stderr).text();
        expect(await child.exited).toBe(1);
        expect(stderr).toContain("require --build-number N or BUILD_NUMBER");
    }
});
