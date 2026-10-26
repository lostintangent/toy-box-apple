import { expect, test } from "bun:test";
import { checkMobileTestCompletion } from "./test-mobile.ts";

test("the iOS runner rejects a successful process without a completed test run", () => {
    expect(() => checkMobileTestCompletion("")).toThrow();
    expect(() => checkMobileTestCompletion("Test run started.")).toThrow();
    expect(() => checkMobileTestCompletion("Test run started.\nTest run with 0 tests passed after 0.1 seconds.")).toThrow();
});

test("the iOS runner propagates failed or interrupted Swift Testing runs", () => {
    expect(() => checkMobileTestCompletion("Test run started.\nTest run with 3 tests failed after 0.1 seconds.")).toThrow();
    expect(() => checkMobileTestCompletion(
        "Test run started.\nTest run with 3 tests passed after 0.1 seconds.\nTest run started.")).toThrow();
});

test("the iOS runner accepts a nonempty completed run", () => {
    expect(() => checkMobileTestCompletion(
        "Test run started.\nTest run with 3 tests in 2 suites passed after 0.1 seconds.")).not.toThrow();
});
