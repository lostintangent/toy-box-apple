import { rm } from "node:fs/promises";
import { join } from "node:path";
import { command, plist } from "../../shared/lib/index.ts";
import { shareExtension } from "../bundle/share-extension.ts";
import { widgetExtension, widgetGroupKey } from "../bundle/widget-extension.ts";

const dataFolderKey = "ToyBoxDataFolder";

/** Keeps a side-by-side copy away from the installed app's system integrations and saved writing.
 * Set the copy's bundle identifier first, since it names the copy's drafts and outbox folder. */
export async function isolateIntegrations(app: string) {
    const info = join(app, "Contents/Info.plist");
    for (const key of ["NSServices", "CFBundleURLTypes", "CFBundleDocumentTypes", widgetGroupKey, dataFolderKey]) {
        const existing = await command(["/usr/libexec/PlistBuddy", "-c", `Print :${key}`, info],
            { quiet: true, allowFailure: true });
        if (!existing.exitCode) await command(["/usr/libexec/PlistBuddy", "-c", `Delete :${key}`, info], { quiet: true });
        else if (!existing.stderr.toString().includes("Does Not Exist")) {
            throw new Error(existing.stderr.toString() || `Could not inspect ${key}.`);
        }
    }
    const identifier = await plist(info, ["Print :CFBundleIdentifier"]);
    await plist(info, [`Add :${dataFolderKey} string ${identifier}`]);
    await rm(shareExtension(app), { recursive: true, force: true });
    await rm(widgetExtension(app), { recursive: true, force: true });
}
