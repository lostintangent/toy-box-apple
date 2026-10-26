import { X509Certificate } from "node:crypto";
import { copyFile, readdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { isMissing, machineLock, temporary, text } from "../lib.ts";
import { bundleMobile, mobileBundleID, mobileEnvironment } from "./mobile.ts";

function record(value: unknown, label: string): Record<string, unknown> {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error(`Invalid ${label}: expected an object.`);
    }
    return value as Record<string, unknown>;
}

function string(value: unknown, label: string): string {
    if (typeof value !== "string" || !value) throw new Error(`Invalid ${label}: expected text.`);
    return value;
}

function strings(value: unknown, label: string): string[] {
    if (!Array.isArray(value) || !value.every(item => typeof item === "string")) {
        throw new Error(`Invalid ${label}: expected a string array.`);
    }
    return value;
}

export type MobileDevice = { identifier: string; udid: string; name: string };

export function selectMobileDevice(result: unknown, requested?: string): MobileDevice {
    const devices = record(result, "device list").devices;
    if (!Array.isArray(devices)) throw new Error("CoreDevice did not return a device list.");
    const phones: MobileDevice[] = [];
    for (const value of devices) {
        const device = record(value, "device");
        const properties = record(device.properties, "device properties");
        const hardware = record(properties.hardware, "device hardware");
        const connection = record(properties.connection, "device connection");
        if (hardware.reality !== "physical" || hardware.deviceType !== "iPhone"
            || hardware.platform !== "iOS" || connection.pairingState !== "paired") continue;
        const software = record(properties.software, "device software");
        const version = string(record(software.osVersionNumber, "device OS version").stringValue, "OS version");
        if (!/^\d+(?:\.\d+)*$/.test(version) || Number(version.split(".")[0]) < 27) continue;
        phones.push({
            identifier: string(device.identifier, "CoreDevice identifier"),
            udid: string(hardware.udid, "device UDID"),
            name: string(record(properties.state, "device state").name, "device name"),
        });
    }
    const matches = requested
        ? phones.filter(phone => [phone.identifier, phone.udid, phone.name].includes(requested)) : phones;
    if (matches.length !== 1) {
        throw new Error(`Select exactly one paired physical iPhone running iOS 27+ with --device-id <name-or-UDID>. `
            + `Matching phones: ${matches.map(phone => phone.name).join(", ") || "none"}. `
            + "Connect and unlock the phone, and enable Developer Mode on the phone if needed.");
    }
    return matches[0]!;
}

export type DevelopmentProfile = {
    path: string; name: string; uuid: string; team: string; prefix: string; applicationIdentifier: string;
    expires: string; devices: string[]; certificates: string[];
};
export type DevelopmentIdentity = { fingerprint: string; name: string };

export function developmentIdentities(output: string): DevelopmentIdentity[] {
    return [...output.matchAll(/^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"(Apple Development: [^"]+)"\s*$/gm)]
        .map(match => ({ fingerprint: match[1]!.toUpperCase(), name: match[2]! }));
}

export function selectDevelopmentSigning(profiles: DevelopmentProfile[], identities: DevelopmentIdentity[],
    udid: string, now = Date.now()) {
    const compatible = profiles.flatMap(profile => {
        const expiry = Date.parse(profile.expires);
        const pattern = profile.applicationIdentifier;
        const applicationIdentifier = `${profile.prefix}.${mobileBundleID}`;
        const matches = pattern === applicationIdentifier
            || pattern.endsWith(".*") && applicationIdentifier.startsWith(pattern.slice(0, -1));
        if (!Number.isFinite(expiry) || expiry <= now || !profile.devices.includes(udid) || !matches) return [];
        const identity = identities.find(item => profile.certificates.includes(item.fingerprint));
        return identity ? [{ profile, identity, applicationIdentifier }] : [];
    });
    if (!compatible.length) {
        throw new Error("No unexpired iOS development profile covers this phone, app and an available Apple Development identity. "
            + "Install the existing team profile, or set MOBILE_PROVISIONING_PROFILE to its path. No signing assets were created.");
    }
    if (new Set(compatible.map(item => item.profile.team)).size !== 1) {
        throw new Error("Multiple development teams match. Set MOBILE_PROVISIONING_PROFILE to the intended team's profile.");
    }
    return compatible.sort((a, b) => Date.parse(b.profile.expires) - Date.parse(a.profile.expires)
        || a.profile.uuid.localeCompare(b.profile.uuid))[0]!;
}

