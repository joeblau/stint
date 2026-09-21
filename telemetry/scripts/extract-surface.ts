/** bun telemetry/scripts/extract-surface.ts <config.json> [--plan] [--diagnostic] [--force]
 * Provider-neutral local imagery input. No implicit downloads, historical width priors or kerbs.
 */
import {readFile, writeFile, mkdir, mkdtemp, rm, rename} from "node:fs/promises";
import {existsSync} from "node:fs";
import {basename, dirname, resolve, join} from "node:path";
import {tmpdir} from "node:os";
import {createHash} from "node:crypto";
import {lonLatToGlobalPx, metersPerPixel, type RgbProfile} from "../src/imagery";
import {parseCircuitGeojson, resampleClosed, unprojectToLonLat, type SimilarityTransform} from "../src/trackimport";
import {continuousMiamiSurface, controlPointAlignment, exportSurface, requireCompleteSurface, measureStrict, measureMiamiCounty, refineMiamiBoundaries, measureKerbsAlongTrack, rejectDiscontinuities, rejectFoldedEdges, smoothSurfaceReference, validCoordinate, type Timing, type Station} from "../src/surface-overlay";

import {validateMiamiKerbReview, traceReviewedMiamiPaint, applyReviewedMiamiKerbs, type MiamiKerbReview} from "../src/miami-kerb-review";

const args = process.argv.slice(2), configPath = args.find(a => !a.startsWith("--"));
if (!configPath || args.filter(a => !a.startsWith("--")).length !== 1 || args.some(a => a.startsWith("--") && !["--plan", "--diagnostic", "--force"].includes(a)))
  throw new Error("Usage: extract-surface <config.json> [--plan] [--diagnostic] [--force]");
const config = JSON.parse(await readFile(configPath, "utf8"));
if (config.circuit !== "miami") throw new Error("This extraction workflow is limited to Miami");
if (typeof config.output !== "string" || basename(config.output) !== "miami.surface.geojson")
  throw new Error("Miami output must be named miami.surface.geojson");
const diagnostic = args.includes("--diagnostic");
const base = dirname(resolve(configPath)), local = (p: string) => resolve(base, p);
const sourceBytes = await readFile(local(config.centerline));
const sourceDoc = JSON.parse(sourceBytes.toString());
const sourceCoords = sourceDoc.features?.find((f: any) => f.geometry?.type === "LineString")?.geometry.coordinates;
if (!sourceCoords?.every(validCoordinate)) throw new Error("Centerline must contain only WGS84 [longitude, latitude] coordinates");
if (!sourceCoords.every(([lon, lat]: number[]) => Math.abs(lon + 80.239) < 0.03 && Math.abs(lat - 25.958) < 0.03))
  throw new Error("Centerline must be located at the Miami circuit");
const parsed = parseCircuitGeojson(sourceBytes.toString(), 12); // parser requires widths; they are never used
const ordered = config.reverse ? parsed.points.slice().reverse() : parsed.points;
const points = config.centerlineInterpolation === "centripetal" ? smoothSurfaceReference(ordered) : ordered;
const spacing = config.spacingM ?? 1, margin = config.marginM ?? 200, zoom = config.zoom ?? 19;
if (!Number.isFinite(spacing) || spacing < 0.25 || spacing > 2 || !Number.isFinite(margin) || margin < 200 || ![19, 20].includes(zoom))
  throw new Error("Require station spacing 0.25..2 m, margin >=200 m and zoom 19 or 20");
const length = points.reduce((s, p, i) => s + Math.hypot(p.x - points[(i + 1) % points.length].x, p.y - points[(i + 1) % points.length].y), 0);
if (!Number.isFinite(length) || length < 100 || length > 30000) throw new Error("Invalid circuit length");
const grid = resampleClosed(points, Math.ceil(length / spacing));
const stations: Station[] = grid.map((p, i) => {
  const a = grid[(i - 1 + grid.length) % grid.length], b = grid[(i + 1) % grid.length], h = Math.hypot(b.x - a.x, b.y - a.y);
  if (h < 1e-6) throw new Error("Degenerate centerline normal");
  return {x: p.x, y: p.y, distanceM: i * length / grid.length, normal: {x: -(b.y - a.y) / h, y: (b.x - a.x) / h}};
});
const hash = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const bounds = {minX: Math.min(...points.map(p => p.x)) - margin, maxX: Math.max(...points.map(p => p.x)) + margin,
  minY: Math.min(...points.map(p => p.y)) - margin, maxY: Math.max(...points.map(p => p.y)) + margin};
