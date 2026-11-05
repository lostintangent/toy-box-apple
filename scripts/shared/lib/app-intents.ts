import { mkdir, rm } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { command, executable, root, text } from "./index.ts";

/** One module's App Intents extraction, over the const values SwiftPM already emitted. */
export type AppIntentsModule = {
    module: string;
    /** The module's source folder, relative to the repository. */
    sources: string;
    /** The `Objects-normal/arm64` folder holding the module's `.swiftconstvalues`. */
    objects: string;
    bundleIdentifier: string;
    binary: string;
    /** The folder that receives `Metadata.appintents`. */
    output: string;
    /** `extract.actionsdata` files of modules this one depends on. */
    dependencies: string[];
    /** Lets a module without App Intents write no metadata instead of failing. */
    optional?: boolean;
};

export type AppIntentsPlatform = {
    family: "macOS" | "iOS";
    sdk: string;
    deploymentTarget: string;
    triple: string;
    environment?: NodeJS.ProcessEnv;
};

/** The intermediate objects folder SwiftPM's build system writes for one target. */
export function swiftBuildObjects(scratch: string, variant: string, target: string) {
    return join(scratch, "out/Intermediates.noindex/ToyBoxDesktop.build", variant, `${target}.build/Objects-normal/arm64`);
}

/**
 * Finds Xcode's `appintentsmetadataprocessor` once, and returns an extraction that writes a module's
 * `Metadata.appintents` and returns its `extract.actionsdata`, which must be nonempty unless the
 * module is optional.
 */
export async function appIntentsExtractor(platform: AppIntentsPlatform, scratch: string) {
    const env = platform.environment;
    let processor = process.env.APP_INTENTS_PROCESSOR;
    if (!processor) {
        const found = await command(["xcrun", "--find", "appintentsmetadataprocessor"],
            { env, quiet: true, allowFailure: true });
        processor = found.exitCode ? undefined : found.stdout.toString().trim();
    }
    processor ||= "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor";
    if (!await executable(processor)) {
        throw new Error("Siri, Shortcuts and controls need Xcode's appintentsmetadataprocessor. Install Xcode 27 or set APP_INTENTS_PROCESSOR.");
    }
    const toolchain = resolve(dirname(processor), "../..");
    const buildVersion = await command(["/usr/libexec/PlistBuddy", "-c", "Print :ProductBuildVersion",
        resolve(toolchain, "../../../version.plist")], { quiet: true, allowFailure: true });
    const xcodeBuild = buildVersion.exitCode
        ? await text(["xcrun", "--sdk", platform.sdk, "--show-sdk-build-version"], { env })
        : buildVersion.stdout.toString().trim();

    function extract(target: AppIntentsModule & { optional: true }): Promise<string | undefined>;
    function extract(target: AppIntentsModule): Promise<string>;
    async function extract(target: AppIntentsModule) {
        const intents = join(scratch, "appintents", target.module);
        await mkdir(intents, { recursive: true });
        await mkdir(target.output, { recursive: true });
        const sources = (await Array.fromAsync(new Bun.Glob("**/*.swift").scan({
            cwd: join(root, target.sources), absolute: true,
        }))).sort();
        await Bun.write(join(intents, "sources.txt"), sources.join("\n") + "\n");
        const stems = new Set(sources.map(source => basename(source, ".swift")));
        const values = (await Array.fromAsync(new Bun.Glob("*.swiftconstvalues").scan({ cwd: target.objects, absolute: true })))
            .filter(path => basename(path, ".swiftconstvalues") === `${target.module}-primary`
                || stems.has(basename(path, ".swiftconstvalues"))).sort();
        if (!values.length) throw new Error(`The compiler wrote no const values to ${target.objects}.`);
        await Bun.write(join(intents, "const-values.txt"), values.join("\n") + "\n");
        await Bun.write(join(intents, "dependency-metadata.txt"),
            target.dependencies.join("\n") + (target.dependencies.length ? "\n" : ""));
        await rm(join(target.output, "Metadata.appintents"), { recursive: true, force: true });
        const result = await command([processor!, "--toolchain-dir", toolchain, "--module-name", target.module,
            "--sdk-root", platform.sdk, "--xcode-version", xcodeBuild, "--platform-family", platform.family,
            "--deployment-target", platform.deploymentTarget, "--bundle-identifier", target.bundleIdentifier,
            "--output", target.output, "--target-triple", platform.triple,
            "--binary-file", target.binary,
            "--dependency-file", join(intents, `${target.module}.d`),
            "--stringsdata-file", join(intents, "ExtractedAppShortcutsMetadata.stringsdata"),
            "--source-file-list", join(intents, "sources.txt"), "--swift-const-vals-list", join(intents, "const-values.txt"),
            "--metadata-file-list", join(intents, "dependency-metadata.txt"),
            "--static-metadata-file-list", join(intents, "dependency-metadata.txt"),
            "--force", "--compile-time-extraction", "--deployment-aware-processing", "--no-app-shortcuts-localization"],
        { env, quiet: true, allowFailure: true });
        const log = result.stdout.toString() + result.stderr.toString();
        await Bun.write(join(intents, "processor.log"), log);
        if (result.exitCode || log.includes("Failed to decode metadata")) {
            throw new Error(log || `${target.module} App Intents metadata extraction failed.`);
        }
        for (const line of log.split("\n").filter(line => /warning|error/i.test(line))) console.error(line);
        const metadata = join(target.output, "Metadata.appintents/extract.actionsdata");
        if (!Bun.file(metadata).size) {
            if (target.optional) return undefined;
            throw new Error(`${log}\nNo ${target.module} App Intents metadata was written.`);
        }
        return metadata;
    }
    return extract;
}
