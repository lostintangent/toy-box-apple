import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmod, lstat, mkdir, realpath, rm, symlink } from "node:fs/promises";
import { join } from "node:path";
import { bundleIdentity, root } from "../../lib.ts";
import { checkVersion } from "../check-update-version.ts";
import { FakeHarness, workflowBody } from "./helpers.ts";
import { checkTestCompletion } from "../../dev/test.ts";
import { prebuiltBenchmarkApp } from "../../dev/benchmark.ts";

describe("Sparkle packaging without credentials", () => {
    let fake: FakeHarness;
    let app: string, framework: string, source: string, license: string;
    beforeEach(async () => {
        fake = await FakeHarness.create();
        app = join(fake.directory, "Toy Box Desktop.app");
        framework = join(app, "Contents/Frameworks/Sparkle.framework");
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
    test("production signing is inside-out, hardened and timestamped, with app-only entitlements", async () => {
        const options = ["--force", "--options", "runtime", "--timestamp", "--sign", "FAKE_IDENTITY"];
        const result = await fake.script("release/sign-app.ts", [app, ...options]);
        expect(result.code).toBe(0);
        const calls = await fake.calls("codesign");
        const signed = calls.filter(call => !call.args.includes("--verify"));
        expect(signed.map(call => call.args.at(-1))).toEqual([
            join(framework, "Versions/Current/Autoupdate"), join(framework, "Versions/Current/Updater.app"), framework, app,
        ]);
        expect(signed.every(call => JSON.stringify(call.args.slice(0, options.length)) === JSON.stringify(options))).toBe(true);
        expect(signed.slice(0, -1).every(call => !call.args.includes("--entitlements"))).toBe(true);
        expect(signed.at(-1)?.args).toContain("--entitlements");
        expect(calls.filter(call => call.args.includes("--strict"))).toHaveLength(4);
        expect(calls.some(call => call.args.includes("--deep"))).toBe(false);
    });
    test("ad-hoc signing avoids hardened runtime and never hides a signing error", async () => {
        expect((await fake.script("release/sign-app.ts", [app])).code).toBe(0);
        const first = (await fake.calls("codesign"))[0].args;
        expect(first).toContain("--timestamp=none");
        expect(first).not.toContain("--options");
        expect(first[first.indexOf("--sign") + 1]).toBe("-");
        await rm(fake.log);
        expect((await fake.script("release/sign-app.ts", [app], { FAIL_SIGN: "1" })).code).toBe(23);
        expect(await fake.calls("codesign")).toHaveLength(1);
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
        await Bun.write(join(output, "ToyBoxDesktop-0.2.0-arm64.zip"), "fake archive");
        env = { OUTPUT_DIR: output, BUILD_NUMBER: "200.1", SPARKLE_ED_PRIVATE_KEY: "fake-sparkle-private-key" };
    });
    afterEach(async () => { await fake.dispose(); });
    test("generates and verifies both signatures without default-Keychain access", async () => {
        const result = await fake.script("release/generate-appcast.ts", ["v0.2.0"], env);
        expect(result.code).toBe(0);
        const generated = (await fake.calls("generate_appcast"))[0].args;
        expect(generated.slice(0, 2)).toEqual(["--ed-key-file", "-"]);
        expect(generated).toContain("--embed-release-notes");
        expect(generated).toContain("--maximum-deltas");
        const verified = await fake.calls("sign_update");
        expect(verified).toHaveLength(2);
        expect(verified.every(call => JSON.stringify(call.args.slice(0, 3)) === JSON.stringify(["--ed-key-file", "-", "--verify"]))).toBe(true);
        expect(result.stdout + result.stderr).not.toContain("fake-sparkle-private-key");
    });
    test.each([
        { SPARKLE_ED_PRIVATE_KEY: "" }, { UNSIGNED_FEED: "1" }, { FAIL_VERIFY: "1" }, { BUILD_NUMBER: "199.1" },
    ])("missing keys, invalid metadata and verification errors never succeed: %j", async extra => {
        const result = await fake.script("release/generate-appcast.ts", ["v0.2.0"], { ...env, ...extra });
        expect(result.code).not.toBe(0);
        expect(result.stdout).not.toContain("Signed update feed:");
    });
    test("an explicit file key never falls back to the Keychain", async () => {
        const key = join(fake.directory, "throwaway-key.txt");
        await Bun.write(key, "fake-key");
        const result = await fake.script("release/generate-appcast.ts", ["v0.2.0"],
            { ...env, SPARKLE_ED_PRIVATE_KEY: "", SPARKLE_ED_KEY_FILE: key });
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

test("prebuilt benchmarks require a runnable source and never overwrite it", async () => {
    const fake = await FakeHarness.create();
    try {
        const app = join(fake.directory, "Historical Toy Box.app");
        const binary = join(app, "Contents/MacOS/ToyBoxDesktop");
        const destination = join(fake.directory, "Toy Box Desktop Benchmark.app");
        const alias = join(fake.directory, "source.app");
        await mkdir(join(app, "Contents/MacOS"), { recursive: true });
        await Bun.write(join(app, "Contents/Info.plist"), "historical plist");
        await Bun.write(binary, "historical executable");
        await chmod(binary, 0o755);
        await symlink(app, alias);
        expect(await prebuiltBenchmarkApp(alias, destination)).toBe(await realpath(app));
        await expect(prebuiltBenchmarkApp(app, alias)).rejects.toThrow("separate from the benchmark copy");
        await expect(prebuiltBenchmarkApp(app, join(app, "copy.app"))).rejects.toThrow("separate from the benchmark copy");
        await chmod(binary, 0o644);
        await expect(prebuiltBenchmarkApp(app, destination)).rejects.toThrow("Not a runnable Toy Box app bundle");
        expect(await Bun.file(join(app, "Contents/Info.plist")).text()).toBe("historical plist");
    } finally { await fake.dispose(); }
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
