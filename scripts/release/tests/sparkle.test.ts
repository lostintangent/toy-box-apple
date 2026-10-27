import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmod, lstat, mkdir, rm, symlink } from "node:fs/promises";
import { join } from "node:path";
import { bundleIdentity, root } from "../../lib.ts";
import { checkVersion } from "../check-update-version.ts";
import { FakeHarness, workflowBody } from "./helpers.ts";
import { checkTestCompletion } from "../../dev/test.ts";
import { configureShareExtension } from "../share-extension.ts";
import { legacyTestBundles } from "../../dev/validate.ts";
import { configureWidgetExtension, widgetAppGroup, widgetExtension } from "../widget-extension.ts";

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
            const result = await fake.script("release/embed-sparkle.ts", [source, app, license]);
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
        const result = await fake.script("release/sign-app.ts", [app, ...options]);
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
        expect((await fake.script("release/sign-app.ts", [app])).code).toBe(0);
        const calls = await fake.calls("codesign");
        expect(calls[0].args).toContain("runtime");
        const first = calls.find(call => call.args.at(-1) === framework && !call.args.includes("--verify"))!.args;
        expect(first).toContain("--timestamp=none");
        expect(first).not.toContain("--options");
        expect(first[first.indexOf("--sign") + 1]).toBe("-");
        await rm(fake.log);
        expect((await fake.script("release/sign-app.ts", [app], { FAIL_SIGN: "1" })).code).toBe(23);
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
        expect((await fake.script("release/sign-app.ts", [app, ...options])).code).toBe(0);
        let signed = (await fake.calls("codesign")).filter(call => !call.args.includes("--verify"));
        expect(signed[0].args.at(-1)).toBe(widget);
        expect(signed[0].args).toContain(join(root, "Resources/WidgetExtension.entitlements"));
        expect(signed.at(-1)?.args).toContain(join(root, "Resources/WidgetHost.entitlements"));
        for (const bundle of [app, widget]) {
            expect(await Bun.file(join(bundle, "Contents/Info.plist")).text()).toContain(`<string>${widgetAppGroup}</string>`);
        }
        await rm(fake.log);
        expect((await fake.script("release/sign-app.ts", [app])).code).toBe(0);
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

describe("update-key setup without a real Keychain", () => {
    let fake: FakeHarness;
    beforeEach(async () => { fake = await FakeHarness.create(); });
    afterEach(async () => { await fake.dispose(); });
    test("uses the app account and sends the private key only over stdin", async () => {
        const result = await fake.script("release/setup-update-secrets.ts", ["example/explicit-repository"]);
        expect(result.code).toBe(0);
        const keys = await fake.calls("generate_keys");
        expect(keys).toHaveLength(3);
        expect(keys.every(call => JSON.stringify(call.args.slice(0, 2)) === JSON.stringify(["--account", bundleIdentity]))).toBe(true);
        const calls = await fake.calls("gh");
        const secret = calls.find(call => call.args[0] === "secret");
        expect(secret?.args).toEqual(["secret", "set", "SPARKLE_ED_PRIVATE_KEY", "--repo", "example/explicit-repository"]);
        expect(secret?.input).toBe("fake-sparkle-private-key");
        expect(calls.find(call => call.args[0] === "variable")?.args[2]).toBe("SPARKLE_ED_PUBLIC_KEY");
        expect(result.stdout + result.stderr).not.toContain("fake-sparkle-private-key");
        expect(await Array.fromAsync(new Bun.Glob("toy-box-update-secrets.*").scan(fake.directory))).toEqual([]);
    });
    test.each([["", 0], ["FAIL_KEY", 25], ["FAIL_SECRET", 24]] as const)(
        "resolves the repository and propagates %s", async (name, code) => {
            const result = await fake.script("release/setup-update-secrets.ts", [], name ? { [name]: "1" } : {});
            expect(result.code).toBe(code);
            if (code) expect(result.stdout).not.toContain("Update signing configured");
            expect(result.stdout + result.stderr).not.toContain("fake-sparkle-private-key");
            expect(await Array.fromAsync(new Bun.Glob("toy-box-update-secrets.*").scan(fake.directory))).toEqual([]);
        });
});

