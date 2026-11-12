import type { IncomingMessage, ServerResponse } from "node:http";

// TOY_BOX_DEMO_LINKS=unsupported serves a server that predates links, which answers 404.
function demoLinksMode() {
    const mode = process.env.TOY_BOX_DEMO_LINKS;
    if (mode === undefined || mode === "unsupported") return mode;
    throw new Error(`TOY_BOX_DEMO_LINKS must be unsupported, not "${mode}"`);
}

function reply(response: ServerResponse, status: number, body: unknown) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(JSON.stringify(body));
}

async function body(request: IncomingMessage): Promise<unknown> {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { return undefined; }
}

class Refusal extends Error {}

// Like the server, a link is the other server's origin. It takes an http:// or https:// address,
// and a bare host is https://.
function address(input: unknown) {
    const text = typeof input === "string" ? input.trim() : "";
    const url = URL.parse(text.includes("://") ? text : `https://${text}`);
    if ((url?.protocol !== "http:" && url?.protocol !== "https:") || url.hostname === "")
        throw new Refusal("Enter an http or https address, like http://studio:3000.");
    return url.origin;
}

function describe(error: unknown) {
    return (error instanceof Error ? error.message : String(error)).replace(/\.$/, "");
}

// Reads the other server's channels within 3 seconds, as the server does before it links one.
async function reach(base: string) {
    const answer = await fetch(`${base}/api/v1/channels`, { redirect: "error", signal: AbortSignal.timeout(3_000) });
    if (!answer.ok) throw new Error(`HTTP ${answer.status}`);
    const catalog = await answer.json().catch(() => undefined) as { channels?: unknown } | undefined;
    if (!Array.isArray(catalog?.channels)) throw new Error("Not a Toy Box channel catalog");
}

/** `/api/v1/server/links`: the other servers this one links, in memory, in the order it linked them.
 *  Reading them contacts no other server. */
export function createDemoLinkRoutes() {
    const mode = demoLinksMode();
    const links: string[] = [];
    const list = () => ({ links: [...links] });
    async function change(request: IncomingMessage, url: URL) {
        if (request.method === "GET") return list();
        if (request.method === "DELETE") {
            const index = links.indexOf(address(url.searchParams.get("address")));
            if (index >= 0) links.splice(index, 1);
            return list();
        }
        const input = await body(request) as { address?: unknown } | undefined;
        const linked = address(input?.address);
        await reach(linked).catch(error => {
            throw new Refusal(`This server can't reach ${linked} (${describe(error)}).`);
        });
        if (!links.includes(linked)) links.push(linked);
        return list();
    }
    return {
        handle(request: IncomingMessage, response: ServerResponse, url: URL) {
            if (url.pathname !== "/api/v1/server/links") return false;
            if (mode === "unsupported") {
                reply(response, 404, { error: "Not found" });
            } else if (!["GET", "POST", "DELETE"].includes(request.method ?? "")) {
                response.setHeader("Allow", "GET, POST, DELETE");
                reply(response, 405, { error: "Method not allowed" });
            } else {
                change(request, url).then(
                    answer => reply(response, 200, answer),
                    error => error instanceof Refusal
                        ? reply(response, 422, { error: error.message })
                        : reply(response, 500, { error: describe(error) }),
                );
            }
            return true;
        },
    };
}
