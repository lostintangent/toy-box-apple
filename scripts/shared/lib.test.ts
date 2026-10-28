import { expect, test } from "bun:test";
import { rm } from "node:fs/promises";

test.skipIf(process.platform !== "darwin")("the machine lock identifies its holder and releases on process exit", async () => {
    const name = `lock-test-${crypto.randomUUID()}`;
    const source = `import { machineLock } from ${JSON.stringify(new URL("./lib.ts", import.meta.url).href)};`;
    const ready = Promise.withResolvers<void>();
    const acquired = Promise.withResolvers<void>();
    const holder = Bun.spawn([process.execPath, "--eval", `${source}
        await machineLock(${JSON.stringify(name)});
        process.send("ready");
        process.on("message", () => process.exit(0));`], {
        stdout: "pipe", stderr: "pipe",
        ipc(message) { if (message === "ready") ready.resolve(); },
    });
    let contender: ReturnType<typeof Bun.spawn> | undefined;
    try {
        await ready.promise;
        const waiting = Bun.spawn([process.execPath, "--eval", `${source}
            const unlock = await machineLock(${JSON.stringify(name)});
            process.send("acquired"); unlock(); process.exit(0);`], {
            stdout: "pipe", stderr: "pipe",
            ipc(message) { if (message === "acquired") acquired.resolve(); },
        });
        contender = waiting;
        const output = await waiting.stdout.getReader().read();
        expect(new TextDecoder().decode(output.value)).toContain(`held by PID ${holder.pid}`);
        holder.send("release");
        expect(await holder.exited).toBe(0);
        await acquired.promise;
        expect(await waiting.exited).toBe(0);
    } finally {
        if (holder.exitCode === null) holder.kill();
        if (contender?.exitCode === null) contender.kill();
        await holder.exited;
        if (contender) await contender.exited;
        await rm(`/tmp/toy-box-${name}.lock`, { force: true });
    }
});
