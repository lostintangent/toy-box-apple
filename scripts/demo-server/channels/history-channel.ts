// The history-demo channel that the history and performance fixture servers serve: the
// reference snapshot stretched to 480 messages, with the latest 100 in the snapshot and the rest in
// canonical 100-message older pages.
import { remapChannel, type Message, type Response, type Snapshot } from "./types.ts";

export const historyChannelID = "history-demo";
export const historyPageSize = 100;
export const historyMessageCount = 480;

// Builds the channel's snapshot and full history from the reference fixture's snapshot.
export function createHistoryFixture(source: Snapshot, { now, origin }: { now: number; origin: string }) {
    const snapshot = remapChannel(source, historyChannelID);
    if (!snapshot.request) throw new Error("The history fixture requires the reference request message.");
    const agents = [snapshot.lead, ...snapshot.members];
    const history = Array.from({ length: historyMessageCount }, (_, index) => {
        const sequence = index + 1;
        const timestamp = new Date(now - (historyMessageCount - sequence) * 20 * 60_000).toISOString();
        if (index < snapshot.messages.length) return { ...snapshot.messages[index], timestamp };
        const agent = agents[index % agents.length];
        const sender = sequence % 9 === 0 ? { type: "user" } : { type: "agent", agentId: agent.id };
        const content = sequence % 17 === 0
            ? `History message ${sequence}\n\nA measured checkpoint for paging.\n\n- Preserve the visible row\n- Keep read receipts monotonic\n- Leave requests unanswered by reads`
            : `History message ${sequence}: the workshop keeps older decisions available while the team continues its current work.`;
        return { id: `history-message-${sequence}`, sequence, timestamp, sender, content };
    });
    const request = {
        ...snapshot.request, id: "history-request", sequence: historyMessageCount,
        timestamp: new Date(now).toISOString(),
        content: "Please confirm the history review. Reading or paging must not answer this request.",
    };
    history[historyMessageCount - 1] = request;
    Object.assign(snapshot.channel, {
        name: "History demo", purpose: "An isolated long-history fixture for native paging, unread landing and read receipts.",
        latestSequence: historyMessageCount, seenThrough: 450, requestSequence: historyMessageCount,
        completedSequence: null, updatedAt: new Date(now).toISOString(),
        previewUrl: `${origin}/demo-preview`,
    });
    snapshot.revision = historyMessageCount;
    snapshot.messages = history.slice(-historyPageSize);
    snapshot.request = request;
    if (snapshot.lead.status?.wakeAt) snapshot.lead.status.wakeAt = new Date(now + 10 * 60_000).toISOString();
    return { snapshot, history };
}

// Answers `GET /api/v1/channels/history-demo/messages?before=N` the way getChannelHistoryResponse
// and listMessagesBefore do, without loading the live database.
export function writeHistoryPage(response: Response, url: URL, history: Message[], revision: number) {
    const before = Number(url.searchParams.get("before"));
    const valid = Number.isSafeInteger(before) && before > 0;
    response.writeHead(valid ? 200 : 400, {
        "Content-Type": "application/json", ...(valid ? { "Cache-Control": "no-store" } : {}),
    });
    response.end(JSON.stringify(valid ? {
        version: 1, revision,
        messages: history.filter(message => message.sequence < before).slice(-historyPageSize),
    } : { error: "Invalid Channel request." }));
}
