import { rm } from "node:fs/promises";
import { join } from "node:path";
import { command } from "../lib.ts";
import { shareExtension } from "../release/share-extension.ts";
import { widgetExtension, widgetGroupKey } from "../release/widget-extension.ts";

export async function isolateIntegrations(app: string) {
    const info = join(app, "Contents/Info.plist");
    for (const key of ["NSServices", "CFBundleURLTypes", "CFBundleDocumentTypes", widgetGroupKey]) {
        const existing = await command(["/usr/libexec/PlistBuddy", "-c", `Print :${key}`, info],
            { quiet: true, allowFailure: true });
        if (!existing.exitCode) await command(["/usr/libexec/PlistBuddy", "-c", `Delete :${key}`, info], { quiet: true });
        else if (!existing.stderr.toString().includes("Does Not Exist")) {
            throw new Error(existing.stderr.toString() || `Could not inspect ${key}.`);
        }
    }
    await rm(shareExtension(app), { recursive: true, force: true });
    await rm(widgetExtension(app), { recursive: true, force: true });
}
