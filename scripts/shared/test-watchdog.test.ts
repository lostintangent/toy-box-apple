import { expect, test } from "bun:test";
import { testProcessTree } from "./test-watchdog.ts";

test("the test watchdog targets only its own process tree, including nested test runners", () => {
    const processes = `
  41  40 /usr/bin/swiftpm-testing
  40  30 /Applications/Xcode 27.app/usr/bin/swift
  90   1 /usr/bin/swiftpm-testing
  42  40 /usr/bin/xctest
  30  20 /opt/homebrew/bin/bun
  20   1 /opt/homebrew/bin/bun
`;
    expect(testProcessTree(processes, 30)).toEqual([
        { pid: 41, parent: 40, command: "/usr/bin/swiftpm-testing" },
        { pid: 40, parent: 30, command: "/Applications/Xcode 27.app/usr/bin/swift" },
        { pid: 42, parent: 40, command: "/usr/bin/xctest" },
        { pid: 30, parent: 20, command: "/opt/homebrew/bin/bun" },
    ]);
});

test("an exited test process does not select unrelated helpers or malformed process rows", () => {
    expect(testProcessTree("90 1 /usr/bin/swiftpm-testing\nmalformed\n 12 not-a-pid /bin/test", 30)).toEqual([]);
});