async function readDevelopmentProfile(path: string): Promise<DevelopmentProfile | undefined> {
    return temporary("toy-box-profile-", async directory => {
        const decoded = join(directory, "profile.plist");
        await text(["security", "cms", "-D", "-i", path, "-o", decoded]);
        const extract = (key: string, format = "raw") =>
            text(["plutil", "-extract", key, format, "-o", "-", decoded]);
        const platforms = strings(JSON.parse(await extract("Platform", "json")), "profile platforms");
        const entitlements = record(JSON.parse(await extract("Entitlements", "json")), "profile entitlements");
        if (!platforms.includes("iOS") || entitlements["get-task-allow"] !== true) {
            console.log(`Skipping non-iOS-development profile ${path}.`);
            return undefined;
        }
        const [name, uuid, expires, team, prefix, devices, certificates] = await Promise.all([
            extract("Name"), extract("UUID"), extract("ExpirationDate"),
            extract("TeamIdentifier", "json"), extract("ApplicationIdentifierPrefix", "json"),
            extract("ProvisionedDevices", "json"),
            extract("DeveloperCertificates", "xml1"),
        ]);
        const teams = strings(JSON.parse(team), "profile teams");
        if (teams.length !== 1 || teams[0] !== entitlements["com.apple.developer.team-identifier"]) {
            throw new Error(`Profile ${path} has inconsistent development-team identifiers.`);
        }
        const prefixes = strings(JSON.parse(prefix), "application identifier prefixes");
        if (prefixes.length !== 1) throw new Error(`Profile ${path} must identify exactly one application prefix.`);
        const fingerprints = [...certificates.matchAll(/<data>([\s\S]*?)<\/data>/g)].map(match =>
            new X509Certificate(Buffer.from(match[1]!.replace(/\s/g, ""), "base64"))
                .fingerprint.replaceAll(":", "").toUpperCase());
        if (!fingerprints.length) throw new Error(`Profile ${path} contains no signing certificates.`);
        return { path, name, uuid, expires, team: teams[0]!, prefix: prefixes[0]!,
            applicationIdentifier: string(entitlements["application-identifier"], "profile application identifier"),
            devices: strings(JSON.parse(devices), "profile devices"), certificates: fingerprints };
    });
}

async function installedProfiles(): Promise<DevelopmentProfile[]> {
    const explicit = process.env.MOBILE_PROVISIONING_PROFILE;
    const paths: string[] = [];
    if (explicit) paths.push(explicit);
    else for (const directory of [
        join(homedir(), "Library/Developer/Xcode/UserData/Provisioning Profiles"),
        join(homedir(), "Library/MobileDevice/Provisioning Profiles"),
    ]) {
        try {
            for (const name of (await readdir(directory)).sort()) {
                if (name.endsWith(".mobileprovision")) paths.push(join(directory, name));
            }
        } catch (error) {
            if (!isMissing(error)) throw error;
        }
    }
    const profiles: DevelopmentProfile[] = [];
    for (const path of paths) {
        const profile = await readDevelopmentProfile(path);
        if (profile) profiles.push(profile);
    }
    return profiles;
}

async function devicectl(args: string[]): Promise<Record<string, unknown>> {
    const document = record(JSON.parse(await text(deviceControlArguments(args),
        { env: mobileEnvironment })), "CoreDevice response");
    if (record(document.info, "CoreDevice info").outcome !== "success") {
        throw new Error("CoreDevice did not report a successful operation.");
    }
    return record(document.result, "CoreDevice result");
}

