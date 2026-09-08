import { readInput } from "../src/io";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { distribution, epochUS, timeline } from "../src/timeline";
import type { Manifest } from "../src/archive";
const session = process.argv[2] ?? "11361", root = join(import.meta.dir, "../data", session);
const manifest: Manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8"));
const report: unknown[] = [];
for (const entry of manifest.entries.filter(e => e.endpoint === "location")) {
  const input = await readInput(root, entry.driverNumber!); const origin = epochUS(input.origin)!;
  const endpoints = Object.fromEntries((["location", "car_data", "laps", "pit", "position", "intervals", "stints", "race_control"] as const).map(endpoint => {
    const field = endpoint === "laps" ? "date_start" : "date", ordered = timeline(input[endpoint], origin, field);
    const inWindow = ordered.events.filter(e => e.time >= -3_600_000_000 && e.time <= epochUS(input.end)! - origin + 7_200_000_000);
    let outOfOrder = 0; const times = input[endpoint].map(r => epochUS(r[field])).filter(t => t !== null);
    times.forEach((t, i) => {if (i && t < times[i - 1]) outOfOrder++;});
    return [endpoint, {rows: input[endpoint].length, outOfOrder, duplicates: ordered.issues.length, untimed: ordered.untimed.length,
      outsideWindow: ordered.events.length - inWindow.length, intervalsUS: distribution(inWindow.map(e => e.time))}];
  }));
  report.push({driver: entry.driverNumber, endpoints});
}
await writeFile(join(import.meta.dir, `../reports/audit-${session}.json`), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report[0], null, 2));
