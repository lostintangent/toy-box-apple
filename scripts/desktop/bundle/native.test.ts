import { expect, test } from "bun:test";
import { lstat, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { command, root, temporary, text } from "../../shared/lib.ts";
import { configureReleaseMetadata } from "../release/release.ts";
import { appcastItems } from "../sparkle/xml.ts";
import { shareExtension, validateShareExtension } from "./share-extension.ts";
import { validateWidgetExtension, widgetExtension } from "./widget-extension.ts";

const hasBundle = process.platform === "darwin" && Boolean(process.env.TOY_BOX_BUNDLE);
const hasTools = hasBundle && Boolean(process.env.SPARKLE_TOOLS_DIR);

// Independent native commands must not consume one shared five-second test deadline.
test.skipIf(!hasBundle)("native bundle: share extension", async () => {
    await validateShareExtension(process.env.TOY_BOX_BUNDLE!);
});

test.skipIf(!hasBundle)("native bundle: widget extension", async () => {
    await validateWidgetExtension(process.env.TOY_BOX_BUNDLE!);
});

test.skipIf(!hasBundle)("native bundle: resources and no development updater", async () => {
    const app = process.env.TOY_BOX_BUNDLE!;
    const framework = join(app, "Contents/Frameworks/Sparkle.framework");
    const info: Record<string, unknown> = JSON.parse(await text(["plutil", "-convert", "json", "-o", "-", join(app, "Contents/Info.plist")]));
    expect(info.SUFeedURL).toBeUndefined(); expect(info.SUPublicEDKey).toBeUndefined();
    expect(info.CFBundleIconFile).toBe("AppIcon"); expect(info.CFBundleIconName).toBe("AppIcon");
    for (const name of ["AppIcon.icns", "Assets.car"]) {
        expect(Bun.file(join(app, "Contents/Resources", name)).size).toBeGreaterThan(0);
    }
    expect((await lstat(join(framework, "Versions/Current"))).isSymbolicLink()).toBe(true);
    expect(await Bun.file(join(app, "Contents/Resources/Sparkle-LICENSE")).exists()).toBe(true);
    for (const component of ["Headers", "PrivateHeaders", "Modules", "XPCServices"]) {
        expect(await lstat(join(framework, component)).then(() => true, error => {
            if (error.code === "ENOENT") return false;
            throw error;
        })).toBe(false);
        expect(await Bun.file(join(framework, "Versions/Current", component)).exists()).toBe(false);
    }
});

for (const relative of ["Contents/MacOS/ToyBoxDesktop",
    join(shareExtension("."), "Contents/MacOS/ToyBoxShare"),
    "Contents/Frameworks/Sparkle.framework/Sparkle",
    join(widgetExtension("."), "Contents/MacOS/ToyBoxWidget"),
    "Contents/Frameworks/Sparkle.framework/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Updater.app/Contents/MacOS/Updater"]) {
    test.skipIf(!hasBundle)(`native bundle architecture: ${relative}`, async () => {
        const path = join(process.env.TOY_BOX_BUNDLE!, relative);
        expect(await text(["xcrun", "lipo", "-archs", path])).toBe("arm64");
    });
}

for (const relative of ["Contents/Frameworks/Sparkle.framework/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Updater.app", "Contents/Frameworks/Sparkle.framework", "."]) {
    test.skipIf(!hasBundle)(`native bundle strict signature: ${relative}`, async () => {
        const path = join(process.env.TOY_BOX_BUNDLE!, relative);
        await command(["codesign", "--verify", "--strict", path]);
    });
}

test.skipIf(!hasTools)("native appcast: ephemeral file key signs the archive and rejects archive tampering", async () => {
    await temporary("toy-box-native-appcast.", async directory => {
        const key = join(directory, "throwaway-key.txt");
        const publicKey = await text(["xcrun", "swift", "-e", `
            import CryptoKit
            import Foundation
            let key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            print(key.publicKey.rawRepresentation.base64EncodedString())
        `, key]);
        const app = join(directory, "Toy Box.app");
        await command(["ditto", process.env.TOY_BOX_BUNDLE!, app]);
        await configureReleaseMetadata(app, "0.2.0", "200.1", publicKey);
        const info: Record<string, unknown> = JSON.parse(await text(["plutil", "-convert", "json", "-o", "-", join(app, "Contents/Info.plist")]));
        expect(info.SUPublicEDKey).toBe(publicKey);
        expect(info.SUEnableAutomaticChecks).toBe(true);
        expect(info.SUVerifyUpdateBeforeExtraction).toBeUndefined();
        expect(info.SURequireSignedFeed).toBeUndefined();
        await command([process.execPath, join(root, "scripts/desktop/bundle/sign-app.ts"), app]);
        const output = join(directory, "dist");
        await mkdir(output);
        const archive = join(output, "ToyBox-0.2.0-arm64.zip");
        await command(["ditto", "-c", "-k", "--keepParent", app, archive]);
        const env = {
            HOME: directory, CFFIXED_USER_HOME: directory, SPARKLE_ED_KEY_FILE: key, SPARKLE_ED_PRIVATE_KEY: "",
            OUTPUT_DIR: output, BUILD_NUMBER: "200.1", DOWNLOAD_URL_PREFIX: "http://127.0.0.1:3298/",
        };
        await Bun.write(join(directory, "CHANGELOG.md"), "## Mac 0.2.0\n\nNative appcast signing fixture.\n");
        await command([process.execPath, "-e",
            `const { generateAppcast } = await import(${JSON.stringify(new URL("../sparkle/generate-appcast.ts", import.meta.url).href)}); await generateAppcast("v0.2.0", ${JSON.stringify(directory)});`], { env });
        const feed = join(output, "appcast.xml");
        const signature = appcastItems(await Bun.file(feed).text())[0].child("enclosure")?.sparkleAttribute("edSignature");
        expect(signature).toBeDefined();
        const bytes = await Bun.file(archive).arrayBuffer();
        await Bun.write(archive, Buffer.concat([Buffer.from(bytes), Buffer.from("tampered")]));
        const verify = [join(process.env.SPARKLE_TOOLS_DIR!, "bin/sign_update"), "--ed-key-file", key, "--verify"];
        expect((await command([...verify, archive, signature!], { env, quiet: true, allowFailure: true })).exitCode).not.toBe(0);
        expect(await Bun.file(feed).text()).not.toContain("<!-- sparkle-signatures:");
    });
}, 120_000);
