import type { IncomingMessage, Server, ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";

const running = "0.3.9", newer = "0.3.10";
const updateDelay = 2000, restartDelay = 3000;

// TOY_BOX_DEMO_SERVER=pending starts with 0.3.10 installed, so Restart shows at once, and `gone` does
// too, but its restart never comes back. `unmanaged` has no installed release, so it offers neither
// action and rejects both. `failing` rejects updates.
const modes = ["pending", "gone", "unmanaged", "failing"] as const;
function demoServerMode() {
    const mode = process.env.TOY_BOX_DEMO_SERVER;
    if (mode === undefined || modes.includes(mode as typeof modes[number])) return mode as typeof modes[number] | undefined;
    throw new Error(`TOY_BOX_DEMO_SERVER must be ${modes.join(", ")}, not "${mode}"`);
}

function reply(response: ServerResponse, status: number, body?: unknown) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(body === undefined ? undefined : JSON.stringify(body));
}

/** `/api/v1/server` and its update and restart, as a server that a package manager installed. */
export function createDemoServerRoutes(server: Server) {
    const mode = demoServerMode();
    let version = running;
    let installedVersion: string | null =
        mode === "unmanaged" ? null : mode === "pending" || mode === "gone" ? newer : running;
    let updating: Promise<void> | undefined;
    let returning: ReturnType<typeof setTimeout> | undefined;
    const current = () => ({ version, installedVersion });
    const unmanaged = "No package manager installed this server, so it can't update itself.";

    // Like the real server, the update answers once its package manager finishes, and concurrent
    // updates share one run.
    function update() {
        updating ??= new Promise<void>((resolve, reject) => setTimeout(() => {
            updating = undefined;
            if (mode === "failing") { reject(new Error("npm couldn't reach the registry.")); return; }
            installedVersion = newer;
            resolve();
        }, updateDelay));
        return updating;
    }

    // Answers first, then drops every connection and stops listening for a few seconds, then comes
    // back running the installed release on the same address.
    function restart(response: ServerResponse) {
        const { address, port } = server.address() as AddressInfo;
        response.once("finish", () => {
            server.close();
            server.closeAllConnections();
            if (mode === "gone") {
                console.log("Restarted and never came back. Run the demo again to bring the server back.");
                return;
            }
            returning = setTimeout(() => {
                returning = undefined;
                version = installedVersion ?? version;
                server.listen(port, address);
            }, restartDelay);
        });
        reply(response, 202);
    }

    return {
        /** Whether the server is listening, rather than down for a restart. */
        get isUp() { return server.listening; },
        /** Cancels a restart's return, so stopping the demo while it's down stops it. */
        close() { clearTimeout(returning); },
        handle(request: IncomingMessage, response: ServerResponse, url: URL) {
            switch (`${request.method} ${url.pathname}`) {
            case "GET /api/v1/server":
                reply(response, 200, current());
                return true;
            case "POST /api/v1/server/update":
                if (installedVersion === null) { reply(response, 422, { error: unmanaged }); return true; }
                update().then(
                    () => reply(response, 200, current()),
                    (error: Error) => reply(response, 422, { error: error.message }),
                );
                return true;
            case "POST /api/v1/server/restart":
                if (installedVersion === null) { reply(response, 422, { error: unmanaged }); return true; }
                restart(response);
                return true;
            default:
                return false;
            }
        },
    };
}
