import { expect, test } from "bun:test";
import { MobileDriveSession, parseMobileDrive, parseMobileDriveStatus, runMobileDriveCommand } from "./mobile-drive.ts";

test("drive actions are strict and native display identifiers are normalized", () => {
    expect(parseMobileDrive([{ tap: "Studio demo" }, { type: "Hello" }, { wait: "Needs you", timeout: 20 },
        { screenshot: "reply", display: 3 }, { back: true }, { fold: false }])).toEqual([
        { tap: "Studio demo" }, { type: "Hello" }, { wait: "Needs you", timeout: 20 },
        { screenshot: "reply", display: "3" }, { back: true }, { fold: false },
    ]);
    expect(parseMobileDrive([{ screenshot: "default" }])).toEqual([{ screenshot: "default", display: "1" }]);
    expect(parseMobileDrive([{ back: true, ifPresent: true }])).toEqual([{ back: true, ifPresent: true }]);
    expect(parseMobileDrive([{ action: "Reply", on: "message-12" }]))
        .toEqual([{ action: "Reply", on: "message-12" }]);
    expect(parseMobileDrive([{ wait: "Replying to Lead", absent: true }]))
        .toEqual([{ wait: "Replying to Lead", absent: true }]);
    for (const direction of ["up", "down", "left", "right"] as const) {
        expect(parseMobileDrive([{ scroll: direction, on: "overview-form", timeout: 20 }]))
            .toEqual([{ scroll: direction, on: "overview-form", timeout: 20 }]);
    }
    expect(parseMobileDrive([{ posture: "folded" }, { posture: "unfolded", timeout: 60 }]))
        .toEqual([{ posture: "folded" }, { posture: "unfolded", timeout: 60 }]);
    for (const value of [[], {}, [{}], [{ tap: "x", wait: "x" }], [{ type: "" }], [{ back: false }],
        [{ fold: 1 }], [{ tap: "x", display: 1 }], [{ screenshot: "x", display: 0 }],
        [{ screenshot: "x", display: "primary" }], [{ wait: "x", timeout: 0 }],
        [{ wait: "x", timeout: 61 }], [{ tap: "x", typo: true }], [{ tap: "x", ifPresent: true }],
        [{ back: true, ifPresent: "yes" }], [{ action: "Reply" }], [{ action: "Reply", on: "" }],
        [{ tap: "Reply", on: "message-12" }], [{ wait: "x", absent: "yes" }], [{ tap: "x", absent: true }],
        [{ scroll: "down" }], [{ scroll: "down", on: "" }], [{ scroll: "forward", on: "form" }],
        [{ scroll: "up", on: "form", display: 1 }],
        [{ posture: "open" }], [{ posture: 0 }], [{ posture: "folded", fold: true }],
        [{ posture: "folded", display: 1 }], [{ posture: "folded", scroll: "down", on: "form" }],
        [{ posture: "folded", on: "form" }]]) {
        expect(() => parseMobileDrive(value)).toThrow();
    }
});

test("posture is observed by the app and never invokes a host fold command", async () => {
    const session = new MobileDriveSession(drive([{ posture: "unfolded" }]), { capture: unexpected, fold: unexpected });
    expect(await session.accept({ ...frame, state: "running" })).toBeUndefined();
    expect(session.completed).toBe(false);
    await session.accept({ ...frame, state: "completed", viewport: [871, 669] });
    expect(session.completed).toBe(true);
    expect(session.screenshots).toEqual([]);
});

test("malformed app statuses never look like completion", () => {
    expect(() => parseMobileDriveStatus({ state: "completed" })).toThrow("invalid drive status");
    expect(() => parseMobileDriveStatus({ state: "completed", step: -1, labels: [], viewport: [] })).toThrow();
    expect(() => parseMobileDriveStatus({ state: "ready", step: 0, labels: [7], viewport: [] })).toThrow();
});

const frame = { step: 0, labels: ["Message"], viewport: [440, 956] };
const unexpected = async () => { throw new Error("Unexpected host action"); };
function drive(steps: unknown) {
    return { steps: parseMobileDrive(steps), directory: "", script: "", output: "/captures" };
}

