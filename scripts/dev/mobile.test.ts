import { expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, readlink, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
    checkMobileBuildVersion, checkMobileExtensionEntryPoint, linkMobileWorkspace, mobileBuildConfiguration,
    mobileExtensions, mobileLaunchOptions,
    mobileSimulatorEntitlements,
    withMobileAppearance,
} from "./mobile.ts";

function buildVersion(platform = "IOSSIMULATOR", minimumOS = "27.0", sdk = "27.1") {
    return `Load command 10
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform ${platform}
        minos ${minimumOS}
          sdk ${sdk}
       ntools 1`;
}

test("phone builds are always optimized while Simulator tests stay debug", () => {
    for (const requested of [undefined, "", "debug", "release"]) {
        expect(mobileBuildConfiguration(true, false, requested)).toBe("release");
        expect(mobileBuildConfiguration(false, true, requested)).toBe("debug");
    }
    expect(mobileBuildConfiguration(false, false, "")).toBe("debug");
    expect(mobileBuildConfiguration(false, false, "debug")).toBe("debug");
    expect(mobileBuildConfiguration(false, false, "release")).toBe("release");
    expect(() => mobileBuildConfiguration(false, false, "profile")).toThrow("CONFIGURATION");
});

test("iOS extensions have exact identities, extension points and executable entry points", async () => {
    for (const extension of mobileExtensions) {
        const info = await readFile(join(import.meta.dir, "../../Resources/Mobile", extension.info), "utf8");
        expect(info).toContain(`<string>dev.toybox.mobile.${extension.suffix}</string>`);
        expect(info).toContain(`<string>${extension.point}</string>`);
        expect(info).toContain(`<string>${extension.executable}</string>`);
    }
    const host = await readFile(join(import.meta.dir, "../../Resources/Mobile/Info.plist"), "utf8");
    expect(host).toMatch(/<key>NSSupportsLiveActivities<\/key>\s*<true\/>/);
    expect(host).toMatch(/<key>CFBundleURLSchemes<\/key>\s*<array><string>toybox-desktop<\/string><\/array>/);
    const package_ = await readFile(join(import.meta.dir, "../../Package.swift"), "utf8");
    for (const extension of mobileExtensions) expect(package_).toContain(`name: "${extension.executable}"`);
});

test("extension binaries bootstrap their context before calling generated Swift main", () => {
    const commands = `Load command 0
          cmd LC_SEGMENT_64
      segname __TEXT
       vmaddr 0x0000000100000000
      fileoff 0
Load command 1
          cmd LC_MAIN
     entryoff 4096`;
    const symbols = `Indirect symbols for (__TEXT,__stubs) 2 entries
address            index name
0x0000000100001000  42 _NSExtensionMain
0x000000010000100C  43 _other`;
    expect(() => checkMobileExtensionEntryPoint(commands, symbols)).not.toThrow();
    for (const output of [
        commands.replace("entryoff 4096", "entryoff 8192"),
        commands.replace("LC_MAIN", "LC_UNIXTHREAD"),
        `${commands}\nLoad command 2\ncmd LC_MAIN\nentryoff 4096`,
        commands.replace("vmaddr 0x0000000100000000", "vmaddr invalid"),
        "",
    ]) expect(() => checkMobileExtensionEntryPoint(output, symbols)).toThrow("_NSExtensionMain");
    for (const output of [
        symbols.replace("_NSExtensionMain", "_main"),
        symbols.replace("(__TEXT,__stubs)", "(__DATA,__got)"),
        "",
    ]) expect(() => checkMobileExtensionEntryPoint(commands, output)).toThrow("_NSExtensionMain");
});

test("simulated capabilities include each bundle identity without a device team or signing profile", () => {
    for (const suffix of ["", ".widget", ".notification"]) {
        const bundleID = `dev.toybox.mobile${suffix}`;
        const entitlements = mobileSimulatorEntitlements(bundleID);
        expect(entitlements["application-identifier"]).toBe(bundleID);
        expect(entitlements["com.apple.security.application-groups"]).toEqual(["group.dev.toybox.mobile"]);
        expect(entitlements).not.toHaveProperty("com.apple.developer.team-identifier");
        expect(entitlements).not.toHaveProperty("get-task-allow");
    }
    expect(() => mobileSimulatorEntitlements("another.app")).toThrow("Unknown mobile bundle");
});

for (const [platform, path] of [["phone", "Mobile/Info.plist"], ["Mac", "Info.plist"]] as const) {
    test(`${platform} ATS allows user-selected HTTP servers without a local-only override`, async () => {
        const info = await readFile(join(import.meta.dir, "../../Resources", path), "utf8");
        const ats = info.match(/<key>NSAppTransportSecurity<\/key>\s*<dict>([\s\S]*?)<\/dict>/)?.[1];
        expect(ats?.replace(/\s/g, "")).toBe("<key>NSAllowsArbitraryLoads</key><true/>");
    });
}

