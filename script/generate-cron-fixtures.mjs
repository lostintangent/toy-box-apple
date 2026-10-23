import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const reference = resolve(process.argv[2] ?? "../toy-box");
const require = createRequire(resolve(reference, "package.json"));
const { CronExpressionParser } = require("cron-parser");
const { version } = JSON.parse(readFileSync(require.resolve("cron-parser/package.json"), "utf8"));
const fixtures = [];
const utc = "2026-01-31T23:59:58.125Z";

function add(expression, from = utc, timeZone = "UTC", count = 4, hashSeed) {
    const fixture = { expression, from, timeZone };
    if (hashSeed !== undefined) fixture.hashSeed = hashSeed;
    try {
        let current = new Date(from);
        fixture.next = [];
        for (let i = 0; i < count; i++) {
            current = CronExpressionParser.parse(expression, { currentDate: current, tz: timeZone, hashSeed }).next().toDate();
            fixture.next.push(current.toISOString());
        }
    } catch (error) {
        fixture.error = error instanceof Error ? error.message : String(error);
    }
    fixtures.push(fixture);
}

for (const expression of [
    "* * * * *", "*/15 * * * *", "10,20,40 8-18/2 * * MON-FRI",
    "5/13 1-23/5 * JAN,MAR,DEC *", "17 23 29 FEB *", "0 0 L * *",
    "0 12 1,15,L * *", "0 0 * * 5L", "0 0 * * 0L", "0 0 * * 7L",
    "0 0 * * MON#2", "0 0 * * 5#5", "0 0 1 * MON", "0 0 ? * TUE",
    "0 0 */2 * SUN", "0 0 * * 0-7", "0 0 29,30,31 2 *",
    "0 0 * FEB FRI#5", "0 0 * * *#3", "0 0 * * 99L", "0 0 2L * *",
    "0 0 * * 1-5/2", "0 0 1-31/3 * ?", "0 0 31 APR FRI",
    "0 */7 * * * *", "*/17 */13 0,12,23 * * *", "59 59 23 31 DEC ?",
    "?", "*", "MON", "JAN", "0 0", "12 * *", "1 2 3 4", "",
    "@yearly", "@annually", "@monthly", "@weekly", "@daily",
    "@hourly", "@minutely", "@secondly", "@weekdays", "@weekends",
]) add(expression);

for (const expression of [
    "H H H * * *", "H/10 H(10-30)/7 * * * *", "H(0-100)/90 * * * * *",
    "0 H/100 H(0-100) H H H", "H(10-20),H(30-40) * * * * *",
]) add(expression, utc, "UTC", 4, "mac-channels-🧭");

for (const [timeZone, from, expressions] of [
    ["America/New_York", "2026-03-08T06:55:00Z", ["30 2 * * *", "0 2 * * *", "*/15 * * * *", "30 1,2,3 * * *"]],
    ["America/New_York", "2026-03-08T07:15:00Z", ["30 2 * * *"]],
    ["America/New_York", "2026-11-01T04:55:00Z", ["30 1 * * *", "0 * * * *", "*/15 * * * *", "*/10 59 1 * * *"]],
    ["America/New_York", "2026-11-01T06:15:00Z", ["30 1 * * *", "0 1 * * *"]],
    ["Europe/Berlin", "2026-03-29T00:55:00Z", ["30 2 * * *", "30 1,2,3 * * *"]],
    ["Europe/Berlin", "2026-10-25T00:15:00Z", ["30 2 * * *", "0 * * * *"]],
    ["Australia/Lord_Howe", "2026-10-03T15:25:00Z", ["0 2 * * *", "15 2 * * *", "45 2 * * *", "*/15 * * * *"]],
    ["Australia/Lord_Howe", "2026-04-04T14:25:00Z", ["45 1 * * *", "0 * * * *"]],
    ["Pacific/Apia", "2011-12-29T09:55:00Z", ["0 0 * * *", "0 12 * * *"]],
    ["America/Santiago", "2026-09-06T03:55:00Z", ["30 0 * * *", "0 0 * * *"]],
]) {
    for (const expression of expressions) add(expression, from, timeZone, 5);
}

let sampleSeed = 0x20261022;
function pick(values) {
    sampleSeed = (Math.imul(sampleSeed, 1664525) + 1013904223) >>> 0;
    return values[Math.floor(sampleSeed / 4294967296 * values.length)];
}
for (let i = 0; i < 240; i++) {
    const expression = [
        pick(["0", "*/17", "5,29,59", "10-40/7"]),
        pick(["*", "*/13", "0,30", "10-50/9"]),
        pick(["*", "0", "1,2,3", "8-22/3"]),
        pick(["*", "?", "1", "15,L", "29,30,31", "*/2"]),
        pick(["*", "JAN-MAR", "1,6,12", "FEB"]),
        pick(["*", "?", "MON-FRI", "1#2", "5L", "7", "0-7/2"]),
    ].join(" ");
    add(expression, pick([
        "2026-03-08T06:55:00.000Z", "2026-11-01T04:55:00.000Z",
        "2026-03-29T00:55:00.000Z", "2026-10-25T00:15:00.000Z",
        "2026-10-03T15:25:00.000Z", "2026-04-04T14:25:00.000Z",
    ]), pick(["UTC", "America/New_York", "Europe/Berlin", "Australia/Lord_Howe"]), 2);
}

for (const expression of [
    "0 0 1W * *", "0 0 LW * *", "0 0 * * L", "0 0 * * MON#0",
    "0 0 * * MON#6", "0 0 * * MON,TUE#2", "0 0 * * MON-FRI#2",
    "0 0 * * MON#1#2", "*/0 * * * *", "60 * * * *", "0 24 * * *",
    "0 0 0 * *", "0 0 * 13 *", "0 0 * * 8", "0 0 * * MONDAY",
    "0 0 * * 1,1", "0 0 * * 0,7", "0 0 * * 5-1",
    "0 0 30 FEB *", "0 0 31 APR *", "0 0 * * MON#2.5",
    "0 0 * * H(8-9)", "0 0 * * H(5-1)", "0 0 * * H/0",
    "0 H(2-3 * * *", "0 H(2) * * *", "0 H(2-3)) * * *",
    "0 0 * * * * *", "@midnight", "@DAILY", " @daily ", " ",
    "0 ".repeat(513),
]) add(expression, utc, "UTC", 1, "invalid-fixture");

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const output = resolve(root, "Tests/ChannelKitTests/Fixtures/cron-occurrences.json");
writeFileSync(output, JSON.stringify({ parser: `cron-parser@${version}`, fixtures }, null, 2) + "\n");
console.log(`${fixtures.length} fixtures from cron-parser@${version}: ${output}`);
