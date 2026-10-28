import { expect, test } from "bun:test";
import { bundleIdentity } from "../shared/lib.ts";
import { legacyTestBundles } from "./validate.ts";

test("validation unregisters only pre-rename copies of its test identity", () => {
    const canonical = "/workspace/.build/agents/Toy Box Desktop Test.app";
    const scratch = "/private/tmp/older scratch/Toy Box Desktop Test.app";
    function record(path: string, identifier = `${bundleIdentity}.test`) {
        return `--------------------------------------------------------------------------------
bundle id:                  Toy Box Desktop Test (0x123)
path:                       ${path} (0x456)
identifier:                 ${identifier}
codeInfoID:                 ${bundleIdentity}.test
`;
    }
    const dump = [
        record(canonical), record(scratch), record(canonical),
        record("/workspace/.build/agents/Toy Box Test.app"),
        record("/Applications/Toy Box Desktop Test.app", bundleIdentity),
        record("/Applications/Toy Box Desktop Test.app", `${bundleIdentity}.test.other`),
        record("/tmp/Toy Box Desktop.app"), record("relative/Toy Box Desktop Test.app"),
        `--------------------------------------------------------------------------------
path:                       /tmp/unrelated/Toy Box Desktop Test.app (0x789)
codeInfoID:                 ${bundleIdentity}.test
`,
    ].join("\n");
    expect(legacyTestBundles(dump)).toEqual([canonical, scratch]);
    expect(legacyTestBundles(dump.replaceAll("\n", "\r\n"))).toEqual([canonical, scratch]);
    expect(legacyTestBundles("")).toEqual([]);
});
