// The catalog route the way the server serves it. A plain GET gets the catalog as JSON. One that
// accepts text/event-stream gets a stream that opens with the catalog, sends each channel and
// member change after it, and keeps alive every 5 seconds.
import type { IncomingMessage, ServerResponse } from "node:http";

type Entity = { id: string; channelId?: string };
type Catalog = { channels: Entity[]; members: Entity[] };

export function createCatalogRoute(read: () => Catalog) {
    const clients = new Set<ServerResponse>();
    const index = ({ channels, members }: Catalog) => ({
        channels: new Map(channels.map(channel => [channel.id, JSON.stringify(channel)])),
        members: new Map(members.map(member => [member.id, JSON.stringify(member)])),
    });
    let sent = index(read());
    const send = (event: unknown) => {
        for (const client of clients) client.write(`data: ${JSON.stringify(event)}\n\n`);
    };
    const heartbeat = setInterval(() => { for (const client of clients) client.write(": keepalive\n\n"); }, 5000);
    heartbeat.unref();
    return {
        serve(request: IncomingMessage, response: ServerResponse) {
            const catalog = read();
            if (!request.headers.accept?.includes("text/event-stream")) {
                response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
                response.end(JSON.stringify(catalog));
                return;
            }
            response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
            response.write("retry: 1000\n\n");
            response.write(`data: ${JSON.stringify({ type: "snapshot", catalog })}\n\n`);
            clients.add(response);
            response.on("close", () => clients.delete(response));
        },
        /** Sends every channel and member that changed since the last call to each open stream. */
        publish() {
            const catalog = read();
            const next = index(catalog);
            for (const channel of catalog.channels) {
                if (sent.channels.get(channel.id) !== next.channels.get(channel.id)) send({ type: "channel.upserted", channel });
            }
            for (const channelId of sent.channels.keys()) {
                if (!next.channels.has(channelId)) send({ type: "channel.deleted", channelId });
            }
            for (const member of catalog.members) {
                if (sent.members.get(member.id) !== next.members.get(member.id)) send({ type: "channel.member.upserted", member });
            }
            for (const [agentId, member] of sent.members) {
                if (!next.members.has(agentId)) send({ type: "channel.member.deleted", channelId: JSON.parse(member).channelId, agentId });
            }
            sent = next;
        },
        close() {
            clearInterval(heartbeat);
            for (const client of clients) client.end();
        },
    };
}
