import { join } from "node:path";
import { command, main, root } from "../../shared/lib/lib.ts";
import { configureShareExtension, shareExtension } from "./share-extension.ts";
import { configureWidgetExtension, widgetExtension } from "./widget-extension.ts";

export async function signApp(app: string, options = ["--force", "--timestamp=none", "--sign", "-"]) {
    const widget = widgetExtension(app);
    const hasWidget = await Bun.file(join(widget, "Contents/Info.plist")).exists();
    const productionWidget = hasWidget && options[options.indexOf("--sign") + 1] !== "-";
    if (hasWidget) {
        await configureWidgetExtension(app, productionWidget);
        const widgetOptions = options.includes("--options") ? options : [...options, "--options", "runtime"];
        await command(["codesign", ...widgetOptions, "--entitlements",
            join(root, productionWidget ? "Resources/WidgetExtension.entitlements" : "Resources/ShareExtension.entitlements"), widget]);
        await command(["codesign", "--verify", "--strict", widget]);
    }
    const extension = shareExtension(app);
    if (await Bun.file(join(extension, "Contents/Info.plist")).exists()) {
        await configureShareExtension(app);
        const extensionOptions = options.includes("--options") ? options : [...options, "--options", "runtime"];
        await command(["codesign", ...extensionOptions, "--entitlements", join(root, "Resources/ShareExtension.entitlements"), extension]);
        await command(["codesign", "--verify", "--strict", extension]);
    }
    const framework = join(app, "Contents/Frameworks/Sparkle.framework");
    for (const component of [
        join(framework, "Versions/Current/Autoupdate"),
        join(framework, "Versions/Current/Updater.app"), framework,
    ]) {
        await command(["codesign", ...options, component]);
        await command(["codesign", "--verify", "--strict", component]);
    }
    await command(["codesign", ...options, "--entitlements",
        join(root, productionWidget ? "Resources/WidgetHost.entitlements" : "Resources/Release.entitlements"), app]);
    await command(["codesign", "--verify", "--strict", app]);
}

if (import.meta.main) await main(async () => {
    const [app, ...options] = process.argv.slice(2);
    if (!app) throw new Error("Usage: bun scripts/desktop/bundle/sign.ts APP [codesign options]");
    await signApp(app, options.length ? options : undefined);
});
