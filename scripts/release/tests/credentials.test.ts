import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { root } from "../../lib.ts";
import { parseNotaryResponse } from "../release.ts";
import { FakeHarness, workflowBody } from "./helpers.ts";

const identity = "0123456789ABCDEF0123456789ABCDEF01234567";
const password = "fake-app-password\\with a space";
const signing = { CERTIFICATE: Buffer.from("fake identity").toString("base64"), CERTIFICATE_PASSWORD: "fake-p12-password" };
const apple = { NOTARY_APPLE_ID: "owner@example.invalid", NOTARY_TEAM_ID: "FAKETEAM12", NOTARY_APP_PASSWORD: password };

describe("release credentials without a real identity or Keychain", () => {
    let fake: FakeHarness;
    beforeEach(async () => { fake = await FakeHarness.create(); });
    afterEach(async () => { await fake.dispose(); });
    const args = [identity, apple.NOTARY_APPLE_ID, apple.NOTARY_TEAM_ID];
    async function setup(arguments_ = args, input = password + "\n", env = {}) {
        const result = await fake.script("release/setup-release-secrets.ts", arguments_, env, input);
        expect(result.stdout + result.stderr).not.toContain(password);
        expect(await Array.fromAsync(new Bun.Glob("toy-box-release-secrets.*").scan(fake.directory))).toEqual([]);
        return result;
    }

    test("stores the local profile and exactly three stdin-only secrets", async () => {
        const result = await setup([...args, "example/explicit-repo"]);
        expect(result.code).toBe(0);
        expect(result.stdout).toContain("Release secrets configured for example/explicit-repo");
        expect((await fake.calls("xcrun")).at(-1)?.args).toEqual([
            "notarytool", "store-credentials", "toy-box-channels-notary", "--apple-id", apple.NOTARY_APPLE_ID,
            "--team-id", apple.NOTARY_TEAM_ID, "--password", password,
        ]);
        const calls = (await fake.calls("gh")).filter(call => call.args[0] === "secret");
        expect(calls.map(call => call.args[2]).sort()).toEqual([
            "MACOS_SIGNING_CERTIFICATE", "MACOS_SIGNING_PASSWORD", "NOTARY_APP_PASSWORD",
        ]);
        const secrets = Object.fromEntries(calls.map(call => [call.args[2], call.input]));
        expect(Buffer.from(secrets.MACOS_SIGNING_CERTIFICATE, "base64").toString()).toBe("fake encrypted identity");
        expect(Buffer.from(secrets.MACOS_SIGNING_PASSWORD, "base64").length).toBe(48);
        expect(secrets.NOTARY_APP_PASSWORD).toBe(password);
        expect(calls.every(call => JSON.stringify(call.args.slice(3)) === JSON.stringify(["--repo", "example/explicit-repo"]))).toBe(true);
        expect((await fake.calls("xcrun"))[0].args).not.toContain(secrets.MACOS_SIGNING_PASSWORD);
    });
    test("resolves the default repository and accepts piped passwords without a newline", async () => {
        const result = await setup(args, password);
        expect(result.code).toBe(0);
        expect(result.stdout).toContain("example/fake-repository");
        expect((await fake.calls("gh")).find(call => call.args[2] === "NOTARY_APP_PASSWORD")?.input).toBe(password);
    });
    test("the only shell helper disables tracing before reading any password", async () => {
        const result = await fake.run(["/bin/bash", "-x", join(root, "scripts/release/read-password.sh"), "Password: "], {}, password);
        expect(result.code).toBe(0);
        expect(result.stdout).toBe(password);
        expect(result.stderr).not.toContain(password);
    });
    test.each(["", "\n"])("an empty password never exports or uploads: %j", async input => {
        expect((await setup(args, input)).code).not.toBe(0);
        expect(await fake.calls("xcrun")).toEqual([]);
        expect((await fake.calls("gh")).some(call => call.args[0] === "secret")).toBe(false);
    });
    test("rejected notary credentials never upload", async () => {
        const result = await setup(args, password, { FAIL_NOTARY: "1" });
        expect(result.code).toBe(23);
        expect(result.stdout).not.toContain("Release secrets configured");
        expect((await fake.calls("gh")).some(call => call.args[0] === "secret")).toBe(false);
    });
    test("failed uploads preserve the failure status", async () => {
        const result = await setup(args, password, { FAIL_SECRET: "NOTARY_APP_PASSWORD" });
        expect(result.code).toBe(24);
        expect(result.stdout).not.toContain("Release secrets configured");
    });
    test.each([[], [identity, "", "team"], [identity, "email", ""],
        ["invalid", "email", "team"], [...args, "repo", "extra"]])("invalid arguments fail before commands: %j", async (...arguments_) => {
        expect((await setup(arguments_)).code).not.toBe(0);
        expect(await Bun.file(fake.log).exists()).toBe(false);
    });
    test("CI stores credentials in its temporary keychain", async () => {
        const body = await workflowBody("Import the signing identity and notarization credentials");
        const result = await fake.run(["/bin/bash", "-c", body], { ...signing, ...apple });
        expect(result.code).toBe(0);
        expect(result.stdout + result.stderr).not.toContain(password);
        expect((await fake.calls("xcrun")).at(-1)?.args).toEqual([
            "notarytool", "store-credentials", "fake-ci-profile", "--keychain",
            join(fake.directory, "toy-box-release.keychain-db"),
            "--apple-id", apple.NOTARY_APPLE_ID, "--team-id", apple.NOTARY_TEAM_ID, "--password", password,
        ]);
    });
    test("the workflow pins only public signing identifiers", async () => {
        const source = await Bun.file(join(root, ".github/workflows/build-and-release.yml")).text();
        for (const [name, value] of Object.entries({
            SIGNING_IDENTITY: "69A492FDF7DDFC679B93DB465E0D5E94F22DAC6A", NOTARY_APPLE_ID: "joncart@outlook.com", NOTARY_TEAM_ID: "RHFNBL7EG4",
        })) expect(source).toContain(`      ${name}: ${value}\n`);
        for (const name of ["MACOS_SIGNING_IDENTITY", "NOTARY_APPLE_ID", "NOTARY_TEAM_ID"]) {
            expect(source).not.toContain(`secrets.${name}`);
        }
    });
    test.each(Object.keys({ ...signing, ...apple }))("CI rejects missing %s before keychain access", async missing => {
        const body = await workflowBody("Import the signing identity and notarization credentials");
        const result = await fake.run(["/bin/bash", "-c", body], { ...signing, ...apple, [missing]: "" });
        expect(result.code).not.toBe(0);
        expect(result.stderr).toContain("Missing");
        expect(await Bun.file(fake.log).exists()).toBe(false);
    });
    test("CI propagates a notary-credential rejection", async () => {
        const result = await fake.run(["/bin/bash", "-c",
            await workflowBody("Import the signing identity and notarization credentials")],
        { ...signing, ...apple, FAIL_NOTARY: "1" });
        expect(result.code).toBe(23);
        expect(await fake.calls("xcrun")).toHaveLength(1);
    });
});

describe("notarytool JSON", () => {
    test("accepted and rejected responses preserve their actual status", () => {
        expect(parseNotaryResponse('{"id":"fake-submission","status":"Accepted"}', 0)).toEqual({ id: "fake-submission", status: "Accepted" });
        expect(parseNotaryResponse('{"id":"fake-submission","status":"Invalid"}', 0).status).toBe("Invalid");
    });
    test.each(["", "{", '{"id":"fake-submission"}', '{"status":null}'])("malformed or missing status fails explicitly: %j", value => {
        expect(() => parseNotaryResponse(value, 23)).toThrow("without a valid submission response (exit 23)");
    });
});
