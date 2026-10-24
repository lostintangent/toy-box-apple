import { mkdir } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { command, main, plist, releaseTag, repositoryURL, required, root, temporary, text } from "../lib.ts";
import { buildApp } from "../dev/run.ts";
import { checkVersion } from "./check-update-version.ts";
import { signApp } from "./sign-app.ts";

export function parseNotaryResponse(response: string, status: number) {
    let parsed: unknown;
    try { parsed = JSON.parse(response); }
    catch { throw new Error(`Notarization failed without a valid submission response (exit ${status}).`); }
    if (!parsed || typeof parsed !== "object" || !("status" in parsed) || typeof parsed.status !== "string") {
        throw new Error(`Notarization failed without a valid submission response (exit ${status}).`);
    }
    const id = "id" in parsed && typeof parsed.id === "string" ? parsed.id : undefined;
    return { status: parsed.status, id };
}

if (import.meta.main) await main(async () => {
    const tag = releaseTag(process.argv[2]);
    const version = tag.slice(1);
    const identity = required("SIGNING_IDENTITY");
    if (!/^[a-fA-F0-9]{40}$/.test(identity)) throw new Error("Signing identity must be a 40-digit SHA-1.");
    const build = required("BUILD_NUMBER");
    await checkVersion(build, process.env.PREVIOUS_APPCAST);
    const publicKey = required("SPARKLE_ED_PUBLIC_KEY");
    if (!/^[A-Za-z0-9+/]{43}=$/.test(publicKey)) throw new Error("The update public key must encode 32 bytes.");
    if (!Bun.file(join(root, "Resources/AppIcon.icns")).size) throw new Error("The release app icon is missing. Run bun run icon.");
    const scratch = resolve(process.env.SCRATCH_PATH || join(root, ".build/distribution"));
    const output = resolve(process.env.OUTPUT_DIR || join(root, "dist"));
    const signArgs = ["--force", "--options", "runtime", "--timestamp", "--sign", identity];
    const identityArgs = ["security", "find-identity", "-v", "-p", "codesigning"];
    if (process.env.SIGNING_KEYCHAIN) {
        signArgs.push("--keychain", process.env.SIGNING_KEYCHAIN);
        identityArgs.push(process.env.SIGNING_KEYCHAIN);
    }
    const identities = await text(identityArgs);
    if (!identities.split("\n").some(line => line.toUpperCase().split(/\s+/).includes(identity.toUpperCase())
        && line.includes('"Developer ID Application: '))) {
        throw new Error("The pinned Developer ID Application identity is unavailable or invalid.");
    }
    const notary = process.env.NOTARY_PROFILE;
    const suffix = notary ? "" : "-SIGNED-UNNOTARIZED";
    if (!notary) console.error("WARNING: NOTARY_PROFILE is unset. This is SIGNED ONLY. Gatekeeper will block downloaded copies.");
    await mkdir(output, { recursive: true });
    const archive = join(output, `ToyBoxDesktop-${version}-arm64${suffix}.zip`);
    if (await Bun.file(archive).exists() || await Bun.file(`${archive}.sha256`).exists()) {
        throw new Error(`Release output already exists: ${archive}`);
    }
    const app = await buildApp("release", scratch);
    const info = join(app, "Contents/Info.plist");
    await plist(info, [`Set :CFBundleShortVersionString ${version}`, `Set :CFBundleVersion ${build}`,
        `Add :SUFeedURL string ${repositoryURL}/releases/latest/download/appcast.xml`,
        `Add :SUPublicEDKey string ${publicKey}`, "Add :SUEnableAutomaticChecks bool true",
        "Add :SUVerifyUpdateBeforeExtraction bool true", "Add :SURequireSignedFeed bool true"]);
    if (await text(["xcrun", "lipo", "-archs", join(app, "Contents/MacOS/ToyBoxDesktop")]) !== "arm64") {
        throw new Error("Release executable must contain only arm64.");
    }
    console.log("Signing with the pinned identity. If a keychain prompt appears, allow codesign to use that key.");
    await signApp(app, signArgs);
    await command(["codesign", "--verify", "--strict", "--verbose=2", app]);
    const display = await command(["codesign", "--display", "--verbose=4", app], { quiet: true });
    if (!/flags=.*runtime/.test(display.stdout.toString() + display.stderr.toString())) {
        throw new Error("The release signature is missing hardened runtime.");
    }
    if (notary) {
        await temporary("toy-box-notarization.", async directory => {
            const submission = join(directory, "submission.zip");
            await command(["ditto", "-c", "-k", "--keepParent", app, submission]);
            const args = ["--keychain-profile", notary];
            if (process.env.NOTARY_KEYCHAIN) args.push("--keychain", process.env.NOTARY_KEYCHAIN);
            const result = await command(["xcrun", "notarytool", "submit", submission, ...args,
                "--wait", "--timeout", "30m", "--output-format", "json"], { quiet: true, allowFailure: true });
            process.stdout.write(result.stdout);
            process.stderr.write(result.stderr);
            const response = parseNotaryResponse(result.stdout.toString(), result.exitCode);
            if (response.status !== "Accepted" || result.exitCode) {
                if (response.id) {
                    console.error(`Notarization was not accepted (${response.status}, submission ${response.id}). Fetching its log:`);
                    const log = await command(["xcrun", "notarytool", "log", response.id, ...args], { allowFailure: true });
                    if (log.exitCode) console.error(`The notarization log could not be fetched. Use submission ${response.id} to check it later.`);
                }
                throw new Error("No release archive was created.");
            }
        });
        await command(["xcrun", "stapler", "staple", app]);
        await command(["xcrun", "stapler", "validate", app]);
        await command(["codesign", "--verify", "--strict", "--verbose=2", app]);
        await command(["spctl", "-a", "-t", "exec", "-vv", app]);
    } else {
        const result = await command(["spctl", "-a", "-t", "exec", "-vv", app], { quiet: true, allowFailure: true });
        const assessment = result.stdout.toString() + result.stderr.toString();
        (result.exitCode ? process.stderr : process.stdout).write(assessment);
        if (result.exitCode) {
            if (!assessment.includes("source=Unnotarized Developer ID")) {
                throw new Error("Gatekeeper failed for a reason other than missing notarization.");
            }
            console.error("WARNING: Gatekeeper rejected this unnotarized build as expected. Do not publish it as a normal release.");
        }
    }
    await command(["ditto", "-c", "-k", "--keepParent", app, archive]);
    const checksum = new Bun.CryptoHasher("sha256").update(await Bun.file(archive).arrayBuffer()).digest("hex");
    await Bun.write(`${archive}.sha256`, `${checksum}  ${basename(archive)}\n`);
    console.log(`Release archive: ${archive}\nSHA-256: ${archive}.sha256`);
});
