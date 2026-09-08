/** Experimental reference trajectory, NOT a surveyed centerline. Release requires reviewed geometry. */
import { readInput } from "../src/io";
import { epochUS, timeline, asOf } from "../src/timeline";
import { distance, type GeometryDefinition, type Point } from "../src/geometry";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
const sessionKey = Number(process.argv[2]), driver = Number(process.argv[3] ?? 1);
const input = await readInput(join(import.meta.dir, "../data", String(sessionKey)), driver);
const origin = epochUS(input.origin)!;
const locations = timeline(input.location, origin).events;
const telemetry = timeline(input.car_data, origin).events;
const laps = timeline(input.laps, origin, "date_start").events;
const pitLaps = new Set(input.pit.map(r => r.lap_number));
let chosen: {points: Point[]; lap: number; ratio: number; duration: number} | undefined;
for (const lap of laps.filter(e => Number(e.data.lap_number) > 1 && !e.data.is_pit_out_lap && !pitLaps.has(e.data.lap_number)).sort((a, b) => Number(a.data.lap_duration) - Number(b.data.lap_duration))) {
  const duration = Number(lap.data.lap_duration); if (!(duration > 45 && duration < 130)) continue;
  const rows = locations.filter(e => e.time >= lap.time && e.time <= lap.time + duration * 1e6);
  if (rows.length < 50) continue;
  // Explicit hypothesis from the upstream position feed; independently check against speed integral.
  const points = rows.map(e => ({x: Number(e.data.x) * .1, y: Number(e.data.y) * .1, z: Number(e.data.z) * .1}));
  const lengths = points.slice(1).map((p, i) => distance(points[i], p));
  if (Math.max(...lengths) > 100 || distance(points[0], points.at(-1)!) > 100) continue;
  if (rows.slice(1).some((e, i) => e.time - rows[i].time > 2_000_000)) continue;
  let speedIntegral = 0;
  for (let i = 1; i < rows.length; i++) {
    const speed = asOf(telemetry, rows[i - 1].time, 1_000_000)?.data.speed;
    if (typeof speed === "number") speedIntegral += speed / 3.6 * (rows[i].time - rows[i - 1].time) / 1e6;
  }
  const ratio = lengths.reduce((a, b) => a + b, 0) / speedIntegral;
  if (ratio < .85 || ratio > 1.15) continue;
  chosen = {points, lap: Number(lap.data.lap_number), ratio, duration}; break;
}
if (!chosen) throw new Error("No sufficiently covered lap; provide external verified geometry");
const definition: GeometryDefinition = {version: 1, sessionKey, metersPerUnit: .1, confidence: .6, verified: false,
  provenance: `Experimental driver ${driver} lap ${chosen.lap}; raw-path / speed-integral ratio ${chosen.ratio.toFixed(4)}. Start/finish is approximate. No surveyed pit geometry or WGS84 transform.`,
  routes: [{id: "track", kind: "track", closed: true, points: chosen.points}]};
const path = join(import.meta.dir, `../geometry/${sessionKey}.experimental.json`);
await writeFile(path, JSON.stringify(definition)); console.log(path, chosen.lap, chosen.ratio);
