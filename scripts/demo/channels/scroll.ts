// The scroll-demo channel that the performance fixture serves for the scroll benchmark: 300 long
// messages, the kind a busy channel accumulates, with headings, lists, quotes, code blocks and
// screenshot-sized images. The latest 100 are in the snapshot and the rest in canonical
// 100-message older pages, which writeHistoryPage serves.
import { deflateSync } from "node:zlib";
import { remapChannel, type Response, type Snapshot } from "./types.ts";

export const scrollChannelID = "scroll-demo";
export const scrollMessageCount = 300;
const pageSize = 100;

const topics = ["transcript", "composer", "sidebar", "inspector", "catalog", "reducer", "stream", "release"];

const code: ((n: number) => string)[] = [
    (n) => "```swift\n"
        + `struct Pass${n}: Equatable {\n    var sequence: Int\n    var rows: [String]\n\n`
        + "    mutating func merge(_ other: Self) {\n        guard other.sequence > sequence else { return }\n"
        + "        sequence = other.sequence\n        rows.append(contentsOf: other.rows.filter { !rows.contains($0) })\n    }\n\n"
        + "    func visible(in range: Range<Int>) -> ArraySlice<String> {\n        rows[range.clamped(to: rows.indices)]\n    }\n}\n```",
    (n) => "```ts\n"
        + `export function reduce${n}(state: ChannelState, event: ChannelEvent): ChannelState {\n`
        + "  if (event.revision <= state.revision) return state;\n  switch (event.type) {\n"
        + "    case 'message':\n      return { ...state, revision: event.revision, messages: [...state.messages, event.message] };\n"
        + "    case 'status':\n      return { ...state, revision: event.revision, statuses: { ...state.statuses, [event.agentId]: event.status } };\n"
        + "    default:\n      return { ...state, revision: event.revision };\n  }\n}\n```",
    (n) => "```json\n"
        + `{\n  "pass": ${n},\n  "channels": ["studio-demo", "history-demo"],\n  "budgets": { "message": 16, "olderPage": 250, "warmSwitch": 150 },\n`
        + '  "checks": [\n    { "name": "scroll", "frames": 300, "dropped": 0 },\n    { "name": "resize", "frames": 120, "dropped": 2 }\n  ]\n}\n```',
    (n) => "```sh\n"
        + `SCRATCH_PATH=/tmp/tbm-pass-${n} bun run test\nSCRATCH_PATH=/tmp/tbm-pass-${n} bun run benchmark scroll\n`
        + "git --no-pager log --oneline -5\ngit push origin HEAD:main\n```",
];

const bodies: ((n: number, topic: string) => string)[] = [
    (n, topic) => `## Pass ${n}: ${topic}\n\nI went through the ${topic} end to end and wrote down what I found. Most of it holds up, `
        + `but two things need a decision before the next pass.\n\n- The **${topic}** keeps its state in one place, so a reconnect `
        + `resumes cleanly\n- Read receipts stay monotonic across pages\n- \`latestSequence\` only moves forward\n- Requests stay open `
        + `until someone answers them\n\nHere's the core of the change:\n\n${code[n % code.length](n)}\n\nThe rest is plumbing. I'll `
        + `land it once the tests pass and someone has scrolled through a long channel with it.`,
    (n, topic) => `I looked at why the ${topic} felt slow in a long channel. The short version is that every frame did work `
        + `proportional to the whole history, even though only a screenful was visible. **That's the part to fix.**\n\n`
        + `> A change is judged by how a real scroll feels, not by a millisecond count.\n\nThe longer version: each update re-read `
        + `the geometry of every loaded row, compared it with the previous frame, and then wrote it back. With ${100 + n} rows `
        + `loaded that's a lot of comparing for nothing, and it gets worse as the channel grows. I'd move the geometry out of the `
        + `view's tracked state, so only the rows that actually change get touched, and keep the read marking on a timer instead `
        + `of on every frame.\n\nI also checked the *pinned* case, where the reader follows the newest message, and the *reading* `
        + `case, where they've scrolled back. Both behave the same way after the change.`,
    (n, topic) => `Screenshots from pass ${n} of the ${topic}, light and dark. The spacing between the header and the first `
        + `row now matches the pane, and the glass toolbar no longer clips the avatar.`,
    (n, topic) => `### Checklist for the ${topic}\n\n1. Open a channel with ${n * 3} messages\n2. Scroll to the top with the `
        + `trackpad, then back down\n3. Resize the window while scrolled up\n4. Switch to another channel and back\n5. Send a message `
        + `and watch it land\n\nWhat I saw:\n\n${code[(n + 1) % code.length](n)}\n\n${code[(n + 2) % code.length](n)}\n\nEverything `
        + `matched except step 3, where the reader's place moved by about one row. I've filed that separately.`,
    (n, topic) => `Quick note on the ${topic}: the change in pass ${n} is in, and the attached capture shows the before and after.`,
];

