import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmod, lstat, mkdir, rm, symlink } from "node:fs/promises";
import { join } from "node:path";
import { bundleIdentity, root } from "../../shared/lib.ts";
import { FakeHarness } from "../../shared/test-helpers.ts";
import { configureShareExtension } from "./share-extension.ts";
import { configureWidgetExtension, widgetAppGroup, widgetExtension } from "./widget-extension.ts";

describe("Sparkle packaging without credentials", () => {
    let fake: FakeHarness;
    let app: string, framework: string, source: string, license: string;
    beforeEach(async () => {
        fake = await FakeHarness.create();
        app = join(fake.directory, "Toy Box.app");
        framework = join(app, "Contents/Frameworks/Sparkle.framework");
        await mkdir(join(app, "Contents/PlugIns/ToyBoxShare.appex/Contents"), { recursive: true });
        await Bun.write(join(app, "Contents/Info.plist"), `<plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>dev.toybox.desktop</string>
            <key>CFBundleShortVersionString</key><string>0.1.0</string>
            <key>CFBundleVersion</key><string>1</string></dict></plist>`);
        await Bun.write(join(app, "Contents/PlugIns/ToyBoxShare.appex/Contents/Info.plist"),
            await Bun.file(join(root, "Resources/ShareExtension-Info.plist")).text());
        source = join(fake.directory, "source.framework");
        const version = join(source, "Versions/B");
        await mkdir(version, { recursive: true });
        await symlink("B", join(source, "Versions/Current"));
        for (const component of ["Headers", "PrivateHeaders", "Modules", "XPCServices"]) {
            await mkdir(join(version, component));
            await symlink(`Versions/Current/${component}`, join(source, component));
        }
        for (const executable of ["Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater"]) {
            const path = join(version, executable);
            await mkdir(join(path, ".."), { recursive: true });
            await Bun.write(path, "fake universal executable");
        }
        await symlink("Versions/Current/Sparkle", join(source, "Sparkle"));
        license = join(fake.directory, "LICENSE.txt");
        await Bun.write(license, "Upstream license notices");
        await chmod(license, 0o444);
    });
    afterEach(async () => { await fake.dispose(); });

    test("repeat embedding preserves links and replaces a read-only license", async () => {
        for (let attempt = 0; attempt < 2; attempt++) {
            const result = await fake.script("desktop/sparkle/embed-sparkle.ts", [source, app, license]);
            expect(result.code).toBe(0);
            await chmod(join(app, "Contents/Resources/Sparkle-LICENSE"), 0o444);
        }
        expect((await lstat(join(framework, "Versions/Current"))).isSymbolicLink()).toBe(true);
        expect((await lstat(join(framework, "Sparkle"))).isSymbolicLink()).toBe(true);
        for (const component of ["Headers", "PrivateHeaders", "Modules", "XPCServices"]) {
            expect(await Bun.file(join(framework, component)).exists()).toBe(false);
            expect(await Bun.file(join(framework, "Versions/B", component)).exists()).toBe(false);
        }
        const thinned = (await fake.calls("xcrun")).filter(call => call.args.includes("-thin"));
        expect(thinned).toHaveLength(6);
        expect(thinned.every(call => JSON.stringify(call.args.slice(2, 4)) === JSON.stringify(["-thin", "arm64"]))).toBe(true);
        expect(await Bun.file(join(app, "Contents/Resources/Sparkle-LICENSE")).text()).toBe(await Bun.file(license).text());
    });
    test("production signing is inside-out with separate sandboxed extension and app entitlements", async () => {
        const options = ["--force", "--options", "runtime", "--timestamp", "--sign", "FAKE_IDENTITY"];
        const result = await fake.script("desktop/bundle/sign-app.ts", [app, ...options]);
        expect(result.code).toBe(0);
        const calls = await fake.calls("codesign");
        const signed = calls.filter(call => !call.args.includes("--verify"));
        expect(signed.map(call => call.args.at(-1))).toEqual([
            join(app, "Contents/PlugIns/ToyBoxShare.appex"),
            join(framework, "Versions/Current/Autoupdate"), join(framework, "Versions/Current/Updater.app"), framework, app,
        ]);
        expect(signed.every(call => JSON.stringify(call.args.slice(0, options.length)) === JSON.stringify(options))).toBe(true);
        expect(signed[0].args).toContain(join(root, "Resources/ShareExtension.entitlements"));
        expect(signed.slice(1, -1).every(call => !call.args.includes("--entitlements"))).toBe(true);
        expect(signed.at(-1)?.args).toContain("--entitlements");
        expect(calls.filter(call => call.args.includes("--strict"))).toHaveLength(5);
        expect(calls.some(call => call.args.includes("--deep"))).toBe(false);
    });
    test("ad-hoc signing avoids hardened runtime and never hides a signing error", async () => {
        expect((await fake.script("desktop/bundle/sign-app.ts", [app])).code).toBe(0);
        const calls = await fake.calls("codesign");
        expect(calls[0].args).toContain("runtime");
        const first = calls.find(call => call.args.at(-1) === framework && !call.args.includes("--verify"))!.args;
        expect(first).toContain("--timestamp=none");
        expect(first).not.toContain("--options");
        expect(first[first.indexOf("--sign") + 1]).toBe("-");
        await rm(fake.log);
        expect((await fake.script("desktop/bundle/sign-app.ts", [app], { FAIL_SIGN: "1" })).code).toBe(23);
        expect(await fake.calls("codesign")).toHaveLength(1);
    });
    test("extension metadata follows its container identity and release versions", async () => {
        const info = join(app, "Contents/Info.plist");
        await Bun.write(info, (await Bun.file(info).text()).replace("dev.toybox.desktop", "dev.toybox.desktop.test")
            .replace("0.1.0", "0.1.2").replace("<string>1</string>", "<string>400.2</string>"));
        await configureShareExtension(app);
        const result = await Bun.file(join(app, "Contents/PlugIns/ToyBoxShare.appex/Contents/Info.plist")).text();
        expect(result).toContain("<string>dev.toybox.desktop.test.share</string>");
        expect(result).toContain("<string>0.1.2</string>");
        expect(result).toContain("<string>400.2</string>");
    });
    test("widget signing grants the shared group only to production host and widget", async () => {
        const widget = widgetExtension(app);
        await mkdir(join(widget, "Contents"), { recursive: true });
        await Bun.write(join(widget, "Contents/Info.plist"),
            await Bun.file(join(root, "Resources/WidgetExtension-Info.plist")).text());
        const options = ["--force", "--options", "runtime", "--timestamp", "--sign", "FAKE_IDENTITY"];
        expect((await fake.script("desktop/bundle/sign-app.ts", [app, ...options])).code).toBe(0);
        let signed = (await fake.calls("codesign")).filter(call => !call.args.includes("--verify"));
        expect(signed[0].args.at(-1)).toBe(widget);
        expect(signed[0].args).toContain(join(root, "Resources/WidgetExtension.entitlements"));
        expect(signed.at(-1)?.args).toContain(join(root, "Resources/WidgetHost.entitlements"));
        for (const bundle of [app, widget]) {
            expect(await Bun.file(join(bundle, "Contents/Info.plist")).text()).toContain(`<string>${widgetAppGroup}</string>`);
        }
        await rm(fake.log);
        expect((await fake.script("desktop/bundle/sign-app.ts", [app])).code).toBe(0);
        signed = (await fake.calls("codesign")).filter(call => !call.args.includes("--verify"));
        expect(signed[0].args).toContain(join(root, "Resources/ShareExtension.entitlements"));
        expect(signed.at(-1)?.args).toContain(join(root, "Resources/Release.entitlements"));
        for (const bundle of [app, widget]) {
            expect(await Bun.file(join(bundle, "Contents/Info.plist")).text()).not.toContain(widgetAppGroup);
        }
    });
    test("widget versions and identity follow the container", async () => {
        const widget = widgetExtension(app);
        await mkdir(join(widget, "Contents"), { recursive: true });
        await Bun.write(join(widget, "Contents/Info.plist"),
            await Bun.file(join(root, "Resources/WidgetExtension-Info.plist")).text());
        await configureWidgetExtension(app, true);
        const info = await Bun.file(join(widget, "Contents/Info.plist")).text();
        expect(info).toContain("<string>dev.toybox.desktop.widget</string>");
        expect(info).toContain("<string>0.1.0</string>");
        expect(info).toContain("<string>1</string>");
        const swift = await Bun.file(join(root, "Sources/ChannelKit/NeedsYouSnapshot.swift")).text();
        expect(swift).toContain(`"${widgetAppGroup}"`);
        for (const name of ["WidgetHost", "WidgetExtension"]) {
            expect(await Bun.file(join(root, `Resources/${name}.entitlements`)).text()).toContain(widgetAppGroup);
        }
    });
});

test("bundle and isolated tool identities agree", async () => {
    const source = await Bun.file(join(root, "Resources/Info.plist")).text();
    expect(source).toMatch(new RegExp(`<key>CFBundleIdentifier</key>\\s*<string>${bundleIdentity.replaceAll(".", "\\.")}</string>`));
    expect(bundleIdentity).toBe("dev.toybox.desktop");
});
