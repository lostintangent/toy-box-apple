import { join } from "node:path";
import { checkTestCompletion, command, machineLock, main } from "../shared/lib/lib.ts";
import { buildMobile, mobileEnvironment } from "./bundle/index.ts";
import { prepareMobileSimulator } from "./dogfood/boot.ts";

export const mobileTestProducts = [
    "ChannelClientTests", "ToyBoxUITests",
    "ToyBoxMobileIntegrationsTests", "ToyBoxMobileWidgetTests", "ToyBoxMobileTests",
];

export function checkMobileTestCompletion(log: string) {
    checkTestCompletion(log);
    if (!/Test run with [1-9][0-9]* tests? .*passed after /.test(log)
        || /Test run with [0-9]+ tests? .*failed after /.test(log)) {
        throw new Error("iOS tests did not finish with a nonempty passing Swift Testing summary.");
    }
}

if (import.meta.main) await main(async () => {
    const options = process.argv.slice(2);
    if (options.some(option => option !== "--if-available")) {
        throw new Error("Usage: bun run test:mobile [--if-available]");
    }
    const unlock = await machineLock("mobile-simulator");
    try {
        const simulator = await prepareMobileSimulator(false, options.includes("--if-available"));
        if (!simulator) return;
        try {
            const { bin } = await buildMobile(false, true);
            const developer = join(mobileEnvironment.DEVELOPER_DIR, "Platforms/iPhoneSimulator.platform/Developer");
            for (const name of mobileTestProducts) {
                const result = await command(["xcrun", "simctl", "spawn", simulator.udid,
                    join(developer, "Library/Xcode/Agents/xctest"), join(bin, `${name}.xctest`)], {
                    env: {
                        ...mobileEnvironment,
                        SIMCTL_CHILD_DYLD_FRAMEWORK_PATH: join(developer, "Library/Frameworks"),
                        SIMCTL_CHILD_DYLD_LIBRARY_PATH: join(developer, "usr/lib"),
                    },
                    quiet: true,
                });
                const log = result.stdout.toString() + result.stderr.toString();
                checkMobileTestCompletion(log);
                console.log(`${name}: ${log.match(/Test run with [^\n]+/)?.[0]}`);
                const skipped = [...log.matchAll(/Test .+ skipped\./g)].length;
                if (skipped) console.log(`  ${skipped} existing opt-in tests skipped.`);
            }
        } finally {
            if (simulator.bootedHere) {
                await command(["xcrun", "simctl", "shutdown", simulator.udid], { env: mobileEnvironment });
            }
        }
    } finally { unlock(); }
});