test("mobile bundles must record their real SDK and preserve their deployment target and platform", () => {
    expect(() => checkMobileBuildVersion(buildVersion(), false, "27.0", "27.1")).not.toThrow();
    expect(() => checkMobileBuildVersion(buildVersion("IOS"), true, "27.0", "27.1")).not.toThrow();
    expect(() => checkMobileBuildVersion(buildVersion("IOS", "27", "27.1.0"), true, "27.0", "27.1")).not.toThrow();
    expect(() => checkMobileBuildVersion(buildVersion("IOSSIMULATOR", "27.0", "27.1.2"),
        false, "27.0", "27.1.2")).not.toThrow();
    for (const output of [
        buildVersion("IOSSIMULATOR", "27.0", "27.0"),
        buildVersion("IOS"),
        buildVersion("MACOS"),
        buildVersion("IOSSIMULATOR", "27.1"),
        buildVersion("IOSSIMULATOR", "27.0", "unknown"),
        buildVersion().replace("          sdk 27.1", ""),
        `${buildVersion()}\n${buildVersion()}`,
        buildVersion().replace("LC_BUILD_VERSION", "LC_VERSION_MIN_IPHONEOS"),
        "",
    ]) {
        expect(() => checkMobileBuildVersion(output, false, "27.0", "27.1")).toThrow();
    }
    expect(() => checkMobileBuildVersion(buildVersion(), true, "27.0", "27.1")).toThrow();
});

test("content size is a validated process launch argument, not a saved simulator preference", () => {
    expect(mobileLaunchOptions()).toEqual({ contentSize: undefined, appearance: undefined, arguments: [] });
    for (const [name, raw] of [
        ["extraSmall", "XS"], ["small", "S"], ["medium", "M"], ["large", "L"], ["extraLarge", "XL"],
        ["extraExtraLarge", "XXL"], ["extraExtraExtraLarge", "XXXL"],
        ["accessibilityMedium", "AccessibilityM"], ["accessibilityLarge", "AccessibilityL"],
        ["accessibilityExtraLarge", "AccessibilityXL"], ["accessibilityExtraExtraLarge", "AccessibilityXXL"],
        ["accessibilityExtraExtraExtraLarge", "AccessibilityXXXL"],
    ]) {
        expect(mobileLaunchOptions(name, "dark")).toEqual({
            contentSize: `UICTContentSizeCategory${raw}`, appearance: "dark",
            arguments: ["-UIPreferredContentSizeCategoryName", `UICTContentSizeCategory${raw}`],
        });
    }
    expect(() => mobileLaunchOptions("extraHuge")).toThrow("--content-size");
    expect(() => mobileLaunchOptions("")).toThrow("--content-size");
    expect(() => mobileLaunchOptions(undefined, "automatic")).toThrow("--appearance");
});

function appearanceHost(initial = "light") {
    const events: string[] = [];
    let current = initial;
    return {
        events,
        async run(args: string[], signal: AbortSignal) {
            signal.throwIfAborted();
            expect(args.slice(0, 3)).toEqual(["ui", "simulator", "appearance"]);
            if (args[3]) {
                current = args[3];
                events.push(`set:${current}`);
            } else events.push("get");
            return { exitCode: 0, stdout: current, stderr: "" };
        },
    };
}

for (const outcome of ["success", "failure", "interruption"]) {
    test(`appearance is restored and read back before shutdown on ${outcome}`, async () => {
        const host = appearanceHost();
        const abort = new AbortController();
        const operation = withMobileAppearance("simulator", "dark", host.run, abort.signal, async () => {
            host.events.push("body");
            if (outcome === "failure") throw new Error("Drive failed");
            if (outcome === "interruption") {
                abort.abort(new Error("Interrupted"));
                abort.signal.throwIfAborted();
            }
            return "done";
        }).finally(() => { host.events.push("shutdown"); });
        if (outcome === "success") expect(await operation).toBe("done");
        else await expect(operation).rejects.toThrow(outcome === "failure" ? "Drive failed" : "Interrupted");
        expect(host.events).toEqual(["get", "set:dark", "get", "body", "set:light", "get", "shutdown"]);
    });
}

