import { expect, test } from "bun:test";
import { benchmarkLaunchCommand } from "./benchmark.ts";

const options = {
    app: "/tmp/benchmark with spaces/Toy Box Benchmark.app", scenario: "scroll",
    out: "/tmp/results/scroll.out", err: "/tmp/results/scroll.err",
    server: "http://127.0.0.1:3292", channel: "scroll-demo",
};

test.each(["table", "document", "lazy", "native-control", undefined])("open forwards transcript selection %s to the app", transcript => {
    const command = benchmarkLaunchCommand({ ...options, transcript });
    expect(command.slice(command.indexOf("--env"), command.indexOf("--stdout")))
        .toEqual(["--env", `TOY_BOX_TRANSCRIPT=${transcript ?? "lazy"}`,
            "--env", "TOY_BOX_BENCHMARK_SCROLL_DRIFT=1",
            "--env", "TOY_BOX_BENCHMARK_SCROLL_TRACE=0"]);
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

test("the opt-in trackpad check stays background-only", () => {
    const command = benchmarkLaunchCommand({ ...options, scenario: "trackpad", transcript: "table" });
    expect(command).toContain("-g");
    expect(command.slice(command.indexOf("--benchmark"), command.indexOf("--benchmark") + 2))
        .toEqual(["--benchmark", "trackpad"]);
});

test("the probe overhead control is forwarded independently of transcript selection", () => {
    const command = benchmarkLaunchCommand({ ...options, transcript: "lazy", scrollDrift: "0" });
    expect(command).toContain("TOY_BOX_TRANSCRIPT=lazy");
    expect(command).toContain("TOY_BOX_BENCHMARK_SCROLL_DRIFT=0");
});

test("signed frame tracing is explicitly opt-in", () => {
    const command = benchmarkLaunchCommand({ ...options, transcript: "lazy", scrollTrace: "1" });
    expect(command).toContain("TOY_BOX_BENCHMARK_SCROLL_TRACE=1");
});
