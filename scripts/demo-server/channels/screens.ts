// The demo's screens, so screen control is proved without driving a real host. Demo Canvas takes
// control and paints where it's pressed, so a capture shows where input landed, and scrolling moves
// its checkerboard. Won't Take Focus fails to take control, the way a window whose app can't come
// forward does. Both follow the server's screens socket and its control rules: one viewer controls
// at a time across every screen, a refused command answers with an error, and leaving lets go.
// `GET /demo/screens/input` lists the input the canvas accepted, in order, and `DELETE` clears it
// with the paint.
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";

type RGB = readonly [number, number, number];

type Input =
    | { type: "pointer"; x: number; y: number; phase: "move" | "down" | "up"; button?: number }
    | { type: "scroll"; x: number; y: number; dx: number; dy: number }
    | { type: "key"; code: string; down: boolean }
    | { type: "text"; text: string };

type Command =
    | { type: "ack"; sequence: number }
    | { type: "resize"; size: { width: number; height: number } }
    | { type: "take-control" }
    | { type: "release-control" }
    | { type: "input"; actions: Input[] };

type Viewer = { id: string; socket: WebSocket; inFlight: number[]; lastSent: number };

type Cell = { x: number; y: number };

type DemoScreen = {
    id: string;
    title: string;
    application: string;
    /** Whether taking control fails, as it does when the window's app can't take focus. */
    refusesFocus: boolean;
    /** The checkerboard's second shade, which tells the screens apart. */
    shade: RGB;
    viewers: Map<string, Viewer>;
    sequence: number;
    frame?: Uint8Array;
    pointer?: Cell;
    pressing?: number;
    scroll: { x: number; y: number };
    /** Paint by board cell, so it scrolls with the board. */
    paint: Map<string, RGB>;
};

const unavailable = "Screen is unavailable. Its display or window may have closed.";
/** Frames a viewer can have unacknowledged. A slower viewer skips ahead to the newest. */
const maxFramesInFlight = 3;
const loggedInputLimit = 1000;

// The window is a grid of cells, 16 pixels in a frame and 8 in a thumbnail. JPEG codes 8-pixel
// blocks, so each cell is two blocks across in a frame and one in a thumbnail.
const columns = 80;
const rows = 50;
const titleRows = 3;
const cellPixels = 16;
const radius = 20;

const base: RGB = [28, 28, 30];
const titleBar: RGB = [44, 44, 46];
const lights: RGB[] = [[255, 95, 87], [254, 188, 46], [40, 200, 64]];
/** Paint by button: primary blue, middle green and secondary orange. */
const paintColors: RGB[] = [[10, 132, 255], [48, 209, 88], [255, 159, 10]];
const pointerColor: RGB = [255, 255, 255];

