import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import {
    checkMobileBuildVersion, checkMobileExtensionEntryPoint,
    mobileEntitlements, mobileExtensions, mobilePushEnvironment, mobileSimulatorEntitlements,
} from "./build.ts";

function buildVersion(platform = "IOSSIMULATOR", minimumOS = "27.0", sdk = "27.1") {
    return `Load command 10
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform ${platform}
        minos ${minimumOS}
          sdk ${sdk}
       ntools 1`;
}

test("iOS extensions have exact identities, extension points and executable entry points", async () => {
    for (const extension of mobileExtensions) {
        const info = await readFile(join(import.meta.dir, "../../../Resources/Mobile", extension.info), "utf8");
        expect(info).toContain(`<string>dev.toybox.mobile.${extension.suffix}</string>`);
        expect(info).toContain(`<string>${extension.point}</string>`);
        expect(info).toContain(`<string>${extension.executable}</string>`);
    }
    const host = await readFile(join(import.meta.dir, "../../../Resources/Mobile/Info.plist"), "utf8");
    expect(host).toMatch(/<key>NSSupportsLiveActivities<\/key>\s*<true\/>/);
    expect(host).toMatch(/<key>CFBundleURLSchemes<\/key>\s*<array><string>toybox-desktop<\/string><\/array>/);
    expect(host).toContain("<string>dev.toybox.desktop.channel</string>");
    const package_ = await readFile(join(import.meta.dir, "../../../Package.swift"), "utf8");
    for (const extension of mobileExtensions) expect(package_).toContain(`name: "${extension.executable}"`);
});

test("extension binaries bootstrap their context before calling generated Swift main", () => {
    const commands = `Load command 0
          cmd LC_SEGMENT_64
      segname __TEXT
       vmaddr 0x0000000100000000
      fileoff 0
Load command 1
          cmd LC_MAIN
     entryoff 4096`;
    const symbols = `Indirect symbols for (__TEXT,__stubs) 2 entries
address            index name
0x0000000100001000  42 _NSExtensionMain
0x000000010000100C  43 _other`;
    expect(() => checkMobileExtensionEntryPoint(commands, symbols)).not.toThrow();
    for (const output of [
        commands.replace("entryoff 4096", "entryoff 8192"),
        commands.replace("LC_MAIN", "LC_UNIXTHREAD"),
        `${commands}\nLoad command 2\ncmd LC_MAIN\nentryoff 4096`,
        commands.replace("vmaddr 0x0000000100000000", "vmaddr invalid"),
        "",
    ]) expect(() => checkMobileExtensionEntryPoint(output, symbols)).toThrow("_NSExtensionMain");
    for (const output of [
        symbols.replace("_NSExtensionMain", "_main"),
        symbols.replace("(__TEXT,__stubs)", "(__DATA,__got)"),
        "",
    ]) expect(() => checkMobileExtensionEntryPoint(commands, output)).toThrow("_NSExtensionMain");
});

test("simulated capabilities include each bundle identity without a device team or signing profile", () => {
    for (const suffix of ["", ".widget", ".notification"]) {
        const bundleID = `dev.toybox.mobile${suffix}`;
        const entitlements = mobileSimulatorEntitlements(bundleID);
        expect(entitlements["application-identifier"]).toBe(bundleID);
        expect(entitlements["com.apple.security.application-groups"]).toEqual(["group.dev.toybox.mobile"]);
        expect(entitlements).not.toHaveProperty("com.apple.developer.team-identifier");
        expect(entitlements).not.toHaveProperty("get-task-allow");
    }
    expect(() => mobileSimulatorEntitlements("another.app")).toThrow("Unknown mobile bundle");
});

test("phone alerts use the app icon without communication intents or their capability", async () => {
    for (const info of ["Info.plist", ...mobileExtensions.map(extension => extension.info)]) {
        const content = await readFile(join(import.meta.dir, "../../../Resources/Mobile", info), "utf8");
        expect(content).not.toContain("INSendMessageIntent");
    }
    for (const suffix of ["", ".widget", ".notification"]) {
        const bundleID = `dev.toybox.mobile${suffix}`;
        for (const entitlements of [
            mobileEntitlements(bundleID), mobileEntitlements(bundleID, true), mobileSimulatorEntitlements(bundleID),
        ]) expect(entitlements).not.toHaveProperty("com.apple.developer.usernotifications.communication");
    }
});

test("the bundled push environment comes from signing rather than optimization", () => {
    expect(mobilePushEnvironment({ "aps-environment": "development" })).toBe("sandbox");
    expect(mobilePushEnvironment({ "aps-environment": "production" })).toBe("production");
    expect(() => mobilePushEnvironment({})).toThrow("validated APNs");
    expect(() => mobilePushEnvironment({ "aps-environment": "sandbox" })).toThrow("validated APNs");
});

for (const [platform, path] of [
    ["phone", "Mobile/Info.plist"], ["phone widget", "Mobile/Widget-Info.plist"],
    ["phone notification", "Mobile/Notification-Info.plist"], ["Mac", "Info.plist"],
] as const) {
    test(`${platform} ATS allows user-selected HTTP servers without a local-only override`, async () => {
        const info = await readFile(join(import.meta.dir, "../../../Resources", path), "utf8");
        const ats = info.match(/<key>NSAppTransportSecurity<\/key>\s*<dict>([\s\S]*?)<\/dict>/)?.[1];
        expect(ats?.replace(/\s/g, "")).toBe("<key>NSAllowsArbitraryLoads</key><true/>");
    });
}

test("mobile bundles must record their real SDK and preserve their deployment target and platform", () => {
    expect(() => checkMobileBuildVersion(buildVersion(), false, "27.0", "27.1")).not.toThrow();
    expect(() => checkMobileBuildVersion(buildVersion("IOS"), true, "27.0", "27.1")).not.toThrow();
    expect(() => checkMobileBuildVersion(buildVersion("IOS", "27", "27.1.0"), true, "27.0", "27.1")).not.toThrow();
    expect(() => checkMobileBuildVersion(buildVersion("IOSSIMULATOR", "27.0", "27.1.2"),
        false, "27.0", "27.1.2")).not.toThrow();
    for (const output of [
        buildVersion("IOSSIMULATOR", "27.0", "27.0"),
        buildVersion("IOS"),
        buildVersion("MACOS"),
        buildVersion("IOSSIMULATOR", "27.1"),
        buildVersion("IOSSIMULATOR", "27.0", "unknown"),
        buildVersion().replace("          sdk 27.1", ""),
        `${buildVersion()}\n${buildVersion()}`,
        buildVersion().replace("LC_BUILD_VERSION", "LC_VERSION_MIN_IPHONEOS"),
        "",
    ]) {
        expect(() => checkMobileBuildVersion(output, false, "27.0", "27.1")).toThrow();
    }
    expect(() => checkMobileBuildVersion(buildVersion(), true, "27.0", "27.1")).toThrow();
});
