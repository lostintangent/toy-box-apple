import { X509Certificate } from "node:crypto";
import { copyFile, readFile, readdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { isMissing, machineLock, plist, temporary, text } from "../shared/lib.ts";
import { bundleMobile, mobileAppGroup, mobileBundleID, mobileEntitlements, mobileEnvironment, mobileExtensions, mobilePushEnvironment } from "./mobile.ts";

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

export type MobileProvisioningProfile = {
    path: string; name: string; uuid: string; team: string; prefix: string; applicationIdentifier: string;
    expires: string; devices: string[]; certificates: string[];
    entitlements: Record<string, unknown>;
    distribution?: boolean;
};
export type MobileSigningIdentity = { fingerprint: string; name: string };

export function mobileSigningIdentities(output: string, distribution = false): MobileSigningIdentity[] {
    const pattern = new RegExp(`^\\s*\\d+\\)\\s+([A-Fa-f0-9]{40})\\s+"(Apple ${distribution ? "Distribution" : "Development"}: [^"]+)"\\s*$`, "gm");
    return [...output.matchAll(pattern)]
        .map(match => ({ fingerprint: match[1]!.toUpperCase(), name: match[2]! }));
}

function compatibleMobileSigning(profiles: MobileProvisioningProfile[], identities: MobileSigningIdentity[],
    udid: string | undefined, now: number, bundleID: string, distribution = false) {
    const required = mobileEntitlements(bundleID, distribution);
    return profiles.flatMap(profile => {
        const expiry = Date.parse(profile.expires);
        const applicationIdentifier = `${profile.prefix}.${bundleID}`;
        const groups = profile.entitlements["com.apple.security.application-groups"];
        if (!Number.isFinite(expiry) || expiry <= now || !!profile.distribution !== distribution
            || (distribution ? profile.devices.length !== 0 || profile.entitlements["get-task-allow"] === true
                : !udid || !profile.devices.includes(udid))
            || profile.applicationIdentifier !== applicationIdentifier
            || !Array.isArray(groups) || !groups.includes(mobileAppGroup)
            || Object.entries(required).some(([key, value]) => key !== "com.apple.security.application-groups"
                && profile.entitlements[key] !== value)) return [];
        const identity = identities.find(item => profile.certificates.includes(item.fingerprint));
        return identity ? [{ profile, identity, applicationIdentifier }] : [];
    }).sort((a, b) => Date.parse(b.profile.expires) - Date.parse(a.profile.expires)
        || a.profile.uuid.localeCompare(b.profile.uuid));
}

export function selectDevelopmentSigning(profiles: MobileProvisioningProfile[], identities: MobileSigningIdentity[],
    udid: string, now = Date.now(), bundleID = mobileBundleID) {
    const compatible = compatibleMobileSigning(profiles, identities, udid, now, bundleID);
    if (!compatible.length) {
        throw new Error(`No unexpired explicit iOS development profile covers ${bundleID}, this phone, `
            + "its required capabilities and an available Apple Development identity. "
            + mobileProfileSetupHelp);
    }
    if (new Set(compatible.map(item => item.profile.team)).size !== 1) {
        throw new Error("Multiple development teams match. Set MOBILE_PROVISIONING_PROFILE to the intended team's profile.");
    }
    return compatible[0]!;
}

export const mobileProfileSetupHelp = "Follow “Your Apple steps” in the shared Next milestone proposal: "
    + `create ${mobileAppGroup}, the app and two extension App IDs, then download three iOS development profiles. `
    + "The app needs sandbox Push and Communication Notifications; the notification extension needs Communication Notifications; "
    + "all three need the App Group. Wildcard profiles are not accepted. No signing assets were created.";

export function selectMobileDevelopmentSigning(profiles: MobileProvisioningProfile[], identities: MobileSigningIdentity[],
    udid: string, now = Date.now(), paths: Record<string, string | undefined> = {}) {
    return selectMobileSigning(profiles, identities, false, udid, now, paths);
}

export function selectMobileSigning(profiles: MobileProvisioningProfile[], identities: MobileSigningIdentity[],
    distribution: boolean, udid?: string, now = Date.now(), paths: Record<string, string | undefined> = {}) {
    const bundleIDs = [mobileBundleID, ...mobileExtensions.map(extension => `${mobileBundleID}.${extension.suffix}`)];
    const sets = identities.flatMap(identity => [...new Set(profiles.map(profile => profile.team))].flatMap(team => {
        const selected = bundleIDs.map(bundleID => {
            const candidates = profiles.filter(profile => profile.team === team
                && (!paths[bundleID] || profile.path === paths[bundleID]));
            const choice = compatibleMobileSigning(candidates, [identity], udid, now, bundleID, distribution)[0];
            return choice ? { bundleID, ...choice } : undefined;
        });
        return selected.every(value => value !== undefined) ? [selected] : [];
    }));
    if (!sets.length) throw new Error(`No compatible app/widget/notification ${distribution ? "App Store" : "development"} profile set shares one ${distribution ? "Apple Distribution" : "development"} identity and team. `
        + (distribution ? "Select three explicit iOS App Store Connect profiles with the App Group, production Push on the host, and Communication Notifications on the host and service. No profiles or certificates were created."
            : mobileProfileSetupHelp));
    if (new Set(sets.map(set => set[0]!.profile.team)).size !== 1) {
        throw new Error("Multiple signing teams match all three bundles. Select the intended profiles with "
            + "MOBILE_PROVISIONING_PROFILE, MOBILE_WIDGET_PROVISIONING_PROFILE and MOBILE_NOTIFICATION_PROVISIONING_PROFILE.");
    }
    return sets.sort((a, b) => a[0]!.identity.fingerprint.localeCompare(b[0]!.identity.fingerprint))[0]!;
}

async function readMobileProfile(path: string, distribution: boolean): Promise<MobileProvisioningProfile | undefined> {
    return temporary("toy-box-profile-", async directory => {
        const decoded = join(directory, "profile.plist");
        await text(["security", "cms", "-D", "-i", path, "-o", decoded]);
        const extract = (key: string, format = "raw") =>
            text(["plutil", "-extract", key, format, "-o", "-", decoded]);
        const platforms = strings(JSON.parse(await extract("Platform", "json")), "profile platforms");
        const entitlements = record(JSON.parse(await extract("Entitlements", "json")), "profile entitlements");
        const xml = await readFile(decoded, "utf8");
        const hasDevices = /<key>\s*ProvisionedDevices\s*<\/key>/.test(xml);
        const hasAllDevices = /<key>\s*ProvisionsAllDevices\s*<\/key>\s*<true\s*\/>/.test(xml);
        if (!platforms.includes("iOS") || (distribution
            ? entitlements["get-task-allow"] === true || hasDevices || hasAllDevices
            : entitlements["get-task-allow"] !== true || !hasDevices)) {
            console.log(`Skipping profile not usable for ${distribution ? "App Store" : "iOS development"}: ${path}.`);
            return undefined;
        }
        const [name, uuid, expires, team, prefix, devices, certificates] = await Promise.all([
            extract("Name"), extract("UUID"), extract("ExpirationDate"),
            extract("TeamIdentifier", "json"), extract("ApplicationIdentifierPrefix", "json"),
            distribution ? Promise.resolve("[]") : extract("ProvisionedDevices", "json"),
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
            devices: strings(JSON.parse(devices), "profile devices"), certificates: fingerprints, entitlements, distribution };
    });
}

async function installedProfiles(distribution = false): Promise<MobileProvisioningProfile[]> {
    const paths = Object.values(mobileProfilePaths()).filter((value): value is string => value !== undefined);
    for (const directory of [
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
    const profiles: MobileProvisioningProfile[] = [];
    for (const path of new Set(paths)) {
        const profile = await readMobileProfile(path, distribution);
        if (profile) profiles.push(profile);
    }
    return profiles;
}

export function mobileProfilePaths() {
    return {
        [mobileBundleID]: process.env.MOBILE_PROVISIONING_PROFILE,
        [`${mobileBundleID}.widget`]: process.env.MOBILE_WIDGET_PROVISIONING_PROFILE,
        [`${mobileBundleID}.notification`]: process.env.MOBILE_NOTIFICATION_PROVISIONING_PROFILE,
    };
}

export async function mobileSigning(distribution: boolean, udid?: string,
    fingerprint = distribution ? process.env.MOBILE_SIGNING_IDENTITY : undefined) {
    if (fingerprint !== undefined && !/^[a-f\d]{40}$/i.test(fingerprint)) {
        throw new Error("MOBILE_SIGNING_IDENTITY must be a 40-digit certificate SHA-1.");
    }
    const identities = mobileSigningIdentities(
        await text(["security", "find-identity", "-v", "-p", "codesigning"]), distribution);
    return selectMobileSigning(await installedProfiles(distribution),
        identities.filter(identity => fingerprint === undefined || identity.fingerprint === fingerprint.toUpperCase()),
        distribution, udid, Date.now(), mobileProfilePaths());
}

export async function signMobileBundles(app: string, signing: ReturnType<typeof selectMobileSigning>, distribution = false) {
    const host = signing.find(component => component.bundleID === mobileBundleID);
    if (!host) throw new Error("Mobile signing has no host profile.");
    await plist(join(app, "Info.plist"), [`Set :ToyBoxPushEnvironment ${mobilePushEnvironment(host.profile.entitlements)}`]);
    await temporary("toy-box-mobile-signing-", async directory => {
        for (const component of [...signing.slice(1), signing[0]!]) {
            const extension = mobileExtensions.find(value => `${mobileBundleID}.${value.suffix}` === component.bundleID);
            const bundle = extension ? join(app, "PlugIns", `${extension.executable}.appex`) : app;
            await copyFile(component.profile.path, join(bundle, "embedded.mobileprovision"));
            const entitlements = join(directory, `${component.bundleID}.entitlements.plist`);
            const required = {
                ...mobileEntitlements(component.bundleID, distribution),
                "application-identifier": component.applicationIdentifier,
                "com.apple.developer.team-identifier": component.profile.team,
                ...(!distribution ? { "get-task-allow": true } : {}),
                "keychain-access-groups": [component.applicationIdentifier],
            };
            await writeFile(entitlements, JSON.stringify(required));
            await text(["plutil", "-convert", "xml1", entitlements]);
            await text(["codesign", "--force", "--sign", component.identity.fingerprint,
                "--entitlements", entitlements, "--generate-entitlement-der", bundle]);
            await text(["codesign", "--verify", "--strict", bundle]);
            if (distribution) {
                const signed = join(directory, "signed.plist");
                await writeFile(signed, await text(["codesign", "--display", "--entitlements", "-", "--xml", bundle]));
                const actual = record(JSON.parse(await text(["plutil", "-convert", "json", "-o", "-", signed])), "signed entitlements");
                if ("get-task-allow" in actual || Object.entries(required).some(([key, value]) =>
                    JSON.stringify(actual[key]) !== JSON.stringify(value))) {
                    throw new Error(`The signed App Store entitlements do not match ${component.bundleID}.`);
                }
            }
        }
    });
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
        const signing = await mobileSigning(false, phone.udid);
        for (const component of signing) {
            console.log(`${component.bundleID}: ${component.profile.name} (${component.profile.uuid}).`);
        }
        const app = await bundleMobile(true);
        await text(["plutil", "-insert", "ToyBoxDefaultServerURL", "-string", server, join(app, "Info.plist")]);
        await signMobileBundles(app, signing);
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
