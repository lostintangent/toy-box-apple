import { basename, join, resolve } from "node:path";
import { command, main, releaseTag, repositoryURL, required, root } from "../../shared/lib/index.ts";
import { sparkleTools } from "./sparkle-tools.ts";
import { appcastItems } from "./xml.ts";
import { releaseChangelog } from "../../shared/release-notes.ts";
import { version } from "../../shared/lib/build-version.ts";

export async function checkVersion(current: string, previous?: string) {
    const build = version(current);
    if (!previous) return;
    const items = appcastItems(await Bun.file(previous).text());
    if (!items.length) throw new Error("The published appcast has no build numbers.");
    for (const item of items) {
        const value = item.sparkle("version") ?? item.child("enclosure")?.sparkleAttribute("version");
        if (value === undefined) throw new Error("A published update has no build number.");
        const published = version(value);
        const difference = build.map((part, index) => part - published[index]).find(part => part !== 0) ?? 0;
        if (difference <= 0) throw new Error(`Build ${current} must be newer than every published update.`);
    }
}

export async function releaseNotes(tag: string, repository = root) {
    releaseTag(tag);
    return (await releaseChangelog(tag, join(repository, "CHANGELOG.md"))).notes;
}

export async function generateAppcast(tag: string, repository = root) {
    releaseTag(tag);
    const noteContents = await releaseNotes(tag, repository);
    const output = resolve(process.env.OUTPUT_DIR || join(root, "dist"));
    const archive = join(output, `ToyBox-${tag.slice(1)}-arm64.zip`);
    if (!Bun.file(archive).size) throw new Error(`A notarized release archive is required: ${archive}`);
    const build = required("BUILD_NUMBER");
    const keyFile = process.env.SPARKLE_ED_KEY_FILE || "-";
    const input = keyFile === "-" ? required("SPARKLE_ED_PRIVATE_KEY") : undefined;
    if (keyFile !== "-" && !Bun.file(keyFile).size) throw new Error("The update signing key file is missing.");
    const tools = await sparkleTools();
    const prefix = process.env.DOWNLOAD_URL_PREFIX || `${repositoryURL}/releases/download/${tag}/`;
    async function signingTool(name: string, args: string[]) {
        await command([join(tools, "bin", name), "--ed-key-file", keyFile, ...args], { input });
    }
    const notes = archive.replace(/\.zip$/, ".txt");
    await Bun.write(notes, noteContents);
    await signingTool("generate_appcast", ["--download-url-prefix", prefix, "--embed-release-notes",
        "--maximum-deltas", "0", "--link", repositoryURL, "-o", join(output, "appcast.xml"), output]);
    const items = appcastItems(await Bun.file(join(output, "appcast.xml")).text());
    if (items.length !== 1) throw new Error("The release feed must contain exactly one update.");
    const item = items[0];
    const enclosure = item.child("enclosure");
    if (!enclosure) throw new Error("The release feed has no update enclosure.");
    if (enclosure.attribute("url") !== prefix + basename(archive)
        || enclosure.attribute("length") !== String(Bun.file(archive).size)) {
        throw new Error("The appcast URL or archive length does not match the release.");
    }
    for (const [key, expected] of [
        ["version", build], ["shortVersionString", tag.slice(1)], ["minimumSystemVersion", "27.0"],
    ]) if (item.sparkle(key) !== expected) throw new Error(`The appcast ${key} does not match the release.`);
    const hardware = item.sparkle("hardwareRequirements");
    if (hardware !== undefined && hardware !== "arm64") throw new Error("The appcast has an unsupported hardware requirement.");
    const signature = enclosure.sparkleAttribute("edSignature") || "";
    if (!/^[A-Za-z0-9+/]{86}==$/.test(signature) || Buffer.from(signature, "base64").length !== 64) {
        throw new Error("The archive is missing a valid EdDSA signature.");
    }
    await signingTool("sign_update", ["--verify", archive, signature]);
    console.log(`Update feed with verified archive signature: ${join(output, "appcast.xml")}`);
}

if (import.meta.main) await main(async () => {
    const [tagOrCheck, current, previous, extra] = process.argv.slice(2);
    if (tagOrCheck === "--check-build") {
        if (!current || extra) throw new Error("Usage: appcast.ts --check-build BUILD [PREVIOUS_APPCAST]");
        await checkVersion(current, previous);
    } else {
        if (current) throw new Error("Usage: appcast.ts vX.Y.Z");
        await generateAppcast(releaseTag(tagOrCheck));
    }
});
