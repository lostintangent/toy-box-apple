#!/usr/bin/env bun
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const reference = resolve(process.argv[2] ?? resolve(root, "../toy-box-Minecraft"));
const { createDemoServer } = await import(pathToFileURL(resolve(reference, "tools/demo-server.ts")).href);
const source = JSON.parse(readFileSync(resolve(reference, "fixtures/channel-snapshot.json"), "utf8"));
const channelID = "history-demo";
const port = 3211;
const pageSize = 100;
const messageCount = 480;
const now = Date.now();

function remap(value) {
    if (value === "studio-demo") return channelID;
    if (Array.isArray(value)) return value.map(remap);
    if (value && typeof value === "object") {
        return Object.fromEntries(Object.entries(value).map(([key, child]) =>
            [key === "studio-demo" ? channelID : key, remap(child)]));
    }
    return value;
}

const snapshot = remap(source);
const agents = [snapshot.lead, ...snapshot.members];
const history = Array.from({ length: messageCount }, (_, index) => {
    const sequence = index + 1;
    const timestamp = new Date(now - (messageCount - sequence) * 20 * 60_000).toISOString();
    if (index < snapshot.messages.length) return { ...snapshot.messages[index], timestamp };
    const agent = agents[index % agents.length];
    const sender = sequence % 9 === 0 ? { type: "user" } : { type: "agent", agentId: agent.id };
    const content = sequence % 17 === 0
        ? `History message ${sequence}\n\nA measured checkpoint for paging.\n\n- Preserve the visible row\n- Keep read receipts monotonic\n- Leave requests unanswered by reads`
        : `History message ${sequence}: the workshop keeps older decisions available while the team continues its current work.`;
    return { id: `history-message-${sequence}`, sequence, timestamp, sender, content };
});
const request = {
    ...snapshot.request, id: "history-request", sequence: messageCount,
    timestamp: new Date(now).toISOString(),
    content: "Please confirm the history review. Reading or paging must not answer this request.",
};
history[messageCount - 1] = request;
Object.assign(snapshot.channel, {
    name: "History demo", purpose: "An isolated long-history fixture for native paging, unread landing and read receipts.",
    latestSequence: messageCount, seenThrough: 450, requestSequence: messageCount,
    completedSequence: null, updatedAt: new Date(now).toISOString(),
    previewUrl: `http://127.0.0.1:${port}/demo-preview`,
});
snapshot.revision = messageCount;
snapshot.messages = history.slice(-pageSize);
snapshot.request = request;
if (snapshot.lead.status?.wakeAt) snapshot.lead.status.wakeAt = new Date(now + 10 * 60_000).toISOString();

const demo = createDemoServer(snapshot, now);
const handlers = demo.server.listeners("request");
if (handlers.length !== 1) throw new Error("Expected the reference demo server's single HTTP handler.");
const originalHandler = handlers[0];
demo.server.removeListener("request", originalHandler);
demo.server.on("request", (request, response) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
    if (request.method === "GET" && url.pathname === "/api/v1/channels") {
        const current = demo.snapshot();
        const { name, role, avatar } = current.lead;
        response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
        response.end(JSON.stringify({
            version: 1, lead: { name, role, avatar }, channels: [current.channel], members: current.members,
        }));
        return;
    }
    if (url.pathname === `/api/v1/channels/${channelID}/messages`) {
        if (request.method !== "GET") {
            response.writeHead(405, { "Content-Type": "application/json", Allow: "GET" });
            response.end(JSON.stringify({ error: "This history fixture supports read receipts, not message sends." }));
            return;
        }
        // Match getChannelHistoryResponse and listMessagesBefore without loading the live database.
        const before = Number(url.searchParams.get("before"));
        const valid = Number.isSafeInteger(before) && before > 0;
        response.writeHead(valid ? 200 : 400, {
            "Content-Type": "application/json", ...(valid ? { "Cache-Control": "no-store" } : {}),
        });
        response.end(JSON.stringify(valid ? {
            version: 1, revision: demo.snapshot().revision,
            messages: history.filter(message => message.sequence < before).slice(-pageSize),
        } : { error: "Invalid Channel request." }));
        return;
    }
    originalHandler(request, response);
});
demo.server.on("error", error => { console.error(error); process.exitCode = 1; });
demo.server.listen(port, "127.0.0.1", () => {
    console.log(`History fixture: http://127.0.0.1:${port} · channel ${channelID}`);
    console.log(`${messageCount} messages, ${pageSize} per page, seen through 450, pending request ${messageCount}.`);
    console.log("Read receipts are isolated here. The studio-demo server on 3210 is untouched.");
});
for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, () => {
        void demo.close().catch(error => { console.error(error); process.exitCode = 1; });
    });
}