test("an interrupted appearance setter still restores using an independent cleanup signal", async () => {
    const host = appearanceHost();
    const abort = new AbortController();
    await expect(withMobileAppearance("simulator", "dark", async (args, signal) => {
        const result = await host.run(args, signal);
        if (args[3] === "dark") {
            abort.abort(new Error("Setter interrupted after applying"));
            signal.throwIfAborted();
        }
        return result;
    }, abort.signal, async () => { throw new Error("Must not launch"); })).rejects.toThrow("Setter interrupted");
    expect(host.events).toEqual(["get", "set:dark", "set:light", "get"]);
});

test("unknown appearance fails before mutation and absent override does not touch it", async () => {
    const host = appearanceHost("unknown");
    await expect(withMobileAppearance("simulator", "dark", host.run, new AbortController().signal,
        async () => "unexpected")).rejects.toThrow("unknown appearance");
    expect(host.events).toEqual(["get"]);
    host.events.length = 0;
    expect(await withMobileAppearance("simulator", undefined, host.run, new AbortController().signal,
        async () => "unchanged")).toBe("unchanged");
    expect(host.events).toEqual([]);
});

test("restoration failure reports both the failed run and cleanup instead of returning success", async () => {
    const host = appearanceHost();
    await expect(withMobileAppearance("simulator", "dark", async (args, signal) => {
        if (args[3] === "light") return { exitCode: 1, stdout: "", stderr: "Restore refused" };
        return host.run(args, signal);
    }, new AbortController().signal, async () => { throw new Error("Original drive failure"); }))
        .rejects.toThrow("Native run failed (Original drive failure). Simulator appearance restoration failed");
});

test("successful setter exits do not substitute for measured appearance application or restoration", async () => {
    for (const ignored of ["dark", "light"]) {
        const host = appearanceHost();
        await expect(withMobileAppearance("simulator", "dark", async (args, signal) => {
            if (args[3] === ignored) return { exitCode: 0, stdout: "", stderr: "" };
            return host.run(args, signal);
        }, new AbortController().signal, async () => "done")).rejects.toThrow(
            ignored === "dark" ? "requested simulator appearance was not applied" : "restored appearance did not match");
    }
});

test("capture-only, build-only and unleased appearance arguments fail before touching the simulator", async () => {
    for (const [args, message] of [
        [["--build-only", "--content-size", "large"], "Build-only"],
        [["--device", "--appearance", "dark"], "Build-only"],
        [["--device-id", "phone"], "--device-id requires --device"],
        [["--device", "--device-id", "phone", "--build-only"], "--device-id cannot be used with --build-only"],
        [["--device", "--displays"], "Build-only/device"],
        [["--build-only", "--server", "http://mac.local:3100"], "Build-only/device"],
        [["--appearance", "dark"], "--appearance requires --hold or --drive"],
        [["--screenshot", "/unused.png", "--content-size", "large"], "require launching"],
        [["--shutdown", "--hold", "--appearance", "dark"], "require launching"],
    ] as const) {
        const process = Bun.spawn([globalThis.process.execPath, join(import.meta.dir, "mobile.ts"), ...args], {
            cwd: import.meta.dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
            env: globalThis.process.env,
        });
        const output = await new Response(process.stderr).text();
        expect(await process.exited).toBe(1);
        expect(output).toContain(message);
    }
});

test("a reused mobile workspace links the requested checkout, including after the old one is removed", async () => {
    const scratch = await mkdtemp(join(tmpdir(), "toy-box-mobile-workspace-"));
    const first = join(scratch, "first");
    const second = join(scratch, "second");
    const workspace = join(scratch, "package");
    try {
        for (const source of [first, second]) {
            for (const name of ["Sources", "Tests"]) await mkdir(join(source, name), { recursive: true });
            await writeFile(join(source, "Package.swift"), source);
        }
        await linkMobileWorkspace(first, workspace);
        await linkMobileWorkspace(second, workspace);
        expect(await readFile(join(workspace, "Package.swift"), "utf8")).toBe(second);
        for (const name of ["Package.swift", "Sources", "Tests"]) {
            expect(await readlink(join(workspace, name))).toBe(join(second, name));
        }
        await rm(second, { recursive: true });
        await linkMobileWorkspace(first, workspace);
        expect(await readFile(join(workspace, "Package.swift"), "utf8")).toBe(first);
    } finally {
        await rm(scratch, { recursive: true, force: true });
    }
});

test("a mobile workspace never replaces an entry that is not a symlink", async () => {
    const scratch = await mkdtemp(join(tmpdir(), "toy-box-mobile-workspace-"));
    try {
        const path = join(scratch, "Package.swift");
        await writeFile(path, "Keep this file");
        await expect(linkMobileWorkspace(join(scratch, "source"), scratch)).rejects.toThrow("not a symlink");
        expect(await readFile(path, "utf8")).toBe("Keep this file");
    } finally {
        await rm(scratch, { recursive: true, force: true });
    }
});
