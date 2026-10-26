import { expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, readlink, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { linkMobileWorkspace } from "./mobile.ts";

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
