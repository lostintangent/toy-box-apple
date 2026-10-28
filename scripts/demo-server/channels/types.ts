import type fixture from "../../../Tests/ChannelKitTests/Fixtures/channel-snapshot.json";
import type { Server, ServerResponse } from "node:http";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

export type Status = { state: string; text?: string; wakeAt?: string; workingOn?: number };
export type Agent = {
    id: string; name: string; role: string; avatar: { mark: string; color: string };
    channelId?: string; status?: Status;
};
export type Message = {
    id: string; sequence: number; timestamp: string;
    sender: { type: string; agentId?: string }; content: string; request?: boolean;
    attachments?: { name: string; url: string }[];
};
export type Snapshot = Omit<typeof fixture, "lead" | "members" | "messages" | "request" | "channel" | "presence"> & {
    lead: Agent; members: Agent[]; messages: Message[]; request: Message | null;
    presence: Record<string, Status>;
    channel: Omit<typeof fixture.channel, "requestSequence" | "completedSequence"> & {
        requestSequence: number | null; completedSequence: number | null;
    };
};
export type Demo = { server: Server; snapshot(): Snapshot; replace(snapshot: Snapshot): void; close(): Promise<void> };
type Factory = (snapshot?: Snapshot, now?: number) => Demo;
export type Response = ServerResponse;

export async function referenceFactory(reference: string): Promise<Factory> {
    const module = await import(pathToFileURL(resolve(reference, "tools/demo-server.ts")).href);
    if (typeof module.createDemoServer !== "function") throw new Error("The reference has no demo server factory.");
    return module.createDemoServer;
}

export function remapChannel<T>(value: T, channel: string): T {
    if (value === "studio-demo") return channel as T;
    if (Array.isArray(value)) return value.map(child => remapChannel(child, channel)) as T;
    if (value && typeof value === "object") {
        return Object.fromEntries(Object.entries(value).map(([key, child]) =>
            [key === "studio-demo" ? channel : key, remapChannel(child, channel)])) as T;
    }
    return value;
}
