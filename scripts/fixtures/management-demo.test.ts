import { expect, test } from "bun:test";
import fixture from "../../Tests/ChannelKitTests/Fixtures/channel-snapshot.json";
import { createManagementFixture } from "./management-demo.ts";

const configured = fixture.channel.model;
const channelPath = "/api/v1/channels/management-demo";

function harness() {
    const demo = createManagementFixture();
    return {
        ...demo,
        call(path: string, method = "GET", body?: unknown) {
            return fetch(new URL(path, demo.server.url), {
                method, ...(body === undefined ? {} : {
                    body: JSON.stringify(body), headers: { "Content-Type": "application/json" },
                }), signal: AbortSignal.timeout(10_000),
            });
        },
    };
}

test("private channel/member CRUD preserves blank state, model options, inheritance and the catalog lead", async () => {
    const demo = harness();
    try {
        const catalog = await (await demo.call("/api/v1/channels")).json();
        expect(catalog).toMatchObject({ version: 1, lead: { name: fixture.lead.name }, members: [] });
        expect(catalog.channels).toHaveLength(1);
        expect(catalog.channels[0]).toMatchObject({ id: "management-demo", name: "Management Scratch" });
        const options = { ...configured, reasoningEffort: "high", fixtureOption: { retained: true } };
        const created = await demo.call("/api/v1/channels", "POST", {
            name: "New scratch", purpose: "Private", directory: "/fixture-only", model: options,
        });
        expect(created.status).toBe(201);
        const { channel } = await created.json();
        const path = `/api/v1/channels/${channel.id}`;
        expect(channel).toMatchObject({
            name: "New scratch", purpose: "Private", directory: "/fixture-only", model: options,
            tasks: [], latestSequence: 0, seenThrough: 0, requestSequence: null, completedSequence: null,
        });
        expect(channel).not.toHaveProperty("previewUrl");
        expect((await (await demo.call(path, "PATCH", { purpose: null })).json()).channel)
            .not.toHaveProperty("purpose");
        const member = await (await demo.call(`${path}/members`, "POST", { name: "Ada", role: "Build" })).json();
        expect(member).toMatchObject({ version: 1, member: { name: "Ada", role: "Build", channelId: channel.id } });
        expect(member.member).not.toHaveProperty("model");
        const memberPath = `${path}/members/${member.member.id}`;
        const models = await (await demo.call(`${memberPath}/models`)).json();
        expect(models).toMatchObject({ version: 1, defaultModel: options });
        const edited = await (await demo.call(memberPath, "PATCH", { name: "Ada edited", model: options })).json();
        expect(edited.member).toMatchObject({ name: "Ada edited", model: options });
        const inherited = await (await demo.call(memberPath, "PATCH", { model: null })).json();
        expect(inherited.member).not.toHaveProperty("model");
        expect((await demo.call(memberPath, "DELETE")).status).toBe(204);
        expect((await demo.call(path, "DELETE")).status).toBe(204);
        expect((await demo.call(channelPath, "DELETE")).status).toBe(204);
        expect(await (await demo.call("/api/v1/channels")).json()).toEqual({
            version: 1, lead: catalog.lead, channels: [], members: [],
        });
    } finally { await demo.close(); }
});

test("snapshot streams publish committed state and deletion, without inherited conversations or work", async () => {
    const demo = harness();
    const abort = new AbortController();
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    try {
        const response = await fetch(new URL(channelPath, demo.server.url), { signal: abort.signal });
        expect(response.headers.get("content-type")).toBe("text/event-stream");
        reader = response.body!.getReader();
        let pending = "";
        const decoder = new TextDecoder();
        async function next() {
            while (true) {
                while (!pending.includes("\n\n")) {
                    const chunk = await reader!.read();
                    if (chunk.done) throw new Error("Stream ended before the expected event.");
                    pending += decoder.decode(chunk.value, { stream: true });
                }
                const end = pending.indexOf("\n\n");
                const frame = pending.slice(0, end);
                pending = pending.slice(end + 2);
                const data = frame.split("\n").filter(line => line.startsWith("data: ")).map(line => line.slice(6));
                if (data.length) return JSON.parse(data.join("\n"));
            }
        }
        const first = await next();
        expect(first).toMatchObject({
            type: "snapshot", state: { revision: 0, request: null, messages: [], routines: [], artifacts: [],
                members: [], presence: {}, lead: { id: "management-demo" } },
        });
        expect((await demo.call(channelPath, "PATCH", { name: "Renamed" })).status).toBe(200);
        expect(await next()).toMatchObject({
            type: "snapshot", state: { revision: 1, channel: { id: "management-demo", name: "Renamed" } },
        });
        expect((await demo.call(channelPath, "DELETE")).status).toBe(204);
        expect(await next()).toEqual({ type: "deleted", channelId: "management-demo" });
        expect((await reader.read()).done).toBe(true);
        expect((await demo.call(channelPath)).status).toBe(404);
    } finally {
        abort.abort();
        await reader?.cancel();
        await demo.close();
    }
});

