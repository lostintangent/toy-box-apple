#!/usr/bin/env bun
import { createHistoryFixture, historyChannelID, historyMessageCount, historyPageSize, writeHistoryPage }
    from "./channels/history-channel.ts";
import { catalogEntry, createCatalogRoute, workingAgents } from "./channels/catalog-stream.ts";
import { createDemoServer, loadDemoFixture } from "./channels/demo-server.ts";
import { createDemoServerRoutes } from "./channels/server-routes.ts";
import { type Snapshot } from "./channels/types.ts";

if (process.argv.length > 2) throw new Error("Usage: bun run demo:history");
const source: Snapshot = loadDemoFixture();
const port = Number(process.env.TOY_BOX_DEMO_PORT ?? 3211);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid TOY_BOX_DEMO_PORT.");
const now = Date.now();
const { snapshot, history } = createHistoryFixture(source, { now, origin: `http://127.0.0.1:${port}` });
const channelID = historyChannelID;

const demo = createDemoServer(snapshot, now, history);
const catalog = createCatalogRoute(() => {
    const { lead: { name, role, avatar }, channel, request, members, presence } = demo.snapshot();
    return {
        lead: { name, role, avatar }, channels: [catalogEntry(channel, request)], members,
        working: workingAgents(presence),
    };
});
demo.onChange(catalog.publish);
// It has no installed release, so it offers no update.
const release = createDemoServerRoutes(demo.server, { id: `history-demo-${port}`, computer: "History Demo", mode: "unmanaged" });
const handlers = demo.server.listeners("request");
if (handlers.length !== 1) throw new Error("Expected the demo server's single HTTP handler.");
const originalHandler = handlers[0];
demo.server.removeListener("request", originalHandler);
demo.server.on("request", (request, response) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
    if (request.method === "GET" && url.pathname === "/api/v1/channels") {
        catalog.serve(request, response);
        return;
    }
    if (release.handle(request, response, url)) return;
    if (url.pathname === `/api/v1/channels/${channelID}/messages`) {
        if (request.method !== "GET") {
            response.writeHead(405, { "Content-Type": "application/json", Allow: "GET" });
            response.end(JSON.stringify({ error: "This history fixture supports read receipts, not message sends." }));
            return;
        }
        writeHistoryPage(response, url, history, demo.snapshot().revision);
        return;
    }
    originalHandler(request, response);
});
demo.server.on("error", error => { console.error(error); process.exitCode = 1; });
demo.server.listen(port, "127.0.0.1", () => {
    console.log(`History fixture: http://127.0.0.1:${port} · channel ${channelID}`);
    console.log(`${historyMessageCount} messages, ${historyPageSize} per page, seen through 450, pending request ${historyMessageCount}.`);
    console.log("Read receipts are isolated here. The studio-demo server on 3210 is untouched.");
});
for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.once(signal, () => {
        catalog.close();
        void demo.close().catch(error => { console.error(error); process.exitCode = 1; });
    });
}