const blockers: string[] = [];
if (!config.imagery?.imagePath) blockers.push("Licensed local imagery raster and pixel georeference missing.");
if (!config.imagery?.licenseEvidence) blockers.push("Imagery extraction/reuse license evidence missing; standard Google Maps terms do not permit this workflow.");
if (!config.controls || config.controls.length < 3) blockers.push("Three or more identified imagery/reference control-point pairs required.");
if (!config.timing) blockers.push("FIA timing-line coordinates and placement provenance missing; equal thirds are forbidden.");
const plan = {circuit: config.circuit, year: config.year, centerlineSource: config.centerlineSource, centerlineSha256: hash(sourceBytes),
  requestedImagery: {provider: config.imagery?.source ?? "Licensed local raster", maptype: "aerial", center: {latitude: 25.958, longitude: -80.239},
    acquisition: "Local georeferenced raster; county source approved for Miami"},
  centerlineInterpolation: config.centerlineInterpolation ?? "linear",
  origin: parsed.origin, stations: stations.length, lengthM: length, zoom, marginM: margin,
  nominalMetersPerPixel: metersPerPixel(parsed.origin.lat0, zoom),
  boundsWGS84: [unprojectToLonLat(bounds.minX, bounds.minY, parsed.origin), unprojectToLonLat(bounds.maxX, bounds.maxY, parsed.origin)],
  blockers, validation: config.validation, officialTimingReference: config.officialTimingReference,
  status: blockers.length ? "awaiting-inputs" : "ready", noNetworkRequests: true};
if (args.includes("--plan")) {console.log(JSON.stringify(plan, null, 2)); process.exit(0);}
// Incomplete diagnostics cannot overwrite the asset consumed by the app.
if (blockers.some(b => !diagnostic || !b.startsWith("FIA"))) throw new Error(blockers.join("\n"));
const raster = config.imagery;
if (![raster.source, raster.licenseEvidence, raster.attribution].every(v => typeof v === "string" && v.trim().length > 0))
  throw new Error("Raster requires source, licenseEvidence and attribution");
if (raster.zoom !== zoom || !Array.isArray(raster.originPx) || raster.originPx.length !== 2 || !raster.originPx.every(Number.isFinite) ||
    ![1, 2].includes(raster.scale ?? 1) || !(raster.nativeMetersPerPixel > 0) || !Number.isFinite(raster.nativeMetersPerPixel))
  throw new Error("Raster requires matching zoom, finite originPx, scale 1 or 2 and nativeMetersPerPixel (resizing does not improve resolution)");
if (config.timing && config.timing.year !== config.year) throw new Error("Timing year must match the target event");
const alignment = controlPointAlignment(config.controls, parsed.origin, config.maxAlignmentRmsM ?? 1.5);
const transform = alignment.transform;
const inverse = (p: {x: number; y: number}, t: SimilarityTransform) => ({
  x: (t.cos * (p.x - t.tx) + t.sin * (p.y - t.ty)) / t.scale,
  y: (-t.sin * (p.x - t.tx) + t.cos * (p.y - t.ty)) / t.scale});
const pixel = (p: {x: number; y: number}): [number, number] => {
  const raw = inverse(p, transform), ll = unprojectToLonLat(raw.x, raw.y, parsed.origin);
  const px = lonLatToGlobalPx(ll.lon, ll.lat, zoom), scale = raster.scale ?? 1;
  return [px.x * scale - raster.originPx[0], px.y * scale - raster.originPx[1]];
};
const profiles = stations.map(s => ({start: pixel({x: s.x - s.normal.x * 25, y: s.y - s.normal.y * 25}),
  end: pixel({x: s.x + s.normal.x * 25, y: s.y + s.normal.y * 25})}));