export function createDemoScreens() {
    const screens = new Map<string, DemoScreen>();
    for (const [id, title, refusesFocus, shade] of [
        ["window:4101:4242:1", "Demo Canvas", false, [38, 38, 46]],
        ["window:4102:4243:1", "Won't Take Focus", true, [50, 36, 36]],
    ] as const) {
        screens.set(id, {
            id, title, application: "Toy Box Demo", refusesFocus, shade, viewers: new Map(), sequence: 0,
            scroll: { x: 0, y: 0 }, paint: new Map(),
        });
    }
    let controller: { screenId: string; viewerId: string } | undefined;
    const input: Input[] = [];
    const sockets = new WebSocketServer({ noServer: true, maxPayload: 16 << 20 });
    for (const screen of screens.values()) render(screen);

    function render(screen: DemoScreen) {
        screen.sequence += 1;
        const metadata = { sequence: screen.sequence, width: columns * cellPixels, height: rows * cellPixels, radius };
        screen.frame = packet(metadata, picture(screen, 2));
        for (const viewer of screen.viewers.values()) sendFrames(screen, viewer);
    }

    function attach(screenId: string, socket: WebSocket) {
        const screen = screens.get(screenId);
        if (!screen) {
            socket.send(JSON.stringify({ type: "state", status: "ended", reason: unavailable, hasControl: false }));
            socket.close();
            return;
        }
        const viewer: Viewer = { id: crypto.randomUUID(), socket, inFlight: [], lastSent: 0 };
        screen.viewers.set(viewer.id, viewer);
        socket.on("message", (data, isBinary) => void receive(screen, viewer, isBinary ? undefined : data.toString()));
        socket.on("close", () => detach(screen, viewer));
        sendState(screen, viewer);
        sendFrames(screen, viewer);
    }

    function detach(screen: DemoScreen, viewer: Viewer) {
        screen.viewers.delete(viewer.id);
        releaseControl(screen, viewer);
    }

    async function receive(screen: DemoScreen, viewer: Viewer, text: string | undefined) {
        try {
            if (text === undefined) throw new Error("Invalid screen message.");
            const command = parseCommand(text);
            switch (command.type) {
                case "ack":
                    return acknowledge(screen, viewer, command.sequence);
                case "resize":
                    return; // Frames keep the window's size, and viewers fit them.
                case "take-control":
                    return await takeControl(screen, viewer);
                case "release-control":
                    return releaseControl(screen, viewer);
                case "input":
                    return accept(screen, viewer, command.actions);
            }
        } catch (error) {
            send(viewer, JSON.stringify({ type: "error", message: error instanceof Error ? error.message : String(error) }));
        }
    }

    function acknowledge(screen: DemoScreen, viewer: Viewer, sequence: number) {
        const drawn = viewer.inFlight.indexOf(sequence);
        if (drawn < 0) return;
        viewer.inFlight.splice(0, drawn + 1);
        sendFrames(screen, viewer);
    }

    /** Takes control from anyone else. A window that can't take focus gives it back and refuses. */
    async function takeControl(screen: DemoScreen, viewer: Viewer) {
        const taken = { screenId: screen.id, viewerId: viewer.id };
        controller = taken;
        // The host lets go of anything the previous controller held.
        for (const each of screens.values()) each.pressing = undefined;
        publishControl();
        if (!screen.refusesFocus) return;
        // The host tries to bring the window's app forward for 200 ms before it gives up.
        await Bun.sleep(200);
        if (controller === taken) {
            controller = undefined;
            publishControl();
        }
        throw new Error("The source application did not receive focus.");
    }

    function releaseControl(screen: DemoScreen, viewer: Viewer) {
        if (controller?.screenId !== screen.id || controller.viewerId !== viewer.id) return;
        controller = undefined;
        screen.pressing = undefined;
        publishControl();
    }

    function accept(screen: DemoScreen, viewer: Viewer, actions: Input[]) {
        if (controller?.screenId !== screen.id || controller.viewerId !== viewer.id) {
            throw new Error("Take control before sending screen input.");
        }
        input.push(...actions);
        input.splice(0, input.length - loggedInputLimit);
        for (const action of actions) apply(screen, action);
        render(screen);
    }

    function sendFrames(screen: DemoScreen, viewer: Viewer) {
        if (!screen.frame || screen.sequence <= viewer.lastSent || viewer.inFlight.length >= maxFramesInFlight) return;
        viewer.inFlight.push(screen.sequence);
        viewer.lastSent = screen.sequence;
        send(viewer, screen.frame);
    }

    function sendState(screen: DemoScreen, viewer: Viewer) {
        const hasControl = controller?.screenId === screen.id && controller.viewerId === viewer.id;
        send(viewer, JSON.stringify({ type: "state", title: screen.title, status: "live", hasControl }));
    }

    function publishControl() {
        for (const screen of screens.values()) {
            for (const viewer of screen.viewers.values()) sendState(screen, viewer);
        }
    }

    function send(viewer: Viewer, data: string | Uint8Array) {
        if (viewer.socket.readyState === viewer.socket.OPEN) viewer.socket.send(data);
    }

    return {
        /** Serves the screens routes and the input log, and returns false for any other request. */
        handle(request: IncomingMessage, response: ServerResponse, url: URL): boolean {
            if (request.method === "GET" && url.pathname === "/api/v1/screens") {
                const windows = [...screens.values()].map(({ id, title, application }) => ({ id, title, application }));
                writeJSON(response, 200, { displays: [], windows });
                return true;
            }
            const thumbnail = url.pathname.match(/^\/api\/v1\/screens\/([^/]+)\/thumbnail$/);
            if (request.method === "GET" && thumbnail) {
                const screen = screens.get(decodeURIComponent(thumbnail[1]));
                if (!screen) {
                    writeJSON(response, 422, { error: unavailable });
                    return true;
                }
                response.writeHead(200, { "Content-Type": "image/jpeg", "Cache-Control": "no-store" });
                response.end(picture(screen, 1));
                return true;
            }
            if (url.pathname === "/demo/screens/input") {
                if (request.method === "GET") {
                    writeJSON(response, 200, { actions: input });
                } else if (request.method === "DELETE") {
                    input.length = 0;
                    for (const screen of screens.values()) {
                        screen.paint.clear();
                        render(screen);
                    }
                    response.writeHead(204);
                    response.end();
                } else {
                    response.writeHead(405, { Allow: "GET, DELETE" });
                    response.end();
                }
                return true;
            }
            return false;
        },
        /** Opens `/socket?service=screens&screen=…` as a viewer of that screen. */
        upgrade(request: IncomingMessage, socket: Duplex, head: Buffer) {
            const url = new URL(request.url ?? "/", "http://127.0.0.1");
            if (url.pathname !== "/socket" || url.searchParams.get("service") !== "screens") {
                socket.destroy();
                return;
            }
            sockets.handleUpgrade(request, socket, head, (viewer) => attach(url.searchParams.get("screen") ?? "", viewer));
        },
        close() {
            for (const screen of screens.values()) {
                for (const viewer of screen.viewers.values()) viewer.socket.terminate();
            }
            sockets.close();
        },
    };
}

