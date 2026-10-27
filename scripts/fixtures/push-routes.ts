import type { IncomingMessage, ServerResponse } from "node:http";
import type { Snapshot } from "./types.ts";

type Environment = "sandbox" | "production";
type Device = { registrationID: string; token: string; environment: Environment; requests: boolean; completions: boolean };
type Activity = { registrationID: string; channelID: string; token: string; environment: Environment; startedAt: number };
type Route = { kind: "device"; id: string } | { kind: "activity"; id: string; channel: string };

function reply(response: ServerResponse, status: number, error?: string) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(error ? JSON.stringify({ error }) : undefined);
}

async function body(request: IncomingMessage): Promise<unknown> {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of request) {
        const data = Buffer.from(chunk);
        size += data.length;
        if (size <= 16_384) chunks.push(data);
    }
    if (size > 16_384) return undefined;
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

export function createDemoPushRoutes(snapshots: () => Snapshot[]) {
    const devices = new Map<string, Device>();
    const activities = new Map<string, Activity>();
    function match(path: string): Route | undefined {
        const device = /^\/api\/v1\/push\/devices\/([^/]+)$/.exec(path);
        if (device) return { kind: "device", id: device[1]! };
        const activity = /^\/api\/v1\/channels\/([^/]+)\/activities\/([^/]+)$/.exec(path);
        if (activity) return { kind: "activity", channel: activity[1]!, id: activity[2]! };
    }
    async function handle(request: IncomingMessage, response: ServerResponse, route: Route) {
        let id: string;
        let channel: string | undefined;
        try {
            id = decodeURIComponent(route.id);
            if (route.kind === "activity") channel = decodeURIComponent(route.channel);
        } catch (error) {
            if (!(error instanceof URIError)) throw error;
            reply(response, 400, "Invalid registration route.");
            return;
        }
        if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(id)) {
            reply(response, 422, "A registration ID must be a UUID.");
            return;
        }
        const key = `${channel}\n${id}`;
        if (request.method === "DELETE") {
            if (route.kind === "device") devices.delete(id);
            else activities.delete(key);
            reply(response, 204);
            return;
        }
        if (request.method !== "PUT") {
            reply(response, 405, "Use PUT or DELETE.");
            return;
        }
        let value: unknown;
        try { value = await body(request); }
        catch (error) {
            if (!(error instanceof SyntaxError)) throw error;
            reply(response, 400, "Expected a JSON registration.");
            return;
        }
        if (value === undefined) { reply(response, 413, "Registration is too large."); return; }
        if (!value || typeof value !== "object" || Array.isArray(value)) {
            reply(response, 422, "Expected a registration object.");
            return;
        }
        const input = value as Record<string, unknown>;
        if (input.registrationID !== id || typeof input.token !== "string"
            || !/^(?:[0-9a-f]{2}){1,512}$/i.test(input.token)
            || (input.environment !== "sandbox" && input.environment !== "production")) {
            reply(response, 422, "Invalid registration ID, token or APNs environment.");
            return;
        }
        const common = { registrationID: id, token: input.token.toLowerCase(), environment: input.environment };
        if (route.kind === "device") {
            if (typeof input.requests !== "boolean" || typeof input.completions !== "boolean") {
                reply(response, 422, "Request and completion preferences must be booleans.");
                return;
            }
            for (const [otherID, device] of devices) {
                if (device.token === common.token && otherID !== id) devices.delete(otherID);
            }
            devices.set(id, { ...common, environment: input.environment,
                              requests: input.requests, completions: input.completions });
        } else {
            if (channel === undefined || !snapshots().some(snapshot => snapshot.channel.id === channel)) {
                reply(response, 404, "Channel not found.");
                return;
            }
            if (typeof input.startedAt !== "number" || !Number.isFinite(input.startedAt) || input.startedAt < 0) {
                reply(response, 422, "Activity start time must be Unix seconds.");
                return;
            }
            if ([...activities].some(([otherKey, activity]) => otherKey !== key && activity.token === common.token)) {
                reply(response, 409, "Activity token is already registered.");
                return;
            }
            activities.set(key, { ...common, channelID: channel, environment: input.environment,
                                  startedAt: activities.get(key)?.startedAt ?? input.startedAt });
        }
        reply(response, 204);
    }
    return { devices, activities, match, handle };
}
