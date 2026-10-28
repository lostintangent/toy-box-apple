import { expect, test } from "bun:test";
import {
    defaultDeviceServer, mobileSigningIdentities, deviceControlArguments, deviceServerArguments,
    selectDevelopmentSigning, selectMobileDevelopmentSigning, selectMobileDevice, type MobileProvisioningProfile,
} from "./device.ts";
import { mobileAppGroup, mobileBundleID, mobileEntitlements } from "./mobile.ts";

function phone(name = "My iPhone", reality = "physical", version = "27.1", pairingState = "paired") {
    return {
        identifier: `core-${name}`,
        properties: {
            hardware: { reality, deviceType: "iPhone", platform: "iOS", udid: `udid-${name}` },
            connection: { pairingState }, state: { name },
            software: { osVersionNumber: { stringValue: version } },
        },
    };
}

test("device mode excludes simulators, unpaired phones and unsupported OS versions", () => {
    const devices = [
        phone("Simulator", "simulated"), phone("Old", "physical", "26.1"),
        phone("Unpaired", "physical", "27.1", "unpaired"), phone(),
    ];
    expect(selectMobileDevice({ devices })).toEqual({
        identifier: "core-My iPhone", udid: "udid-My iPhone", name: "My iPhone",
    });
    for (const requested of ["My iPhone", "core-My iPhone", "udid-My iPhone"]) {
        expect(selectMobileDevice({ devices }, requested).name).toBe("My iPhone");
    }
    for (const requested of ["Simulator", "Old", "Unpaired", "Unknown"]) {
        expect(() => selectMobileDevice({ devices }, requested)).toThrow("Select exactly one");
    }
});

test("ambiguous, absent or malformed device lists never pick an arbitrary device", () => {
    for (const devices of [[], [phone(), phone("Other")]]) {
        expect(() => selectMobileDevice({ devices })).toThrow("Select exactly one");
    }
    expect(selectMobileDevice({ devices: [phone(), phone("Other")] }, "Other").name).toBe("Other");
    for (const result of [undefined, {}, { devices: "not an array" }, { devices: [{}] }]) {
        expect(() => selectMobileDevice(result)).toThrow();
    }
});

const fingerprint = "1234567890ABCDEF1234567890ABCDEF12345678";
const identity = { fingerprint, name: "Apple Development: Test User (PERSON)" };
function profile(overrides: Partial<MobileProvisioningProfile> = {}): MobileProvisioningProfile {
    return {
        path: "/profiles/dev.mobileprovision", name: "Development", uuid: "profile",
        team: "TEAM", prefix: "TEAM", applicationIdentifier: "TEAM.dev.toybox.mobile",
        expires: "2027-01-01T00:00:00Z", devices: ["phone"], certificates: [fingerprint],
        entitlements: mobileEntitlements(mobileBundleID),
        ...overrides,
    };
}
const now = Date.parse("2026-10-26T12:00:00Z");

test("signing requires a matching development identity, device, app and valid expiration", () => {
    const selected = selectDevelopmentSigning([profile()], [identity], "phone", now);
    expect(selected.applicationIdentifier).toBe("TEAM.dev.toybox.mobile");
    expect(selected.identity).toEqual(identity);
    for (const invalid of [
        profile({ expires: "2026-10-26T12:00:00Z" }), profile({ expires: "invalid" }),
        profile({ devices: ["other"] }), profile({ applicationIdentifier: "TEAM.other.*" }),
        profile({ applicationIdentifier: "TEAM.dev.other" }), profile({ certificates: [] }),
    ]) {
        expect(() => selectDevelopmentSigning([invalid], [identity], "phone", now)).toThrow("No unexpired explicit");
    }
    expect(() => selectDevelopmentSigning([profile()], [], "phone", now)).toThrow("No unexpired");
    for (const applicationIdentifier of ["TEAM.*", "TEAM.dev.toybox.*"]) {
        expect(() => selectDevelopmentSigning([profile({ applicationIdentifier })], [identity], "phone", now))
            .toThrow("Wildcard profiles are not accepted");
    }
    expect(selectDevelopmentSigning([profile({ applicationIdentifier: "TEAM.dev.toybox.mobile" })],
        [identity], "phone", now).applicationIdentifier).toBe("TEAM.dev.toybox.mobile");
    expect(selectDevelopmentSigning([profile({ prefix: "LEGACY", applicationIdentifier: "LEGACY.dev.toybox.mobile" })],
        [identity], "phone", now).applicationIdentifier).toBe("LEGACY.dev.toybox.mobile");
});

function profileSet(team = "TEAM", certificate = fingerprint) {
    return ["dev.toybox.mobile", "dev.toybox.mobile.widget", "dev.toybox.mobile.notification"].map(bundleID => profile({
        path: `/profiles/${team}/${bundleID}`, uuid: `${team}-${bundleID}`, team, prefix: team,
        applicationIdentifier: `${team}.${bundleID}`, certificates: [certificate],
        entitlements: mobileEntitlements(bundleID),
    }));
}

