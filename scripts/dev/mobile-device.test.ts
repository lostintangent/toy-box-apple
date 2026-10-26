import { expect, test } from "bun:test";
import {
    defaultDeviceServer, developmentIdentities, deviceControlArguments, deviceServerArguments,
    selectDevelopmentSigning, selectMobileDevice, type DevelopmentProfile,
} from "./mobile-device.ts";

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
function profile(overrides: Partial<DevelopmentProfile> = {}): DevelopmentProfile {
    return {
        path: "/profiles/dev.mobileprovision", name: "Development", uuid: "profile",
        team: "TEAM", prefix: "TEAM", applicationIdentifier: "TEAM.*",
        expires: "2027-01-01T00:00:00Z", devices: ["phone"], certificates: [fingerprint],
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
        expect(() => selectDevelopmentSigning([invalid], [identity], "phone", now)).toThrow("No unexpired");
    }
    expect(() => selectDevelopmentSigning([profile()], [], "phone", now)).toThrow("No unexpired");
    expect(selectDevelopmentSigning([profile({ applicationIdentifier: "TEAM.dev.toybox.*" })],
        [identity], "phone", now).applicationIdentifier).toBe("TEAM.dev.toybox.mobile");
    expect(selectDevelopmentSigning([profile({ applicationIdentifier: "TEAM.dev.toybox.mobile" })],
        [identity], "phone", now).applicationIdentifier).toBe("TEAM.dev.toybox.mobile");
    expect(selectDevelopmentSigning([profile({ prefix: "LEGACY", applicationIdentifier: "LEGACY.*" })],
        [identity], "phone", now).applicationIdentifier).toBe("LEGACY.dev.toybox.mobile");
});

test("same-team profiles choose the latest expiration but different teams require an explicit profile", () => {
    const later = profile({ uuid: "later", expires: "2028-01-01T00:00:00Z" });
    expect(selectDevelopmentSigning([profile(), later], [identity], "phone", now).profile.uuid).toBe("later");
    expect(() => selectDevelopmentSigning([profile(), profile({ team: "OTHER" })],
        [identity], "phone", now)).toThrow("Multiple development teams");
});

test("only valid Apple Development identity fingerprints are considered", () => {
    expect(developmentIdentities(`
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
