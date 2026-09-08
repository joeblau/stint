import { readInput } from "../src/io";
import { epochUS } from "../src/timeline";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
for (const [session, driver, ranges] of [
  [11361, 1, [["2026-09-06T13:03:00Z", "2026-09-06T13:10:00Z"], ["2026-09-06T13:38:00Z", "2026-09-06T13:49:00Z"]]],
  [11361, 63, [["2026-09-06T13:06:00Z", "2026-09-06T13:10:00Z"], ["2026-09-06T13:38:00Z", "2026-09-06T13:42:00Z"]]],
  [11299, 1, [["2026-06-07T13:03:00Z", "2026-06-07T14:01:00Z"]]],
  [11253, 1, [["2026-03-29T05:14:00Z", "2026-03-29T05:20:00Z"]]],
] as [number, number, string[][]][]) {
  const root = join(import.meta.dir, "../data", String(session)), input = await readInput(root, driver);
  const windows = ranges.map(r => r.map(t => epochUS(t)!));
  for (const endpoint of ["location", "car_data"] as const) input[endpoint] = input[endpoint].filter(r => {
    const time = epochUS(r.date)!; return windows.some(([a, b]) => time >= a && time <= b);
  });
  const manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8"));
  await writeFile(join(import.meta.dir, `../tests/fixtures/${session}-${driver}.json`), JSON.stringify({
    provenance: {description: "Extracted test subset; original byte-exact response bodies remain in the raw archive.", ranges,
      sources: manifest.entries.filter((e: {driverNumber?: number}) => e.driverNumber === undefined || e.driverNumber === driver)}, input}));
}
