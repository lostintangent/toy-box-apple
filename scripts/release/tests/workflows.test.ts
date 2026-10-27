import { expect, test } from "bun:test";
import { join } from "node:path";
import { root } from "../../lib.ts";

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
                    run: "bun test scripts/dev/mobile-icon.test.ts",
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
            run: "bun scripts/dev/test-watchdog.ts",
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
            run: "bun scripts/dev/test-watchdog.ts --filter ChannelClientTests",
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