for (const mode of ["reject422", "commit500"] as const) {
    for (const operation of ["createChannel", "editChannel", "deleteChannel", "createMember", "editMember", "removeMember"]) {
        test(`${operation}: ${mode} affects exactly one matching write and allows readback`, async () => {
            const demo = harness();
            try {
                const needsMember = ["editMember", "removeMember"].includes(operation);
                const member = needsMember
                    ? (await (await demo.call(`${channelPath}/members`, "POST", { name: "Original" })).json()).member
                    : undefined;
                const method = operation.startsWith("create") ? "POST"
                    : ["deleteChannel", "removeMember"].includes(operation) ? "DELETE" : "PATCH";
                const path = operation === "createChannel" ? "/api/v1/channels"
                    : operation === "createMember" ? `${channelPath}/members`
                        : member ? `${channelPath}/members/${member.id}` : channelPath;
                const input = operation === "createChannel" ? { name: "Changed", model: configured } : { name: "Changed" };
                const before = await (await demo.call("/_fixture/state")).json();
                expect((await demo.call("/_fixture/fault", "POST", { method, path, mode })).status).toBe(204);
                await demo.call("/api/v1/channels");
                await demo.call("/api/v1/models");
                const armed = await (await demo.call("/_fixture/state")).json();
                expect(armed.fault).toEqual({ method, path, mode });
                expect(armed.writes).toEqual(before.writes);
                const write = await demo.call(path, method, method === "DELETE" ? undefined : input);
                expect(write.status).toBe(mode === "reject422" ? 422 : 500);
                const after = await (await demo.call("/_fixture/state")).json();
                expect(after.fault).toBeNull();
                expect(after.writes.slice(before.writes.length)).toEqual([{
                    method, path, status: mode === "reject422" ? 422 : 500, committed: mode === "commit500",
                }]);
                if (mode === "reject422") {
                    expect(after.channels).toEqual(before.channels);
                } else {
                    expect(after.channels).not.toEqual(before.channels);
                    if (operation === "createChannel") expect(after.channels).toHaveLength(2);
                    if (operation === "deleteChannel") expect(after.channels).toHaveLength(0);
                    if (operation === "editChannel") expect(after.channels[0].channel.name).toBe("Changed");
                    if (operation === "createMember") expect(after.channels[0].members).toHaveLength(1);
                    if (operation === "editMember") expect(after.channels[0].members[0].name).toBe("Changed");
                    if (operation === "removeMember") expect(after.channels[0].members).toHaveLength(0);
                }
                const catalog = await (await demo.call("/api/v1/channels")).json();
                expect(catalog.channels).toEqual(after.channels.map((state: { channel: unknown }) => state.channel));
                const next = await demo.call(path, method, method === "DELETE" ? undefined : input);
                expect(next.status).not.toBe(500);
                expect(next.status).not.toBe(422);
            } finally { await demo.close(); }
        });
    }
}

test("invalid edits are atomic and fault controls reject unsupported routes and overlapping arms", async () => {
    const demo = harness();
    try {
        const before = await (await demo.call("/_fixture/state")).json();
        expect((await demo.call(channelPath, "PATCH", { name: "Do not apply", model: {} })).status).toBe(422);
        expect((await (await demo.call("/_fixture/state")).json()).channels).toEqual(before.channels);
        expect((await demo.call("/_fixture/fault", "POST", {
            method: "POST", path: `${channelPath}/routines`, mode: "commit500",
        })).status).toBe(400);
        const fault = { method: "PATCH", path: channelPath, mode: "commit500" };
        expect((await demo.call("/_fixture/fault", "POST", fault)).status).toBe(204);
        expect((await demo.call("/_fixture/fault", "POST", fault)).status).toBe(409);
        expect((await demo.call("/_fixture/fault", "DELETE")).status).toBe(204);
        expect((await demo.call(channelPath, "PATCH", { name: "Valid" })).status).toBe(200);
        expect((await demo.call("/api/v1/channels", "POST", { name: "Missing model" })).status).toBe(422);
        expect((await demo.call(`${channelPath}/routines`, "POST", {})).status).toBe(404);
    } finally { await demo.close(); }
});
