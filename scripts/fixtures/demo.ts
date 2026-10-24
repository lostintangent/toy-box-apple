#!/usr/bin/env bun
import { resolve } from "node:path";
import { root } from "../lib.ts";
import { referenceFactory, type Snapshot } from "./types.ts";

const reference = resolve(process.argv[2] ?? resolve(root, "../toy-box-Minecraft"));
const createDemoServer = await referenceFactory(reference);
const port = Number(process.env.TOY_BOX_DEMO_PORT ?? 3210);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid TOY_BOX_DEMO_PORT.");

const snapshotPath = process.env.TOY_BOX_DEMO_SNAPSHOT;
const initial: Snapshot | undefined = snapshotPath ? await Bun.file(snapshotPath).json() : undefined;
const demo = createDemoServer(initial);
// The reference factory makes dates recent. Restore an exported snapshot without that adjustment.
if (initial) demo.replace(initial);
const handlers = demo.server.listeners("request");
if (handlers.length !== 1) throw new Error("Expected the reference demo server's single HTTP handler.");
const originalHandler = handlers[0];
demo.server.removeListener("request", originalHandler);
demo.server.on("request", (request, response) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
    if (request.method === "GET" && url.pathname === "/api/v1/channels") {
        const snapshot = demo.snapshot();
        const { name, role, avatar } = snapshot.lead;
        response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
        response.end(JSON.stringify({
            version: 1, lead: { name, role, avatar }, channels: [snapshot.channel], members: snapshot.members,
        }));
        return;
    }
    originalHandler(request, response);
});
demo.server.on("error", error => { console.error(error); process.exitCode = 1; });
demo.server.listen(port, "127.0.0.1", () => {
    console.log(`Toy Box fixture: http://127.0.0.1:${port} · channel studio-demo`);
    console.log("The catalog serves the fixture's lead profile. No agents or models run.");
});
for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.once(signal, () => {
        void demo.close().catch(error => { console.error(error); process.exitCode = 1; });
    });
}
