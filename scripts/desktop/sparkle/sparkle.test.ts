import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { bundleIdentity } from "../../shared/lib.ts";
import { checkVersion } from "./check-update-version.ts";
import { FakeHarness, workflowBody } from "../../shared/test-helpers.ts";

describe("update-key setup without a real Keychain", () => {
    let fake: FakeHarness;
    beforeEach(async () => { fake = await FakeHarness.create(); });
    afterEach(async () => { await fake.dispose(); });
    test("uses the app account and sends the private key only over stdin", async () => {
        const result = await fake.script("desktop/sparkle/setup-update-secrets.ts", ["example/explicit-repository"]);
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
            const result = await fake.script("desktop/sparkle/setup-update-secrets.ts", [], name ? { [name]: "1" } : {});
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
        `const { generateAppcast } = await import(${JSON.stringify(new URL("./generate-appcast.ts", import.meta.url).href)}); await generateAppcast("v0.2.0", ${JSON.stringify(fake.directory)});`],
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
