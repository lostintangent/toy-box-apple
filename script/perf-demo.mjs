#!/usr/bin/env bun
// The benchmark fixture that script/benchmark starts for each scenario. It serves studio-demo and
// the 480-message history-demo on one port, through the reference demo server imported read-only,
// and adds one route the benchmark drives:
//
//   POST /perf/messages?channel=ID&count=N&interval=MS
//
// It answers at once with the sequences it will use, then streams N agent messages to that
// channel's open streams, MS apart. Its messages stay out of the reference server's history, so a
// reconnect drops them. Each benchmark launch starts a fresh fixture.
//
// Usage: bun script/perf-demo.mjs [path to toy-box-Minecraft]. TOY_BOX_PERF_PORT sets the port (3292).
import { readFileSync } from "node:fs";
import http from "node:http";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createHistoryFixture, historyChannelID, writeHistoryPage } from "./history-fixture.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const reference = resolve(process.argv[2] ?? resolve(root, "../toy-box-Minecraft"));
const { createDemoServer } = await import(pathToFileURL(resolve(reference, "tools/demo-server.ts")).href);
const source = JSON.parse(readFileSync(resolve(reference, "fixtures/channel-snapshot.json"), "utf8"));
const port = Number(process.env.TOY_BOX_PERF_PORT ?? 3292);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid TOY_BOX_PERF_PORT.");
const now = Date.now();
const { snapshot: historySnapshot, history } = createHistoryFixture(source, { now, origin: `http://127.0.0.1:${port}` });

const demos = { "studio-demo": createDemoServer(source, now), [historyChannelID]: createDemoServer(historySnapshot, now) };
const handlers = Object.fromEntries(Object.entries(demos).map(([id, demo]) => {
    const listeners = demo.server.listeners("request");
    if (listeners.length !== 1) throw new Error("Expected the reference demo server's single HTTP handler.");
    return [id, listeners[0]];
}));
const streams = Object.fromEntries(Object.keys(demos).map(id => [id, new Set()]));
const injected = Object.fromEntries(Object.keys(demos).map(id => [id, 0]));

// Plain prose, a list, a mention and a code block, so new rows exercise each kind of formatting.
const bodies = [
    (n) => `Update ${n}: the transcript keeps up while several agents report at once.`,
    (n) => `Pass ${n}\n\n- Checked the **message flow** end to end\n- Kept read receipts monotonic\n- Left the request open for the user`,
    (n, handle) => `@${handle} pass ${n} is ready for review. The shelf now sits beside the team desks, and the entrance stays clear for visitors.`,
    (n) => `Pass ${n} result:\n\n\`\`\`swift\nlet total = messages.reduce(0) { $0 + $1.count }\n\`\`\`\n\nThe count matches the server.`,
];

function json(response, status, value) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(JSON.stringify(value));
}

function streamMessages(response, url) {
    const channel = url.searchParams.get("channel");
    const count = Number(url.searchParams.get("count") ?? 1);
    const interval = Number(url.searchParams.get("interval") ?? 0);
    if (!(channel in demos) || !Number.isInteger(count) || count < 1 || count > 500
        || !Number.isInteger(interval) || interval < 0 || interval > 5000) {
        json(response, 400, { error: "Expected a fixture channel, a count from 1 to 500 and an interval up to 5000 ms." });
        return;
    }
    if (streams[channel].size === 0) {
        json(response, 409, { error: `Nothing is streaming ${channel}.` });
        return;
    }
    const base = demos[channel].snapshot();
    const agents = [base.lead, ...base.members];
    const first = base.channel.latestSequence + injected[channel] + 1;
    json(response, 200, { first, last: first + count - 1 });
    const send = () => {
        const offset = ++injected[channel];
        const agent = agents[offset % agents.length];
        const mentioned = agents[(offset + 1) % agents.length].name.split(" ")[0].toLowerCase();
        const message = {
            id: `perf-${channel}-${offset}`, sequence: base.channel.latestSequence + offset,
            timestamp: new Date().toISOString(), sender: { type: "agent", agentId: agent.id },
            content: bodies[offset % bodies.length](offset, mentioned),
        };
        const revision = base.revision + offset;
        const event = `id: ${revision}\ndata: ${JSON.stringify({ type: "message", revision, message })}\n\n`;
        for (const stream of streams[channel]) stream.write(event);
    };
    if (interval === 0) {
        for (let index = 0; index < count; index++) send();
        return;
    }
    let sent = 0;
    const timer = setInterval(() => {
        send();
        if (++sent === count) clearInterval(timer);
    }, interval);
}

const server = http.createServer((request, response) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
    if (request.method === "GET" && url.pathname === "/api/v1/channels") {
        const studio = demos["studio-demo"].snapshot();
        const history = demos[historyChannelID].snapshot();
        const { name, role, avatar } = studio.lead;
        json(response, 200, {
            version: 1, lead: { name, role, avatar }, channels: [studio.channel, history.channel],
            members: [...studio.members, ...history.members],
        });
        return;
    }
    if (url.pathname === "/perf/messages") {
        if (request.method !== "POST") {
            response.writeHead(405, { "Content-Type": "application/json", Allow: "POST" });
            response.end(JSON.stringify({ error: "Stream benchmark messages with POST." }));
            return;
        }
        streamMessages(response, url);
        return;
    }
    if (url.pathname === `/api/v1/channels/${historyChannelID}/messages`) {
        if (request.method !== "GET") {
            response.writeHead(405, { "Content-Type": "application/json", Allow: "GET" });
            response.end(JSON.stringify({ error: "This history fixture supports read receipts, not message sends." }));
            return;
        }
        writeHistoryPage(response, url, history, demos[historyChannelID].snapshot().revision);
        return;
    }
    // Artifact and preview routes belong to studio-demo, whose snapshot history-demo copies.
    const channel = url.pathname.startsWith(`/api/v1/channels/${historyChannelID}`) ? historyChannelID : "studio-demo";
    if (request.method === "GET" && url.pathname === `/api/v1/channels/${channel}`) {
        streams[channel].add(response);
        response.on("close", () => streams[channel].delete(response));
    }
    handlers[channel](request, response);
});
server.on("error", error => { console.error(error); process.exit(1); });
server.listen(port, "127.0.0.1", () => {
    console.log(`Benchmark fixture: http://127.0.0.1:${port} · channels studio-demo, ${historyChannelID}`);
});
for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => process.exit(0));
