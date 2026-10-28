import { expect, test } from "bun:test";
import { createServer } from "node:http";
import fixture from "../../Tests/ChannelKitTests/Fixtures/channel-snapshot.json";
import { createCompletedDemoFixture, demoOptions, installDemoCatalogRoutes } from "./demo.ts";
import type { Snapshot } from "./types.ts";

test("the normal demo baseline stays unchanged unless completion proof is explicitly requested", () => {
    expect(demoOptions([])).toEqual({ reference: undefined, completed: false });
    expect(demoOptions(["../reference"])).toEqual({ reference: "../reference", completed: false });
    for (const args of [["--completed", "../reference"], ["../reference", "--completed"]]) {
        expect(demoOptions(args)).toEqual({ reference: "../reference", completed: true });
    }
    expect(() => demoOptions(["one", "two"])).toThrow("Usage");
    expect(() => demoOptions(["--unknown"])).toThrow();
});

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
        const registrationPath = `/api/v1/push/${id}`;
        const subscriptionPath = `/api/v1/push/${id}/topics/studio-demo`;
        expect(routes.match(`/api/v1/push/activities/${id}/studio-demo`)).toBeUndefined();
        const put = (path: string, value: unknown) => fetch(base + path, {
            method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(value),
        });
        const subscription = { token: "aa", startedAt: 1793086200 };
        expect((await put(subscriptionPath, subscription)).status).toBe(404);
        expect(routes.registrations.size).toBe(0);
        expect(routes.subscriptions.size).toBe(0);
        const registration = { token: "bb", environment: "sandbox" as const };
        expect((await put(registrationPath, registration)).status).toBe(201);
        expect(routes.registrations.get(id)).toEqual({ registrationID: id, ...registration });
        expect((await put(subscriptionPath, { ...subscription, token: "cc" })).status).toBe(204);
        expect(routes.subscriptions.get(`studio-demo\n${id}`)?.startedAt).toBe(subscription.startedAt);
        expect(routes.subscriptions.get(`studio-demo\n${id}`)?.token).toBe("cc");
        expect((await fetch(base + registrationPath, { method: "DELETE" })).status).toBe(204);
        expect((await fetch(base + registrationPath, { method: "DELETE" })).status).toBe(204);
        expect(routes.registrations.size).toBe(0);
        expect(routes.subscriptions.size).toBe(0);
        expect((await put(subscriptionPath, subscription)).status).toBe(404);
        expect((await put(registrationPath, registration)).status).toBe(201);
        expect((await put(subscriptionPath, subscription)).status).toBe(204);
        expect((await put(`/api/v1/push/${other}`, {
            ...registration, token: "BB",
        })).status).toBe(201);
        expect([...routes.registrations.keys()]).toEqual([other]);
        expect(routes.registrations.get(other)?.token).toBe("bb");
        expect(routes.subscriptions.size).toBe(0);
        const unknown = `/api/v1/push/${other}/topics/missing`;
        expect((await put(unknown, subscription)).status).toBe(204);
        expect(routes.subscriptions.get(`missing\n${other}`)?.topic).toBe("missing");
        expect((await fetch(base + unknown, { method: "DELETE" })).status).toBe(204);
        expect((await put(registrationPath, { ...registration, token: "not-hex" })).status).toBe(422);
        expect((await put(registrationPath, { ...registration, environment: "unknown" })).status).toBe(422);
        expect((await put(registrationPath, { ...registration, extra: "x".repeat(17_000) })).status).toBe(413);
        expect((await fetch(base + registrationPath, { method: "PUT", body: "invalid" })).status).toBe(400);
        expect(routes.registrations.size).toBe(1);
        expect((await fetch(base + subscriptionPath, { method: "DELETE" })).status).toBe(204);
        expect(routes.subscriptions.size).toBe(0);
        expect((await fetch(base + registrationPath)).status).toBe(405);
    } finally {
        await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    }
});

