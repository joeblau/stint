/** Import external open circuit geometry (TUMFTM racetrack-database or bacinger/f1-circuits), align it into a
 *  session's experimental local meter frame by similarity fit over phase/direction, and emit unverified geometry
 *  with track widths. Sources are cached under geometry/reference/ with their SHA-256 recorded in provenance.
 *  Output never replaces the experimental geometry and refuses to overwrite prior output without --force.
 *
 *  bun telemetry/scripts/import-geometry.ts 11253 --tumftm Suzuka [--kerbs] [--force] [--max-rms 15]
 *  bun telemetry/scripts/import-geometry.ts 11299 --geojson mc-1929 --default-width 11 [--kerbs] [--force] */
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { sha256 } from "../src/archive";
import { Route, type GeometryDefinition, type Point } from "../src/geometry";
import { alignClosedLoops, applyTransform, nearestZ, parseCircuitGeojson, parseTumftmCsv, synthesizeKerbs, type CenterlinePoint } from "../src/trackimport";

const args = process.argv.slice(2);
const flag = (name: string) => {const i = args.indexOf(name); return i === -1 ? undefined : args[i + 1];};
const sessionKey = Number(args[0]);
const tumftm = flag("--tumftm"), geojson = flag("--geojson");
const defaultWidth = Number(flag("--default-width") ?? 11);
const maxRms = Number(flag("--max-rms") ?? 15);
if (!sessionKey || (!tumftm && !geojson) || (tumftm && geojson))
  throw new Error("Usage: import-geometry <sessionKey> (--tumftm <TrackName> | --geojson <circuit-id> [--default-width <m>]) [--kerbs] [--force] [--max-rms <m>]");

const source = tumftm
  ? {kind: "tumftm", url: `https://raw.githubusercontent.com/TUMFTM/racetrack-database/master/tracks/${tumftm}.csv`, cache: `tumftm-${tumftm}.csv`}
  : {kind: "bacinger", url: `https://raw.githubusercontent.com/bacinger/f1-circuits/master/circuits/${geojson}.geojson`, cache: `bacinger-${geojson}.geojson`};
const referenceDir = join(import.meta.dir, "../geometry/reference");
const cachePath = join(referenceDir, source.cache);
let body: string;
if (existsSync(cachePath)) body = await readFile(cachePath, "utf8");
else {
  const response = await fetch(source.url);
  if (!response.ok) throw new Error(`Download failed: ${response.status} ${source.url}`);
  body = await response.text();
  await mkdir(referenceDir, {recursive: true});
  await writeFile(cachePath, body);
}
const sourceHash = sha256(body);
const parsed = tumftm
  ? {points: parseTumftmCsv(body), widthProvenance: "satellite-derived per-point left/right widths"}
  : {...parseCircuitGeojson(body, defaultWidth), widthProvenance: `constant ${defaultWidth} m default width (source has no measured widths)`};

const experimentalPath = join(import.meta.dir, `../geometry/${sessionKey}.experimental.json`);
const experimental: GeometryDefinition = JSON.parse(await readFile(experimentalPath, "utf8"));
const target = experimental.routes.find(r => r.kind === "track")?.points;
if (!target) throw new Error(`${experimentalPath}: no track route`);

const alignment = alignClosedLoops(parsed.points, target);
if (alignment.rms > maxRms)
  throw new Error(`Alignment RMS ${alignment.rms.toFixed(2)} m exceeds ${maxRms} m; refusing to emit misaligned geometry`);