// Messages 2 and 4 of every 5 carry screenshots, and every tenth carries two.
function attachments(sequence: number) {
    const kind = sequence % bodies.length;
    if (kind !== 2 && kind !== 4) return undefined;
    const count = sequence % 10 === 2 ? 2 : 1;
    return Array.from({ length: count }, (_, index) => ({
        name: `pass ${sequence} ${index + 1}.png`,
        url: `/api/serve/machine/scroll-demo/pass-${sequence}-${index + 1}.png`,
    }));
}

export function createScrollFixture(source: Snapshot, { now, origin }: { now: number; origin: string }) {
    const snapshot = remapChannel(source, scrollChannelID);
    const agents = [snapshot.lead, ...snapshot.members];
    const history = Array.from({ length: scrollMessageCount }, (_, index) => {
        const sequence = index + 1;
        const timestamp = new Date(now - (scrollMessageCount - sequence) * 7 * 60_000).toISOString();
        const agent = agents[index % agents.length];
        const sender = sequence % 11 === 0 ? { type: "user" } : { type: "agent", agentId: agent.id };
        const content = bodies[sequence % bodies.length](sequence, topics[sequence % topics.length]);
        const files = attachments(sequence);
        return { id: `scroll-message-${sequence}`, sequence, timestamp, sender, content, ...(files ? { attachments: files } : {}) };
    });
    Object.assign(snapshot.channel, {
        name: "Scroll demo", purpose: "A long channel of rich messages for the scroll benchmark.",
        latestSequence: scrollMessageCount, seenThrough: scrollMessageCount, requestSequence: null,
        completedSequence: null, updatedAt: new Date(now).toISOString(), previewUrl: `${origin}/demo-preview`,
    });
    snapshot.revision = scrollMessageCount;
    snapshot.messages = history.slice(-pageSize);
    snapshot.request = null;
    if (snapshot.lead.status?.wakeAt) snapshot.lead.status.wakeAt = new Date(now + 10 * 60_000).toISOString();
    return { snapshot, history };
}

// Screenshot-sized PNGs, so each image costs what a real capture does to download, decode and draw.
const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
});
function crc32(buffer: Uint8Array) {
    let c = 0xffffffff;
    for (const byte of buffer) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}
function chunk(type: string, data: Uint8Array) {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
}
function screenshot(seed: number, width = 1440, height = 900) {
    const row = width * 3 + 1;
    const pixels = Buffer.alloc(row * height);
    for (let y = 0; y < height; y++) {
        pixels[y * row] = 0;
        for (let x = 0; x < width; x++) {
            const offset = y * row + 1 + x * 3;
            // Flat panels and text-like bars, the way an app window's capture looks.
            const panel = x < 280 ? 0 : y < 64 ? 1 : 2;
            const bar = panel === 2 && (y % 36) < 12 && x > 320 && x < 320 + ((y * 37 + seed * 101) % 900);
            const shade = bar ? 90 : [228, 242, 250][panel] - seed * 12;
            pixels[offset] = shade;
            pixels[offset + 1] = bar ? 110 + seed * 30 : shade;
            pixels[offset + 2] = bar ? 160 : shade + (panel === 0 ? 4 : 0);
        }
    }
    const header = Buffer.alloc(13);
    header.writeUInt32BE(width, 0);
    header.writeUInt32BE(height, 4);
    header[8] = 8;
    header[9] = 2;
    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        chunk("IHDR", header), chunk("IDAT", deflateSync(pixels)), chunk("IEND", Buffer.alloc(0)),
    ]);
}
const screenshots = Array.from({ length: 4 }, (_, seed) => screenshot(seed));

// Answers the GET for one of the channel's screenshots, and returns whether the path was one.
export function writeScrollImage(response: Response, pathname: string) {
    const match = pathname.match(/^\/api\/serve\/machine\/scroll-demo\/pass-(\d+)-(\d+)\.png$/);
    if (!match) return false;
    const image = screenshots[(Number(match[1]) + Number(match[2])) % screenshots.length];
    response.writeHead(200, { "Content-Type": "image/png", "Content-Length": image.length, "Cache-Control": "no-store" });
    response.end(image);
    return true;
}
