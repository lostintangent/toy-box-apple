import { X509Certificate } from "node:crypto";
import { copyFile, readFile, readdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { isMissing, plist, temporary, text } from "../../shared/lib/index.ts";
import { mobileAppGroup, mobileBundleID, mobileEntitlements, mobileExtensions, mobilePushEnvironment } from "./index.ts";

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

export type MobileProvisioningProfile = {
    path: string; name: string; uuid: string; team: string; prefix: string; applicationIdentifier: string;
    expires: string; devices: string[]; certificates: string[];
    entitlements: Record<string, unknown>;
    distribution: boolean;
};
export type MobileSigningIdentity = { fingerprint: string; name: string };

export function mobileSigningIdentities(output: string): MobileSigningIdentity[] {
    return [...output.matchAll(/^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"(Apple Distribution: [^"]+)"\s*$/gm)]
        .map(match => ({ fingerprint: match[1]!.toUpperCase(), name: match[2]! }));
}

function compatibleMobileSigning(profiles: MobileProvisioningProfile[], identities: MobileSigningIdentity[],
    now: number, bundleID: string) {
    const required = mobileEntitlements(bundleID, true);
    return profiles.flatMap(profile => {
        const expiry = Date.parse(profile.expires);
        const applicationIdentifier = `${profile.prefix}.${bundleID}`;
        const groups = profile.entitlements["com.apple.security.application-groups"];
        if (!Number.isFinite(expiry) || expiry <= now || !profile.distribution
            || profile.devices.length !== 0 || profile.entitlements["get-task-allow"] === true
            || profile.applicationIdentifier !== applicationIdentifier
            || !Array.isArray(groups) || !groups.includes(mobileAppGroup)
            || Object.entries(required).some(([key, value]) => key !== "com.apple.security.application-groups"
                && profile.entitlements[key] !== value)) return [];
        const identity = identities.find(item => profile.certificates.includes(item.fingerprint));
        return identity ? [{ profile, identity, applicationIdentifier }] : [];
    }).sort((a, b) => Date.parse(b.profile.expires) - Date.parse(a.profile.expires)
        || a.profile.uuid.localeCompare(b.profile.uuid));
}

export function selectMobileSigning(profiles: MobileProvisioningProfile[], identities: MobileSigningIdentity[],
    now = Date.now(), paths: Record<string, string | undefined> = {}) {
    const bundleIDs = [mobileBundleID, ...mobileExtensions.map(extension => `${mobileBundleID}.${extension.suffix}`)];
    const sets = identities.flatMap(identity => [...new Set(profiles.map(profile => profile.team))].flatMap(team => {
        const selected = bundleIDs.map(bundleID => {
            const candidates = profiles.filter(profile => profile.team === team
                && (!paths[bundleID] || profile.path === paths[bundleID]));
            const choice = compatibleMobileSigning(candidates, [identity], now, bundleID)[0];
            return choice ? { bundleID, ...choice } : undefined;
        });
        return selected.every(value => value !== undefined) ? [selected] : [];
    }));
    if (!sets.length) throw new Error("No compatible app/widget/notification/share App Store profile set shares one Apple Distribution identity and team. "
        + "Select four explicit iOS App Store Connect profiles with the App Group and production Push on the host. No profiles or certificates were created.");
    if (new Set(sets.map(set => set[0]!.profile.team)).size !== 1) {
        throw new Error("Multiple signing teams match all four bundles. Select the intended profiles with "
            + "MOBILE_PROVISIONING_PROFILE, MOBILE_WIDGET_PROVISIONING_PROFILE, MOBILE_NOTIFICATION_PROVISIONING_PROFILE "
            + "and MOBILE_SHARE_PROVISIONING_PROFILE.");
    }
    return sets.sort((a, b) => a[0]!.identity.fingerprint.localeCompare(b[0]!.identity.fingerprint))[0]!;
}

async function readMobileProfile(path: string): Promise<MobileProvisioningProfile | undefined> {
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
        if (!platforms.includes("iOS") || entitlements["get-task-allow"] === true || hasDevices || hasAllDevices) {
            console.log(`Skipping profile not usable for App Store: ${path}.`);
            return undefined;
        }
        const [name, uuid, expires, team, prefix, certificates] = await Promise.all([
            extract("Name"), extract("UUID"), extract("ExpirationDate"),
            extract("TeamIdentifier", "json"), extract("ApplicationIdentifierPrefix", "json"),
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
            devices: [], certificates: fingerprints, entitlements, distribution: true };
    });
}

async function installedProfiles(): Promise<MobileProvisioningProfile[]> {
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
        const profile = await readMobileProfile(path);
        if (profile) profiles.push(profile);
    }
    return profiles;
}

export function mobileProfilePaths() {
    return {
        [mobileBundleID]: process.env.MOBILE_PROVISIONING_PROFILE,
        [`${mobileBundleID}.widget`]: process.env.MOBILE_WIDGET_PROVISIONING_PROFILE,
        [`${mobileBundleID}.notification`]: process.env.MOBILE_NOTIFICATION_PROVISIONING_PROFILE,
        [`${mobileBundleID}.share`]: process.env.MOBILE_SHARE_PROVISIONING_PROFILE,
    };
}

export async function mobileSigning(fingerprint = process.env.MOBILE_SIGNING_IDENTITY) {
    if (fingerprint !== undefined && !/^[a-f\d]{40}$/i.test(fingerprint)) {
        throw new Error("MOBILE_SIGNING_IDENTITY must be a 40-digit certificate SHA-1.");
    }
    const identities = mobileSigningIdentities(
        await text(["security", "find-identity", "-v", "-p", "codesigning"]));
    return selectMobileSigning(await installedProfiles(),
        identities.filter(identity => fingerprint === undefined || identity.fingerprint === fingerprint.toUpperCase()),
        Date.now(), mobileProfilePaths());
}

export async function signMobileBundles(app: string, signing: ReturnType<typeof selectMobileSigning>) {
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
                ...mobileEntitlements(component.bundleID, true),
                "application-identifier": component.applicationIdentifier,
                "com.apple.developer.team-identifier": component.profile.team,
                "keychain-access-groups": [component.applicationIdentifier],
            };
            await writeFile(entitlements, JSON.stringify(required));
            await text(["plutil", "-convert", "xml1", entitlements]);
            await text(["codesign", "--force", "--sign", component.identity.fingerprint,
                "--entitlements", entitlements, "--generate-entitlement-der", bundle]);
            await text(["codesign", "--verify", "--strict", bundle]);
            const signed = join(directory, "signed.plist");
            await writeFile(signed, await text(["codesign", "--display", "--entitlements", "-", "--xml", bundle]));
            const actual = record(JSON.parse(await text(["plutil", "-convert", "json", "-o", "-", signed])), "signed entitlements");
            if ("get-task-allow" in actual || Object.entries(required).some(([key, value]) =>
                JSON.stringify(actual[key]) !== JSON.stringify(value))) {
                throw new Error(`The signed App Store entitlements do not match ${component.bundleID}.`);
            }
        }
    });
}
