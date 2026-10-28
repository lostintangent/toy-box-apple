import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmod, rm } from "node:fs/promises";
import { join } from "node:path";
import { root } from "../../shared/support/lib.ts";
import { FakeHarness, workflowBody } from "../../shared/support/test-helpers.ts";
import { mobileBundleID, mobileEntitlements, mobileExtensions } from "./build.ts";

const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
const password = "fake-certificate-password\\with a space";
let fake: FakeHarness;
beforeEach(async () => { fake = await FakeHarness.create(); });
afterEach(async () => { await fake.dispose(); });

test.each(["push", "workflow_dispatch"])("%s calls only the shared mobile command with the right upload gate", async event => {
    await rm(join(fake.directory, "bin/bun"));
    await Bun.write(join(fake.directory, "bin/bun"),
        `#!${process.execPath}\nimport { fake } from ${JSON.stringify(join(import.meta.dir, "../../shared/support/fake-command.ts"))}; await fake("bun");`);
    await chmod(join(fake.directory, "bin/bun"), 0o700);
    const result = await fake.run(["/bin/bash", "-c",
        await workflowBody("Build and validate or upload to TestFlight", "mobile-release.yml")], { GITHUB_EVENT_NAME: event });
    expect(result.code).toBe(0);
    expect((await fake.calls("bun"))[0]!.args).toEqual([
        "run", "testflight", ...(event === "workflow_dispatch" ? ["--validate-only"] : []),
    ]);
});

const signing = {
    CERTIFICATE: Buffer.from("fake distribution identity").toString("base64"),
    CERTIFICATE_PASSWORD: password,
    SIGNING_CERTIFICATE_CHAIN: "fake public issuer chain",
    HOST_PROFILE: Buffer.from("host profile").toString("base64"),
    WIDGET_PROFILE: Buffer.from("widget profile").toString("base64"),
    NOTIFICATION_PROFILE: Buffer.from("notification profile").toString("base64"),
    NOTARY_APP_PASSWORD: "fake-upload-password",
    MOBILE_SIGNING_IDENTITY: fingerprint, APP_STORE_CONNECT_APP_ID: "123456789",
};
test("CI imports only temporary signing material and restores the original keychain list", async () => {
    const install = await fake.run(["/bin/bash", "-c",
        await workflowBody("Install temporary TestFlight signing material", "mobile-release.yml")], signing);
    expect(install.code).toBe(0);
    expect(install.stdout + install.stderr).not.toContain(password);
    const directory = join(fake.directory, "toy-box-testflight-signing");
    expect(await Bun.file(join(directory, "app.mobileprovision")).text()).toBe("host profile");
    expect(await Bun.file(join(directory, "widget.mobileprovision")).text()).toBe("widget profile");
    expect(await Bun.file(join(directory, "notification.mobileprovision")).text()).toBe("notification profile");
    expect(await Bun.file(join(directory, "issuer-chain.pem")).text()).toBe("fake public issuer chain");
    expect(await Bun.file(join(fake.directory, "github-env")).text()).toBe([
        `MOBILE_PROVISIONING_PROFILE=${directory}/app.mobileprovision`,
        `MOBILE_WIDGET_PROVISIONING_PROFILE=${directory}/widget.mobileprovision`,
        `MOBILE_NOTIFICATION_PROVISIONING_PROFILE=${directory}/notification.mobileprovision`,
        "",
    ].join("\n"));
    const cleanup = await fake.run(["/bin/bash", "-c",
        await workflowBody("Remove temporary TestFlight signing material", "mobile-release.yml")]);
    expect(cleanup.code).toBe(0);
    expect(await Bun.file(join(directory, "identity.p12")).exists()).toBe(false);
    expect(await Bun.file(join(directory, "app.mobileprovision")).exists()).toBe(false);
    expect((await fake.calls("security")).findLast(call => call.args[0] === "list-keychains")!.args)
        .toEqual(["list-keychains", "-d", "user", "-s", "/fake/login.keychain-db"]);
});
test.each(Object.keys(signing))("missing %s fails before importing anything", async missing => {
    const result = await fake.run(["/bin/bash", "-c",
        await workflowBody("Install temporary TestFlight signing material", "mobile-release.yml")],
    { ...signing, [missing]: "" });
    expect(result.code).not.toBe(0);
    expect(result.stderr).toContain("Missing");
    expect(await fake.calls("security")).toEqual([]);
});
test("a missing iPhone changelog never reaches signing or building", async () => {
    const result = await fake.run(["/bin/bash", "-c",
        await workflowBody("Require the iPhone changelog entry", "mobile-release.yml")],
    { RELEASE_TAG: "mobile-v9.9.9", GITHUB_STEP_SUMMARY: join(fake.directory, "summary") });
    expect(result.code).not.toBe(0);
    expect(await fake.calls("security")).toEqual([]);
    expect(await fake.calls("xcrun")).toEqual([]);
});

