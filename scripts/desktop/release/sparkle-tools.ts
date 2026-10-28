import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { command, executable, main, root } from "../../shared/lib/index.ts";

export async function sparkleTools() {
    const version = "2.10.0";
    const checksum = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c";
    const cache = resolve(process.env.SPARKLE_TOOLS_DIR || join(root, ".build/sparkle-tools", version));
    if ((await Promise.all(["generate_appcast", "generate_keys", "sign_update"]
        .map(name => executable(join(cache, "bin", name))))).every(Boolean)) return cache;
    await mkdir(cache, { recursive: true });
    const temporary = await mkdtemp(join(cache, ".download."));
    try {
        const archive = join(temporary, "Sparkle.tar.xz");
        await command(["curl", "--fail", "--silent", "--show-error", "--location",
            `https://github.com/sparkle-project/Sparkle/releases/download/${version}/Sparkle-${version}.tar.xz`,
            "-o", archive]);
        const actual = new Bun.CryptoHasher("sha256").update(await Bun.file(archive).arrayBuffer()).digest("hex");
        if (actual !== checksum) throw new Error("Sparkle tools checksum does not match the pinned release.");
        await command(["tar", "-xJf", archive, "-C", cache]);
    } finally { await rm(temporary, { recursive: true, force: true }); }
    return cache;
}

if (import.meta.main) await main(async () => { console.log(await sparkleTools()); });
