import { expect, test } from "bun:test";
import { join } from "node:path";
import { changelogEntry, releaseContext } from "../changelog.ts";
import { FakeHarness } from "./helpers.ts";

const source = "# Changelog\n\n## iPhone 0.1.0\n\nPhone notes.\n\n## Mac 0.1.0\n\nMac notes.\n";
test("the two release lines select only their exact platform/version entry", () => {
    expect(changelogEntry(source, "mobile-v0.1.0")).toEqual({
        platform: "iPhone", version: "0.1.0", notes: "Phone notes.\n",
    });
    expect(changelogEntry(source.replaceAll("\n", "\r\n"), "v0.1.0")).toEqual({
        platform: "Mac", version: "0.1.0", notes: "Mac notes.\n",
    });
    for (const tag of ["v0.1", "mobile-0.1.0", "v01.1.0", "mobile-v1.2.3.4"])
        expect(() => releaseContext(tag)).toThrow("Release tag");
});
test("missing, empty and duplicate entries fail instead of substituting Git commit messages", () => {
    expect(() => changelogEntry(source, "v0.2.0")).toThrow("exactly one");
    expect(() => changelogEntry(source + "\n## Mac 0.1.0\nDuplicate", "v0.1.0")).toThrow("exactly one");
    expect(() => changelogEntry("## Mac 0.1.0\n\n## Mac 0.0.9\nOld", "v0.1.0")).toThrow("empty");
});
test("the CLI enforces MOBILE_VERSION and writes only the selected entry for release jobs", async () => {
    const fake = await FakeHarness.create();
    try {
        const path = join(fake.directory, "notes.md");
        const result = await fake.script("release/changelog.ts", ["mobile-v0.1.0", path], { MOBILE_VERSION: "0.1.0" });
        expect(result.code).toBe(0);
        expect(result.stdout.trim()).toBe("0.1.0");
        expect(await Bun.file(path).text()).toContain("First iPhone companion");
        expect(await Bun.file(path).text()).not.toContain("conversation accessibility crash");
        expect((await fake.script("release/changelog.ts", ["mobile-v0.1.0"],
            { MOBILE_VERSION: "0.2.0" })).code).toBe(1);
        expect((await fake.script("release/changelog.ts", ["v9.9.9", join(fake.directory, "missing.md")])).code).toBe(1);
        expect(await Bun.file(join(fake.directory, "missing.md")).exists()).toBe(false);
    } finally { await fake.dispose(); }
});
