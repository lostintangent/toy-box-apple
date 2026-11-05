import { X509Certificate, createHash } from "node:crypto";
import { copyFile, readdir, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { bundleIdentity, command, isMissing, main, plist, root, scratchPath, temporary, text } from "../../shared/lib/index.ts";
import { buildApp } from "../bundle/index.ts";
import { signApp } from "../bundle/sign.ts";
import { isolateIntegrations } from "./isolate.ts";
import { installCopy, launch, pidsFor, registerOnly } from "./install.ts";

const identifier = `${bundleIdentity}.dev`;
const name = "Toy Box Dev";
const app = join(homedir(), "Applications", `${name}.app`);
const profileFolders = ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"]
    .map(folder => join(homedir(), folder));

type Certificate = { hash: string; team: string; expires: Date };
type Profile = { path: string; team: string; certificate: Certificate; explicit: boolean; expires: Date };

// Reads only public certificate metadata, never keys.
async function developmentCertificates() {
    const identities = await text(["security", "find-identity", "-v", "-p", "codesigning"]);
    const valid = new Set([...identities.matchAll(/^\s*\d+\)\s+([0-9A-F]{40})\s+"Apple Development: /gm)].map(match => match[1]));
    const listed = await text(["security", "find-certificate", "-a", "-Z", "-p", "-c", "Apple Development: "], { allowFailure: true });
    const certificates = new Map<string, Certificate>();
    for (const match of listed.matchAll(/^SHA-1 hash: ([0-9A-F]{40})$[\s\S]*?(-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----)/gm)) {
        if (!valid.has(match[1])) continue;
        const certificate = new X509Certificate(match[2]);
        certificates.set(match[1], {
            hash: match[1], team: certificate.subject.match(/^OU=(.+)$/m)?.[1] ?? "", expires: new Date(certificate.validTo),
        });
    }
    return [...certificates.values()];
}

async function provisioningUDID() {
    const hardware = JSON.parse(await text(["system_profiler", "-json", "SPHardwareDataType"]));
    const udid: unknown = hardware.SPHardwareDataType?.[0]?.provisioning_UDID;
    if (typeof udid !== "string" || !udid) throw new Error("Could not read this Mac's Provisioning UDID.");
    return udid;
}

async function readProfile(path: string, certificates: Certificate[], device: string): Promise<Profile | undefined> {
    const decoded = await text(["security", "cms", "-D", "-i", path], { allowFailure: true });
    if (!decoded) return;
    const value = async (key: string, format: "json" | "raw" | "xml1") => {
        const result = await command(["plutil", "-extract", key, format, "-o", "-", "-"],
            { input: decoded, quiet: true, allowFailure: true });
        return result.exitCode ? undefined : result.stdout.toString();
    };
    const platforms: string[] = JSON.parse(await value("Platform", "json") ?? "[]");
    const devices: string[] = JSON.parse(await value("ProvisionedDevices", "json") ?? "[]");
    const entitlements: Record<string, unknown> = JSON.parse(await value("Entitlements", "json") ?? "{}");
    const team: string | undefined = JSON.parse(await value("TeamIdentifier", "json") ?? "[]")[0];
    const expires = new Date((await value("ExpirationDate", "raw"))?.trim() ?? 0);
    const hashes = [...(await value("DeveloperCertificates", "xml1") ?? "").matchAll(/<data>([^<]+)<\/data>/g)]
        .map(match => createHash("sha1").update(Buffer.from(match[1].replace(/\s/g, ""), "base64")).digest("hex").toUpperCase());
    const certificate = certificates.find(certificate => hashes.includes(certificate.hash));
    const applicationID = entitlements["com.apple.application-identifier"] ?? entitlements["application-identifier"];
    if (!team || !certificate || !platforms.includes("OSX") || !devices.includes(device) || !(expires > new Date())) return;
    if (applicationID !== `${team}.${identifier}` && applicationID !== `${team}.*`) return;
    return { path, team, certificate, explicit: applicationID === `${team}.${identifier}`, expires };
}

async function matchingProfile(certificates: Certificate[], device: string) {
    const profiles: Profile[] = [];
    for (const folder of profileFolders) {
        let files: string[];
        try { files = await readdir(folder); }
        catch (error) { if (isMissing(error)) continue; throw error; }
        for (const file of files.filter(file => file.endsWith(".provisionprofile"))) {
            const profile = await readProfile(join(folder, file), certificates, device);
            if (profile) profiles.push(profile);
        }
    }
    return profiles.sort((a, b) => Number(b.explicit) - Number(a.explicit) || b.expires.getTime() - a.expires.getTime())[0];
}

function missingProfile(certificates: Certificate[], device: string) {
    const teams = [...new Set(certificates.map(certificate => certificate.team))].join(" or ");
    const certificate = certificates.length === 1
        ? `the Apple Development certificate that expires ${certificates[0].expires.toLocaleDateString("en-US",
            { month: "long", day: "numeric", year: "numeric", timeZone: "UTC" })}`
        : "your Apple Development certificate";
    return [
        "Siri's developer preview answers only development-signed builds, and no macOS development profile matches Toy Box Dev.",
        `In Certificates, Identifiers & Profiles for team ${teams}:`,
        `1. Devices: register this Mac if it isn't listed. Platform macOS, Device ID ${device}.`,
        `2. Identifiers: add an App ID with the explicit Bundle ID ${identifier} and no capabilities.`,
        `3. Profiles: add a macOS App Development profile for that App ID, with ${certificate} and this Mac.`,
        "4. In Xcode, open Settings, then Accounts, select the team and click Download Manual Profiles.",
        "Then run this again.",
    ].join("\n");
}

async function quitRunningCopy() {
    const binary = join(app, "Contents/MacOS/ToyBoxDesktop");
    if (!await Bun.file(binary).exists()) return;
    const running = await realpath(binary);
    const pids = await pidsFor(running);
    if (!pids.length) return;
    await command(["kill", ...pids.map(String)]);
    for (let attempt = 0; attempt < 50; attempt++) {
        if (!(await pidsFor(running)).length) return;
        await Bun.sleep(100);
    }
    throw new Error(`${name} is still running. Quit it, then run this again.`);
}

if (import.meta.main) await main(async () => {
    const certificates = await developmentCertificates();
    if (!certificates.length) {
        throw new Error(`${name} is signed with your Apple Development certificate, and the keychain has no valid one.`);
    }
    const device = await provisioningUDID();
    const profile = await matchingProfile(certificates, device);
    if (!profile) throw new Error(missingProfile(certificates, device));
    const built = await buildApp("release", scratchPath());
    const release = JSON.parse(await text(["plutil", "-convert", "json", "-o", "-", join(root, "Resources/Desktop/Release.entitlements")]));
    await temporary("toy-box-development.", async folder => {
        const entitlements = join(folder, "Development.entitlements");
        await Bun.write(entitlements, JSON.stringify({
            ...release,
            "com.apple.application-identifier": `${profile.team}.${identifier}`,
            "com.apple.developer.team-identifier": profile.team,
            "com.apple.security.get-task-allow": true,
        }));
        await command(["plutil", "-convert", "xml1", entitlements]);
        await quitRunningCopy();
        await installCopy(built, app, async staged => {
            await plist(join(staged, "Contents/Info.plist"), [
                `Set :CFBundleIdentifier ${identifier}`, `Set :CFBundleName ${name}`, `Set :CFBundleDisplayName ${name}`,
            ]);
            await isolateIntegrations(staged);
            await copyFile(profile.path, join(staged, "Contents/embedded.provisionprofile"));
            await signApp(staged, ["--force", "--options", "runtime", "--timestamp=none", "--sign", profile.certificate.hash],
                entitlements);
        });
    });
    await registerOnly(app, identifier);
    const pid = await launch(app, process.argv.slice(2));
    console.log(`Launched ${name} from ${app} as pid ${pid}, signed for team ${profile.team}.`);
});