export function deviceControlArguments(args: string[]): string[] {
    return ["xcrun", "devicectl", "--timeout", "120", "--json-output", "-", ...args];
}

export function deviceServerArguments(server?: string): string[] {
    if (server === undefined) return [];
    const url = new URL(server);
    const host = url.hostname.toLowerCase();
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password
        || host === "localhost" || host.endsWith(".localhost") || host.startsWith("127.")
        || ["0.0.0.0", "[::]", "[::1]"].includes(host)) {
        throw new Error("--server must be a phone-reachable HTTP(S) URL, not this Mac's loopback address or embedded credentials.");
    }
    return ["--server", server];
}

export function defaultDeviceServer(localHostName: string): string {
    if (!/^[a-z\d](?:[a-z\d-]{0,61}[a-z\d])?$/i.test(localHostName)) {
        throw new Error("Cannot determine this Mac's Bonjour host name. Provide --server <phone-reachable-URL>.");
    }
    return `http://${localHostName}.local:3100`;
}

export async function runMobileDevice(requested?: string, server?: string) {
    server ??= defaultDeviceServer(await text(["scutil", "--get", "LocalHostName"]));
    const arguments_ = deviceServerArguments(server);
    const phone = selectMobileDevice(await devicectl(["list", "devices"]), requested);
    const unlock = await machineLock(`mobile-device-${phone.udid}`);
    try {
        const signing = selectDevelopmentSigning(await installedProfiles(),
            developmentIdentities(await text(["security", "find-identity", "-v", "-p", "codesigning"])), phone.udid);
        console.log(`Building for ${phone.name}; development profile ${signing.profile.name} (${signing.profile.uuid}).`);
        const app = await bundleMobile(true);
        await text(["plutil", "-insert", "ToyBoxDefaultServerURL", "-string", server, join(app, "Info.plist")]);
        await copyFile(signing.profile.path, join(app, "embedded.mobileprovision"));
        await temporary("toy-box-device-signing-", async directory => {
            const entitlements = join(directory, "entitlements.plist");
            await writeFile(entitlements, JSON.stringify({
                "application-identifier": signing.applicationIdentifier,
                "com.apple.developer.team-identifier": signing.profile.team,
                "get-task-allow": true,
                "keychain-access-groups": [signing.applicationIdentifier],
            }));
            await text(["plutil", "-convert", "xml1", entitlements]);
            await text(["codesign", "--force", "--sign", signing.identity.fingerprint,
                "--entitlements", entitlements, "--generate-entitlement-der", app]);
            await text(["codesign", "--verify", "--strict", app]);
        });
        console.log(`Signed ${app}. Unlock ${phone.name} for installation and launch.`);
        await devicectl(["device", "install", "app", "--device", phone.identifier, app]);
        console.log(`Installed ${mobileBundleID} on ${phone.name}. Launching.`);
        const launched = await devicectl(["device", "process", "launch", "--device", phone.identifier,
            "--terminate-existing", mobileBundleID, "--", ...arguments_]);
        const process = record(launched.process, "launched process");
        if (typeof process.processIdentifier !== "number" || process.processIdentifier <= 0) {
            throw new Error("CoreDevice did not return a running app process identifier.");
        }
        const processes = await devicectl(["device", "info", "processes", "--device", phone.identifier]);
        if (!Array.isArray(processes.runningProcesses) || !processes.runningProcesses.some(value =>
            record(value, "running process").processIdentifier === process.processIdentifier)) {
            throw new Error("The installed app was launched but is no longer running.");
        }
        console.log(`Installed and running ${mobileBundleID} on ${phone.name} (PID ${process.processIdentifier}).`);
        console.log(`Server: ${server} (launch-only override, not saved in Settings).`);
    } finally { unlock(); }
}
