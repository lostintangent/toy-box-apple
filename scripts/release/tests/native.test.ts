import { expect, test } from "bun:test";
import { lstat, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { command, plist, root, temporary, text } from "../../lib.ts";
import { appcastItems } from "../xml.ts";

const hasBundle = process.platform === "darwin" && Boolean(process.env.TOY_BOX_BUNDLE);
const hasTools = hasBundle && Boolean(process.env.SPARKLE_TOOLS_DIR);

test.skipIf(!hasBundle)("native bundle: arm64-only, strictly signed and no development updater", async () => {
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
    for (const path of [join(app, "Contents/MacOS/ToyBoxDesktop"), join(framework, "Sparkle"),
        join(framework, "Autoupdate"), join(framework, "Updater.app/Contents/MacOS/Updater")]) {
        expect(await text(["xcrun", "lipo", "-archs", path])).toBe("arm64");
    }
    for (const path of [join(framework, "Autoupdate"), join(framework, "Updater.app"), framework, app]) {
        await command(["codesign", "--verify", "--strict", path]);
    }
});

test.skipIf(!hasTools)("native appcast: ephemeral file key signs archive/feed and rejects tampering", async () => {
    await temporary("toy-box-native-appcast.", async directory => {
        const key = join(directory, "throwaway-key.txt");
        const publicKey = await text(["xcrun", "swift", "-e", `
            import CryptoKit
            import Foundation
            let key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            print(key.publicKey.rawRepresentation.base64EncodedString())
        `, key]);
        const app = join(directory, "Toy Box Desktop.app");
        await command(["ditto", process.env.TOY_BOX_BUNDLE!, app]);
        await plist(join(app, "Contents/Info.plist"), ["Set :CFBundleVersion 200.1", "Set :CFBundleShortVersionString 0.2.0",
            "Add :SUFeedURL string http://127.0.0.1:3298/appcast.xml", `Add :SUPublicEDKey string ${publicKey}`,
            "Add :SURequireSignedFeed bool true", "Add :SUVerifyUpdateBeforeExtraction bool true"]);
        await command([process.execPath, join(root, "scripts/release/sign-app.ts"), app]);
        const output = join(directory, "dist");
        await mkdir(output);
        const archive = join(output, "ToyBoxDesktop-0.2.0-arm64.zip");
        await command(["ditto", "-c", "-k", "--keepParent", app, archive]);
        const env = {
            HOME: directory, CFFIXED_USER_HOME: directory, SPARKLE_ED_KEY_FILE: key, SPARKLE_ED_PRIVATE_KEY: "",
            OUTPUT_DIR: output, BUILD_NUMBER: "200.1", DOWNLOAD_URL_PREFIX: "http://127.0.0.1:3298/",
        };
        await command([process.execPath, join(root, "scripts/release/generate-appcast.ts"), "v0.2.0"], { env });
        const feed = join(output, "appcast.xml");
        const signature = appcastItems(await Bun.file(feed).text())[0].child("enclosure")?.sparkleAttribute("edSignature");
        expect(signature).toBeDefined();
        const bytes = await Bun.file(archive).arrayBuffer();
        await Bun.write(archive, Buffer.concat([Buffer.from(bytes), Buffer.from("tampered")]));
        const verify = [join(process.env.SPARKLE_TOOLS_DIR!, "bin/sign_update"), "--ed-key-file", key, "--verify"];
        expect((await command([...verify, archive, signature!], { env, quiet: true, allowFailure: true })).exitCode).not.toBe(0);
        const original = await Bun.file(feed).text();
        const tampered = original.replaceAll("0.2.0", "9.2.0");
        expect(tampered).not.toBe(original);
        await Bun.write(feed, tampered);
        expect((await command([...verify, feed], { env, quiet: true, allowFailure: true })).exitCode).not.toBe(0);
    });
}, 120_000);