async function setupSigning(extra: NodeJS.ProcessEnv = {}) {
    const bundles = [mobileBundleID, ...mobileExtensions.map(extension => `${mobileBundleID}.${extension.suffix}`)];
    const components = [];
    for (const bundleID of bundles) {
        const path = join(fake.directory, `${bundleID}.mobileprovision`);
        await Bun.write(path, `public profile ${bundleID}`);
        components.push({ bundleID, applicationIdentifier: `TEAM.${bundleID}`,
            identity: { fingerprint, name: "Apple Distribution: Fixture" },
            profile: { path, name: bundleID, uuid: bundleID, team: "TEAM", prefix: "TEAM",
                applicationIdentifier: `TEAM.${bundleID}`, expires: "2099-01-01", devices: [],
                certificates: [fingerprint], distribution: true, entitlements: mobileEntitlements(bundleID, true) } });
    }
    return fake.run([process.execPath, "-e",
        `const { main } = await import(${JSON.stringify(new URL("../../shared/support/lib.ts", import.meta.url).href)}); const { uploadTestFlightSigning } = await import(${JSON.stringify(new URL("../setup-secrets.ts", import.meta.url).href)}); await main(() => uploadTestFlightSigning(JSON.parse(process.env.FAKE_SIGNING), "123456789", "example/repo", process.env.FAKE_EXPORT_PASSWORD));`],
    { FAKE_SIGNING: JSON.stringify(components), FAKE_EXPORT_PASSWORD: password, ...extra });
}
test("user setup exports only the selected identity and five stdin-only signing secrets", async () => {
    const result = await setupSigning();
    expect(result.code).toBe(0);
    expect(result.stdout + result.stderr).not.toContain(password);
    const calls = await fake.calls("gh");
    const secrets = calls.filter(call => call.args[0] === "secret");
    expect(secrets.map(call => call.args[2])).toEqual([
        "MOBILE_SIGNING_CERTIFICATE", "MOBILE_SIGNING_PASSWORD", "MOBILE_PROVISIONING_PROFILE",
        "MOBILE_WIDGET_PROVISIONING_PROFILE", "MOBILE_NOTIFICATION_PROVISIONING_PROFILE",
    ]);
    expect(secrets.every(call => !call.args.includes(password))).toBe(true);
    expect(secrets.find(call => call.args[2] === "MOBILE_SIGNING_PASSWORD")!.input).toBe(password);
    expect(calls.filter(call => call.args[0] === "variable").map(call => call.args[2]))
        .toEqual(["MOBILE_SIGNING_CERTIFICATE_CHAIN", "MOBILE_SIGNING_IDENTITY", "APP_STORE_CONNECT_APP_ID"]);
    expect(calls.some(call => call.args.includes("NOTARY_APP_PASSWORD"))).toBe(false);
    expect((await fake.calls("xcrun"))[0]!.args).not.toContain(password);
    expect(await Array.fromAsync(new Bun.Glob("toy-box-testflight-secrets.*").scan(fake.directory))).toEqual([]);
});
test("partial secret failure is reported and the temporary private export is removed", async () => {
    const result = await setupSigning({ FAIL_SECRET: "MOBILE_WIDGET_PROVISIONING_PROFILE" });
    expect(result.code).toBe(24);
    expect(result.stdout).not.toContain("TestFlight signing configured");
    expect(result.stdout + result.stderr).not.toContain(password);
    expect(await Array.fromAsync(new Bun.Glob("toy-box-testflight-secrets.*").scan(fake.directory))).toEqual([]);
});
test("an issuing-chain export failure never uploads a partial replacement", async () => {
    const result = await setupSigning({ FAIL_EXPORT: "1" });
    expect(result.code).toBe(28);
    expect((await fake.calls("gh")).some(call => ["secret", "variable"].includes(call.args[0]!))).toBe(false);
    expect(await Array.fromAsync(new Bun.Glob("toy-box-testflight-secrets.*").scan(fake.directory))).toEqual([]);
});
test("invalid setup arguments fail before credential or repository commands", async () => {
    const result = await fake.script("mobile/setup-secrets.ts", ["invalid", "123"]);
    expect(result.code).toBe(1);
    expect(await fake.calls("security")).toEqual([]);
    expect(await fake.calls("gh")).toEqual([]);
});
