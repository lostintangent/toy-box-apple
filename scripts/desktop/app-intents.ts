import { mkdir, rm } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { command, executable, plist, root, text } from "../shared/lib.ts";
import { validateControlMetadata, widgetExtension } from "./bundle/widget-extension.ts";

export async function extractAppIntents(app: string, scratch: string, configuration: string,
    sdk: string, minimumOS: string) {
    let processor = process.env.APP_INTENTS_PROCESSOR;
    if (!processor) {
        const found = await command(["xcrun", "--find", "appintentsmetadataprocessor"],
            { quiet: true, allowFailure: true });
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
        ? await text(["xcrun", "--sdk", sdk, "--show-sdk-build-version"])
        : buildVersion.stdout.toString().trim();
    const sharedOutput = join(scratch, "appintents/ToyBoxControlIntents/output");

    async function extract(module: string, bundle: string, binaryName: string, output: string, dependencies: string[]) {
        const intents = join(scratch, "appintents", module);
        const target = module === "ToyBoxControlIntents" ? `${module}-t` : `${module}-p`;
        const objects = join(scratch, "out/Intermediates.noindex/ToyBoxDesktop.build",
            configuration === "release" ? "Release" : "Debug", `${target}.build/Objects-normal/arm64`);
        await mkdir(intents, { recursive: true });
        await mkdir(output, { recursive: true });
        const sources = (await Array.fromAsync(new Bun.Glob("**/*.swift").scan({
            cwd: join(root, "Sources", module), absolute: true,
        }))).sort();
        await Bun.write(join(intents, "sources.txt"), sources.join("\n") + "\n");
        const stems = new Set(sources.map(source => basename(source, ".swift")));
        const values = (await Array.fromAsync(new Bun.Glob("*.swiftconstvalues").scan({ cwd: objects, absolute: true })))
            .filter(path => basename(path, ".swiftconstvalues") === `${module}-primary`
                || stems.has(basename(path, ".swiftconstvalues"))).sort();
        if (!values.length) throw new Error(`The compiler wrote no const values to ${objects}.`);
        await Bun.write(join(intents, "const-values.txt"), values.join("\n") + "\n");
        await Bun.write(join(intents, "dependency-metadata.txt"), dependencies.join("\n") + (dependencies.length ? "\n" : ""));
        await rm(join(output, "Metadata.appintents"), { recursive: true, force: true });
        const result = await command([processor!, "--toolchain-dir", toolchain, "--module-name", module,
            "--sdk-root", sdk, "--xcode-version", xcodeBuild, "--platform-family", "macOS",
            "--deployment-target", minimumOS, "--bundle-identifier",
            await plist(join(bundle, "Contents/Info.plist"), ["Print :CFBundleIdentifier"]),
            "--output", output, "--target-triple", `arm64-apple-macos${minimumOS}`,
            "--binary-file", join(bundle, "Contents/MacOS", binaryName),
            "--dependency-file", join(intents, `${module}.d`),
            "--stringsdata-file", join(intents, "ExtractedAppShortcutsMetadata.stringsdata"),
            "--source-file-list", join(intents, "sources.txt"), "--swift-const-vals-list", join(intents, "const-values.txt"),
            "--metadata-file-list", join(intents, "dependency-metadata.txt"),
            "--static-metadata-file-list", join(intents, "dependency-metadata.txt"),
            "--force", "--compile-time-extraction", "--deployment-aware-processing", "--no-app-shortcuts-localization"],
        { quiet: true, allowFailure: true });
        const log = result.stdout.toString() + result.stderr.toString();
        await Bun.write(join(intents, "processor.log"), log);
        if (result.exitCode || log.includes("Failed to decode metadata")) {
            throw new Error(log || `${module} App Intents metadata extraction failed.`);
        }
        for (const line of log.split("\n").filter(line => /warning|error/i.test(line))) console.error(line);
        const metadata = Bun.file(join(output, "Metadata.appintents/extract.actionsdata"));
        if (!metadata.size) {
            throw new Error(`${log}\nNo ${module} App Intents metadata was written.`);
        }
        validateControlMetadata(await metadata.text());
    }

    await extract("ToyBoxControlIntents", app, "ToyBoxDesktop", sharedOutput, []);
    const dependencies = [join(sharedOutput, "Metadata.appintents/extract.actionsdata")];
    await extract("ToyBoxDesktop", app, "ToyBoxDesktop", join(app, "Contents/Resources"), dependencies);
    const widget = widgetExtension(app);
    await extract("ToyBoxWidget", widget, "ToyBoxWidget", join(widget, "Contents/Resources"), dependencies);
}
