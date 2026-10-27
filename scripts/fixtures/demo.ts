#!/usr/bin/env bun
import { resolve } from "node:path";
import { root } from "../lib.ts";
import { referenceFactory, type Demo, type Snapshot } from "./types.ts";
import { createDemoPushRoutes } from "./push-routes.ts";

export function installDemoCatalogRoutes(demo: Pick<Demo, "server" | "snapshot">) {
    const push = createDemoPushRoutes(demo.snapshot);
    const handlers = demo.server.listeners("request");
    if (handlers.length !== 1) throw new Error("Expected the reference demo server's single HTTP handler.");
    const originalHandler = handlers[0];
    demo.server.removeListener("request", originalHandler);
    demo.server.on("request", (request, response) => {
        const url = new URL(request.url ?? "/", "http://127.0.0.1");
        const route = push.match(url.pathname);
        if (route) {
            void push.handle(request, response, route).catch(error => {
                console.error("Demo push registration failed:", error);
                response.writeHead(500, { "Content-Type": "application/json" });
                response.end(JSON.stringify({ error: "Could not register push delivery." }));
            });
            return;
        }
        if (request.method === "GET" && ["/api/v1/channels", "/api/v1/models"].includes(url.pathname)) {
            const snapshot = demo.snapshot();
            const { name, role, avatar } = snapshot.lead;
            const model = snapshot.channel.model;
            const body = url.pathname === "/api/v1/models"
                ? {
                    version: 1, provider: model.provider, defaultModel: model,
                    models: [{ id: model.name, name: model.name, provider: model.provider }],
                }
                : { version: 1, lead: { name, role, avatar }, channels: [snapshot.channel], members: snapshot.members };
            response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
            response.end(JSON.stringify(body));
            return;
        }
        originalHandler(request, response);
    });
    return push;
}

if (import.meta.main) {
    const reference = resolve(process.argv[2] ?? resolve(root, "../toy-box-Minecraft"));
    const createDemoServer = await referenceFactory(reference);
    const port = Number(process.env.TOY_BOX_DEMO_PORT ?? 3210);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid TOY_BOX_DEMO_PORT.");

    const snapshotPath = process.env.TOY_BOX_DEMO_SNAPSHOT;
    const initial: Snapshot | undefined = snapshotPath ? await Bun.file(snapshotPath).json() : undefined;
    const demo = createDemoServer(initial);
    // The reference factory makes dates recent. Restore an exported snapshot without that adjustment.
    if (initial) demo.replace(initial);
    installDemoCatalogRoutes(demo);
    demo.server.on("error", error => { console.error(error); process.exitCode = 1; });
    demo.server.listen(port, "127.0.0.1", () => {
        console.log(`Toy Box fixture: http://127.0.0.1:${port} · channel studio-demo`);
        console.log("The catalog serves the fixture's lead profile and configured model. No agents or models run.");
    });
    for (const signal of ["SIGINT", "SIGTERM"] as const) {
        process.once(signal, () => {
            void demo.close().catch(error => { console.error(error); process.exitCode = 1; });
        });
    }
}
