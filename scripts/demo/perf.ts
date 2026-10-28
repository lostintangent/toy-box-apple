#!/usr/bin/env bun
// The benchmark fixture that bun run benchmark starts for each scenario. It serves studio-demo, the
// 480-message history-demo and the 300 long messages of scroll-demo on one port, through the
// reference demo server imported read-only, and adds two routes the benchmark drives:
//
//   POST /perf/messages?channel=ID&count=N&interval=MS
//
// It answers at once with the sequences it will use, then streams N agent messages to that
// channel's open streams, MS apart.
//
//   POST /perf/working?channel=ID&count=N
//
// It makes the lead and then members working until N are, adding members when the channel has
// fewer, and the rest idle.
//
// What these routes stream stays out of the reference server's history, so a reconnect drops it.
// Each benchmark launch starts a fresh fixture.
//
// Usage: bun run demo:perf [path to toy-box-Minecraft]. TOY_BOX_PERF_PORT sets the port (3292).
import http from "node:http";
import { resolve } from "node:path";
import { createHistoryFixture, historyChannelID, writeHistoryPage } from "./channels/history.ts";
import { createScrollFixture, scrollChannelID, writeScrollImage } from "./channels/scroll.ts";
import { root } from "../shared/support/lib.ts";
import { referenceFactory, type Agent, type Message, type Response, type Snapshot, type Status } from "./channels/types.ts";

const reference = resolve(process.argv[2] ?? resolve(root, "../toy-box-Minecraft"));
const createDemoServer = await referenceFactory(reference);
const source: Snapshot = await Bun.file(resolve(reference, "fixtures/channel-snapshot.json")).json();
const port = Number(process.env.TOY_BOX_PERF_PORT ?? 3292);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid TOY_BOX_PERF_PORT.");
const now = Date.now();
const origin = `http://127.0.0.1:${port}`;
const { snapshot: historySnapshot, history } = createHistoryFixture(source, { now, origin });
const { snapshot: scrollSnapshot, history: scrollHistory } = createScrollFixture(source, { now, origin });
const histories: Record<string, Message[]> = { [historyChannelID]: history, [scrollChannelID]: scrollHistory };

const demos: Record<string, ReturnType<typeof createDemoServer>> = {
    "studio-demo": createDemoServer(source, now), [historyChannelID]: createDemoServer(historySnapshot, now),
    [scrollChannelID]: createDemoServer(scrollSnapshot, now),
};
const handlers = Object.fromEntries(Object.entries(demos).map(([id, demo]) => {
    const listeners = demo.server.listeners("request");
    if (listeners.length !== 1) throw new Error("Expected the reference demo server's single HTTP handler.");
    return [id, listeners[0]];
}));
const streams = Object.fromEntries(Object.keys(demos).map(id => [id, new Set<Response>()]));
const injected = Object.fromEntries(Object.keys(demos).map(id => [id, 0]));
const revisions = Object.fromEntries(Object.keys(demos).map(id => [id, 0]));
const added = Object.fromEntries(Object.keys(demos).map(id => [id, [] as Agent[]]));

// Plain prose, a list, a mention and a code block, so new rows exercise each kind of formatting.
const bodies: ((n: number, handle: string) => string)[] = [
    (n) => `Update ${n}: the transcript keeps up while several agents report at once.`,
    (n) => `Pass ${n}\n\n- Checked the **message flow** end to end\n- Kept read receipts monotonic\n- Left the request open for the user`,
    (n, handle) => `@${handle} pass ${n} is ready for review. The shelf now sits beside the team desks, and the entrance stays clear for visitors.`,
    (n) => `Pass ${n} result:\n\n\`\`\`swift\nlet total = messages.reduce(0) { $0 + $1.count }\n\`\`\`\n\nThe count matches the server.`,
];

function json(response: Response, status: number, value: unknown) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(JSON.stringify(value));
}

