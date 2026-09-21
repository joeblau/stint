/** Export the measured 2026 track surfaces for the Stint app: one combined
 *  apple/Stint/Resources/track-surfaces.json keyed by the app's DemoCircuit rawValue.
 *  Per circuit: centerline as compact [lat, lon, halfWidthLeft, halfWidthRight] rows and kerb
 *  strips as WGS84 polygons with an imagery-verified flag. Attribution travels with the data —
 *  each circuit keeps its full source provenance and the top-level "attribution" array carries
 *  the Esri/TUMFTM/bacinger credit strings found in the source files.
 *
 *  bun telemetry/scripts/export-app-surfaces.ts [--force] */
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { unprojectToLonLat } from "../src/trackimport";

/** App DemoCircuit rawValue -> tracks2026 file id (identity entries omitted). */
const RENAMED: Record<string, string> = {
  barcelona: "catalunya", spafrancorchamps: "spa", mexicocity: "mexico-city",
  interlagos: "sao-paulo", lasvegas: "las-vegas", yasmarina: "yas-marina",
};
const APP_IDS = ["austin", "baku", "barcelona", "budapest", "interlagos", "jeddah", "lasvegas", "lusail",
  "madrid", "melbourne", "mexicocity", "miami", "monaco", "montreal", "monza", "sakhir", "shanghai",
  "silverstone", "singapore", "spafrancorchamps", "spielberg", "suzuka", "yasmarina", "zandvoort"];

const sourceDir = join(import.meta.dir, "../geometry/tracks2026");
const outPath = join(import.meta.dir, "../../apple/Stint/Resources/track-surfaces.json");
const force = process.argv.includes("--force");
if (existsSync(outPath) && !force) throw new Error(`${outPath} exists; pass --force to overwrite`);

const round = (value: number, decimals: number) => {
  const scale = 10 ** decimals;
  return Math.round(value * scale) / scale;
};
/** Extract the reusable credit strings from a source provenance narrative. */
function credits(provenance: string, into: Set<string>) {
  const esri = provenance.match(/Esri World Imagery \([^)]*\)/);
  if (esri) into.add(`Widths re-measured and kerb strips classified against ${esri[0]}, tiles https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile.`);
  if (provenance.includes("TUMFTM racetrack-database"))
    into.add("Track widths: TUMFTM racetrack-database satellite-derived per-point widths (per-circuit source URLs and hashes in each circuit's provenance).");
  if (provenance.includes("bacinger/f1-circuits"))
    into.add("WGS84 reference centerlines: bacinger/f1-circuits (per-circuit source URLs and hashes in each circuit's provenance).");
}

const attribution = new Set<string>();
const circuits: Record<string, unknown> = {};
for (const appId of APP_IDS) {
  const fileId = RENAMED[appId] ?? appId;
  const geometry = JSON.parse(await readFile(join(sourceDir, `${fileId}.json`), "utf8"));
  const kerbs = JSON.parse(await readFile(join(sourceDir, `${fileId}.kerbs.json`), "utf8"));
  const origin = geometry.projection as {lat0: number; lon0: number};
  const route = geometry.routes[0];
  if (!route.closed) throw new Error(`${fileId}: expected a closed route`);
  credits(geometry.provenance, attribution);
  if (typeof kerbs.provenance === "string") credits(kerbs.provenance, attribution);

  // Closed loop without a duplicated endpoint: Swift wraps neighbors modulo the point count.
  let points = route.points as {lat: number; lon: number; wl: number; wr: number}[];
  const first = points[0], last = points[points.length - 1];
  if (first.lat === last.lat && first.lon === last.lon) points = points.slice(0, -1);
  const centerline = points.map(p => [round(p.lat, 7), round(p.lon, 7), round(p.wl, 2), round(p.wr, 2)]);

  const strips = (kerbs.kerbs as {polygon: {x: number; y: number}[]; provenance?: string}[]).map(strip => ({
    polygon: strip.polygon.map(p => {
      const geo = unprojectToLonLat(p.x, p.y, origin);
      return [round(geo.lat, 7), round(geo.lon, 7)];
    }),
    imagery: strip.provenance === "imagery",
  }));

  circuits[appId] = {closed: true, provenance: geometry.provenance, centerline, kerbs: strips};
}

const doc = {
  version: 1,
  generated: new Date().toISOString(),
  source: "telemetry/geometry/tracks2026 (measured 2026 F1 circuit library)",
  attribution: [...attribution].sort(),
  note: "centerline rows are [lat, lon, halfWidthLeftM, halfWidthRightM]; closed loops without a duplicated endpoint. " +
    "Kerb polygons are [lat, lon] rings; imagery=true marks strips verified against satellite imagery, false marks curvature-synthetic strips. Unverified; not surveyed.",
  circuits,
};
await writeFile(outPath, JSON.stringify(doc));
const kb = (JSON.stringify(doc).length / 1024).toFixed(0);
console.log(`Wrote ${outPath}: ${APP_IDS.length} circuits, ${attribution.size} attribution strings, ${kb} KB`);