describe("signed appcast generation", () => {
    let fake: FakeHarness;
    let env: NodeJS.ProcessEnv;
    beforeEach(async () => {
        fake = await FakeHarness.create();
        const output = join(fake.directory, "release");
        await mkdir(output);
        await Bun.write(join(output, "ToyBox-0.2.0-arm64.zip"), "fake archive");
        env = { OUTPUT_DIR: output, BUILD_NUMBER: "200.1", SPARKLE_ED_PRIVATE_KEY: "fake-sparkle-private-key" };
        await Bun.write(join(fake.directory, "CHANGELOG.md"), "## Mac 0.2.0\n\nQuick Send and the menu bar inbox.\n");
    });
    afterEach(async () => { await fake.dispose(); });
    const generate = (extra: NodeJS.ProcessEnv = {}) => fake.run([process.execPath, "-e",
        `const { generateAppcast } = await import(${JSON.stringify(new URL("../generate-appcast.ts", import.meta.url).href)}); await generateAppcast("v0.2.0", ${JSON.stringify(fake.directory)});`],
    { ...env, ...extra });
    test("generates a feed and verifies only the required archive signature without Keychain access", async () => {
        const result = await generate();
        expect(result.code).toBe(0);
        const generated = (await fake.calls("generate_appcast"))[0].args;
        expect(generated.slice(0, 2)).toEqual(["--ed-key-file", "-"]);
        expect(generated).toContain("--embed-release-notes");
        expect(generated).toContain("--maximum-deltas");
        const verified = await fake.calls("sign_update");
        expect(verified).toHaveLength(1);
        expect(verified[0].args.at(-2)).toBe(join(env.OUTPUT_DIR!, "ToyBox-0.2.0-arm64.zip"));
        expect(verified.every(call => JSON.stringify(call.args.slice(0, 3)) === JSON.stringify(["--ed-key-file", "-", "--verify"]))).toBe(true);
        expect(result.stdout + result.stderr).not.toContain("fake-sparkle-private-key");
        expect(await Bun.file(join(env.OUTPUT_DIR!, "ToyBox-0.2.0-arm64.txt")).text())
            .toBe("Quick Send and the menu bar inbox.\n");
    });
    test.each([
        { SPARKLE_ED_PRIVATE_KEY: "" }, { UNSIGNED_FEED: "1" }, { FAIL_VERIFY: "1" }, { BUILD_NUMBER: "199.1" },
    ])("missing keys, invalid metadata and verification errors never succeed: %j", async extra => {
        const result = await generate(extra);
        expect(result.code).not.toBe(0);
        expect(result.stdout).not.toContain("Update feed with verified archive signature:");
    });
    test("an explicit file key never falls back to the Keychain", async () => {
        const key = join(fake.directory, "throwaway-key.txt");
        await Bun.write(key, "fake-key");
        const result = await generate({ SPARKLE_ED_PRIVATE_KEY: "", SPARKLE_ED_KEY_FILE: key });
        expect(result.code).toBe(0);
        const calls = [...await fake.calls("generate_appcast"), ...await fake.calls("sign_update")];
        expect(calls.every(call => JSON.stringify(call.args.slice(0, 2)) === JSON.stringify(["--ed-key-file", key]))).toBe(true);
    });
    test.each([
        [{}, true], [{ LATEST_TAG: "v0.2.0" }, false],
        [{ PREVIOUS_FEED_URL: "https://example.invalid/appcast.xml", BUILD_NUMBER: "200.2" }, true],
        [{ PREVIOUS_FEED_URL: "https://example.invalid/appcast.xml" }, false],
    ] as [NodeJS.ProcessEnv, boolean][])("CI only bootstraps 0.1.0 and rejects older builds: %j", async (extra, success) => {
        const previous = join(fake.directory, "source-appcast.xml");
        await Bun.write(previous, '<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><s:version>200.1</s:version></item></channel></rss>');
        const result = await fake.run(["/bin/bash", "-c", await workflowBody("Check update signing configuration and build number")], {
            ...env, SPARKLE_ED_PUBLIC_KEY: "fake-public-key", GITHUB_REPOSITORY: "example/fake-repository",
            FAKE_PREVIOUS_FEED: previous, ...extra,
        });
        expect(result.code === 0).toBe(success);
    });
});