const output = diagnostic ? resolve(import.meta.dir, "../reports/miami.surface.diagnostic.geojson") : local(config.output);
const reportPath = `${output}.report.json`;
if (!args.includes("--force") && (existsSync(output) || existsSync(reportPath))) throw new Error("Output exists; pass --force to replace it");
const python = process.env.STINT_IMAGERY_PYTHON ?? (existsSync("/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "python3");
const worker = join(import.meta.dir, "imagery/sample-local.py"), temporary = await mkdtemp(join(tmpdir(), "stint-surface-"));
function runPython(command: string, input: string, out?: string) {
  const result = Bun.spawnSync([python, worker, command, input, ...(out ? [out] : [])], {stdin: "ignore", stdout: "inherit", stderr: "inherit"});
  if (result.exitCode) throw new Error(`Imagery worker ${command} failed (Pillow, numpy and shapely required)`);
}
try {
  const job = join(temporary, "job.json"), samplesPath = join(temporary, "samples.json"), candidate = join(temporary, "surface.geojson");
  await writeFile(job, JSON.stringify({imagePath: local(raster.imagePath), count: 201, profiles}));
  runPython("sample", job, samplesPath);
  const sampled = JSON.parse(await readFile(samplesPath, "utf8"));
  if (diagnostic) await writeFile(local(raster.imagePath) + ".profiles.json", JSON.stringify({stations, sampled}));
  // All four bounds corners must fit: no silently reduced 200 m margin or edge clamping.
  const coverage = [[bounds.minX, bounds.minY], [bounds.maxX, bounds.minY], [bounds.maxX, bounds.maxY], [bounds.minX, bounds.maxY]]
    .map(([x, y]) => pixel({x, y}));
  if (coverage.some(([x, y]) => x < 0 || y < 0 || x >= sampled.size[0] || y >= sampled.size[1])) throw new Error("Raster does not cover the circuit plus its 200 m margin");
  if (sampled.samples.length !== stations.length) throw new Error("Worker returned the wrong number of stations");
  const rgbProfiles: (RgbProfile | null)[] = sampled.samples.map((p: RgbProfile | null) => p && {...p, stepM: 0.25, rangeM: 25});
  const firstPass = rgbProfiles.map(config.imageryDetection === "miami-turquoise" ? measureMiamiCounty : measureStrict);
  const edges = rejectDiscontinuities(config.imageryDetection === "miami-turquoise" ? refineMiamiBoundaries(rgbProfiles, firstPass, length / grid.length) : firstPass);
  const observed = rejectFoldedEdges(stations, measureKerbsAlongTrack(rgbProfiles, edges, length / grid.length));
  const imageryHash = hash(await readFile(local(raster.imagePath)));
  const kerbReview: MiamiKerbReview | null = config.kerbReview ? JSON.parse(await readFile(local(config.kerbReview), "utf8")) : null;
  if (kerbReview) validateMiamiKerbReview(kerbReview, imageryHash, hash(sourceBytes), length);
  const prior = config.continuousVisualization ? continuousMiamiSurface(stations, observed, length / grid.length) : null;
  if (kerbReview && !prior) throw new Error("Reviewed Miami kerbs require continuous visualization");
  const traced = kerbReview ? traceReviewedMiamiPaint(stations, rgbProfiles, observed, prior!.measured, kerbReview, length) : null;
  const refinement = traced ? continuousMiamiSurface(stations, traced.measured, length / grid.length) : prior;
  const reviewed = traced ? applyReviewedMiamiKerbs(refinement!.measured, traced.traces, kerbReview!) : null;
  const measured = reviewed?.measured ?? refinement?.measured ?? observed;
  if (reviewed) refinement!.audit.kerbs = "Full-lap reviewed inventory with onboard-confirmed presence; raster-traced positions; explicit bridge/shadow interpolation; low geographic confidence";
  if (reviewed) for (const strip of reviewed.audit) Object.assign(strip, {
    renderedCoordinates: strip.samples.map(({station: i}) => {
      const s = stations[i], sign = strip.side === "left" ? 1 : -1;
      const offset = measured[i][strip.side === "left" ? "kerbLeft" : "kerbRight"]!.offsetM;
      const p = unprojectToLonLat(s.x + s.normal.x * offset * sign, s.y + s.normal.y * offset * sign, parsed.origin);
      return [p.lon, p.lat];
    })
  });
  const doc = exportSurface(stations, measured, parsed.origin, config.timing as Timing | null,
    {...plan, refinement: refinement?.audit, kerbReview: kerbReview && {...kerbReview, tracedKerbs: reviewed!.audit}, status: diagnostic ? "diagnostic" : "unverified-extraction", alignment, imagery: {...raster, sha256: imageryHash},
      validation: config.validation ?? {status: "unavailable", reason: "No independent reference supplied"}}, config.strokePixels ?? 2, config.observedPatches === true);
  if (refinement) {
    Object.assign(doc.metadata, {displayRoadFraction: 1,
      observedRoadFraction: observed.filter((m, i) => m.left && m.right && observed[(i + 1) % observed.length].left && observed[(i + 1) % observed.length].right).length / observed.length});
    for (const feature of doc.features) Object.assign(feature.properties, {
      geometrySource: "regularized-imagery-visualization", includesInferredGeometry: true});
  }
  if (!diagnostic) requireCompleteSurface(doc, config.observedPatches === true);
  await writeFile(candidate, JSON.stringify(doc));
  if (diagnostic) await writeFile(resolve(import.meta.dir, "../reports/miami.surface.raw.geojson"), JSON.stringify(doc));
  if (config.observedPatches) runPython("assemble", candidate);
  runPython("validate", candidate); // refuse invalid rings/holes rather than silently repair geometry
  const assembled = JSON.parse(await readFile(candidate, "utf8"));
  await mkdir(dirname(output), {recursive: true});
  await writeFile(`${output}.tmp`, JSON.stringify(assembled));
  await rename(`${output}.tmp`, output);
  await writeFile(reportPath, JSON.stringify(assembled.metadata, null, 2));
  console.log(`${output}: ${assembled.features.length} features, ${doc.metadata.missing.length} missing side/stations. Unverified.`);
} finally {await rm(temporary, {recursive: true, force: true});}