test("the completed demo is a separate finished channel and leaves Studio's request untouched", () => {
    const source: Snapshot = { ...fixture, messages: [fixture.request], request: fixture.request };
    const original = structuredClone(source);
    const completed = createCompletedDemoFixture(source, 1793086200000);
    expect(source).toEqual(original);
    expect(source.request?.sequence).toBe(15);
    expect(source.channel.requestSequence).toBe(15);
    expect(completed.channel.id).toBe("completed-demo");
    expect(completed.channel.name).toBe("Completed demo");
    expect(completed.channel.tasks.every(task => task.status === "done")).toBe(true);
    expect(completed.channel.tasks.flatMap(task => task.children ?? []).every(task => task.status === "done")).toBe(true);
    expect(completed.channel.completedSequence).toBe(1);
    expect(completed.channel.latestSequence).toBe(1);
    expect(completed.channel.seenThrough).toBe(0);
    expect(completed.channel.requestSequence).toBeNull();
    expect(completed.request).toBeNull();
    expect(completed.messages).toHaveLength(1);
    expect(completed.messages[0]?.sequence).toBe(1);
    expect(completed.lead.avatar).toEqual(source.lead.avatar);
    expect(completed.members.every(member => member.channelId === completed.channel.id)).toBe(true);
    expect(Object.values(completed.presence).every(presence => presence.state === "idle")).toBe(true);
});

test("multiple demo channels keep their own history, routes and Activity registrations", async () => {
    const primary: Snapshot = { ...fixture, messages: [fixture.request], request: fixture.request };
    const completed = createCompletedDemoFixture(primary);
    const makeServer = (name: string) => createServer((request, response) => {
        response.writeHead(200); response.end(`${name}: ${request.url}`);
    });
    const server = makeServer("Studio");
    const peer = makeServer("Completed");
    const routes = installDemoCatalogRoutes({ server, snapshot: () => primary },
        [{ server: peer, snapshot: () => completed }]);
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    try {
        const address = server.address();
        if (!address || typeof address === "string") throw new Error("Expected a TCP fixture listener.");
        const base = `http://127.0.0.1:${address.port}`;
        const catalog = await (await fetch(`${base}/api/v1/channels`)).json();
        expect(catalog.channels).toEqual([primary.channel, completed.channel]);
        expect(catalog.members).toEqual([...primary.members, ...completed.members]);
        for (const suffix of ["", "/read"]) {
            expect(await (await fetch(`${base}/api/v1/channels/completed-demo${suffix}`)).text())
                .toBe(`Completed: /api/v1/channels/completed-demo${suffix}`);
        }
        expect(await (await fetch(`${base}/api/v1/channels/studio-demo`)).text())
            .toBe("Studio: /api/v1/channels/studio-demo");
        expect(await (await fetch(`${base}/api/v1/channels/completed-demo-other`)).text())
            .toBe("Studio: /api/v1/channels/completed-demo-other");
        for (const [channel, before, message] of [
            [primary, 16, fixture.request], [completed, 2, completed.messages[0]],
        ] as const) {
            const response = await fetch(`${base}/api/v1/channels/${channel.channel.id}/messages?before=${before}`);
            expect(response.status).toBe(200);
            expect(await response.json()).toEqual({ version: 1, revision: channel.revision, messages: [message] });
        }
        expect((await fetch(`${base}/api/v1/channels/studio-demo/messages?before=0`)).status).toBe(400);
        expect(await (await fetch(`${base}/api/v1/channels/completed-demo/messages`, { method: "POST" })).text())
            .toBe("Completed: /api/v1/channels/completed-demo/messages");
        const id = "00000000-0000-4000-8000-000000000003";
        expect((await fetch(`${base}/api/v1/push/${id}`, {
            method: "PUT", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ token: "bb", environment: "sandbox" }),
        })).status).toBe(201);
        const response = await fetch(`${base}/api/v1/push/${id}/topics/completed-demo`, {
            method: "PUT", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ token: "aa", startedAt: 1793086200 }),
        });
        expect(response.status).toBe(204);
        expect(routes.subscriptions.get(`completed-demo\n${id}`)?.topic).toBe("completed-demo");
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