test("each mobile bundle needs its own exact profile, capabilities and shared container", () => {
    const profiles = profileSet();
    const selected = selectMobileDevelopmentSigning(profiles, [identity], "phone", now);
    expect(selected.map(value => value.bundleID)).toEqual([
        "dev.toybox.mobile", "dev.toybox.mobile.widget", "dev.toybox.mobile.notification",
    ]);
    expect(new Set(selected.map(value => value.profile.uuid)).size).toBe(3);
    for (const index of [0, 1, 2]) {
        expect(() => selectMobileDevelopmentSigning(profiles.filter((_, n) => n !== index), [identity], "phone", now))
            .toThrow("Your Apple steps");
        const missingGroup = profiles.map((value, n) => n === index
            ? { ...value, entitlements: { ...value.entitlements, "com.apple.security.application-groups": [] } } : value);
        expect(() => selectMobileDevelopmentSigning(missingGroup, [identity], "phone", now)).toThrow("App Group");
    }
    for (const [index, key, wrong] of [
        [0, "aps-environment", undefined], [0, "aps-environment", "production"],
        [0, "com.apple.developer.usernotifications.communication", false],
        [2, "com.apple.developer.usernotifications.communication", undefined],
    ] as const) {
        const invalid = profiles.map((value, n) => n === index
            ? { ...value, entitlements: { ...value.entitlements, [key]: wrong } } : value);
        expect(() => selectMobileDevelopmentSigning(invalid, [identity], "phone", now)).toThrow("No compatible");
    }
    expect(mobileEntitlements("dev.toybox.mobile.widget")).toEqual({
        "com.apple.security.application-groups": [mobileAppGroup],
    });
    expect(() => mobileEntitlements("dev.toybox.other")).toThrow("Unknown mobile bundle");
});

test("the profile set must share a team and one available signing identity", () => {
    const otherFingerprint = "ABCDEF1234567890ABCDEF1234567890ABCDEF12";
    const other = { fingerprint: otherFingerprint, name: "Apple Development: Other" };
    const profiles = profileSet();
    expect(() => selectMobileDevelopmentSigning([profiles[0]!, ...profileSet("OTHER").slice(1)],
        [identity], "phone", now)).toThrow("one development identity and team");
    expect(() => selectMobileDevelopmentSigning(profiles.map((value, index) => index === 1
        ? { ...value, certificates: [otherFingerprint] } : value), [identity, other], "phone", now))
        .toThrow("one development identity and team");
    expect(() => selectMobileDevelopmentSigning([...profiles, ...profileSet("OTHER")], [identity], "phone", now))
        .toThrow("Multiple signing teams");
    expect(selectMobileDevelopmentSigning([...profiles, ...profileSet("OTHER")], [identity], "phone", now, {
        "dev.toybox.mobile": profiles[0]!.path,
    }).map(value => value.profile.team)).toEqual(["TEAM", "TEAM", "TEAM"]);
    expect(() => selectMobileDevelopmentSigning(profiles, [identity], "phone", now, {
        "dev.toybox.mobile.widget": "/wrong-profile",
    })).toThrow("Your Apple steps");
});

test("same-team profiles choose the latest expiration but different teams require an explicit profile", () => {
    const later = profile({ uuid: "later", expires: "2028-01-01T00:00:00Z" });
    expect(selectDevelopmentSigning([profile(), later], [identity], "phone", now).profile.uuid).toBe("later");
    expect(() => selectDevelopmentSigning([profile(), profile({ team: "OTHER" })],
        [identity], "phone", now)).toThrow("Multiple development teams");
});

test("only valid Apple Development identity fingerprints are considered", () => {
    expect(mobileSigningIdentities(`
  1) ${fingerprint.toLowerCase()} "${identity.name}"
  2) ${fingerprint} "Developer ID Application: Test User (TEAM)"
  3) NOTAFINGERPRINT "Apple Development: Broken"
     3 valid identities found
`)).toEqual([identity]);
});

test("CoreDevice JSON and timeout options remain before the launch argument separator", () => {
    const args = deviceControlArguments(["device", "process", "launch", "--device", "phone",
        "dev.toybox.mobile", "--", "--server", "http://mac.local:3100"]);
    expect(args).toEqual(["xcrun", "devicectl", "--timeout", "120", "--json-output", "-",
        "device", "process", "launch", "--device", "phone", "dev.toybox.mobile",
        "--", "--server", "http://mac.local:3100"]);
});

test("device launch uses a Bonjour default and rejects loopback or credential-bearing server URLs", () => {
    expect(defaultDeviceServer("My-Mac")).toBe("http://My-Mac.local:3100");
    expect(deviceServerArguments("http://My-Mac.local:3100")).toEqual(["--server", "http://My-Mac.local:3100"]);
    expect(deviceServerArguments("https://channels.example.test/api")).toEqual([
        "--server", "https://channels.example.test/api",
    ]);
    for (const server of [
        "http://localhost:3100", "http://127.0.0.1:3210", "http://127.0.0.2:3100", "http://[::1]:3100",
        "http://server.localhost:3100", "http://0.0.0.0:3100", "http://[::]:3100",
        "file:///tmp/server", "https://user:password@example.test", "not a URL",
    ]) expect(() => deviceServerArguments(server)).toThrow();
    for (const host of ["", "-invalid", "invalid-", "mac.local", "mac/evil"]) {
        expect(() => defaultDeviceServer(host)).toThrow("Bonjour");
    }
});