function streamMessages(response: Response, url: URL) {
    const channel = url.searchParams.get("channel");
    const count = Number(url.searchParams.get("count") ?? 1);
    const interval = Number(url.searchParams.get("interval") ?? 0);
    if (!channel || !(channel in demos) || !Number.isInteger(count) || count < 1 || count > 500
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
        broadcast(channel, { type: "message", revision: base.revision + ++revisions[channel], message });
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

function broadcast(channel: string, event: { revision?: number; [key: string]: unknown }) {
    const id = event.revision === undefined ? "" : `id: ${event.revision}\n`;
    for (const stream of streams[channel]) stream.write(`${id}data: ${JSON.stringify(event)}\n\n`);
}

function setWorking(response: Response, url: URL) {
    const channel = url.searchParams.get("channel");
    const count = Number(url.searchParams.get("count") ?? 1);
    if (!channel || !(channel in demos) || !Number.isInteger(count) || count < 0 || count > 100) {
        json(response, 400, { error: "Expected a fixture channel and a count up to 100." });
        return;
    }
    if (streams[channel].size === 0) {
        json(response, 409, { error: `Nothing is streaming ${channel}.` });
        return;
    }
    const base = demos[channel].snapshot();
    const agents = [base.lead, ...base.members, ...added[channel]];
    const statuses = new Map<number, Status>();
    for (let index = 0; index < Math.max(count, agents.length); index++) {
        statuses.set(index, index < count ? { state: "working", text: `Checking pass ${index + 1}` } : { state: "idle" });
    }
    for (let index = agents.length; index < count; index++) {
        const { avatar } = base.members[index % base.members.length];
        const member = {
            channelId: channel, id: `perf-agent-${index}`, name: `Agent ${index}`,
            role: "Keep the benchmark busy.", avatar, status: statuses.get(index),
        };
        added[channel].push(member);
        agents.push(member);
        broadcast(channel, { type: "member", revision: base.revision + ++revisions[channel], member });
    }
    agents.forEach((agent, index) => {
        broadcast(channel, {
            type: "status", revision: base.revision + ++revisions[channel], agentId: agent.id, status: statuses.get(index),
        });
    });
    broadcast(channel, { type: "presence", presence: Object.fromEntries(agents.map((agent, index) => [agent.id, statuses.get(index)])) });
    json(response, 200, { working: count, agents: agents.length });
}

const server = http.createServer((request, response) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
    if (request.method === "GET" && url.pathname === "/api/v1/channels") {
        const snapshots = Object.values(demos).map(demo => demo.snapshot());
        const { name, role, avatar } = snapshots[0].lead;
        json(response, 200, {
            version: 1, lead: { name, role, avatar }, channels: snapshots.map(snapshot => snapshot.channel),
            members: snapshots.flatMap(snapshot => snapshot.members),
        });
        return;
    }
    if (url.pathname === "/perf/messages" || url.pathname === "/perf/working") {
        if (request.method !== "POST") {
            response.writeHead(405, { "Content-Type": "application/json", Allow: "POST" });
            response.end(JSON.stringify({ error: `Use POST for ${url.pathname}.` }));
            return;
        }
        if (url.pathname === "/perf/messages") streamMessages(response, url);
        else setWorking(response, url);
        return;
    }
    const paged = Object.keys(histories).find(id => url.pathname === `/api/v1/channels/${id}/messages`);
    if (paged) {
        if (request.method !== "GET") {
            response.writeHead(405, { "Content-Type": "application/json", Allow: "GET" });
            response.end(JSON.stringify({ error: "This history fixture supports read receipts, not message sends." }));
            return;
        }
        writeHistoryPage(response, url, histories[paged], demos[paged].snapshot().revision);
        return;
    }
    if (request.method === "GET" && writeScrollImage(response, url.pathname)) return;
    // Artifact and preview routes belong to studio-demo, whose snapshot the other channels copy.
    const channel = Object.keys(histories).find(id => url.pathname.startsWith(`/api/v1/channels/${id}`)) ?? "studio-demo";
    if (request.method === "GET" && url.pathname === `/api/v1/channels/${channel}`) {
        streams[channel].add(response);
        response.on("close", () => streams[channel].delete(response));
    }
    handlers[channel](request, response);
});
server.on("error", error => { console.error(error); process.exit(1); });
server.listen(port, "127.0.0.1", () => {
    console.log(`Benchmark fixture: ${origin} · channels ${Object.keys(demos).join(", ")}`);
});
for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, () => process.exit(0));
