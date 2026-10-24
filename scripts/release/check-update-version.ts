import { appcastItems } from "./xml.ts";
import { main } from "../lib.ts";

export function version(value: string) {
    if (!/^[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}$/.test(value)) {
        throw new Error(`Invalid Apple build number: ${JSON.stringify(value)}`);
    }
    const parts = value.split(".").map(Number);
    while (parts.length < 3) parts.push(0);
    return parts;
}

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

if (import.meta.main) await main(async () => {
    const [current, previous, extra] = process.argv.slice(2);
    if (!current || extra) throw new Error("Usage: bun run check-update-version BUILD [PREVIOUS_APPCAST]");
    try { await checkVersion(current, previous); }
    catch (error) {
        throw new Error(`Cannot publish update: ${error instanceof Error ? error.message : String(error)}`);
    }
});
