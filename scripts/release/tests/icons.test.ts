import { describe, expect, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { embedAppIcon } from "../../dev/icon.ts";
import { temporary } from "../../lib.ts";

describe("committed icon packaging without Icon Composer or actool", () => {
    test("copies the layered appearances and fallback without rendering them", async () => {
        await temporary("toy-box-icon-test.", async directory => {
            const source = join(directory, "source");
            const app = join(directory, "Toy Box Desktop.app");
            await mkdir(source);
            for (const name of ["AppIcon.icns", "Assets.car"]) {
                await Bun.write(join(source, name), `fixture ${name}`);
            }
            await embedAppIcon(source, app);
            for (const name of ["AppIcon.icns", "Assets.car"]) {
                expect(await Bun.file(join(app, "Contents/Resources", name)).text()).toBe(`fixture ${name}`);
            }
        });
    });

    test.each(["AppIcon.icns", "Assets.car"])("rejects missing or empty %s before copying", async missing => {
        await temporary("toy-box-icon-test.", async directory => {
            const source = join(directory, "source");
            const app = join(directory, "Toy Box Desktop.app");
            await mkdir(source);
            const other = missing === "Assets.car" ? "AppIcon.icns" : "Assets.car";
            await Bun.write(join(source, other), "valid fixture");
            for (const empty of [false, true]) {
                if (empty) await Bun.write(join(source, missing), "");
                await expect(embedAppIcon(source, app)).rejects.toThrow(`${missing} is missing or empty`);
                expect(await Bun.file(join(app, "Contents/Resources", other)).exists()).toBe(false);
            }
        });
    });
});
