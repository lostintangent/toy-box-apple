import { expect, spyOn, test } from "bun:test";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import * as tools from "../lib.ts";
import {
    deliverTestFlightIPA, nextTestFlightBuild, prepareTestFlightBundle, testFlightAuthentication,
    testFlightProcessingIsValid,
} from "./mobile-testflight.ts";
import { mobileBundleID, mobileEntitlements, mobileExtensions } from "./mobile.ts";
import { mobileSigningIdentities, selectMobileSigning, signMobileBundles, type MobileProvisioningProfile } from "./mobile-device.ts";

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

test("local build reservations increase using Apple's build-number shape and reject repeated or regressing overrides", () => {
    expect(nextTestFlightBuild(undefined)).toBe("1");
    expect(nextTestFlightBuild(undefined, "42.1")).toBe("42.1");
    expect(nextTestFlightBuild("1")).toBe("1.0.1");
    expect(nextTestFlightBuild("1.2.99")).toBe("1.3.0");
    expect(nextTestFlightBuild("1.99.99")).toBe("2.0.0");
    expect(nextTestFlightBuild("42.1", "43.1")).toBe("43.1");
    for (const value of ["", "42.1", "42", "0", "10000", "1.100", "v43"]) {
        expect(() => nextTestFlightBuild("42.1", value)).toThrow();
    }
});

test("upload authentication passes only a keychain or environment reference, never a password", () => {
    const auth = testFlightAuthentication({
        APP_STORE_CONNECT_USERNAME: "test@example.test",
        APP_STORE_CONNECT_APP_ID: "123456789",
    });
    expect(auth.passwordReference).toBe("@keychain:toy-box-testflight");
    expect(auth).not.toHaveProperty("password");
    expect(testFlightAuthentication({ CI: "true", APP_STORE_CONNECT_APP_ID: "123",
        NOTARY_APPLE_ID: "test@example.test" }).passwordReference).toBe("@env:NOTARY_APP_PASSWORD");
    expect(() => testFlightAuthentication({})).toThrow("login keychain");
});

test("Apple processing is distinct from upload acceptance", () => {
    expect(testFlightProcessingIsValid({ data: { processingState: "VALID" } })).toBe(true);
    for (const state of ["PROCESSING", "FAILED", "INVALID"]) {
        expect(testFlightProcessingIsValid({ data: { processingState: state } })).toBe(false);
    }
    expect(testFlightProcessingIsValid({ message: "UPLOAD SUCCEEDED" })).toBe(false);
});

test.skipIf(process.platform !== "darwin")("all three bundles get real metadata, aligned versions and privacy manifests without a server default", async () => {
    await tools.temporary("toy-box-testflight-metadata-", async directory => {
        const app = join(directory, "Toy Box.app");
        const components = [app, ...mobileExtensions.map(extension => join(app, "PlugIns", `${extension.executable}.appex`))];
        for (const bundle of components) {
            await mkdir(bundle, { recursive: true });
            await writeFile(join(bundle, "Info.plist"), JSON.stringify({
                CFBundleIdentifier: bundle === app ? mobileBundleID : "extension",
                MinimumOSVersion: "27.0", ToyBoxDefaultServerURL: "http://private.local:3100",
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
            for (const bundle of components) {
                const info = await Bun.file(join(bundle, "Info.plist")).arrayBuffer();
                expect(new Uint8Array(info).byteLength).toBeGreaterThan(0);
                const parsed = JSON.parse(await original(["plutil", "-convert", "json", "-o", "-", join(bundle, "Info.plist")]));
                expect(parsed).toMatchObject({ ...metadata, CFBundleVersion: release.build,
                    CFBundleShortVersionString: release.version, ITSAppUsesNonExemptEncryption: false,
                    UIDeviceFamily: [1], LSRequiresIPhoneOS: true });
                expect(parsed).not.toHaveProperty("ToyBoxDefaultServerURL");
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
    const auth = { username: "test@example.test", appID: "123", passwordReference: "@keychain:fake" };
    try {
        await deliverTestFlightIPA("/fake.ipa", release, auth, true);
        expect(calls).toHaveLength(1);
        expect(calls[0]).toContain("--validate-app");
        calls.length = 0;
        await deliverTestFlightIPA("/fake.ipa", release, auth, false);
        expect(calls.map(args => args[2])).toEqual(["--validate-app", "--upload-package", "--build-status"]);
        expect(calls.flat()).not.toContain("--auth-string");
        execute.mockRejectedValue(new Error("Apple rejected the bundle"));
        calls.length = 0;
        await expect(deliverTestFlightIPA("/fake.ipa", release, auth, false)).rejects.toThrow("Apple rejected");
        expect(calls).toEqual([]);
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

test("TestFlight rejects all local-launch/proof flags before reading signing or upload assets", async () => {
    for (const args of [
        ["--server", "http://private.local"], ["--device"], ["--hold"], ["--drive", "steps.json"],
        ["--foundation-proof"], ["--activity-fixture-proof"], ["--appearance", "dark"],
        ["--validate-only", "--build-only"],
    ]) {
        const child = Bun.spawn([process.execPath, join(import.meta.dir, "mobile.ts"), "--testflight", ...args], {
            stdout: "pipe", stderr: "pipe", env: { ...process.env },
        });
        const stderr = await new Response(child.stderr).text();
        expect(await child.exited).toBe(1);
        expect(stderr).toContain("--testflight accepts only");
    }
});
