import { expect, onTestFinished, test } from "bun:test";
import { createServer } from "node:http";
import fixture from "../../Tests/ChannelKitTests/Fixtures/channel-snapshot.json";
import { installDemoCatalogRoutes } from "./demo.ts";
import type { Snapshot } from "./types.ts";

async function serve(snapshot: () => Snapshot) {
    const server = createServer((request, response) => {
        response.writeHead(404);
        response.end(`Reference: ${request.method} ${request.url}`);
    });
    const routes = installDemoCatalogRoutes({ server, snapshot });
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    onTestFinished(() => new Promise<void>((resolve, reject) =>
        server.close(error => error ? reject(error) : resolve())));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Expected a TCP fixture listener.");
    return { base: `http://127.0.0.1:${address.port}`, routes };
}

test("demo push routes preserve the install, independent topics and supplied Activity start", async () => {
    const { base, routes } = await serve(() => ({ ...fixture, messages: [], request: null }));
    const id = "00000000-0000-4000-8000-000000000001";
    const other = "00000000-0000-4000-8000-000000000002";
    const registrationPath = `/api/v1/push/${id}`;
    const subscriptionPath = `/api/v1/push/${id}/topics/studio-demo`;
    const put = (path: string, value: unknown) => fetch(base + path, {
        method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(value),
    });
    const subscription = { token: "aa", startedAt: 1793086200 };
    const registration = { token: "bb", environment: "sandbox" as const };
    expect(routes.match(`/api/v1/push/activities/${id}/studio-demo`)).toBeUndefined();
    expect((await put(subscriptionPath, subscription)).status).toBe(404);
    expect((await put(registrationPath, registration)).status).toBe(201);
    expect((await put(registrationPath, registration)).status).toBe(204);
    expect((await put(subscriptionPath, { ...subscription, token: "cc" })).status).toBe(204);
    expect(routes.subscriptions.get(`studio-demo\n${id}`)).toMatchObject({ token: "cc", startedAt: subscription.startedAt });
    expect((await put(`/api/v1/push/${id}/topics/requests`, {})).status).toBe(204);
    expect((await fetch(`${base}/api/v1/push/${id}/topics/requests`, { method: "DELETE" })).status).toBe(204);
    expect((await fetch(`${base}/api/v1/push/${id}/topics/requests`, { method: "DELETE" })).status).toBe(204);
    expect(routes.subscriptions.size).toBe(1);
    expect((await put(`/api/v1/push/${other}`, { ...registration, token: "BB" })).status).toBe(201);
    expect([...routes.registrations.keys()]).toEqual([other]);
    expect(routes.subscriptions.size).toBe(0);
    const opaque = `/api/v1/push/${other}/topics/missing`;
    expect((await put(opaque, subscription)).status).toBe(204);
    expect((await fetch(base + opaque, { method: "DELETE" })).status).toBe(204);
    for (const invalid of [{ ...registration, token: "not-hex" }, { ...registration, environment: "unknown" }])
        expect((await put(registrationPath, invalid)).status).toBe(422);
    expect((await put(registrationPath, { ...registration, extra: "x".repeat(17_000) })).status).toBe(413);
    expect((await fetch(base + registrationPath, { method: "PUT", body: "invalid" })).status).toBe(400);
    expect((await fetch(`${base}/api/v1/push/${other}`, { method: "DELETE" })).status).toBe(204);
    expect(routes.registrations.size).toBe(0);
    expect((await fetch(base + registrationPath)).status).toBe(405);
});

test("demo catalog, model and history reads use the current fixture and leave reference writes alone", async () => {
    let snapshot: Snapshot = { ...fixture, messages: [fixture.request], request: fixture.request };
    const { base } = await serve(() => snapshot);
    expect(await (await fetch(`${base}/api/v1/channels`)).json()).toEqual({
        version: 1, lead: { name: fixture.lead.name, role: fixture.lead.role, avatar: fixture.lead.avatar },
        channels: [fixture.channel], members: fixture.members,
    });
    for (const name of [fixture.channel.model.name, "updated-fixture-model"]) {
        snapshot = { ...snapshot, channel: { ...snapshot.channel, model: { ...snapshot.channel.model, name } } };
        const models = await fetch(`${base}/api/v1/models`);
        expect(models.headers.get("cache-control")).toBe("no-store");
        expect(await models.json()).toEqual({
            version: 1, provider: snapshot.channel.model.provider, defaultModel: snapshot.channel.model,
            models: [{ id: name, name, provider: snapshot.channel.model.provider }],
        });
    }
    expect(await (await fetch(`${base}/api/v1/channels/studio-demo/messages?before=16`)).json())
        .toEqual({ version: 1, revision: snapshot.revision, messages: [fixture.request] });
    expect((await fetch(`${base}/api/v1/channels/studio-demo/messages?before=0`)).status).toBe(400);
    for (const path of ["/api/v1/models", "/api/v1/channels/studio-demo/messages"])
        expect(await (await fetch(base + path, { method: "POST" })).text()).toBe(`Reference: POST ${path}`);
    expect(await (await fetch(`${base}/other`)).text()).toBe("Reference: GET /other");
});
