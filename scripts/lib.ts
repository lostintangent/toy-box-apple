import { $ } from "bun";
import { access, mkdtemp, rm } from "node:fs/promises";
import { constants } from "node:fs";
import { resolve, join } from "node:path";
import { tmpdir } from "node:os";

export const root = resolve(import.meta.dir, "..");
export const developerEnvironment = {
    ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR || "/Library/Developer/CommandLineTools",
};

export class CommandFailure extends Error {
    constructor(readonly exitCode: number, message: string) { super(message); }
}

export async function main(body: () => Promise<void>) {
    try { await body(); }
    catch (error) {
        console.error(error instanceof Error ? error.message : String(error));
        process.exitCode = error instanceof CommandFailure ? error.exitCode : 1;
    }
}

type CommandOptions = {
    cwd?: string;
    env?: NodeJS.ProcessEnv;
    quiet?: boolean;
    input?: string | Uint8Array;
    allowFailure?: boolean;
};

export async function command(args: string[], options: CommandOptions = {}) {
    const shell = $.cwd(options.cwd ?? root).env({ ...developerEnvironment, ...options.env });
    const input = options.input;
    const pending = input === undefined ? shell`${args}` : shell`${args} < ${Buffer.from(input)}`;
    const result = await (options.quiet ? pending.quiet() : pending).nothrow();
    if (result.exitCode && !options.allowFailure) {
        if (options.quiet) {
            process.stdout.write(result.stdout);
            process.stderr.write(result.stderr);
        }
        // Never include arguments here: signing commands can carry credentials.
        throw new CommandFailure(result.exitCode, `${args[0]} failed (exit ${result.exitCode}).`);
    }
    return result;
}

export async function text(args: string[], options: CommandOptions = {}) {
    return (await command(args, { ...options, quiet: true })).stdout.toString().trim();
}

export function required(name: string) {
    const value = process.env[name];
    if (!value) throw new Error(`Missing ${name}.`);
    return value;
}

export function scratchPath() { return resolve(process.env.SCRATCH_PATH || join(root, ".build")); }

export async function executable(path: string) {
    try { await access(path, constants.X_OK); return true; }
    catch (error) {
        if (isMissing(error) || (error instanceof Error && "code" in error && error.code === "EACCES")) return false;
        throw error;
    }
}

export function isMissing(error: unknown) {
    return error instanceof Error && "code" in error && error.code === "ENOENT";
}

export async function temporary<T>(prefix: string, body: (directory: string) => Promise<T>) {
    const directory = await mkdtemp(join(process.env.TMPDIR || tmpdir(), prefix));
    try { return await body(directory); }
    finally { await rm(directory, { recursive: true, force: true }); }
}

export async function plist(path: string, operations: string[]) {
    return text(["/usr/libexec/PlistBuddy", ...operations.flatMap(operation => ["-c", operation]), path]);
}

export function releaseTag(value: string | undefined) {
    if (!value || !/^v[0-9]+\.[0-9]+\.[0-9]+$/.test(value)) throw new Error("Release tag must be vX.Y.Z.");
    return value;
}

export const bundleIdentity = "dev.toybox.desktop";
export const repositoryURL = "https://github.com/lostintangent/toy-box-apple";
