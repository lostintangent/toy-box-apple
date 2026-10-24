import { appendFileSync, cpSync, copyFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function fake(command: string) {
    const args = process.argv.slice(2);
    const input = command === "shasum" || (command === "gh" && args[0] === "secret" && args[1] === "set")
        ? await Bun.stdin.text() : "";
    appendFileSync(process.env.FAKE_LOG!, JSON.stringify({ command, args, input }) + "\n");
    if (command === "ditto") {
        cpSync(args[0], args[1], { recursive: true, dereference: false, verbatimSymlinks: true });
    } else if (command === "xcrun") {
        if (args[0] === "--find") console.log("/fake/toolchain/usr/bin/swiftc");
        else if (args[0] === "lipo" && args[1] === "-archs") console.log("arm64 x86_64");
        else if (args[0] === "lipo") copyFileSync(args[1], args.at(-1)!);
        else if (args[0] === "swift" && args[1] === "test") {
            process.stdout.write(process.env.TEST_LOG || "");
            process.exit(Number(process.env.TEST_EXIT || 0));
        } else if (args[0] === "swift") writeFileSync(args.at(-1)!, "fake encrypted identity");
        else if (args[0] === "notarytool" && args[1] === "store-credentials") {
            if (process.env.FAIL_NOTARY === "1") { console.error("Fake notarization rejection"); process.exit(23); }
        } else throw new Error("Unexpected fake xcrun invocation.");
    } else if (command === "codesign") {
        if (process.env.FAIL_SIGN === "1" && !args.includes("--verify")) process.exit(23);
    } else if (command === "gh") {
        if (args[0] === "repo" && args[1] === "view") console.log("example/fake-repository");
        else if (args[0] === "release" && args[1] === "view") {
            console.log(args[args.indexOf("--json") + 1] === "assets" ? process.env.PREVIOUS_FEED_URL || ""
                : process.env.LATEST_TAG || "v0.1.0");
        } else if (args[0] === "secret" && args[1] === "set"
            && (process.env.FAIL_SECRET === "1" || process.env.FAIL_SECRET === args[2])) process.exit(24);
    } else if (command === "openssl") console.log("fake-generated-password");
    else if (command === "curl") {
        const destination = args[args.indexOf("-o") + 1];
        if (process.env.FAKE_PREVIOUS_FEED) copyFileSync(process.env.FAKE_PREVIOUS_FEED, destination);
        else writeFileSync(destination, "fake intermediate certificate");
    } else if (command === "security") {
        if (args[0] === "list-keychains" && !args.includes("-s")) console.log('    "/fake/login.keychain-db"');
    } else if (command === "generate_keys") {
        if (process.env.FAIL_KEY === "1") process.exit(25);
        if (args.includes("-x")) writeFileSync(args[args.indexOf("-x") + 1], "fake-sparkle-private-key");
        else if (args.includes("-p")) console.log(Buffer.alloc(32, "p").toString("base64"));
    } else if (command === "generate_appcast") {
        const output = args[args.indexOf("-o") + 1];
        const archive = join(process.env.OUTPUT_DIR!, "ToyBox-0.2.0-arm64.zip");
        writeFileSync(output, Bun.XML.stringify({ rss: {
            "@xmlns:s": "http://www.andymatuschak.org/xml-namespaces/sparkle", channel: { item: {
                "s:version": "200.1", "s:shortVersionString": "0.2.0", "s:minimumSystemVersion": "27.0",
                "s:hardwareRequirements": "arm64",
                enclosure: {
                    "@url": args[args.indexOf("--download-url-prefix") + 1] + "ToyBox-0.2.0-arm64.zip",
                    "@length": String(Bun.file(archive).size),
                    "@s:edSignature": process.env.UNSIGNED_FEED === "1" ? "" : Buffer.alloc(64, "s").toString("base64"),
                },
            } },
        } }));
    } else if (command === "sign_update") {
        if (process.env.FAIL_VERIFY === "1") process.exit(26);
    } else if (command !== "shasum") throw new Error(`Unexpected fake command: ${command}`);
}
