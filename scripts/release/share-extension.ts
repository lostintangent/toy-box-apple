import { copyFile, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { command, plist, root, text } from "../lib.ts";

export function shareExtension(app: string) { return join(app, "Contents/PlugIns/ToyBoxShare.appex"); }

export async function embedShareExtension(bin: string, app: string, sdkVersion: string, minimumOS: string) {
    const extension = shareExtension(app);
    await rm(extension, { recursive: true, force: true });
    await mkdir(join(extension, "Contents/MacOS"), { recursive: true });
    const binary = join(extension, "Contents/MacOS/ToyBoxShare");
    await copyFile(join(bin, "ToyBoxShare"), binary);
    await copyFile(join(root, "Resources/ShareExtension-Info.plist"), join(extension, "Contents/Info.plist"));
    await command(["xcrun", "vtool", "-set-build-version", "macos", minimumOS, sdkVersion,
        "-replace", "-output", binary, binary]);
}

export async function configureShareExtension(app: string) {
    const appNode = Bun.XML.parse(await Bun.file(join(app, "Contents/Info.plist")).text(), { compact: false });
    const path = join(shareExtension(app), "Contents/Info.plist");
    const extensionNode = Bun.XML.parse(await Bun.file(path).text(), { compact: false });
    const children = (node: Bun.XML.Node) => node.children.filter((child): child is Bun.XML.Node =>
        typeof child !== "string" && "name" in child);
    const dictionary = (node: Bun.XML.Node) => {
        const dict = children(node).find(child => child.name === "dict");
        if (!dict) throw new Error("The app and Share extension require plist dictionaries.");
        return children(dict);
    };
    const appKeys = dictionary(appNode), extensionKeys = dictionary(extensionNode);
    for (const key of ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]) {
        const source = appKeys[appKeys.findIndex(node => node.name === "key" && node.children.join("") === key) + 1];
        const target = extensionKeys[extensionKeys.findIndex(node => node.name === "key" && node.children.join("") === key) + 1];
        if (source?.name !== "string" || target?.name !== "string") throw new Error(`Missing bundle metadata: ${key}.`);
        target.children = [source.children.join("") + (key === "CFBundleIdentifier" ? ".share" : "")];
    }
    await Bun.write(path, `<?xml version="1.0" encoding="UTF-8"?>\n${Bun.XML.stringify(extensionNode)}\n`);
}

export async function validateShareExtension(app: string) {
    const extension = shareExtension(app);
    const info = join(extension, "Contents/Info.plist");
    const appInfo = join(app, "Contents/Info.plist");
    for (const key of ["CFBundleVersion", "CFBundleShortVersionString"]) {
        if (await plist(info, [`Print :${key}`]) !== await plist(appInfo, [`Print :${key}`])) {
            throw new Error(`Share extension ${key} must match its containing app.`);
        }
    }
    if (await plist(info, ["Print :CFBundleIdentifier"]) !== `${await plist(appInfo, ["Print :CFBundleIdentifier"])}.share`
        || await plist(info, ["Print :NSExtension:NSExtensionPointIdentifier"]) !== "com.apple.share-services") {
        throw new Error("The Share extension identity or extension point is invalid.");
    }
    const binary = join(extension, "Contents/MacOS/ToyBoxShare");
    if (await text(["xcrun", "lipo", "-archs", binary]) !== "arm64") {
        throw new Error("The Share extension must contain only arm64.");
    }
    const versions = await text(["xcrun", "vtool", "-show-build", binary]);
    const sdks = [...versions.matchAll(/^\s*sdk\s+(\S+)/gm)].map(match => match[1]);
    if (!sdks.length || sdks.some(version => !/^\d+(?:\.\d+)*$/.test(version) || Number(version.split(".")[0]) < 27)) {
        throw new Error("The Share extension requires a macOS SDK 27 or later stamp.");
    }
    await command(["codesign", "--verify", "--strict", extension]);
    const display = await command(["codesign", "--display", "--verbose=4", extension], { quiet: true });
    if (!/flags=.*runtime/.test(display.stdout.toString() + display.stderr.toString())) {
        throw new Error("The Share extension signature is missing hardened runtime.");
    }
    const entitlements = await text(["codesign", "--display", "--entitlements", "-", "--xml", extension]);
    const parsed = Bun.XML.parse(entitlements) as { plist?: { dict?: { key?: string; true?: unknown } } };
    if (parsed.plist?.dict?.key !== "com.apple.security.app-sandbox"
        || !Object.hasOwn(parsed.plist.dict, "true")) {
        throw new Error("The Share extension must have only the App Sandbox entitlement.");
    }
}
