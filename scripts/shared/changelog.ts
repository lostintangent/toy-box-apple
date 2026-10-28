import { mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { main, root } from "./lib.ts";

export function releaseContext(tag: string) {
    const match = /^(mobile-)?v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(tag);
    if (!match) throw new Error("Release tag must be vX.Y.Z (Mac) or mobile-vX.Y.Z (iPhone).");
    return { platform: match[1] ? "iPhone" : "Mac", version: match.slice(2).join(".") };
}

export function changelogEntry(source: string, tag: string) {
    const { platform, version } = releaseContext(tag);
    const lines = source.replaceAll("\r\n", "\n").split("\n");
    const heading = `## ${platform} ${version}`;
    const starts = lines.flatMap((line, index) => line.trimEnd() === heading ? [index + 1] : []);
    if (starts.length !== 1) throw new Error(`CHANGELOG.md needs exactly one "${heading}" entry.`);
    const start = starts[0]!;
    const next = lines.findIndex((line, index) => index >= start && /^## /.test(line));
    const notes = lines.slice(start, next < 0 ? undefined : next).join("\n").trim();
    if (!notes || !/[a-z\d]/i.test(notes)) throw new Error(`The "${heading}" changelog entry is empty.`);
    return { platform, version, notes: notes + "\n" };
}

export async function releaseChangelog(tag: string, path = join(root, "CHANGELOG.md")) {
    const entry = changelogEntry(await Bun.file(path).text(), tag);
    if (entry.platform === "iPhone" && process.env.MOBILE_VERSION !== undefined
        && process.env.MOBILE_VERSION !== entry.version) {
        throw new Error(`MOBILE_VERSION must match ${tag}: expected ${entry.version}.`);
    }
    return entry;
}

if (import.meta.main) await main(async () => {
    const [tag, destination, extra] = process.argv.slice(2);
    if (!tag || extra) throw new Error("Usage: bun run release-notes TAG [OUTPUT.md]");
    const entry = await releaseChangelog(tag);
    if (destination) {
        await mkdir(dirname(destination), { recursive: true });
        await Bun.write(destination, entry.notes);
        console.log(entry.version);
    } else process.stdout.write(entry.notes);
});
