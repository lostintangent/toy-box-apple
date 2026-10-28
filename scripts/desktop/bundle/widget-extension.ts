import { copyFile, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { command, plist, root, text } from "../../shared/support/lib.ts";
import { configureExtension } from "./share-extension.ts";

export const widgetAppGroup = "RHFNBL7EG4.dev.toybox.desktop";
export const widgetGroupKey = "ToyBoxWidgetAppGroup";
export function widgetExtension(app: string) { return join(app, "Contents/PlugIns/ToyBoxWidget.appex"); }

function record(value: unknown): Record<string, unknown> | undefined {
    return value !== null && typeof value === "object" && !Array.isArray(value)
        ? value as Record<string, unknown> : undefined;
}

export function validateControlMetadata(contents: string) {
    const metadata = record(JSON.parse(contents));
    const intent = record(record(metadata?.actions)?.OpenToyBoxControlIntent);
    const parameters = intent?.parameters;
    const target = Array.isArray(parameters) && parameters.length === 1 ? record(parameters[0]) : undefined;
    const enumeration = record(record(record(target?.valueType)?.linkEnumeration)?.wrapper);
    const destinations = Array.isArray(metadata?.enums)
        ? metadata.enums.map(record).find(value => value?.identifier === "ToyBoxControlDestination") : undefined;
    const cases = Array.isArray(destinations?.cases) ? destinations.cases.map(value => record(value)?.identifier) : [];
    if (intent?.fullyQualifiedTypeName !== "ToyBoxControlIntents.OpenToyBoxControlIntent"
        || intent.openAppWhenRun !== true || intent.supportedModes !== 2 || intent.isDiscoverable !== false
        || target?.name !== "target" || target.isOptional !== false
        || enumeration?.identifier !== "ToyBoxControlDestination"
        || destinations?.fullyQualifiedTypeName !== "ToyBoxControlIntents.ToyBoxControlDestination"
        || JSON.stringify(cases.toSorted()) !== JSON.stringify(["needsYou", "quickSend"])) {
        throw new Error("Control metadata requires the shared foreground intent and both typed destinations.");
    }
}

export function validateControlExports(symbols: string, isWidget: boolean) {
    const required = [
        "ToyBoxControlIntents.OpenToyBoxControlIntent : AppIntents.AppIntent",
        ...(isWidget ? [
            "ToyBoxWidget.ToyBoxWidgets : SwiftUI.WidgetBundle",
            "ToyBoxWidget.QuickSendControl : SwiftUI.ControlWidget",
            "ToyBoxWidget.NeedsYouControl : SwiftUI.ControlWidget",
        ] : []),
    ];
    for (const name of required) {
        if (!symbols.includes(`protocol conformance descriptor for ${name} in `)) {
            throw new Error(`Missing compiled control conformance: ${name}.`);
        }
    }
}

export async function embedWidgetExtension(bin: string, app: string, sdkVersion: string, minimumOS: string) {
    const extension = widgetExtension(app);
    await rm(extension, { recursive: true, force: true });
    await mkdir(join(extension, "Contents/MacOS"), { recursive: true });
    const binary = join(extension, "Contents/MacOS/ToyBoxWidget");
    await copyFile(join(bin, "ToyBoxWidget"), binary);
    await copyFile(join(root, "Resources/WidgetExtension-Info.plist"), join(extension, "Contents/Info.plist"));
    await command(["xcrun", "vtool", "-set-build-version", "macos", minimumOS, sdkVersion,
        "-replace", "-output", binary, binary]);
}

async function groupMetadata(path: string, enabled: boolean) {
    const node = Bun.XML.parse(await Bun.file(path).text(), { compact: false });
    const dict = node.children.find((child): child is Bun.XML.Node =>
        typeof child !== "string" && "name" in child && child.name === "dict");
    if (!dict) throw new Error("The widget and host require plist dictionaries.");
    const elements = dict.children.filter((child): child is Bun.XML.Node =>
        typeof child !== "string" && "name" in child);
    const index = elements.findIndex(child => child.name === "key" && child.children.join("") === widgetGroupKey);
    if (index >= 0) elements.splice(index, 2);
    if (enabled) elements.push(
        Bun.XML.parse(`<key>${widgetGroupKey}</key>`, { compact: false }),
        Bun.XML.parse(`<string>${widgetAppGroup}</string>`, { compact: false }),
    );
    dict.children = elements;
    await Bun.write(path, `<?xml version="1.0" encoding="UTF-8"?>\n${Bun.XML.stringify(node)}\n`);
}

export async function configureWidgetExtension(app: string, production: boolean) {
    await configureExtension(app, widgetExtension(app), ".widget");
    for (const path of [app, widgetExtension(app)]) {
        await groupMetadata(join(path, "Contents/Info.plist"), production);
    }
}

export async function validateWidgetExtension(app: string) {
    const extension = widgetExtension(app), info = join(extension, "Contents/Info.plist");
    const host = join(app, "Contents/Info.plist");
    for (const key of ["CFBundleVersion", "CFBundleShortVersionString"]) {
        if (await plist(info, [`Print :${key}`]) !== await plist(host, [`Print :${key}`])) {
            throw new Error(`Widget extension ${key} must match its containing app.`);
        }
    }
    if (await plist(info, ["Print :CFBundleIdentifier"]) !== `${await plist(host, ["Print :CFBundleIdentifier"])}.widget`
        || await plist(info, ["Print :NSExtension:NSExtensionPointIdentifier"]) !== "com.apple.widgetkit-extension") {
        throw new Error("The widget identity or extension point is invalid.");
    }
    const binary = join(extension, "Contents/MacOS/ToyBoxWidget");
    if (await text(["xcrun", "lipo", "-archs", binary]) !== "arm64") {
        throw new Error("The widget extension must contain only arm64.");
    }
    const versions = await text(["xcrun", "vtool", "-show-build", binary]);
    const sdks = [...versions.matchAll(/^\s*sdk\s+(\S+)/gm)].map(match => match[1]);
    if (!sdks.length || sdks.some(version => !/^\d+(?:\.\d+)*$/.test(version) || Number(version.split(".")[0]) < 27)) {
        throw new Error("The widget extension requires a macOS SDK 27 or later stamp.");
    }
    for (const bundle of [app, extension]) {
        validateControlMetadata(await Bun.file(join(bundle, "Contents/Resources/Metadata.appintents/extract.actionsdata")).text());
        const executable = bundle === app ? "ToyBoxDesktop" : "ToyBoxWidget";
        const symbols = await text(["xcrun", "swift-demangle"], {
            input: await text(["xcrun", "nm", "-U", join(bundle, "Contents/MacOS", executable)]),
        });
        validateControlExports(symbols, bundle === extension);
    }
    await command(["codesign", "--verify", "--strict", extension]);
    const display = await command(["codesign", "--display", "--verbose=4", extension], { quiet: true });
    if (!/flags=.*runtime/.test(display.stdout.toString() + display.stderr.toString())) {
        throw new Error("The widget extension signature is missing hardened runtime.");
    }
    const entitlements = await text(["codesign", "--display", "--entitlements", "-", "--xml", extension]);
    const parsed = Bun.XML.parse(entitlements) as {
        plist?: { dict?: { key?: string | string[]; true?: unknown; array?: { string?: string } } };
    };
    const dict = parsed.plist?.dict;
    const keys = typeof dict?.key === "string" ? [dict.key] : dict?.key;
    const production = (await Bun.file(host).text()).includes(`<string>${widgetAppGroup}</string>`);
    const expected = ["com.apple.security.app-sandbox", ...(production ? ["com.apple.security.application-groups"] : [])];
    if (!dict || !Object.hasOwn(dict, "true") || JSON.stringify(keys?.toSorted()) !== JSON.stringify(expected.toSorted())
        || (production && dict.array?.string !== widgetAppGroup)) {
        throw new Error("The widget must be sandboxed with only its production app group, when enabled.");
    }
    if (production) {
        if (!(display.stdout.toString() + display.stderr.toString()).includes(`TeamIdentifier=${widgetAppGroup.split(".")[0]}`)) {
            throw new Error("The widget signing team must own its app group.");
        }
        const hostEntitlements = Bun.XML.parse(await text(["codesign", "--display", "--entitlements", "-", "--xml", app])) as {
            plist?: { dict?: { key?: string[]; array?: { string?: string } } };
        };
        if (hostEntitlements.plist?.dict?.array?.string !== widgetAppGroup
            || JSON.stringify(hostEntitlements.plist.dict.key?.toSorted()) !== JSON.stringify([
                "com.apple.security.application-groups", "com.apple.security.device.audio-input",
            ])) {
            throw new Error("The host must have only audio-input and its widget app group.");
        }
        for (const path of [host, info]) {
            if (await plist(path, [`Print :${widgetGroupKey}`]) !== widgetAppGroup) {
                throw new Error("The host and widget must use the same app group.");
            }
        }
    }
}
