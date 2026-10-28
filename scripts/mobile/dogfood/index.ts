import { join } from "node:path";
import { parseArgs } from "node:util";
import { command, machineLock, main, scratchPath, text } from "../../shared/lib/index.ts";
import { bundleMobile, mobileBundleID, mobileEnvironment } from "../bundle/index.ts";
import { prepareMobileSimulator } from "./boot.ts";
import { prepareMobileDrive, runMobileDrive, runMobileSimulatorCommand, simulatorDriveHost } from "./drive.ts";

const contentSizeCategories = {
    extraSmall: "UICTContentSizeCategoryXS", small: "UICTContentSizeCategoryS",
    medium: "UICTContentSizeCategoryM", large: "UICTContentSizeCategoryL",
    extraLarge: "UICTContentSizeCategoryXL", extraExtraLarge: "UICTContentSizeCategoryXXL",
    extraExtraExtraLarge: "UICTContentSizeCategoryXXXL",
    accessibilityMedium: "UICTContentSizeCategoryAccessibilityM",
    accessibilityLarge: "UICTContentSizeCategoryAccessibilityL",
    accessibilityExtraLarge: "UICTContentSizeCategoryAccessibilityXL",
    accessibilityExtraExtraLarge: "UICTContentSizeCategoryAccessibilityXXL",
    accessibilityExtraExtraExtraLarge: "UICTContentSizeCategoryAccessibilityXXXL",
};
type Appearance = "light" | "dark";
function mobileLaunchOptions(contentSize?: string, appearance?: string): {
    contentSize: string | undefined; appearance: Appearance | undefined; arguments: string[];
} {
    const category = Object.entries(contentSizeCategories).find(([name]) => name === contentSize)?.[1];
    if (contentSize !== undefined && !category) {
        throw new Error(`--content-size must be one of: ${Object.keys(contentSizeCategories).join(", ")}.`);
    }
    if (appearance !== undefined && appearance !== "light" && appearance !== "dark") {
        throw new Error("--appearance must be light or dark.");
    }
    return { contentSize: category, appearance, arguments: [
        ...(category ? ["-UIPreferredContentSizeCategoryName", category] : []),
        ...(appearance ? ["-appearance", appearance] : []),
    ] };
}