function apply(screen: DemoScreen, action: Input) {
    if (action.type === "scroll") {
        screen.scroll.x += action.dx;
        screen.scroll.y += action.dy;
    } else if (action.type === "pointer") {
        const cell = { x: Math.min(columns - 1, Math.floor(action.x * columns)), y: Math.min(rows - 1, Math.floor(action.y * rows)) };
        const from = action.phase === "down" ? cell : screen.pointer ?? cell;
        screen.pointer = cell;
        if (action.phase === "down") screen.pressing = action.button ?? 0;
        if (screen.pressing !== undefined) {
            // A drag paints every cell it crosses, so it reads as a line rather than separate clicks.
            const steps = Math.max(Math.abs(cell.x - from.x), Math.abs(cell.y - from.y));
            for (let step = 0; step <= steps; step++) {
                const t = steps ? step / steps : 0;
                const crossed = { x: Math.round(from.x + (cell.x - from.x) * t), y: Math.round(from.y + (cell.y - from.y) * t) };
                if (crossed.y >= titleRows) screen.paint.set(boardKey(screen, crossed), paintColors[screen.pressing]);
            }
        }
        if (action.phase === "up") screen.pressing = undefined;
    }
}

/** A window cell's place on the scrolled board. */
function boardKey(screen: DemoScreen, cell: Cell) {
    const [x, y] = boardCell(screen, cell);
    return `${x},${y}`;
}

function boardCell(screen: DemoScreen, { x, y }: Cell): [number, number] {
    return [x + Math.round(screen.scroll.x / cellPixels), y - titleRows + Math.round(screen.scroll.y / cellPixels)];
}

/** The window as a JPEG, with `scale` 8-pixel blocks to a cell. */
function picture(screen: DemoScreen, scale: number): Uint8Array {
    return jpeg(columns * scale * 8, rows * scale * 8, (blockX, blockY) => {
        const cell = { x: Math.floor(blockX / scale), y: Math.floor(blockY / scale) };
        if (screen.pointer?.x === cell.x && screen.pointer.y === cell.y) return pointerColor;
        if (cell.y < titleRows) return cell.y === 1 && [2, 4, 6].includes(cell.x) ? lights[cell.x / 2 - 1] : titleBar;
        const painted = screen.paint.get(boardKey(screen, cell));
        if (painted) return painted;
        const [x, y] = boardCell(screen, cell);
        return (Math.floor(x / 4) + Math.floor(y / 4)) % 2 === 0 ? base : screen.shade;
    });
}

/** A screen packet: two big-endian 32-bit lengths, the frame as JSON, then its JPEG. */
function packet(metadata: object, jpeg: Uint8Array): Uint8Array {
    const json = new TextEncoder().encode(JSON.stringify(metadata));
    const bytes = new Uint8Array(8 + json.length + jpeg.length);
    const view = new DataView(bytes.buffer);
    view.setUint32(0, json.length);
    view.setUint32(4, jpeg.length);
    bytes.set(json, 8);
    bytes.set(jpeg, 8 + json.length);
    return bytes;
}

// A baseline JPEG of flat 8-pixel blocks, which is all the window draws: each block codes only its
// average, with a quantizer of 1 so colors stay exact. DC uses the standard luminance table for
// every component, and AC has only end-of-block, as the single 1-bit code.
const dcBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const dcValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const acBits = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
const acValues = [0];
const dcCodes = huffmanCodes(dcBits, dcValues);

