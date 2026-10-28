import { expect, test } from "bun:test";
import { join } from "node:path";
import { root } from "./lib.ts";

const source = await Bun.file(join(root, ".github/workflows/build-and-release.yml")).text();
const workflow = () => Bun.YAML.parse(source);

test("CI checks pull requests and main without losing release tags or manual dry runs", () => {
    expect(workflow()).toHaveProperty("on.push", { branches: ["main"], tags: ["v*"] });
    expect(workflow()).toHaveProperty("on.pull_request");
    expect(workflow()).toHaveProperty("on.workflow_dispatch.inputs.tag.default", "v0.1.0");
});

test("superseded checks coalesce by PR or ref without cancelling serialized releases", () => {
    expect(workflow()).toHaveProperty("concurrency", {
        group: "${{ (startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch') && 'release-publication' || format('build-{0}', github.event.pull_request.number || github.ref) }}",
        "cancel-in-progress": "${{ !startsWith(github.ref, 'refs/tags/v') && github.event_name != 'workflow_dispatch' }}",
    });
});

test("native icon coverage runs explicitly on the Mac runner", () => {
    expect(workflow()).toMatchObject({
        jobs: {
            test: {
                "runs-on": "xcode-27",
                steps: expect.arrayContaining([{
                    name: "Test native icon tooling",
                    run: "bun test scripts/shared/mobile-icon.test.ts",
                }]),
            },
        },
    });
});

test("the Mac gate emits unbuffered progress and preserves bounded hang diagnostics", () => {
    expect(workflow()).toHaveProperty("jobs.test.timeout-minutes", 20);
    expect(workflow()).toHaveProperty("jobs.test.steps", expect.arrayContaining([
        expect.objectContaining({
            name: "Test",
            env: expect.objectContaining({ NSUnbufferedIO: "YES" }),
            run: "bun scripts/shared/test-watchdog.ts --skip ChannelClientTests",
        }),
        expect.objectContaining({
            name: "Upload blocked test diagnostics",
            if: "failure()",
            with: expect.objectContaining({ path: "${{ runner.temp }}/toy-box-tests/mac-test-watchdog/*.txt" }),
        }),
    ]));
});

test("the Mac gate constrains ChannelClient to one cooperative worker", () => {
    expect(workflow()).toHaveProperty("jobs.test.steps", expect.arrayContaining([
        expect.objectContaining({
            name: "Test ChannelClient with a single cooperative worker",
            env: expect.objectContaining({
                NSUnbufferedIO: "YES",
                LIBDISPATCH_COOPERATIVE_POOL_STRICT: "1",
            }),
            run: "bun scripts/shared/test-watchdog.ts --filter ChannelClientTests",
        }),
    ]));
});

test("release checks run shared, desktop and mobile tooling once", () => {
    expect(workflow()).toHaveProperty("jobs.release-checks.steps", expect.arrayContaining([
        {
            name: "Test tooling with fake commands",
            run: "bun test scripts/shared scripts/desktop scripts/mobile",
        },
    ]));
    expect(source).not.toContain("name: Test development tooling");
    expect(source).not.toContain("run: bun run test:release");
});

test("iOS runs for main and pull requests, not release tags or manual dry runs", () => {
    expect(workflow()).toHaveProperty("jobs.mobile.if",
        "github.event_name == 'pull_request' || (github.event_name == 'push' && github.ref == 'refs/heads/main')");
    expect(workflow()).toHaveProperty("jobs.release.needs", ["test", "release-checks"]);
});

test("bundle qualification runs only in the release job and reuses its optimized build", () => {
    const bundle = expect.objectContaining({ name: "Bundle with Siri and Shortcuts metadata" });
    expect(workflow()).not.toHaveProperty("jobs.test.steps", expect.arrayContaining([bundle]));
    expect(workflow()).toHaveProperty("jobs.release.steps", expect.arrayContaining([
        expect.objectContaining({
            name: "Bundle with Siri and Shortcuts metadata",
            env: {
                CONFIGURATION: "release",
                SCRATCH_PATH: "${{ runner.temp }}/toy-box-release",
            },
            run: expect.stringContaining("bun test scripts/desktop/bundle/native.test.ts"),
        }),
    ]));
});

test("workflow actions remain pinned to full commit hashes with readable versions", () => {
    const actions = [...source.matchAll(/uses:\s+([^\s#]+)([^\n]*)/g)];
    expect(actions.length).toBeGreaterThan(0);
    for (const [, reference, comment] of actions) {
        expect(reference).toMatch(/@[a-f0-9]{40}$/);
        expect(comment).toMatch(/# v\d/);
    }
});

test("Mac builds require changelog notes and publish the same file instead of generated notes", () => {
    const steps = source.split("\n").filter(line => line.startsWith("      - name: "));
    expect(steps).toContain("      - name: Require the Mac changelog entry");
    expect(steps.indexOf("      - name: Require the Mac changelog entry"))
        .toBeLessThan(steps.indexOf("      - name: Bundle with Siri and Shortcuts metadata"));
    expect(source).toContain('--notes-file dist/release-notes.md');
    expect(source).not.toContain("--generate-notes");
    expect(source).not.toContain("Fetch annotated release tag");
});