if (import.meta.main) await main(async () => {
    const { values } = parseArgs({ args: process.argv.slice(2), options: {
        "build-only": { type: "boolean" },
        shutdown: { type: "boolean" },
        screenshot: { type: "string" }, hold: { type: "boolean" }, display: { type: "string" },
        displays: { type: "boolean" }, server: { type: "string" },
        drive: { type: "string" }, "content-size": { type: "string" }, appearance: { type: "string" },
    } });
    const launch = mobileLaunchOptions(values["content-size"], values.appearance);
    if (values.drive && (values.hold || values.screenshot || values.displays || values.shutdown)) {
        throw new Error("--drive owns its captures and simulator lifetime; do not combine it with --hold, --screenshot, --displays or --shutdown.");
    }
    if (values.display && !values.screenshot) throw new Error("--display requires --screenshot.");
    if (values["build-only"]) {
        if (values.shutdown || values.screenshot || values.hold || values.displays || values.drive
            || values["content-size"] || values.appearance || values.server) {
            throw new Error("--build-only cannot use simulator launch, capture or shutdown options.");
        }
        console.log(await bundleMobile());
        return;
    }
    if ((values["content-size"] || values.appearance)
        && (values.shutdown || (values.screenshot || values.displays) && !values.hold)) {
        throw new Error("Content size and appearance require launching the app, not a capture/list/shutdown-only command.");
    }
    const unlock = await machineLock("mobile-simulator");
    let leasedSimulator: string | undefined;
    let runFailed = false;
    let runFailure: unknown;
    const interruption = new AbortController();
    const interrupt = () => interruption.abort();
    if (values.drive || values.hold) {
        process.on("SIGINT", interrupt);
        process.on("SIGTERM", interrupt);
    }
    try {
        const simulator = await prepareMobileSimulator(true);
        if (!simulator) throw new Error("No iPhone simulator is available.");
        if ((values.drive || values.hold) && !values.shutdown) leasedSimulator = simulator.udid;
        interruption.signal.throwIfAborted();
        if (values.displays) {
            const ports = await text(["xcrun", "simctl", "io", simulator.udid, "enumerate"],
                { env: mobileEnvironment });
            const displays = ports.split(/(?=^Port:\n)/m)
                .find(port => /^\s+Class: DisplayAdapter$/m.test(port));
            if (!displays) throw new Error("The simulator did not report its native display adapter.");
            console.log(displays.trim());
            if (!values.hold) return;
        }
        if (values.shutdown) {
            await command(["xcrun", "simctl", "shutdown", simulator.udid], { env: mobileEnvironment });
            return;
        }
        const capture = async () => {
            if (!values.screenshot) return;
            const result = await runMobileSimulatorCommand(["io", simulator.udid, "screenshot",
                ...(values.display ? [`--display=${values.display}`] : []), values.screenshot],
                mobileEnvironment, AbortSignal.timeout(15_000));
            if (result.exitCode) throw new Error(`Simulator capture failed: ${result.stderr.trim()}`);
        };
        if (values.screenshot && !values.hold) {
            await capture();
            return;
        }
        const app = await bundleMobile();
        interruption.signal.throwIfAborted();
        console.log(app);
        await command(["xcrun", "simctl", "install", simulator.udid, app], { env: mobileEnvironment });
        interruption.signal.throwIfAborted();
        const server = values.server ?? process.env.TOY_BOX_SERVER_URL ?? "http://127.0.0.1:3210";
        const data = await text(["xcrun", "simctl", "get_app_container", simulator.udid, mobileBundleID, "data"],
            { env: mobileEnvironment });
        const drive = values.drive ? await prepareMobileDrive(values.drive, data,
            join(scratchPath(), "mobile-drive", crypto.randomUUID())) : undefined;
        interruption.signal.throwIfAborted();
        const result = await runMobileSimulatorCommand([
            "launch", "--terminate-running-process", simulator.udid, mobileBundleID,
            "--server", server, ...launch.arguments,
        ], { ...mobileEnvironment, ...(drive ? { SIMCTL_CHILD_TOY_BOX_AUTOMATION_SCRIPT: drive.script } : {}) },
        AbortSignal.any([interruption.signal, AbortSignal.timeout(30_000)]));
        if (result.exitCode) throw new Error(`Mobile launch failed: ${result.stderr.trim()}`);
        console.log(result.stdout.trim());
        console.log(`Running on ${simulator.udid}, server ${server}`);
        console.log(`App data: ${data}`);
        if (drive) {
            await runMobileDrive(drive, simulatorDriveHost(simulator.udid, mobileEnvironment), interruption.signal, {
                ...(launch.contentSize ? { contentSizeCategory: launch.contentSize } : {}),
                ...(launch.appearance ? { interfaceStyle: launch.appearance } : {}),
            });
            return;
        }
        if (values.hold) {
            console.log("Simulator lock held for UI checks for at most 15 minutes. Ctrl-C releases it and shuts down.");
            if (values.screenshot) console.log(`The current pose will be captured to ${values.screenshot} before shutdown.`);
            await new Promise<void>(resolve => {
                const finish = () => {
                    clearTimeout(timer);
                    interruption.signal.removeEventListener("abort", finish);
                    resolve();
                };
                const timer = setTimeout(() => {
                    console.log("The 15-minute simulator lease expired.");
                    finish();
                }, 15 * 60 * 1000);
                interruption.signal.addEventListener("abort", finish, { once: true });
                if (interruption.signal.aborted) finish();
            });
            await capture();
        }
    } catch (error) {
        runFailed = true;
        runFailure = error;
        throw error;
    } finally {
        try {
            if (leasedSimulator) {
                const result = await runMobileSimulatorCommand(["shutdown", leasedSimulator], mobileEnvironment,
                    AbortSignal.timeout(15_000));
                if (result.exitCode) throw new Error(`Simulator shutdown failed: ${result.stderr.trim()}`);
            }
        } catch (error) {
            if (runFailed) {
                throw new AggregateError([runFailure, error],
                    `Native run failed (${runFailure instanceof Error ? runFailure.message : String(runFailure)}). `
                    + `Simulator shutdown failed (${error instanceof Error ? error.message : String(error)}).`);
            }
            throw error;
        } finally {
            process.removeListener("SIGINT", interrupt);
            process.removeListener("SIGTERM", interrupt);
            unlock();
        }
    }
});
