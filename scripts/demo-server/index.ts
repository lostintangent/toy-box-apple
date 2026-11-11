#!/usr/bin/env bun
import { parseArgs } from "node:util";
import { catalogEntry, createCatalogRoute, workingAgents } from "./channels/catalog-stream.ts";
import { createDemoServer, type DemoServer } from "./channels/demo-server.ts";
import { type Snapshot } from "./channels/types.ts";
import { createDemoPushRoutes } from "./channels/push-routes.ts";
import { writeHistoryPage } from "./channels/history-channel.ts";
import { createDemoScreens } from "./channels/screens.ts";

export function installDemoCatalogRoutes(demo: Pick<DemoServer, "server" | "snapshot" | "onChange">) {
    const push = createDemoPushRoutes();
    const screens = createDemoScreens();
    demo.server.on("upgrade", screens.upgrade);
    const catalog = createCatalogRoute(() => {
        const { lead: { name, role, avatar }, channel, request, members, presence } = demo.snapshot();
        return {
            lead: { name, role, avatar }, channels: [catalogEntry(channel, request)], members,
            working: workingAgents(presence),
        };
    });
    demo.onChange(catalog.publish);
    const handlers = demo.server.listeners("request");
    if (handlers.length !== 1) throw new Error("Expected the demo server's single HTTP handler.");
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
        if (screens.handle(request, response, url)) return;
        const snapshot = demo.snapshot();
        if (request.method === "GET"
            && url.pathname === `/api/v1/channels/${encodeURIComponent(snapshot.channel.id)}/messages`) {
            writeHistoryPage(response, url, snapshot.messages, snapshot.revision);
            return;
        }
        if (request.method === "GET" && url.pathname === "/api/v1/channels") {
            catalog.serve(request, response);
            return;
        }
        if (request.method === "GET" && url.pathname === "/api/v1/models") {
            const model = snapshot.channel.model;
            response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
            response.end(JSON.stringify({
                provider: model.provider, defaultModel: model,
                models: [{ id: model.name, name: model.name, provider: model.provider }],
            }));
            return;
        }
        originalHandler(request, response);
    });
    return { push, catalog, screens };
}

if (import.meta.main) {
    const { positionals } = parseArgs({ args: process.argv.slice(2), allowPositionals: true, options: {} });
    if (positionals.length) throw new Error("Usage: bun run demo");
    const port = Number(process.env.TOY_BOX_DEMO_PORT ?? 3210);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid TOY_BOX_DEMO_PORT.");
    const snapshotPath = process.env.TOY_BOX_DEMO_SNAPSHOT;
    const initial: Snapshot | undefined = snapshotPath ? await Bun.file(snapshotPath).json() : undefined;
    const demo = createDemoServer(initial);
    // The demo server makes dates recent. Restore an exported snapshot without that adjustment.
    if (initial) demo.replace(initial);
    if (process.env.TOY_BOX_DEMO_LONG_MARKDOWN !== undefined) {
        if (process.env.TOY_BOX_DEMO_LONG_MARKDOWN !== "1") {
            throw new Error("TOY_BOX_DEMO_LONG_MARKDOWN must be 1.");
        }
        const snapshot = demo.snapshot();
        const messages: Snapshot["messages"] = snapshot.messages;
        const message = messages.find(({ id }) => id === "fixture-progress");
        if (!message) throw new Error("The demo snapshot has no fixture-progress message.");
        message.content = (await Bun.file(new URL("./fixtures/progress-message.md", import.meta.url)).text()).trimEnd();
        demo.replace(snapshot);
        const artifacts: Snapshot["artifacts"] = demo.snapshot().artifacts;
        const artifact = artifacts.find(({ id }) => id === "machine:/demo/Interaction notes.md");
        if (!artifact) throw new Error("The demo snapshot has no Interaction notes artifact.");
        demo.setResource(artifact.url, await Bun.file(
            new URL("./fixtures/interaction-notes-long.md", import.meta.url)
        ).text());
    }
    const { catalog, screens } = installDemoCatalogRoutes(demo);
    demo.server.on("error", error => { console.error(error); process.exitCode = 1; });
    demo.server.listen(port, "127.0.0.1", () => {
        console.log(`Toy Box fixture: http://127.0.0.1:${port} · channel ${demo.snapshot().channel.id}`);
        console.log("The catalog serves the fixture's lead profile and configured model. No agents or models run.");
    });
    for (const signal of ["SIGINT", "SIGTERM"] as const) {
        process.once(signal, () => {
            catalog.close();
            screens.close();
            void demo.close().catch(error => { console.error(error); process.exitCode = 1; });
        });
    }
}
