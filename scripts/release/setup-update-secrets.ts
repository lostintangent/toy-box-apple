import { join } from "node:path";
import { bundleIdentity, command, main, temporary, text } from "../lib.ts";
import { sparkleTools } from "./sparkle-tools.ts";

if (import.meta.main) await main(async () => {
    process.umask(0o077);
    const [repository, extra] = process.argv.slice(2);
    if (extra) throw new Error("Usage: bun run setup-update-secrets [OWNER/REPO]");
    const repo = repository || await text(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
    await command(["gh", "auth", "status"], { quiet: true });
    const tools = await sparkleTools();
    await temporary("toy-box-update-secrets.", async directory => {
        const args = [join(tools, "bin/generate_keys"), "--account", bundleIdentity];
        await command(args);
        const publicKey = await text([...args, "-p"]);
        if (!/^[A-Za-z0-9+/]{43}=$/.test(publicKey)) throw new Error("Sparkle returned an invalid public key.");
        const key = join(directory, "private-key");
        await command([...args, "-x", key]);
        await command(["gh", "secret", "set", "SPARKLE_ED_PRIVATE_KEY", "--repo", repo],
            { input: new Uint8Array(await Bun.file(key).arrayBuffer()) });
        await command(["gh", "variable", "set", "SPARKLE_ED_PUBLIC_KEY", "--repo", repo, "--body", publicKey]);
        console.log(`Update signing configured for ${repo}. If this key is lost, rerun setup on another Mac; a Developer ID for the same app and Apple team can authorize its replacement.`);
    });
});
