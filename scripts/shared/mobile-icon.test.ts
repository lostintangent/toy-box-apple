import { expect, test } from "bun:test";
import { chmod, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { embedMobileAppIcon } from "./icon.ts";
import { plist, temporary } from "./lib.ts";

const iconMetadata = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIcons</key><dict>
<key>CFBundlePrimaryIcon</key><dict>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>
</dict></dict></dict></plist>`;

async function iconFixture(directory: string, output = "valid") {
    const resources = join(directory, "Resources");
    const app = join(directory, "Toy Box.app");
    const compiler = join(directory, "actool");
    const argumentsPath = join(directory, "arguments.json");
    await mkdir(join(resources, "AppIcon.icon"), { recursive: true });
    await mkdir(app);
    await Bun.write(join(resources, "AppIcon.icon/icon.json"), "{}");
    await Bun.write(join(app, "Info.plist"),
        '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.toybox.mobile</string></dict></plist>');
    await Bun.write(compiler, `#!${process.execPath}
import { writeFileSync } from "node:fs";
import { join } from "node:path";
const args = process.argv.slice(2);
writeFileSync(process.env.ICON_ARGUMENTS, JSON.stringify(args));
const directory = args[args.indexOf("--compile") + 1];
const output = process.env.ICON_OUTPUT;
if (output !== "missing-assets") writeFileSync(join(directory, "Assets.car"), output === "empty-assets" ? "" : "layered");
if (output !== "missing-png") writeFileSync(join(directory, "AppIcon60x60@2x.png"), "fallback");
writeFileSync(args[args.indexOf("--output-partial-info-plist") + 1],
    output === "wrong-icon" ? ${JSON.stringify(iconMetadata.replace("AppIcon</string>", "WrongIcon</string>"))}
        : ${JSON.stringify(iconMetadata)});
if (output === "failure") process.exit(17);
`);
    await chmod(compiler, 0o755);
    return { resources, app, argumentsPath,
        env: { ...process.env, ACTOOL: compiler, ICON_ARGUMENTS: argumentsPath, ICON_OUTPUT: output } };
}

for (const device of [false, true]) {
    test.skipIf(process.platform !== "darwin" || (!device && process.env.TOY_BOX_TEST_MOBILE_ICON_TIMING !== "1"))(
        `mobile ${device ? "device" : "Simulator"} icons compile the shared document and merge native metadata`, async () => {
        await temporary("toy-box-mobile-icon-test.", async directory => {
            const fixture = await iconFixture(directory);
            await embedMobileAppIcon(fixture.resources, fixture.app, device, "27.0", fixture.env);
            const args: string[] = await Bun.file(fixture.argumentsPath).json();
            expect(args[0]).toBe(join(fixture.resources, "AppIcon.icon"));
            for (const [flag, value] of [
                ["--platform", device ? "iphoneos" : "iphonesimulator"], ["--minimum-deployment-target", "27.0"],
                ["--target-device", "iphone"], ["--app-icon", "AppIcon"],
            ] as const) expect(args[args.indexOf(flag) + 1]).toBe(value);
            expect(await Bun.file(join(fixture.app, "Assets.car")).text()).toBe("layered");
            expect(await Bun.file(join(fixture.app, "AppIcon60x60@2x.png")).text()).toBe("fallback");
            expect(await Bun.file(join(fixture.app, "icon.plist")).exists()).toBe(false);
            expect(await plist(join(fixture.app, "Info.plist"), ["Print :CFBundleIdentifier"])).toBe("dev.toybox.mobile");
            expect(await plist(join(fixture.app, "Info.plist"),
                ["Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName"])).toBe("AppIcon");
            expect(await plist(join(fixture.app, "Info.plist"),
                ["Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0"])).toBe("AppIcon60x60");
    });
    });
}

for (const output of ["missing-assets", "empty-assets", "missing-png", "wrong-icon", "failure"]) {
    test.skipIf(process.platform !== "darwin")(`mobile icon ${output} is rejected before any bundle mutation`, async () => {
        await temporary("toy-box-mobile-icon-test.", async directory => {
            const fixture = await iconFixture(directory, output);
            const original = await Bun.file(join(fixture.app, "Info.plist")).text();
            await expect(embedMobileAppIcon(fixture.resources, fixture.app, false, "27.0", fixture.env))
                .rejects.toThrow(output === "failure" ? "failed (exit 17)" : "iPhone AppIcon");
            expect(await Bun.file(join(fixture.app, "Assets.car")).exists()).toBe(false);
            expect(await Bun.file(join(fixture.app, "Info.plist")).text()).toBe(original);
        });
    });
}

test("mobile icons require the canonical document instead of silently using a fallback", async () => {
    await temporary("toy-box-mobile-icon-test.", async directory => {
        await expect(embedMobileAppIcon(join(directory, "missing"), join(directory, "Toy Box.app"), false, "27.0"))
            .rejects.toThrow("AppIcon.icon source is missing");
    });
});

test.skipIf(process.platform !== "darwin")("mobile icon compilation uses the selected Xcode unless ACTOOL is explicitly overridden", async () => {
    await temporary("toy-box-mobile-icon-test.", async directory => {
        const fixture = await iconFixture(directory);
        const developer = join(directory, "Xcode/Contents/Developer");
        await mkdir(join(developer, "usr/bin"), { recursive: true });
        const { copyFile } = await import("node:fs/promises");
        await copyFile(fixture.env.ACTOOL, join(developer, "usr/bin/actool"));
        await embedMobileAppIcon(fixture.resources, fixture.app, true, "27.0",
            { ...fixture.env, ACTOOL: undefined, DEVELOPER_DIR: developer });
        expect(await Bun.file(fixture.argumentsPath).exists()).toBe(true);
    });
});
