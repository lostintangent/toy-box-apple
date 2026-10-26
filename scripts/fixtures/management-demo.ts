#!/usr/bin/env bun
import fixture from "../../Tests/ChannelKitTests/Fixtures/channel-snapshot.json";
import type { Agent, Snapshot, Status } from "./types.ts";

type Model = Snapshot["channel"]["model"] & Record<string, unknown>;
type State = Omit<Snapshot, "channel" | "members" | "presence"> & {
    channel: Omit<Snapshot["channel"], "purpose" | "previewUrl"> & {
        purpose?: string; directory?: string; previewUrl?: string;
    };
    members: (Agent & { model?: Model })[];
    presence: Record<string, Status>;
};
type Fault = { method: string; path: string; mode: "reject422" | "commit500" };
type Write = { method: string; path: string; status: number; committed: boolean };
type Client = { controller: ReadableStreamDefaultController<Uint8Array>; active: boolean };

class Rejection extends Error {
    constructor(readonly status: number, message: string) { super(message); }
}

function record(value: unknown): value is Record<string, unknown> {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requiredText(value: unknown, name: string): string {
    if (typeof value !== "string" || !value.trim()) throw new Rejection(422, `${name} is required.`);
    return value.trim();
}

function model(value: unknown): Model {
    if (!record(value)) throw new Rejection(422, "Expected a model configuration.");
    return {
        ...value,
        provider: requiredText(value.provider, "Model provider"), name: requiredText(value.name, "Model name"),
    };
}

function json(status: number, value: unknown) {
    return Response.json(value, { status, headers: { "Cache-Control": "no-store" } });
}

function managementWrite(method: string, path: string[]) {
    return path[0] === "api" && path[1] === "v1" && path[2] === "channels"
        && (method === "POST" && (path.length === 3 || path.length === 5 && path[4] === "members")
            || ["PATCH", "DELETE"].includes(method) && (path.length === 4
                || path.length === 6 && path[4] === "members")
            || method === "DELETE" && path.length === 6 && path[4] === "routines"
            || method === "POST" && path.length === 7 && path[4] === "routines" && path[6] === "run");
}

export function createManagementFixture(port = 0, source: Snapshot = { ...fixture, messages: [], request: null }) {
    const states = new Map<string, State>();
    const clients = new Map<string, Set<Client>>();
    const writes: Write[] = [];
    const routineRuns: { channelId: string; routineId: string }[] = [];
    const encoder = new TextEncoder();
    let fault: Fault | undefined;
    const lead = { name: source.lead.name, role: source.lead.role, avatar: source.lead.avatar };

    function makeChannel(id: string, body: Record<string, unknown>): State {
        const state: State = {
            ...structuredClone(source), revision: 0, messages: [], request: null,
            members: [], artifacts: [], routines: [], presence: {},
            lead: { id, ...structuredClone(lead), channelId: id },
            channel: {
                ...structuredClone(source.channel), id, name: requiredText(body.name, "Channel name"),
                model: model(body.model), tasks: [], latestSequence: 0, seenThrough: 0,
                requestSequence: null, completedSequence: null, updatedAt: new Date().toISOString(),
            },
        };
        delete state.channel.purpose;
        delete state.channel.previewUrl;
        if (body.purpose !== undefined && body.purpose !== null) {
            state.channel.purpose = requiredText(body.purpose, "Purpose");
        }
        if (body.directory !== undefined && body.directory !== null) {
            state.channel.directory = requiredText(body.directory, "Directory");
        }
        return state;
    }
    const initial = makeChannel("management-demo", { name: "Management Scratch", model: source.channel.model });
    initial.routines = [{ ...structuredClone(fixture.routines[0]!), id: "management-routine" }];
    states.set(initial.channel.id, initial);

    function publish(id: string, event: unknown, close = false) {
        const data = encoder.encode(`data: ${JSON.stringify(event)}\n\n`);
        for (const client of clients.get(id) ?? []) {
            if (!client.active) continue;
            client.controller.enqueue(data);
            if (close) {
                client.active = false;
                client.controller.close();
            }
        }
        if (close) clients.delete(id);
    }

    function changed(state: State) {
        state.revision += 1;
        state.channel.updatedAt = new Date().toISOString();
        publish(state.channel.id, { type: "snapshot", state });
    }

    function commit(method: string, path: string[], body: Record<string, unknown>) {
        if (path.length === 3 && method === "POST") {
            const state = makeChannel(`management-${crypto.randomUUID()}`, body);
            states.set(state.channel.id, state);
            return { status: 201, value: { version: 1, channel: state.channel } };
        }
        const id = path[3]!;
        const state = states.get(id);
        if (!state) throw new Rejection(404, "Channel not found.");
        if (path[4] === "routines") {
            const routine = state.routines.find(routine => routine.id === path[5]);
            if (!routine) throw new Rejection(404, "Routine not found.");
            if (method === "POST") {
                routineRuns.push({ channelId: id, routineId: routine.id });
            } else {
                state.routines = state.routines.filter(candidate => candidate !== routine);
                changed(state);
            }
            return { status: 204, value: undefined };
        }
        if (path.length === 4) {
            if (method === "DELETE") {
                states.delete(id);
                publish(id, { type: "deleted", channelId: id }, true);
                return { status: 204, value: undefined };
            }
            const name = body.name === undefined ? state.channel.name : requiredText(body.name, "Channel name");
            const selected = body.model === undefined ? state.channel.model : model(body.model);
            const purpose = body.purpose === undefined ? state.channel.purpose
                : body.purpose === null ? undefined : requiredText(body.purpose, "Purpose");
            state.channel.name = name;
            state.channel.model = selected;
            if (purpose === undefined) delete state.channel.purpose;
            else state.channel.purpose = purpose;
            changed(state);
            return { status: 200, value: { version: 1, channel: state.channel } };
        }
        if (path.length === 5 && method === "POST") {
            if (body.role !== undefined && typeof body.role !== "string") throw new Rejection(422, "Expected a role.");
            const member: State["members"][number] = {
                id: crypto.randomUUID(), channelId: id, name: requiredText(body.name, "Agent name"),
                role: typeof body.role === "string" ? body.role : "", avatar: structuredClone(lead.avatar),
                ...(body.model == null ? {} : { model: model(body.model) }),
            };
            state.members.push(member);
            changed(state);
            return { status: 201, value: { version: 1, member } };
        }
        const member = state.members.find(member => member.id === path[5]);
        if (!member) throw new Rejection(404, "Agent not found.");
        if (method === "DELETE") {
            state.members = state.members.filter(candidate => candidate !== member);
            delete state.presence[member.id];
            changed(state);
            return { status: 204, value: undefined };
        }
        const name = body.name === undefined ? member.name : requiredText(body.name, "Agent name");
        if (body.role !== undefined && typeof body.role !== "string") throw new Rejection(422, "Expected a role.");
        const selected = body.model === undefined ? member.model : body.model === null ? undefined : model(body.model);
        member.name = name;
        if (typeof body.role === "string") member.role = body.role;
        if (selected === undefined) delete member.model;
        else member.model = selected;
        changed(state);
        return { status: 200, value: { version: 1, member } };
    }

    async function body(request: Request) {
        if (request.headers.get("Content-Type")?.split(";")[0]?.trim() !== "application/json") {
            throw new Rejection(400, "Expected application/json.");
        }
        const value: unknown = await request.json();
        if (!record(value)) throw new Rejection(400, "Expected a JSON object.");
        return value;
    }

    const server = Bun.serve({
        port, hostname: "127.0.0.1", maxRequestBodySize: 65_536,
        async fetch(request) {
            const url = new URL(request.url);
            const method = request.method;
            let isWrite = false;
            let committed = false;
            try {
                const path = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
                isWrite = managementWrite(method, path);
                if (url.pathname === "/_fixture/state" && method === "GET") {
                    return json(200, { channels: [...states.values()], writes, routineRuns, fault: fault ?? null });
                }
                if (url.pathname === "/_fixture/fault" && method === "DELETE") {
                    fault = undefined;
                    return new Response(null, { status: 204 });
                }
                if (url.pathname === "/_fixture/fault" && method === "POST") {
                    const input = await body(request);
                    const mode = input.mode;
                    if (typeof input.method !== "string" || !["POST", "PATCH", "DELETE"].includes(input.method)
                        || typeof input.path !== "string" || !/^\/api\/v1\/channels(?:\/[^/?#]+)*$/.test(input.path)
                        || !managementWrite(input.method, input.path.split("/").filter(Boolean).map(decodeURIComponent))
                        || mode !== "reject422" && mode !== "commit500") {
                        throw new Rejection(400, "Expected a method, exact management path and reject422/commit500 mode.");
                    }
                    if (fault) throw new Rejection(409, "A fault is already armed. Clear it before arming another.");
                    fault = { method: input.method, path: input.path, mode };
                    return new Response(null, { status: 204 });
                }
                if (method === "GET" && url.pathname === "/api/v1/channels") {
                    return json(200, { version: 1, lead, channels: [...states.values()].map(s => s.channel),
                        members: [...states.values()].flatMap(s => s.members) });
                }
                if (method === "GET" && (url.pathname === "/api/v1/models"
                    || path[0] === "api" && path[1] === "v1" && path[2] === "channels"
                    && path.length === 7 && path[4] === "members" && path[6] === "models")) {
                    const state = path.length === 7 ? states.get(path[3]!) : undefined;
                    if (path.length === 7 && !state?.members.some(m => m.id === path[5])) {
                        throw new Rejection(404, "Agent not found.");
                    }
                    const selected = state?.channel.model ?? source.channel.model;
                    return json(200, { version: 1, provider: selected.provider, defaultModel: selected,
                        models: [{ id: selected.name, name: selected.name, provider: selected.provider }] });
                }
                if (isWrite) {
                    const input = method === "DELETE" || path[4] === "routines" ? {} : await body(request);
                    const injected = fault?.method === method && fault.path === url.pathname ? fault : undefined;
                    if (injected) fault = undefined;
                    if (injected?.mode === "reject422") throw new Rejection(422, "Fixture rejection. No change was applied.");
                    const result = commit(method, path, input);
                    committed = true;
                    const status = injected?.mode === "commit500" ? 500 : result.status;
                    writes.push({ method, path: url.pathname, status, committed });
                    if (status === 500) return json(500, { error: "Injected server failure." });
                    return status === 204 ? new Response(null, { status }) : json(status, result.value);
                }
                const state = states.get(path[3]!);
                if (path[0] === "api" && path[1] === "v1" && path[2] === "channels" && state) {
                    if (method === "GET" && path.length === 4) {
                        let client: Client;
                        const cleanup = () => { client.active = false; clients.get(state.channel.id)?.delete(client); };
                        const stream = new ReadableStream<Uint8Array>({
                            start(controller) {
                                client = { controller, active: true };
                                const subscribers = clients.get(state.channel.id) ?? new Set<Client>();
                                subscribers.add(client);
                                clients.set(state.channel.id, subscribers);
                                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "snapshot", state })}\n\n`));
                                request.signal.addEventListener("abort", cleanup, { once: true });
                            },
                            cancel() { cleanup(); request.signal.removeEventListener("abort", cleanup); },
                        });
                        return new Response(stream, { headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-store" } });
                    }
                    if (method === "GET" && path.length === 5 && path[4] === "messages") {
                        return json(200, { version: 1, revision: state.revision, messages: [] });
                    }
                    if (method === "POST" && path.length === 5 && path[4] === "read") {
                        const input = await body(request);
                        if (!Number.isSafeInteger(input.sequence) || Number(input.sequence) < 0) {
                            throw new Rejection(400, "Expected a non-negative read sequence.");
                        }
                        return json(200, { version: 1, seenThrough: state.channel.seenThrough });
                    }
                }
                return json(404, { error: "This private fixture supports channel/member management, routine Run/Delete, catalog, history and read receipts only." });
            } catch (error) {
                const status = error instanceof Rejection ? error.status
                    : error instanceof SyntaxError || error instanceof URIError ? 400 : 500;
                if (status === 500) console.error(error);
                if (isWrite) writes.push({ method, path: url.pathname, status, committed });
                return json(status, { error: error instanceof Error ? error.message : "Unexpected fixture failure." });
            }
        },
    });
    const heartbeat = setInterval(() => {
        for (const subscribers of clients.values()) {
            for (const client of subscribers) if (client.active) client.controller.enqueue(encoder.encode(": keepalive\n\n"));
        }
    }, 5_000);
    heartbeat.unref();
    return {
        server,
        async close() {
            clearInterval(heartbeat);
            for (const subscribers of clients.values()) {
                for (const client of subscribers) if (client.active) {
                    client.active = false;
                    client.controller.close();
                }
            }
            clients.clear();
            await server.stop(true);
        },
    };
}

if (import.meta.main) {
    const port = Number(process.env.TOY_BOX_MANAGEMENT_PORT ?? 3240);
    if (!Number.isInteger(port) || port < 1 || port > 65535 || [3100, 3210, 3211, 3292].includes(port)) {
        throw new Error("Choose a private TOY_BOX_MANAGEMENT_PORT, not a live/shared fixture port.");
    }
    const demo = createManagementFixture(port);
    console.log(`Private management fixture: ${demo.server.url} · Management Scratch (management-demo)`);
    console.log("Channel/member CRUD and simulated routine Run/Delete. No agent or model runs.");
    console.log("Arm exact one-shot faults at /_fixture/fault; inspect /_fixture/state, including routineRuns.");
    for (const signal of ["SIGINT", "SIGTERM"] as const) {
        process.once(signal, () => { void demo.close().catch(error => { console.error(error); process.exitCode = 1; }); });
    }
}
