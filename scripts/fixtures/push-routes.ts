import type { IncomingMessage, ServerResponse } from "node:http";

type Environment = "sandbox" | "production";
type Registration = { registrationID: string; token: string; environment: Environment };
type Subscription = { registrationID: string; topic: string; token: string | null; startedAt: number | null };
type Route = { id: string; topic?: string };

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

export function createDemoPushRoutes() {
    const registrations = new Map<string, Registration>();
    const subscriptions = new Map<string, Subscription>();
    function removeRegistration(id: string) {
        registrations.delete(id);
        for (const [key, subscription] of subscriptions)
            if (subscription.registrationID === id) subscriptions.delete(key);
    }
    function match(path: string): Route | undefined {
        const match = /^\/api\/v1\/push\/([^/]+)(?:\/topics\/([^/]+))?$/.exec(path);
        if (match) return { id: match[1]!, topic: match[2] };
    }
    async function handle(request: IncomingMessage, response: ServerResponse, route: Route) {
        let id: string;
        let topic: string | undefined;
        try {
            id = decodeURIComponent(route.id);
            if (route.topic !== undefined) topic = decodeURIComponent(route.topic);
        } catch (error) {
            if (!(error instanceof URIError)) throw error;
            reply(response, 400, "Invalid registration route.");
            return;
        }
        if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(id)) {
            reply(response, 422, "A registration ID must be a UUID.");
            return;
        }
        const key = `${topic}\n${id}`;
        if (request.method === "DELETE") {
            if (topic === undefined) removeRegistration(id);
            else subscriptions.delete(key);
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
        const keys = topic === undefined ? ["token", "environment"] : ["token", "startedAt"];
        if (Object.keys(input).some(key => !keys.includes(key))) {
            reply(response, 422, "Unexpected registration field.");
            return;
        }
        const token = typeof input.token === "string" && /^(?:[0-9a-f]{2}){1,512}$/i.test(input.token)
            ? input.token.toLowerCase() : undefined;
        let created = false;
        if (topic === undefined) {
            if (!token || (input.environment !== "sandbox" && input.environment !== "production")) {
                reply(response, 422, "Invalid notification token or APNs environment.");
                return;
            }
            const common: Registration = { registrationID: id, token, environment: input.environment };
            created = !registrations.has(id);
            for (const [otherID, registration] of registrations) {
                if (registration.token === common.token && registration.environment === common.environment && otherID !== id) removeRegistration(otherID);
            }
            registrations.set(id, common);
        } else {
            if (!registrations.has(id)) {
                reply(response, 404, "Push registration not found.");
                return;
            }
            const standard = input.token == null && input.startedAt == null;
            if (!standard && (!token || typeof input.startedAt !== "number" ||
                !Number.isFinite(input.startedAt) || input.startedAt < 0)) {
                reply(response, 422, "Subscription start time must be Unix seconds.");
                return;
            }
            subscriptions.set(key, {
                registrationID: id, topic,
                token: token ?? null,
                startedAt: standard ? null : (typeof input.startedAt === "number" ? input.startedAt : null),
            });
        }
        reply(response, created ? 201 : 204);
    }
    return { registrations, subscriptions, match, handle };
}