test("bundle and isolated tool identities agree", async () => {
    const source = await Bun.file(join(root, "Resources/Info.plist")).text();
    expect(source).toMatch(new RegExp(`<key>CFBundleIdentifier</key>\\s*<string>${bundleIdentity.replaceAll(".", "\\.")}</string>`));
    expect(bundleIdentity).toBe("dev.toybox.desktop");
});

test("validation unregisters only pre-rename copies of its test identity", () => {
    const canonical = "/workspace/.build/agents/Toy Box Desktop Test.app";
    const scratch = "/private/tmp/older scratch/Toy Box Desktop Test.app";
    function record(path: string, identifier = `${bundleIdentity}.test`) {
        return `--------------------------------------------------------------------------------
bundle id:                  Toy Box Desktop Test (0x123)
path:                       ${path} (0x456)
identifier:                 ${identifier}
codeInfoID:                 ${bundleIdentity}.test
`;
    }
    const dump = [
        record(canonical), record(scratch), record(canonical),
        record("/workspace/.build/agents/Toy Box Test.app"),
        record("/Applications/Toy Box Desktop Test.app", bundleIdentity),
        record("/Applications/Toy Box Desktop Test.app", `${bundleIdentity}.test.other`),
        record("/tmp/Toy Box Desktop.app"), record("relative/Toy Box Desktop Test.app"),
        `--------------------------------------------------------------------------------
path:                       /tmp/unrelated/Toy Box Desktop Test.app (0x789)
codeInfoID:                 ${bundleIdentity}.test
`,
    ].join("\n");
    expect(legacyTestBundles(dump)).toEqual([canonical, scratch]);
    expect(legacyTestBundles(dump.replaceAll("\n", "\r\n"))).toEqual([canonical, scratch]);
    expect(legacyTestBundles("")).toEqual([]);
});

test("build comparison is numeric, strict and checks every published item", async () => {
    const fake = await FakeHarness.create();
    try {
        const feed = join(fake.directory, "previous.xml");
        await Bun.write(feed, `<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><s:version>199.10</s:version></item><item><enclosure s:version="200.1"/></item></channel></rss>`);
        await checkVersion("200.2", feed); await checkVersion("201", feed);
        for (const value of ["200.1", "200.1.0", "200", "199.99", "1", "invalid", "10000.1"]) {
            await expect(checkVersion(value, feed)).rejects.toThrow();
        }
        for (const xml of ["<rss><channel><item/></channel></rss>", "<rss><channel/></rss>", "<rss>"]) {
            await Bun.write(feed, xml);
            await expect(checkVersion("201", feed)).rejects.toThrow();
        }
    } finally { await fake.dispose(); }
});

test("test-run completion guards reject partial Swift Testing and XCTest runs", () => {
    checkTestCompletion("Test run started.\nTest run with 1 test in 1 suite passed after 0.1 seconds.");
    checkTestCompletion("Test Suite 'All tests' started\nTest Suite 'All tests' passed");
    expect(() => checkTestCompletion("Test run started.")).toThrow("remaining tests never ran");
    expect(() => checkTestCompletion("Test Suite 'Selected tests' started")).toThrow("remaining tests never ran");
});

test("the Bun test entrypoint preserves nonzero Swift exits and rejects success without a summary", async () => {
    const fake = await FakeHarness.create();
    try {
        expect((await fake.script("dev/test.ts", [], { TEST_LOG: "Test run started.\n" })).code).toBe(1);
        expect((await fake.script("dev/test.ts", [], { TEST_EXIT: "23" })).code).toBe(23);
        const result = await fake.script("dev/test.ts", ["--filter", "ComposerTests"], {
            TEST_LOG: "Test run started.\nTest run with 1 test passed after 0.1 seconds.\n",
        });
        expect(result.code).toBe(0);
        expect((await fake.calls("xcrun")).at(-1)?.args.slice(-2)).toEqual(["--filter", "ComposerTests"]);
    } finally { await fake.dispose(); }
});
