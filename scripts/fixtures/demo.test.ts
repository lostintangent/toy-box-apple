import { expect, test } from "bun:test";
import { createServer } from "node:http";
import fixture from "../../Tests/ChannelKitTests/Fixtures/channel-snapshot.json";
import { installDemoCatalogRoutes } from "./demo.ts";
import type { Snapshot } from "./types.ts";

test("demo catalogs serve the current fixture lead and model without changing reference routes", async () => {
    let snapshot: Snapshot = { ...fixture, messages: [], request: null };
    const server = createServer((request, response) => {
        response.writeHead(404);
        response.end(`Reference: ${request.method} ${request.url}`);
    });
    installDemoCatalogRoutes({ server, snapshot: () => snapshot });
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    try {
        const address = server.address();
        if (!address || typeof address === "string") throw new Error("Expected a TCP fixture listener.");
        const base = `http://127.0.0.1:${address.port}`;
        const channels = await fetch(`${base}/api/v1/channels`);
        expect(channels.status).toBe(200);
        expect(await channels.json()).toEqual({
            version: 1,
            lead: { name: fixture.lead.name, role: fixture.lead.role, avatar: fixture.lead.avatar },
            channels: [fixture.channel], members: fixture.members,
        });
        for (const name of [fixture.channel.model.name, "updated-fixture-model"]) {
            snapshot = { ...snapshot, channel: { ...snapshot.channel, model: { ...snapshot.channel.model, name } } };
            const models = await fetch(`${base}/api/v1/models`);
            expect(models.status).toBe(200);
            expect(models.headers.get("cache-control")).toBe("no-store");
            expect(await models.json()).toEqual({
                version: 1, provider: snapshot.channel.model.provider, defaultModel: snapshot.channel.model,
                models: [{ id: name, name, provider: snapshot.channel.model.provider }],
            });
        }
        const post = await fetch(`${base}/api/v1/models`, { method: "POST" });
        expect(post.status).toBe(404);
        expect(await post.text()).toBe("Reference: POST /api/v1/models");
        const other = await fetch(`${base}/other`);
        expect(other.status).toBe(404);
        expect(await other.text()).toBe("Reference: GET /other");
    } finally {
        await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    }
});