function jpeg(width: number, height: number, block: (x: number, y: number) => RGB): Uint8Array {
    const bytes: number[] = [0xff, 0xd8];
    const segment = (marker: number, payload: number[]) => {
        bytes.push(0xff, marker, (payload.length + 2) >> 8, (payload.length + 2) & 0xff, ...payload);
    };
    segment(0xe0, [0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
    segment(0xdb, [0, ...new Array<number>(64).fill(1)]);
    segment(0xc0, [8, height >> 8, height & 0xff, width >> 8, width & 0xff, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]);
    segment(0xc4, [0x00, ...dcBits, ...dcValues, 0x10, ...acBits, ...acValues]);
    segment(0xda, [3, 1, 0, 2, 0, 3, 0, 0, 63, 0]);

    let accumulator = 0;
    let count = 0;
    const write = (value: number, length: number) => {
        for (let bit = length - 1; bit >= 0; bit--) {
            accumulator = (accumulator << 1) | ((value >> bit) & 1);
            if (++count < 8) continue;
            bytes.push(accumulator);
            if (accumulator === 0xff) bytes.push(0);
            accumulator = 0;
            count = 0;
        }
    };
    const previous = [0, 0, 0];
    for (let y = 0; y < height / 8; y++) {
        for (let x = 0; x < width / 8; x++) {
            const [r, g, b] = block(x, y);
            const components = [
                0.299 * r + 0.587 * g + 0.114 * b,
                128 - 0.168736 * r - 0.331264 * g + 0.5 * b,
                128 + 0.5 * r - 0.418688 * g - 0.081312 * b,
            ];
            components.forEach((value, index) => {
                const dc = 8 * (Math.min(255, Math.max(0, Math.round(value))) - 128);
                const difference = dc - previous[index];
                previous[index] = dc;
                const category = difference === 0 ? 0 : 32 - Math.clz32(Math.abs(difference));
                const [code, length] = dcCodes[category];
                write(code, length);
                write(difference < 0 ? difference + (1 << category) - 1 : difference, category);
                write(0, 1); // End of block.
            });
        }
    }
    if (count) write(0xff, 8 - count);
    bytes.push(0xff, 0xd9);
    return new Uint8Array(bytes);
}

/** Each value's canonical code and length, from a table's count of codes of each length. */
function huffmanCodes(bits: number[], values: number[]): [code: number, length: number][] {
    const codes: [number, number][] = [];
    let code = 0;
    let index = 0;
    bits.forEach((count, length) => {
        for (let i = 0; i < count; i++) codes[values[index++]] = [code++, length + 1];
        code <<= 1;
    });
    return codes;
}

// The server's checks for what a viewer sends, which reject a key it doesn't know.

function parseCommand(text: string): Command {
    const message: unknown = JSON.parse(text);
    if (isRecord(message)) {
        switch (message.type) {
            case "ack":
                if (exact(message, ["type", "sequence"]) && isPositiveInteger(message.sequence)) return message as Command;
                break;
            case "resize":
                if (exact(message, ["type", "size"]) && isRecord(message.size) && exact(message.size, ["width", "height"])
                    && isPositiveInteger(message.size.width) && isPositiveInteger(message.size.height)) return message as Command;
                break;
            case "take-control":
            case "release-control":
                if (exact(message, ["type"])) return message as Command;
                break;
            case "input":
                if (exact(message, ["type", "actions"]) && Array.isArray(message.actions)
                    && message.actions.length >= 1 && message.actions.length <= 64 && message.actions.every(isInput)) {
                    return message as Command;
                }
                break;
        }
    }
    throw new Error("Invalid screen message.");
}

function isInput(value: unknown): value is Input {
    if (!isRecord(value)) return false;
    const fraction = (n: unknown) => typeof n === "number" && n >= 0 && n <= 1;
    const delta = (n: unknown) => typeof n === "number" && Number.isFinite(n) && Math.abs(n) <= 10000;
    const text = (s: unknown, limit: number) => typeof s === "string" && s.length >= 1 && s.length <= limit;
    switch (value.type) {
        case "pointer":
            return exact(value, ["type", "x", "y", "phase"], ["button"]) && fraction(value.x) && fraction(value.y)
                && ["move", "down", "up"].includes(value.phase as string)
                && (value.button === undefined || [0, 1, 2].includes(value.button as number));
        case "scroll":
            return exact(value, ["type", "x", "y", "dx", "dy"]) && fraction(value.x) && fraction(value.y)
                && delta(value.dx) && delta(value.dy);
        case "key":
            return exact(value, ["type", "code", "down"]) && text(value.code, 32) && typeof value.down === "boolean";
        case "text":
            return exact(value, ["type", "text"]) && text(value.text, 4096);
        default:
            return false;
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPositiveInteger(value: unknown) {
    return Number.isInteger(value) && (value as number) > 0;
}

function exact(value: Record<string, unknown>, required: string[], optional: string[] = []) {
    return required.every((key) => Object.hasOwn(value, key))
        && Object.keys(value).every((key) => required.includes(key) || optional.includes(key));
}

function writeJSON(response: ServerResponse, status: number, body: unknown) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(JSON.stringify(body));
}