test("settled capture completes before acknowledgement and never repeats", async () => {
    const captures: string[] = [];
    let finish!: () => void;
    const captured = new Promise<void>(resolve => { finish = resolve; });
    const session = new MobileDriveSession(drive([{ screenshot: "reply" }]), {
        async capture(path, display) {
            captures.push(`${display}:${path}`);
            await captured;
        },
        fold: unexpected,
    });
    const acknowledgement = session.accept({ ...frame, state: "ready" });
    expect(session.screenshots).toEqual([]);
    expect(session.completed).toBe(false);
    finish();
    expect(await acknowledgement).toEqual({ step: 0 });
    expect(await session.accept({ ...frame, state: "ready" })).toBeUndefined();
    await session.accept({ ...frame, state: "completed" });
    expect(session.completed).toBe(true);
    expect(session.screenshots).toEqual(["/captures/reply.png"]);
    expect(captures).toEqual(["1:/captures/reply.png"]);
});

test("an app failure reports its exact step and accessible labels", async () => {
    const session = new MobileDriveSession(drive([{ tap: "Send" }]), { capture: unexpected, fold: unexpected });
    await expect(session.accept({ ...frame, state: "failed", labels: ["Studio demo", "Message"],
        error: "Timed out waiting for Send." })).rejects.toThrow(
        "Drive step 1 failed: Timed out waiting for Send.\nVisible accessibility labels:\n  Studio demo\n  Message");
});

test("host errors are acknowledged once and cannot become successful completion", async () => {
    let captures = 0;
    const session = new MobileDriveSession(drive([{ screenshot: "reply" }]), {
        async capture() { captures++; throw new Error("Display unavailable"); }, fold: unexpected,
    });
    expect(await session.accept({ ...frame, state: "ready" })).toEqual({ step: 0, error: "Display unavailable" });
    expect(await session.accept({ ...frame, state: "ready" })).toBeUndefined();
    expect(captures).toBe(1);
    expect(session.screenshots).toEqual([]);
    await expect(session.accept({ ...frame, state: "completed" })).rejects.toThrow("Display unavailable");
    expect(session.completed).toBe(false);
});

test("completion cannot skip actions or host acknowledgements", async () => {
    const host = { capture: unexpected, fold: unexpected };
    const session = new MobileDriveSession(drive([{ screenshot: "folded" }, { tap: "Back" }]), host);
    await expect(session.accept({ ...frame, state: "completed" })).rejects.toThrow("before every scripted action");
    await expect(session.accept({ ...frame, state: "completed", step: 1 })).rejects.toThrow("skipped host acknowledgement");
    await expect(session.accept({ ...frame, state: "running", step: 2 })).rejects.toThrow("unknown step");
});

test("fold uses the same single acknowledgement handshake", async () => {
    const folds: boolean[] = [];
    const session = new MobileDriveSession(drive([{ fold: false }]), {
        capture: unexpected, async fold(closed) { folds.push(closed); },
    });
    expect(await session.accept({ ...frame, state: "ready" })).toEqual({ step: 0 });
    expect(await session.accept({ ...frame, state: "ready" })).toBeUndefined();
    await session.accept({ ...frame, state: "completed", viewport: [810, 1080] });
    expect(folds).toEqual([false]);
    expect(session.completed).toBe(true);
});

for (const reason of ["timeout", "cancellation"]) {
    test(`a stalled host ${reason} waits for child termination and cannot acknowledge success`, async () => {
        const deadline = new AbortController();
        const cancellation = new AbortController();
        let finish!: (exit: number) => void;
        const exited = new Promise<number>(resolve => { finish = resolve; });
        let stopped = false;
        let settled = false;
        const session = new MobileDriveSession(drive([{ screenshot: "reply" }]), {
            async capture(_path, _display, signal) {
                await runMobileDriveCommand(["controlled-child"], {}, signal, (_args, childSignal) => {
                    childSignal.addEventListener("abort", () => { stopped = true; }, { once: true });
                    const empty = () => new ReadableStream<Uint8Array>({ start(controller) { controller.close(); } });
                    return { exited, stdout: empty(), stderr: empty(), kill() { stopped = true; } };
                });
            },
            fold: unexpected,
        });
        const pending = session.accept({ ...frame, state: "ready" }, cancellation.signal, deadline.signal);
        void pending.then(() => { settled = true; });
        const controller = reason === "timeout" ? deadline : cancellation;
        controller.abort(new Error(`Host ${reason}`));
        expect(stopped).toBe(true);
        expect(settled).toBe(false);
        finish(137);
        expect(await pending).toEqual({ step: 0, error: `Host ${reason}` });
        expect(session.screenshots).toEqual([]);
        expect(await session.accept({ ...frame, state: "ready" })).toBeUndefined();
        await expect(session.accept({ ...frame, state: "completed" })).rejects.toThrow(`Host ${reason}`);
        expect(session.completed).toBe(false);
    });
}
