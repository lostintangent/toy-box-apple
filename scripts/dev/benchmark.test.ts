import { expect, test } from "bun:test";
import { benchmarkLaunchCommand } from "./benchmark.ts";

const options = {
    app: "/tmp/benchmark with spaces/Toy Box Benchmark.app", scenario: "scroll",
    out: "/tmp/results/scroll.out", err: "/tmp/results/scroll.err",
    server: "http://127.0.0.1:3292", channel: "scroll-demo",
};

test.each(["table", "lazy", undefined])("open forwards transcript selection %s to the app", transcript => {
    const command = benchmarkLaunchCommand({ ...options, transcript });
    expect(command.slice(command.indexOf("--env"), command.indexOf("--stdout")))
        .toEqual(["--env", `TOY_BOX_TRANSCRIPT=${transcript ?? "lazy"}`]);
    expect(command.slice(command.indexOf(options.app))).toEqual([
        options.app, "--args", "--server", options.server, "--channel", options.channel,
        "--benchmark", "scroll", "-ApplePersistenceIgnoreState", "YES",
    ]);
    expect(command).toContain("-g");
    expect(command).toContain("-W");
});

test("only the key-window scenario takes focus", () => {
    expect(benchmarkLaunchCommand({ ...options, scenario: "key", transcript: "table" })).not.toContain("-g");
});