const {transform, reversed} = alignment;
// Densify coarse sources (GeoJSON chords reach >100 m) so emitted segments stay well under the Route 100 m limit.
const dense: CenterlinePoint[] = [];
for (let i = 0; i < parsed.points.length; i++) {
  const a = parsed.points[i], b = parsed.points[(i + 1) % parsed.points.length];
  dense.push(a);
  const span = Math.hypot(b.x - a.x, b.y - a.y), parts = Math.ceil(span / 25);
  for (let k = 1; k < parts; k++) dense.push({x: a.x + (b.x - a.x) * k / parts, y: a.y + (b.y - a.y) * k / parts, wr: a.wr + (b.wr - a.wr) * k / parts, wl: a.wl + (b.wl - a.wl) * k / parts});
}
const transformed: Point[] = dense.map(p => {
  const q = applyTransform(p, transform);
  const donor = nearestZ(q, target);
  return reversed
    ? {x: q.x, y: q.y, z: donor.z, wr: p.wl, wl: p.wr}
    : {x: q.x, y: q.y, z: donor.z, wr: p.wr, wl: p.wl};
});
const zDonorMax = Math.max(...transformed.map(p => nearestZ(p, target).horizontal));
for (let i = 1; i <= transformed.length; i++)
  if (Math.hypot(transformed[i % transformed.length].x - transformed[i - 1].x, transformed[i % transformed.length].y - transformed[i - 1].y) > 100)
    throw new Error("Transformed centerline has a >100 m segment; refusing to bridge the gap");
const widths = parsed.points.flatMap(p => [p.wr, p.wl]);
const confidence = Math.min(.8, Math.max(.3, Math.round((.85 - alignment.rms * .03) * 100) / 100));
const definition: GeometryDefinition = {version: 1, sessionKey, metersPerUnit: 1, confidence, verified: false,
  provenance: `${tumftm ? "TUMFTM racetrack-database" : "bacinger/f1-circuits"} ${source.url} sha256:${sourceHash}. ` +
    `Similarity-aligned to ${sessionKey}.experimental.json: RMS ${alignment.rms.toFixed(2)} m over ${alignment.samples} arc-length samples, ` +
    `scale ${transform.scale.toFixed(4)}, ${reversed ? "reversed" : "matching"} direction, phase offset ${alignment.offset}. ` +
    `Widths: ${parsed.widthProvenance} (range ${Math.min(...widths).toFixed(2)}–${Math.max(...widths).toFixed(2)} m half-width). ` +
    `z copied from nearest experimental point (max donor distance ${zDonorMax.toFixed(1)} m); sources carry no elevation. ` +
    `Unverified; no WGS84 transform; start/finish approximate; not surveyed.`,
  routes: [{id: "track", kind: "track", closed: true, points: transformed}]};
const outPath = join(import.meta.dir, `../geometry/${sessionKey}.${source.kind}.json`);
if (existsSync(outPath) && !args.includes("--force")) throw new Error(`${outPath} exists; pass --force to overwrite`);
await writeFile(outPath, JSON.stringify(definition));
new Route(definition.routes[0]); // Validate against the same constraints normalize.ts relies on.

let kerbPath: string | undefined, kerbCount = 0;
if (args.includes("--kerbs")) {
  const loop: CenterlinePoint[] = alignment.reference.map(p => applyTransform(p, transform));
  const kerbs = synthesizeKerbs(loop);
  kerbCount = kerbs.length;
  kerbPath = join(import.meta.dir, `../geometry/${sessionKey}.kerbs.json`);
  if (existsSync(kerbPath) && !args.includes("--force")) throw new Error(`${kerbPath} exists; pass --force to overwrite`);
  await writeFile(kerbPath, JSON.stringify({version: 1, sessionKey, synthetic: true,
    provenance: `Synthetic kerbs synthesized from curvature of ${sessionKey}.${source.kind}.json centerline (curvature >= 0.012/m, 2 m strips at track edge). NOT measured geometry. Same local meter frame.`,
    kerbs}, null, 2));
}
console.log(JSON.stringify({output: outPath, cache: cachePath, sha256: sourceHash, rms: +alignment.rms.toFixed(3), reversed,
  scale: +transform.scale.toFixed(4), confidence, points: transformed.length,
  halfWidthRange: [+Math.min(...widths).toFixed(2), +Math.max(...widths).toFixed(2)], zDonorMax: +zDonorMax.toFixed(1),
  ...(kerbPath ? {kerbs: kerbPath, kerbCount} : {})}));
