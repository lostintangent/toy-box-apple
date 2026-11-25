// The demo's terminal, forwarded byte for byte to `bun run terminal-server`, so a pane opened on
// studio-demo attaches to a real shell while the app never connects to that server, which lists
// this Mac's live peers. When it isn't running the socket is refused, and the pane reconnects on
// its own.
import type { IncomingMessage } from "node:http";
import { connect } from "node:net";
import type { Duplex } from "node:stream";

const port = 3212;

export function createDemoTerminal() {
    const open = new Set<Duplex>();
    return {
        /** Forwards `/socket?service=terminal`, and leaves every other socket alone. */
        upgrade(request: IncomingMessage, socket: Duplex, head: Buffer) {
            const url = new URL(request.url ?? "/", "http://127.0.0.1");
            if (url.pathname !== "/socket" || url.searchParams.get("service") !== "terminal") return false;
            const shell = connect(port, "127.0.0.1");
            let connected = false;
            open.add(socket).add(shell);
            shell.once("connect", () => {
                connected = true;
                const headers = request.rawHeaders.map((value, index) => index % 2 ? `${value}\r\n` : `${value}: `);
                shell.write(`${request.method} ${request.url} HTTP/${request.httpVersion}\r\n${headers.join("")}\r\n`);
                shell.write(head);
                socket.pipe(shell).pipe(socket);
            });
            shell.on("error", () => {
                if (connected) return socket.destroy();
                const reason = `No terminal server on ${port}. Start one with bun run terminal-server.\n`;
                socket.end(`HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\n`
                    + `Content-Length: ${Buffer.byteLength(reason)}\r\nConnection: close\r\n\r\n${reason}`);
            });
            socket.on("error", () => shell.destroy());
            shell.once("close", () => open.delete(shell));
            socket.once("close", () => { open.delete(socket); shell.destroy(); });
            return true;
        },
        close() {
            for (const socket of open) socket.destroy();
        },
    };
}
