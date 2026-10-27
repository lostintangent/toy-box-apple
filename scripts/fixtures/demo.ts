#!/usr/bin/env bun
import { resolve } from "node:path";
import { parseArgs } from "node:util";
import { root } from "../lib.ts";
import { referenceFactory, remapChannel, type Demo, type Snapshot } from "./types.ts";
import { createDemoPushRoutes } from "./push-routes.ts";
import { writeHistoryPage } from "./history-fixture.ts";

export function demoOptions(args: string[]): { reference: string | undefined; completed: boolean } {
    const { values, positionals } = parseArgs({
        args, allowPositionals: true, options: { completed: { type: "boolean" } },
    });
    if (positionals.length > 1) throw new Error("Usage: bun run demo [--completed] [path to toy-box-Minecraft]");
    return { reference: positionals[0], completed: values.completed ?? false };
}

export function createCompletedDemoFixture(source: Snapshot, now = Date.now()): Snapshot {
    if (source.channel.id !== "studio-demo") throw new Error("The completion fixture needs the canonical Studio demo.");
    const snapshot = remapChannel(structuredClone(source), "completed-demo");
    type Task = { status: string; children?: Task[] };
    const complete = (tasks: Task[]) => {
        for (const task of tasks) {
            task.status = "done";
            if (task.children) complete(task.children);
        }
    };
    complete(snapshot.channel.tasks);
    const timestamp = new Date(now).toISOString();
    snapshot.channel.name = "Completed demo";
    snapshot.channel.latestSequence = 1;
    snapshot.channel.seenThrough = 0;
    snapshot.channel.completedSequence = 1;
    snapshot.channel.requestSequence = null;
    snapshot.channel.updatedAt = timestamp;
    snapshot.request = null;
    snapshot.revision = 1;
    snapshot.lead.status = { state: "idle" };
    for (const member of snapshot.members) member.status = { state: "idle" };
    snapshot.presence = Object.fromEntries(Object.keys(snapshot.presence).map(id => [id, { state: "idle" }]));
    snapshot.messages = [{
        id: "completed-demo-result", sequence: 1, timestamp,
        sender: { type: "agent", agentId: snapshot.lead.id },
        content: "The workshop is complete. All tasks are done.",
    }];
    return snapshot;
}

export function installDemoCatalogRoutes(demo: Pick<Demo, "server" | "snapshot">,
    additional: Pick<Demo, "server" | "snapshot">[] = []) {
    const snapshots = () => [demo, ...additional].map(fixture => fixture.snapshot());
    const push = createDemoPushRoutes(snapshots);
    const peers = additional.map(fixture => {
        const listeners = fixture.server.listeners("request");
        if (listeners.length !== 1) throw new Error("Expected the reference demo server's single HTTP handler.");
        return { fixture, handler: listeners[0]! };
    });
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
        if (request.method === "GET" && url.pathname.endsWith("/messages")) {
            const snapshot = snapshots().find(snapshot =>
                url.pathname === `/api/v1/channels/${encodeURIComponent(snapshot.channel.id)}/messages`);
            if (snapshot) {
                writeHistoryPage(response, url, snapshot.messages, snapshot.revision);
                return;
            }
        }
        if (request.method === "GET" && ["/api/v1/channels", "/api/v1/models"].includes(url.pathname)) {
            const current = snapshots();
            const snapshot = current[0]!;
            const { name, role, avatar } = snapshot.lead;
            const model = snapshot.channel.model;
            const body = url.pathname === "/api/v1/models"
                ? {
                    version: 1, provider: model.provider, defaultModel: model,
                    models: [{ id: model.name, name: model.name, provider: model.provider }],
                }
                : {
                    version: 1, lead: { name, role, avatar },
                    channels: current.map(snapshot => snapshot.channel),
                    members: current.flatMap(snapshot => snapshot.members),
                };
            response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
            response.end(JSON.stringify(body));
            return;
        }
        const peer = peers.find(({ fixture }) => {
            const path = `/api/v1/channels/${encodeURIComponent(fixture.snapshot().channel.id)}`;
            return url.pathname === path || url.pathname.startsWith(`${path}/`);
        });
        if (peer) peer.handler(request, response);
        else originalHandler(request, response);
    });
    return push;
}

if (import.meta.main) {
    const options = demoOptions(process.argv.slice(2));
    const reference = resolve(options.reference ?? resolve(root, "../toy-box-Minecraft"));
    const createDemoServer = await referenceFactory(reference);
    const port = Number(process.env.TOY_BOX_DEMO_PORT ?? 3210);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid TOY_BOX_DEMO_PORT.");

    const snapshotPath = process.env.TOY_BOX_DEMO_SNAPSHOT;
    const initial: Snapshot | undefined = snapshotPath ? await Bun.file(snapshotPath).json() : undefined;
    const demo = createDemoServer(initial);
    // The reference factory makes dates recent. Restore an exported snapshot without that adjustment.
    if (initial) demo.replace(initial);
    const additional = options.completed ? [createDemoServer(createCompletedDemoFixture(demo.snapshot()))] : [];
    installDemoCatalogRoutes(demo, additional);
    demo.server.on("error", error => { console.error(error); process.exitCode = 1; });
    demo.server.listen(port, "127.0.0.1", () => {
        console.log(`Toy Box fixture: http://127.0.0.1:${port} · channels ${[demo, ...additional]
            .map(fixture => fixture.snapshot().channel.id).join(", ")}`);
        console.log("The catalog serves the fixture's lead profile and configured model. No agents or models run.");
    });
    for (const signal of ["SIGINT", "SIGTERM"] as const) {
        process.once(signal, () => {
            void Promise.all([demo, ...additional].map(async fixture => {
                try { await fixture.close(); }
                catch (error) {
                    if (fixture !== demo && error instanceof Error
                        && "code" in error && error.code === "ERR_SERVER_NOT_RUNNING") return;
                    throw error;
                }
            })).catch(error => { console.error(error); process.exitCode = 1; });
        });
    }
}
