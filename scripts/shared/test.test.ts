import { expect, test } from "bun:test";
import { checkTestCompletion } from "./test.ts";
import { FakeHarness } from "./test-helpers.ts";

test("test-run completion guards reject partial Swift Testing and XCTest runs", () => {
    checkTestCompletion("Test run started.\nTest run with 1 test in 1 suite passed after 0.1 seconds.");
    checkTestCompletion("Test Suite 'All tests' started\nTest Suite 'All tests' passed");
    expect(() => checkTestCompletion("Test run started.")).toThrow("remaining tests never ran");
    expect(() => checkTestCompletion("Test Suite 'Selected tests' started")).toThrow("remaining tests never ran");
});

test("the Bun test entrypoint preserves nonzero Swift exits and rejects success without a summary", async () => {
    const fake = await FakeHarness.create();
    try {
        expect((await fake.script("shared/test.ts", [], { TEST_LOG: "Test run started.\n" })).code).toBe(1);
        expect((await fake.script("shared/test.ts", [], { TEST_EXIT: "23" })).code).toBe(23);
        const result = await fake.script("shared/test.ts", ["--filter", "ComposerTests"], {
            TEST_LOG: "Test run started.\nTest run with 1 test passed after 0.1 seconds.\n",
        });
        expect(result.code).toBe(0);
        expect((await fake.calls("xcrun")).at(-1)?.args.slice(-2)).toEqual(["--filter", "ComposerTests"]);
    } finally { await fake.dispose(); }
});
