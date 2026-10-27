import { chmod, mkdir, mkdtemp, rm, symlink } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { root } from "../../lib.ts";

export type Call = { command: string; args: string[]; input: string };
export class FakeHarness {
    readonly log: string;
    readonly env: NodeJS.ProcessEnv;
    private constructor(readonly directory: string) {
        this.log = join(directory, "commands.jsonl");
        this.env = { PATH: `${join(directory, "bin")}:/usr/bin:/bin`, HOME: directory, TMPDIR: directory,
            FAKE_LOG: this.log, RUNNER_TEMP: directory, GITHUB_ENV: join(directory, "github-env"),
            SPARKLE_TOOLS_DIR: directory, NOTARY_PROFILE: "fake-ci-profile",
            NOTARY_APPLE_ID: "", NOTARY_TEAM_ID: "", NOTARY_APP_PASSWORD: "" };
    }
    static async create() {
        const harness = new FakeHarness(await mkdtemp(join(tmpdir(), "toy-box-tooling-test.")));
        await mkdir(join(harness.directory, "bin"));
        for (const name of ["ditto", "xcrun", "codesign", "gh", "openssl", "security", "curl", "shasum",
            "generate_keys", "generate_appcast", "sign_update"]) {
            const path = join(harness.directory, "bin", name);
            await Bun.write(path, `#!${process.execPath}\nimport { fake } from ${JSON.stringify(join(import.meta.dir, "fake-command.ts"))};\nawait fake(${JSON.stringify(name)});\n`);
            await chmod(path, 0o700);
        }
        await symlink(process.execPath, join(harness.directory, "bin/bun"));
        return harness;
    }
    async dispose() { await rm(this.directory, { recursive: true, force: true }); }
    async calls(command: string) {
        if (!await Bun.file(this.log).exists()) return [];
        return (await Bun.file(this.log).text()).trim().split("\n")
            .map(line => JSON.parse(line) as Call).filter(call => call.command === command);
    }
    async run(args: string[], extra: NodeJS.ProcessEnv = {}, input = "") {
        const child = Bun.spawn(args, { cwd: root, env: { ...this.env, ...extra },
            stdin: new Blob([input]), stdout: "pipe", stderr: "pipe", timeout: 15_000 });
        const [stdout, stderr, code] = await Promise.all([
            new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
        ]);
        return { stdout, stderr, code };
    }
    script(path: string, args: string[] = [], extra: NodeJS.ProcessEnv = {}, input = "") {
        return this.run([process.execPath, join(root, "scripts", path), ...args], extra, input);
    }
}

export async function workflowBody(name: string, file = "build-and-release.yml") {
    const lines = (await Bun.file(join(root, ".github/workflows", file)).text()).split("\n");
    const start = lines.indexOf(`      - name: ${name}`);
    if (start < 0) throw new Error(`Workflow step not found: ${name}`);
    const run = lines.indexOf("        run: |", start);
    if (run < 0) throw new Error(`Workflow step has no shell body: ${name}`);
    const body: string[] = [];
    for (const line of lines.slice(run + 1)) {
        if (line && !line.startsWith("          ")) break;
        body.push(line.slice(10));
    }
    return body.join("\n") + "\n";
}
