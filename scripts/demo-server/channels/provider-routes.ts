import type { IncomingMessage, ServerResponse } from "node:http";

type Provider = { id: string, name: string, status: string, error?: string, version?: string, enabled: boolean };
type Subscription = { plan: string, limits: { name: string, usedPercent: number, resetsAt?: number }[] };

// Each ready, enabled provider's subscription matches the live server's. Cursor's usage fails.
const subscriptions: Record<string, Subscription> = {
    copilot: { plan: "enterprise", limits: [] },
    codex: { plan: "pro", limits: [{ name: "Weekly", usedPercent: 0, resetsAt: 1795722169000 }] },
    claude: {
        plan: "max",
        limits: [
            { name: "Weekly", usedPercent: 10, resetsAt: 1795568399982 },
            { name: "Weekly Fable", usedPercent: 20, resetsAt: 1795568399982 },
        ],
    },
};

// What each provider's CLI update does: Copilot installs a newer version once, Gemini's fails, and
// the rest are current. Each takes its own time, as CLIs do.
const newer: Record<string, string> = { copilot: "1.0.115" };
const updateDelays: Record<string, number> = { copilot: 3000, gemini: 2500 };
const defaultUpdateDelay = 1500;

function reply(response: ServerResponse, status: number, body: unknown) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(JSON.stringify(body));
}

/** `/api/v1/providers`, each provider's subscription, and its update, as the server serves them.
 *  An update changes the versions the list reports for as long as the process runs, so they
 *  survive the demo server's restart, as a real CLI's install does. */
export function createDemoProviderRoutes() {
    const providers: Provider[] = [
        { id: "copilot", name: "GitHub Copilot", status: "ready", version: "1.0.114", enabled: true },
        { id: "codex", name: "OpenAI Codex", status: "ready", version: "0.170.0", enabled: true },
        { id: "claude", name: "Claude Agent", status: "ready", version: "2.1.328", enabled: true },
        { id: "gemini", name: "Gemini", status: "signedOut", enabled: true },
        { id: "cursor", name: "Cursor", status: "ready", version: "1.0.0", enabled: true },
        { id: "windsurf", name: "Windsurf", status: "failed", error: "CLI exited 1.", version: "1.2.0", enabled: true },
        { id: "ollama", name: "Ollama", status: "unavailable", enabled: false },
        { id: "chatgpt", name: "ChatGPT", status: "ready", version: "0.1.0", enabled: false },
    ];

    // Like the real server, a provider that isn't installed is refused, and a failed update answers
    // "Unable to update <id>.", which the apps show as nothing newer.
    async function update(provider: Provider, response: ServerResponse) {
        if (provider.status === "unavailable") return reply(response, 422, { error: `${provider.name} isn't installed.` });
        await new Promise(resolve => setTimeout(resolve, updateDelays[provider.id] ?? defaultUpdateDelay));
        if (provider.id === "gemini") return reply(response, 500, { error: "Unable to update gemini." });
        const before = provider.version;
        provider.version = newer[provider.id] ?? provider.version;
        reply(response, 200, { version: provider.version, updated: provider.version !== before });
    }

    function handle(request: IncomingMessage, response: ServerResponse, url: URL): boolean {
        if (request.method === "GET" && url.pathname === "/api/v1/providers") {
            reply(response, 200, { providers });
            return true;
        }
        const route = /^\/api\/v1\/providers\/([^/]+)\/(subscription|update)$/.exec(url.pathname);
        if (!route) return false;
        const id = decodeURIComponent(route[1]);
        const provider = providers.find(candidate => candidate.id === id);
        if (request.method === "GET" && route[2] === "subscription") {
            if (id === "cursor") reply(response, 500, { error: "Usage unavailable." });
            else if (subscriptions[id]) reply(response, 200, subscriptions[id]);
            else reply(response, 404, { error: "Provider not found." });
            return true;
        }
        if (request.method === "POST" && route[2] === "update") {
            if (provider) void update(provider, response);
            else reply(response, 404, { error: "Provider not found." });
            return true;
        }
        return false;
    }

    return { handle };
}
