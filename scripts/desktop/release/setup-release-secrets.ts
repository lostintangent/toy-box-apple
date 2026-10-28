import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { CommandFailure, command, developerEnvironment, main, root, temporary, text } from "../../shared/lib.ts";

if (import.meta.main) await main(async () => {
    process.umask(0o077);
    const [identity, appleID, teamID, repository, extra] = process.argv.slice(2);
    if (!identity || !appleID || !teamID || extra) {
        throw new Error("Usage: bun run setup-release-secrets SHA1 APPLE_ID TEAM_ID [OWNER/REPO]");
    }
    if (!/^[a-fA-F0-9]{40}$/.test(identity)) throw new Error("Identity must be a 40-digit SHA-1.");
    const repo = repository || await text(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
    await command(["gh", "auth", "status"], { quiet: true });
    await temporary("toy-box-release-secrets.", async directory => {
        // Bash's read -rs keeps the terminal's password handling small and auditable.
        const reader = Bun.spawn(["/bin/bash", join(root, "scripts/shared/read-password.sh"),
            `App-specific password for ${appleID}: `], {
            env: developerEnvironment, stdin: "inherit", stdout: "pipe", stderr: "inherit",
        });
        const password = await new Response(reader.stdout).text();
        const status = await reader.exited;
        if (status) throw new CommandFailure(status, "Unable to read the app-specific password.");
        const exportPassword = randomBytes(48).toString("base64");
        const identityFile = join(directory, "identity.p12");
        const chainFile = join(directory, "issuer-chain.pem");
        await command(["xcrun", "swift", join(root, "scripts/shared/export-signing-identity.swift"),
            identity, identityFile, chainFile], { env: { P12_PASSWORD: exportPassword } });
        await command(["xcrun", "notarytool", "store-credentials", "toy-box-channels-notary",
            "--apple-id", appleID, "--team-id", teamID, "--password", password]);
        for (const [name, input] of [
            ["MACOS_SIGNING_CERTIFICATE", Buffer.from(await Bun.file(identityFile).arrayBuffer()).toString("base64")],
            ["MACOS_SIGNING_PASSWORD", exportPassword], ["NOTARY_APP_PASSWORD", password],
        ]) await command(["gh", "secret", "set", name, "--repo", repo], { input });
        await command(["gh", "variable", "set", "MACOS_SIGNING_CERTIFICATE_CHAIN", "--repo", repo,
            "--body", await Bun.file(chainFile).text()]);
        await command(["gh", "variable", "set", "MACOS_SIGNING_IDENTITY", "--repo", repo, "--body", identity.toUpperCase()]);
        console.log(`Release secrets configured for ${repo}. Local notarization profile: toy-box-channels-notary.`);
    });
});
