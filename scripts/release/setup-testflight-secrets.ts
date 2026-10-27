import { join } from "node:path";
import { CommandFailure, command, developerEnvironment, main, root, temporary, text } from "../lib.ts";
import { mobileBundleID } from "../dev/mobile.ts";
import { mobileSigning } from "../dev/mobile-device.ts";

export async function uploadTestFlightSigning(signing: Awaited<ReturnType<typeof mobileSigning>>,
    appID: string, repository: string, password: string) {
    const host = signing.find(component => component.bundleID === mobileBundleID);
    if (!host || !password) throw new Error("TestFlight signing and a nonempty export password are required.");
    await temporary("toy-box-testflight-secrets.", async directory => {
        const exported = join(directory, "identity.p12");
        await command(["xcrun", "swift", join(root, "scripts/release/export-signing-identity.swift"),
            host.identity.fingerprint, exported], { env: { P12_PASSWORD: password } });
        const secrets: [string, string][] = [
            ["MOBILE_SIGNING_CERTIFICATE", Buffer.from(await Bun.file(exported).arrayBuffer()).toString("base64")],
            ["MOBILE_SIGNING_PASSWORD", password],
        ];
        for (const [bundleID, secret] of [
            [mobileBundleID, "MOBILE_PROVISIONING_PROFILE"],
            [`${mobileBundleID}.widget`, "MOBILE_WIDGET_PROVISIONING_PROFILE"],
            [`${mobileBundleID}.notification`, "MOBILE_NOTIFICATION_PROVISIONING_PROFILE"],
        ] as const) {
            const component = signing.find(value => value.bundleID === bundleID);
            if (!component) throw new Error(`Missing App Store profile for ${bundleID}.`);
            secrets.push([secret, Buffer.from(await Bun.file(component.profile.path).arrayBuffer()).toString("base64")]);
        }
        for (const [name, input] of secrets)
            await command(["gh", "secret", "set", name, "--repo", repository], { input });
        for (const [name, value] of [
            ["MOBILE_SIGNING_IDENTITY", host.identity.fingerprint],
            ["APP_STORE_CONNECT_APP_ID", appID],
        ] as const) await command(["gh", "variable", "set", name, "--repo", repository, "--body", value]);
        console.log(`TestFlight signing configured for ${repository}. Reuses the existing NOTARY_APP_PASSWORD secret.`);
    });
}

if (import.meta.main) await main(async () => {
    process.umask(0o077);
    const [identity, appID, repository, extra] = process.argv.slice(2);
    if (!identity || !/^[a-f\d]{40}$/i.test(identity) || !appID || !/^[1-9]\d*$/.test(appID) || extra) {
        throw new Error("Usage: bun run setup-testflight-secrets SHA1 APP_STORE_CONNECT_APP_ID [OWNER/REPO]");
    }
    const signing = await mobileSigning(true, undefined, identity);
    const repo = repository || await text(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
    await command(["gh", "auth", "status"], { quiet: true });
    const reader = Bun.spawn(["/bin/bash", join(root, "scripts/release/read-password.sh"),
        "Password to encrypt the Apple Distribution certificate export: "], {
        env: developerEnvironment, stdin: "inherit", stdout: "pipe", stderr: "inherit",
    });
    const password = await new Response(reader.stdout).text();
    const status = await reader.exited;
    if (status) throw new CommandFailure(status, "Unable to read the certificate export password.");
    await uploadTestFlightSigning(signing, appID, repo, password);
});
