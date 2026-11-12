import type { IncomingMessage } from "node:http";

export async function body(request: IncomingMessage): Promise<unknown> {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { return undefined; }
}

/** A request the server refuses with a 422 and its reason, storing nothing. */
export class Refusal extends Error {}

// Like the server, a link is the other server's origin. It takes an http:// or https:// address,
// and a bare host is https://.
function address(input: unknown) {
    const text = typeof input === "string" ? input.trim() : "";
    const url = URL.parse(text.includes("://") ? text : `https://${text}`);
    if ((url?.protocol !== "http:" && url?.protocol !== "https:") || url.hostname === "")
        throw new Refusal("Enter an http or https address, like http://studio:3000.");
    return url.origin;
}

export function describe(error: unknown) {
    return (error instanceof Error ? error.message : String(error)).replace(/\.$/, "");
}

/** Reads the other server within 3 seconds, as the server does once before it links one. */
async function reach(origin: string) {
    const answer = await fetch(`${origin}/api/v1/server`, { redirect: "error", signal: AbortSignal.timeout(3_000) })
        .catch(error => { throw new Refusal(`This server can't reach ${origin} (${describe(error)}).`); });
    if (!answer.ok) throw new Refusal(`This server can't reach ${origin} (HTTP ${answer.status}).`);
    return await answer.json() as { id: string, links: string[] };
}

/** Asks the other server to change its end of the link, naming this one by `self`. */
async function ask(origin: string, self: string, linking: boolean) {
    const route = `${origin}/api/v1/server/links`;
    const answer = await fetch(linking ? route : `${route}?address=${encodeURIComponent(self)}`, {
        method: linking ? "POST" : "DELETE", redirect: "error", signal: AbortSignal.timeout(3_000),
        ...linking ? { headers: { "Content-Type": "application/json" }, body: JSON.stringify({ address: self }) } : {},
    }).catch(error => { throw new Refusal(`This server can't reach ${origin} (${describe(error)}).`); });
    if (answer.ok) return;
    const refusal = await answer.json().catch(() => undefined) as { error?: unknown } | undefined;
    throw new Refusal(typeof refusal?.error === "string" ? refusal.error : `${origin} answered HTTP ${answer.status}.`);
}

/** The other servers this one links, in memory, in the order it linked them. Reading them contacts
 *  no other server. The demos treat every request as reaching them where other servers do, since
 *  on this Mac their Tailscale address is their own, so each change reaches the other end too,
 *  naming this server by the origin the request reached. A pair already in that state answers at
 *  once, which is how the other end's request back ends. */
export function createDemoLinks(id: string) {
    const links: string[] = [];
    return {
        get list() { return [...links]; },
        async change(request: IncomingMessage, url: URL) {
            const self = `http://${request.headers.host ?? url.host}`;
            if (request.method === "DELETE") {
                const other = address(url.searchParams.get("address"));
                const index = links.indexOf(other);
                if (index < 0) return;
                links.splice(index, 1);
                // The other end may be gone, and unlinking this end still holds.
                await ask(other, self, false).catch(() => {});
                return;
            }
            const input = await body(request) as { address?: unknown } | undefined;
            const other = address(input?.address);
            if (links.includes(other)) return;
            if (other === self) throw new Refusal("A server can't link with itself.");
            const server = await reach(other);
            if (server.id === id) throw new Refusal("A server can't link with itself.");
            links.push(other);
            if (server.links.includes(self)) return;
            await ask(other, self, true).catch(error => {
                const index = links.indexOf(other);
                if (index >= 0) links.splice(index, 1);
                throw error;
            });
        },
    };
}
