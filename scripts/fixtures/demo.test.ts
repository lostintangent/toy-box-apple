import { expect, test } from "bun:test";
import { createServer } from "node:http";
import fixture from "../../Tests/ChannelKitTests/Fixtures/channel-snapshot.json";
import { installDemoCatalogRoutes } from "./demo.ts";
import type { Snapshot } from "./types.ts";

test("demo push routes keep alerts and follows independent and preserve the original Activity start", async () => {
    const snapshot: Snapshot = { ...fixture, messages: [], request: null };
    const server = createServer((_, response) => { response.writeHead(404); response.end(); });
    const routes = installDemoCatalogRoutes({ server, snapshot: () => snapshot });
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    try {
        const address = server.address();
        if (!address || typeof address === "string") throw new Error("Expected a TCP fixture listener.");
        const base = `http://127.0.0.1:${address.port}`;
        const id = "00000000-0000-4000-8000-000000000001";
        const other = "00000000-0000-4000-8000-000000000002";
        const devicePath = `/api/v1/push/devices/${id}`;
        const activityPath = `/api/v1/channels/studio-demo/activities/${id}`;
        const put = (path: string, value: unknown) => fetch(base + path, {
            method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(value),
        });
        const activity = { registrationID: id, token: "aa", environment: "sandbox", startedAt: 1793086200 };
        expect((await put(activityPath, activity)).status).toBe(204);
        expect(routes.devices.size).toBe(0);
        expect(routes.activities.size).toBe(1);
        const device = { registrationID: id, token: "bb", environment: "sandbox" as const, requests: true, completions: false };
        expect((await put(devicePath, device)).status).toBe(204);
        expect(routes.devices.get(id)).toEqual(device);
        expect((await put(activityPath, { ...activity, token: "cc", startedAt: activity.startedAt + 600 })).status).toBe(204);
        expect(routes.activities.get(`studio-demo\n${id}`)?.startedAt).toBe(activity.startedAt);
        expect(routes.activities.get(`studio-demo\n${id}`)?.token).toBe("cc");
        expect((await fetch(base + devicePath, { method: "DELETE" })).status).toBe(204);
        expect(routes.devices.size).toBe(0);
        expect(routes.activities.size).toBe(1);
        expect((await put(devicePath, device)).status).toBe(204);
        expect((await put(`/api/v1/push/devices/${other}`, {
            ...device, registrationID: other, token: "BB", requests: false, completions: true,
        })).status).toBe(204);
        expect([...routes.devices.keys()]).toEqual([other]);
        expect(routes.devices.get(other)?.token).toBe("bb");
        expect(routes.devices.get(other)?.requests).toBe(false);
        expect(routes.devices.get(other)?.completions).toBe(true);
        expect((await put(`/api/v1/channels/missing/activities/${id}`, activity)).status).toBe(404);
        expect((await put(devicePath, { ...device, requests: "yes" })).status).toBe(422);
        expect((await put(devicePath, { ...device, environment: "unknown" })).status).toBe(422);
        expect((await put(devicePath, { ...device, extra: "x".repeat(17_000) })).status).toBe(413);
        expect((await fetch(base + devicePath, { method: "PUT", body: "invalid" })).status).toBe(400);
        expect(routes.devices.size).toBe(1);
        expect((await fetch(base + activityPath, { method: "DELETE" })).status).toBe(204);
        expect(routes.activities.size).toBe(0);
        expect((await fetch(base + devicePath)).status).toBe(405);
    } finally {
        await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    }
});

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
