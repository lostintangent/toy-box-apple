import type { IncomingMessage, Server, ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { body, createDemoLinks, describe, Refusal } from "./link-routes.ts";

const updateDelay = 2000, restartDelay = 3000;
const nameLimit = 64;

// TOY_BOX_DEMO_SERVER=pending starts with a newer release installed, so Restart shows at once, and
// `gone` does too, but its restart never comes back. `unmanaged` has no installed release, so it
// offers neither action and rejects both. `failing` rejects updates.
const modes = ["pending", "gone", "unmanaged", "failing"] as const;
type Mode = typeof modes[number];
function demoServerMode() {
    const mode = process.env.TOY_BOX_DEMO_SERVER;
    if (mode === undefined || modes.includes(mode as Mode)) return mode as Mode | undefined;
    throw new Error(`TOY_BOX_DEMO_SERVER must be ${modes.join(", ")}, not "${mode}"`);
}

function reply(response: ServerResponse, status: number, body?: unknown) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(body === undefined ? undefined : JSON.stringify(body));
}

/** `/api/v1/server`, its rename, links, update and restart, as a server that a package manager
 *  installed unless `mode` says otherwise. `id` is the identity it keeps, and `computer` the name it
 *  starts with and returns to when a rename clears it. */
export function createDemoServerRoutes(server: Server, { id, computer, mode = demoServerMode() }:
    { id: string, computer: string, mode?: Mode }) {
    const running = "0.4.0", newer = "0.4.1";
    let version = running;
    let installedVersion: string | null =
        mode === "unmanaged" ? null : mode === "pending" || mode === "gone" ? newer : running;
    let name = computer;
    const accentColor = "#facc15";
    const links = createDemoLinks(id);
    let updating: Promise<void> | undefined;
    let returning: ReturnType<typeof setTimeout> | undefined;
    const current = () => ({ id, name, accentColor, version, installedVersion, links: links.list });
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

    // Like the server, a name is trimmed and at most 64 UTF-16 units, and an empty one gives back
    // the computer's name.
    async function rename(request: IncomingMessage) {
        const input = await body(request) as { name?: unknown } | undefined;
        const requested = typeof input?.name === "string" ? input.name.trim() : undefined;
        if (requested === undefined || requested.length > nameLimit) return false;
        name = requested || computer;
        return true;
    }

    function answer(response: ServerResponse, change: Promise<unknown>) {
        change.then(
            () => reply(response, 200, current()),
            error => error instanceof Refusal
                ? reply(response, 422, { error: error.message })
                : reply(response, 500, { error: describe(error) }),
        );
    }

    return {
        /** Whether the server is listening, rather than down for a restart. */
        get isUp() { return server.listening; },
        /** Cancels a restart's return, so stopping the demo while it's down stops it. */
        close() { clearTimeout(returning); },
        handle(request: IncomingMessage, response: ServerResponse, url: URL) {
            if (url.pathname !== "/api/v1/server" && !url.pathname.startsWith("/api/v1/server/")) return false;
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
            }
            if (url.pathname === "/api/v1/server" && request.method === "PATCH") {
                rename(request).then(renamed => renamed
                    ? reply(response, 200, current())
                    : reply(response, 400, { error: "Invalid request." }));
            } else if (url.pathname === "/api/v1/server/links" && ["POST", "DELETE"].includes(request.method ?? "")) {
                answer(response, links.change(request, url));
            } else if (url.pathname === "/api/v1/server" || url.pathname === "/api/v1/server/links") {
                response.setHeader("Allow", url.pathname === "/api/v1/server" ? "GET, PATCH" : "POST, DELETE");
                reply(response, 405, { error: "Method not allowed" });
            } else {
                reply(response, 404, { error: "Not found" });
            }
            return true;
        },
    };
}
