/** Measure track widths and detect kerbs from Esri World Imagery for the 2026 track library.
 *
 *  Pipeline per circuit:
 *   1. (TS) Resample the tracks2026 centerline to a ~5 m grid, compute normals, corner kerb strips and the
 *      set of Web-Mercator tiles intersecting a 60 m buffer -> geometry/imagery/<id>/job.json.
 *   2. (Python, scripts/imagery/measure.py) Download Esri tiles (cache + gray-placeholder zoom fallback),
 *      stitch a mosaic, sample RGB cross-profiles and kerb-strip pixel stats -> result.json. PIL/numpy only;
 *      no measurement decisions.
 *   3. (TS, src/imagery.ts) Edge detection -> per-station half-widths + confidence; median smoothing,
 *      interpolation of short gaps, prior-width fallback for long/dark spans; kerb classification;
 *      TUMFTM cross-validation where a TUMFTM width source exists.
 *   4. (TS) Rewrite tracks2026/<id>.json (measured wr/wl + provenance), <id>.kerbs.json (per-strip
 *      imagery/synthetic provenance) and manifest.json (imageryZoom, widthProvenance, kerbProvenance,
 *      measured width range, % measured, notes). Refuses to overwrite a previously measured track
 *      without --force.
 *   5. (Python) QA render -> reports/tracks2026-qa/<id>.png (mosaic + centerline/edges/kerbs + summary).
 *
 *  bun telemetry/scripts/measure-imagery.ts <circuit-id> [more ids...] [--force] [--zoom 18] [--buffer 60]
 *
 *  Imagery attribution (recorded in all outputs): Esri, Maxar, Earthstar Geographics, and the GIS User
 *  Community. Everything emitted remains verified: false — imagery measurements are unreviewed estimates. */
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { CircuitGeometryDefinition, Point } from "../src/geometry";
import { ESRI_ATTRIBUTION, ESRI_TILE_URL, PROFILE_RANGE_M, PROFILE_STEP_M, classifyKerb, continuityGuided,
  edgeCandidates, fuseWidths, measureWidth, metersPerPixel, pearson, tilesForBuffer, type KerbStripStats,
  type LapMeasurement, type PointStatus, type StationEdges } from "../src/imagery";
import { resampleClosed, cornerZoneSpans, projectLonLat, unprojectToLonLat, type CenterlinePoint } from "../src/trackimport";

const args = process.argv.slice(2);
const force = args.includes("--force");
const refetch = args.includes("--refetch"); // re-download tiles + rebuild mosaic (default: reuse caches)
const noManifest = args.includes("--no-manifest"); // write per-track manifest fragments instead of manifest.json
const constantDefault = args.includes("--constant-default"); // imagery predates the circuit: keep prior widths, flag fallback
const mergeFragments = args.includes("--merge-fragments"); // merge all fragments into manifest.json, then exit
const flag = (name: string, fallback: number) => {const i = args.indexOf(name); return i === -1 ? fallback : Number(args[i + 1]);};
const zoom = flag("--zoom", 18), bufferM = flag("--buffer", 60);
// Paved-apron overshoot guard: full-width pairs above this cap are treated as unmeasured (fall back to
// prior widths). Use where cross-validation shows the detector locking onto outer runoff/apron edges.
const maxFullWidth = flag("--max-full-width", Infinity);
const ids = args.filter(a => !a.startsWith("--") && !/^\d+(\.\d+)?$/.test(a));
const USAGE = "Usage: measure-imagery <circuit-id> [more ids...] [--force] [--zoom 18] [--buffer 60] [--refetch] [--no-manifest] [--constant-default]\n" +
  "       measure-imagery --merge-fragments";
if (ids.length === 0 && !mergeFragments) throw new Error(USAGE);

const python = existsSync("/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "python3";
const pyScript = join(import.meta.dir, "imagery/measure.py");
const tracksDir = join(import.meta.dir, "../geometry/tracks2026");
const qaDir = join(import.meta.dir, "../reports/tracks2026-qa");

function runPython(pyArgs: string[]): void {
  const out = Bun.spawnSync({cmd: [python, pyScript, ...pyArgs], stdout: "pipe", stderr: "inherit"});
  if (out.exitCode !== 0) throw new Error(`measure.py ${pyArgs[0]} failed with exit code ${out.exitCode}`);
  console.log(out.stdout.toString().trim());
}

const manifestPath = join(tracksDir, "manifest.json");
const manifestDoc = JSON.parse(await readFile(manifestPath, "utf8"));

/** Imagery-measurement fields for one circuit, as merged into its manifest entry. */
interface ManifestFragment {
  id: string; imageryZoom: number; imageryZooms: Record<string, number>; imageryAttribution: string;
  imageryTiles: number; widthProvenance: string; kerbProvenance: string; kerbStrips: number;
  measuredWidthRangeM: [number, number] | null; pctMeasured: number; imageryMeasuredAt: string; imageryNotes: string;
}

if (mergeFragments) {
  // One-pass, idempotent merge of all per-track fragments (parallel workers never touch manifest.json).
  const {readdir} = await import("node:fs/promises");
  const files = (await readdir(qaDir)).filter(f => f.endsWith(".manifest-fragment.json")).sort();
  if (files.length === 0) throw new Error(`no fragments found in ${qaDir}`);
  const merged: string[] = [];
  for (const file of files) {
    const fragment: ManifestFragment = JSON.parse(await readFile(join(qaDir, file), "utf8"));
    const entry = manifestDoc.circuits.find((c: any) => c.id === fragment.id);
    if (!entry) throw new Error(`${file}: circuit ${fragment.id} not in manifest.json`);
    const {id, ...fields} = fragment;
    Object.assign(entry, fields);
    merged.push(id);
  }
  await writeFile(manifestPath, JSON.stringify(manifestDoc, null, 2));
  console.log(`merged ${merged.length} fragment(s) into ${manifestPath}: ${merged.join(", ")}`);
  process.exit(0);
}

const rows: string[] = [];

for (const id of ids) {
  const trackPath = join(tracksDir, `${id}.json`), kerbPath = join(tracksDir, `${id}.kerbs.json`);
  if (!existsSync(trackPath) || !existsSync(kerbPath)) throw new Error(`${id}: build-track-library output missing (${trackPath})`);
  const entry = manifestDoc.circuits.find((c: any) => c.id === id);
  if (!entry) throw new Error(`${id}: not in manifest.json`);
  const fragmentPath = join(qaDir, `${id}.manifest-fragment.json`);
  if (!force && (entry.imageryZoom !== undefined || (noManifest && existsSync(fragmentPath))))
    throw new Error(`${id}: imagery measurement already applied; pass --force to overwrite`);

  const definition: CircuitGeometryDefinition = JSON.parse(await readFile(trackPath, "utf8"));
  const kerbDoc = JSON.parse(await readFile(kerbPath, "utf8"));
  const route = definition.routes.find(r => r.kind === "track");
  if (!route || !route.closed) throw new Error(`${id}: no closed track route`);
  const origin = definition.projection;
  let length = 0;
  for (let i = 0; i < route.points.length; i++)
    length += Math.hypot(route.points[(i + 1) % route.points.length].x - route.points[i].x,
      route.points[(i + 1) % route.points.length].y - route.points[i].y);
  const n = Math.max(64, Math.round(length / 5)), spacingM = length / n;
  const grid = resampleClosed(route.points as CenterlinePoint[], n);

  // Uniform ~5 m measurement grid: lon/lat, left-normal (east/north components), prior half-widths.
  const samples = grid.map((p, i) => {
    const a = grid[(i - 1 + n) % n], b = grid[(i + 1) % n];
    const h = Math.hypot(b.x - a.x, b.y - a.y) || 1;
    const ll = unprojectToLonLat(p.x, p.y, origin);
    return {index: i, lat: ll.lat, lon: ll.lon, nE: -(b.y - a.y) / h, nN: (b.x - a.x) / h,
      priorWl: p.wl ?? 6, priorWr: p.wr ?? 6};
  });
  const tiles = tilesForBuffer(samples.filter((_, i) => i % 4 === 0).map(s => ({lon: s.lon, lat: s.lat})), bufferM, zoom);

  const imageryDir = join(import.meta.dir, `../geometry/imagery/${id}`);
  await mkdir(imageryDir, {recursive: true});
  const jobPath = join(imageryDir, "job.json");
  await writeFile(jobPath, JSON.stringify({circuit: id, imageryDir, zoom, bufferM, tiles, samples,
    profile: {stepM: PROFILE_STEP_M, rangeM: PROFILE_RANGE_M}}));
  runPython(["build", "--job", jobPath, "--out", join(imageryDir, "result.json"), ...(refetch ? ["--force"] : [])]);

  const result = JSON.parse(await readFile(join(imageryDir, "result.json"), "utf8"));
  const stations: StationEdges[] = [];
  const firstPass: LapMeasurement[] = result.samples.map((s: any, i: number) => {
    const profile = {r: s.r, g: s.g, b: s.b, stepM: PROFILE_STEP_M, rangeM: PROFILE_RANGE_M};
    const m = measureWidth(profile);
    stations.push({left: edgeCandidates(profile, 1), right: edgeCandidates(profile, -1)});
    return {index: i, distanceM: i * spacingM, leftM: m.leftM, rightM: m.rightM, confidence: m.confidence, dark: m.dark};
  });
  const prior = samples.map(s => ({leftM: s.priorWl, rightM: s.priorWr}));
  const pass1 = fuseWidths(firstPass, prior, spacingM);
  // Continuity pass: expectation is the pass-1 fused series (median smoothing already kills isolated
  // outliers, so a deviant station is judged against its neighbors, not itself).
  const expectedL = pass1.leftM.map((v, i) => pass1.status[i] === "fallback" ? null : v);
  const expectedR = pass1.rightM.map((v, i) => pass1.status[i] === "fallback" ? null : v);
  const guided = continuityGuided(stations, expectedL, expectedR, firstPass);
  const guidedCount = guided.filter(g => g.guided).length;
  const measurements: LapMeasurement[] = firstPass.map((m, i) => {
    if (constantDefault) return {...m, leftM: null, rightM: null, confidence: 0};
    const g = {...m, leftM: guided[i].leftM, rightM: guided[i].rightM, confidence: guided[i].confidence};
    if (g.leftM !== null && g.rightM !== null && g.leftM + g.rightM > maxFullWidth)
      return {...g, leftM: null, rightM: null, confidence: 0};
    return g;
  });
  const cappedCount = Number.isFinite(maxFullWidth)
    ? firstPass.filter((m, i) => guided[i].leftM !== null && guided[i].rightM !== null
        && guided[i].leftM! + guided[i].rightM! > maxFullWidth).length
    : 0;
  const fused = fuseWidths(measurements, prior, spacingM);
  const measuredIdx = fused.status.map((s, i) => s === "measured" ? i : -1).filter(i => i >= 0);
  const pctMeasured = measuredIdx.length / n;
  const darkCount = measurements.filter(m => m.dark).length;
  const full = (i: number) => fused.leftM[i] + fused.rightM[i];
  const measuredFull = measuredIdx.map(full);
  const widthRange: [number, number] = measuredFull.length ? [Math.min(...measuredFull), Math.max(...measuredFull)] : [NaN, NaN];

  // Cross-validation against prior widths (meaningful when the prior is TUMFTM satellite-derived).
  let validation = "";
  if (entry.widthProvenance === "tumftm-satellite" && measuredIdx.length > 10) {
    const mv = measuredIdx.map(full), tv = measuredIdx.map(i => prior[i].leftM + prior[i].rightM);
    const r = pearson(mv, tv), mad = mv.reduce((a, v, k) => a + Math.abs(v - tv[k]), 0) / mv.length;
    validation = `TUMFTM cross-validation over ${mv.length} measured stations: Pearson r=${r.toFixed(3)}, mean |Δ full width|=${mad.toFixed(2)} m.`;
  }

  // Kerb search: corner-zone spans recomputed on the measurement grid (same curvature logic as the
  // synthetic strips), anchored to the MEASURED edge for each zone's side — synthetic strip positions
  // are too coarse to sample directly. Strips are regenerated at the measured edges so ids match the
  // search results by construction; undetected strips keep provenance "synthetic".
  const zones = cornerZoneSpans(grid as CenterlinePoint[]);
  const kerbSearch = zones.map(zone => {
    const entries: {sample: number; edgesM: number[]}[] = [];
    for (let k = zone.from; k <= zone.to; k++) {
      const i = k % n;
      const fusedEdge = zone.side === "left" ? fused.leftM[i] : fused.rightM[i];
      // Multiple anchors: the fused edge plus strong white-line candidates (the marked edge can lose the
      // pair vote to paved-apron edges, but the kerb lives at the marked line).
      const candidates = (zone.side === "left" ? stations[i].left : stations[i].right)
        .filter(c => c.kind === "white-line" && c.score >= 0.4)
        .map(c => c.offsetM);
      const edgesM = [fusedEdge];
      for (const c of candidates)
        if (edgesM.length < 3 && !edgesM.some(e => Math.abs(e - c) < 1.5)) edgesM.push(c);
      entries.push({sample: i, edgesM});
    }
    return {id: `corner-${zone.corner}-${zone.kind}`, side: zone.side, entries};
  });
  kerbDoc.kerbs = zones.map(zone => {
    const inner: {x: number; y: number}[] = [], outer: {x: number; y: number}[] = [];
    for (let k = zone.from; k <= zone.to; k++) {
      const i = k % n, p = grid[i], s = samples[i];
      const edge = zone.side === "left" ? fused.leftM[i] : fused.rightM[i];
      inner.push({x: p.x + s.nE * edge, y: p.y + s.nN * edge});
      outer.push({x: p.x + s.nE * (edge + 2), y: p.y + s.nN * (edge + 2)});
    }
    return {id: `corner-${zone.corner}-${zone.kind}`, corner: zone.corner, kind: zone.kind, side: zone.side,
      cornerDirection: zone.cornerDirection, widthM: 2, polygon: [...inner, ...outer.reverse()]};
  });
  const edgePoint = (i: number, half: number, status: PointStatus) => {
    const s = samples[i], x = grid[i].x + s.nE * half, y = grid[i].y + s.nN * half;
    return {...unprojectToLonLat(x, y, origin), status};
  };
  const measurementsPath = join(imageryDir, "measurements.json");
  const baseMeasurements = {
    centerline: samples.map(s => ({lat: s.lat, lon: s.lon})),
    left: samples.map((s, i) => edgePoint(i, fused.leftM[i], fused.status[i])),
    right: samples.map((s, i) => edgePoint(i, -fused.rightM[i], fused.status[i])),
    kerbSearch,
  };
  await writeFile(measurementsPath, JSON.stringify(baseMeasurements));
  runPython(["kerbs", "--job", jobPath, "--measurements", measurementsPath, "--out", join(imageryDir, "kerbs.json")]);
  const kerbResult = JSON.parse(await readFile(join(imageryDir, "kerbs.json"), "utf8"));

  // Kerb classification from the measured-edge search bands; detected strips adopt the observed polygon.
  const statsById = new Map<string, KerbStripStats>(kerbResult.strips.map((s: KerbStripStats) => [s.id, s]));
  let imageryKerbs = 0;
  for (const k of kerbDoc.kerbs) {
    const stats = statsById.get(k.id);
    const verdict = stats ? classifyKerb(stats) : {detected: false, confidence: 0, reason: "no pixels sampled"};
    k.provenance = verdict.detected ? "imagery" : "synthetic";
    k.detection = {detected: verdict.detected, confidence: verdict.confidence, reason: verdict.reason,
      ...(stats ? {redPixels: stats.red, whitePixels: stats.white, totalPixels: stats.total, bestRowM: stats.bestRowM} : {})};
    if (verdict.detected) {
      imageryKerbs++;
      if (stats!.polygon) {
        k.polygon = stats!.polygon.map(p => ({...projectLonLat(p.lon, p.lat, origin)}));
        k.widthM = 2;
        k.detection.note = "polygon re-localized to the red-painted band observed in imagery";
      }
    }
  }
  const kerbProvenance = imageryKerbs === 0 ? "synthetic" : imageryKerbs === kerbDoc.kerbs.length ? "imagery" : "mixed";

  // Write measured widths back onto the (non-uniform) route points by arc-length position.
  const cumulative = [0];
  for (let i = 1; i <= route.points.length; i++) {
    const a = route.points[i - 1], b = route.points[i % route.points.length];
    cumulative.push(cumulative[i - 1] + Math.hypot(b.x - a.x, b.y - a.y));
  }
  const points: Point[] = route.points.map((p, i) => {
    const idx = Math.min(n - 1, Math.round(cumulative[i] / spacingM) % n);
    return {...p, wr: Math.round(fused.rightM[idx] * 100) / 100, wl: Math.round(fused.leftM[idx] * 100) / 100};
  });

  const zooms: Record<string, number> = result.mosaic.zooms;
  const zoomLabel = Object.keys(zooms).length === 1 ? `${result.zoom}` : `${result.zoom} (fallbacks: ${JSON.stringify(zooms)})`;
  const mpp = metersPerPixel(samples[0].lat, result.zoom);
  const widthProvenance = pctMeasured >= 0.5 ? "esri-imagery" : pctMeasured > 0 ? "esri-imagery+default-fallback" : entry.widthProvenance;
  const measuredAt = new Date().toISOString();
  const imageryNote = [
    constantDefault ? "CONSTANT-DEFAULT FALLBACK (--constant-default): available Esri imagery predates circuit construction, so no width/kerb measurement was attempted; prior constant-default widths kept at every station and all kerbs remain synthetic." : null,
    cappedCount > 0 ? `Paved-apron overshoot guard (--max-full-width ${maxFullWidth} m): ${cappedCount} stations whose measured full width exceeded the cap were treated as unmeasured and fell back to prior widths.` : null,
    `Imagery measurement ${measuredAt}: ${tiles.length} tiles, mosaic ${result.mosaic.size.join("x")} px, zoom ${zoomLabel} (~${mpp.toFixed(2)} m/px at track latitude).`,
    `${(pctMeasured * 100).toFixed(1)}% of ${n} stations measured at confidence>=0.45 (${guidedCount} continuity-guided), ${fused.status.filter(s => s === "interpolated").length} interpolated over <=60 m bridges, ${fused.status.filter(s => s === "fallback").length} fell back to prior widths (${darkCount} dark/shadow-suspect stations).`,
    measuredFull.length ? `Measured full-width range ${widthRange[0].toFixed(1)}-${widthRange[1].toFixed(1)} m (median ${measuredFull.sort((a, b) => a - b)[Math.floor(measuredFull.length / 2)].toFixed(1)} m).` : "No confident measurements.",
    validation, `Kerbs: ${imageryKerbs}/${kerbDoc.kerbs.length} strips imagery-detected.`,
  ].filter(Boolean).join(" ");

  definition.routes = [{...route, points}];
  definition.provenance += constantDefault
    ? ` Esri World Imagery (${ESRI_ATTRIBUTION}) inspected ${imageryNote} Imagery predates circuit construction, so prior constant-default widths were kept (documented fallback). Still unverified; not surveyed.`
    : ` Widths re-measured from Esri World Imagery (${ESRI_ATTRIBUTION}), tiles ${ESRI_TILE_URL}, ${imageryNote} Kerbs re-classified per strip from imagery (provenance per strip). Still unverified; not surveyed.`;
  await writeFile(trackPath, JSON.stringify(definition));

  kerbDoc.synthetic = imageryKerbs === 0;
  kerbDoc.kerbProvenance = kerbProvenance;
  kerbDoc.provenance += ` Kerb strips regenerated at the measured track edges and re-classified against Esri World Imagery (${ESRI_ATTRIBUTION}) z${result.zoom}: ${imageryKerbs}/${kerbDoc.kerbs.length} strips show red/white striped painted kerbs (provenance "imagery", polygon re-localized to the observed red band); the rest remain curvature-synthetic in shape (provenance "synthetic") but follow the measured edges. Detection stats per strip under "detection".`;
  await writeFile(kerbPath, JSON.stringify(kerbDoc, null, 2));

  const fragment: ManifestFragment = {id, imageryZoom: result.zoom, imageryZooms: zooms,
    imageryAttribution: ESRI_ATTRIBUTION, imageryTiles: tiles.length, widthProvenance, kerbProvenance,
    kerbStrips: kerbDoc.kerbs.length,
    measuredWidthRangeM: measuredFull.length ? [+widthRange[0].toFixed(2), +widthRange[1].toFixed(2)] : null,
    pctMeasured: +(pctMeasured * 100).toFixed(1), imageryMeasuredAt: measuredAt, imageryNotes: imageryNote};
  if (noManifest) {
    await mkdir(qaDir, {recursive: true});
    await writeFile(fragmentPath, JSON.stringify(fragment, null, 2));
  } else {
    const {id: _circuit, ...fields} = fragment;
    Object.assign(entry, fields);
    await writeFile(manifestPath, JSON.stringify(manifestDoc, null, 2));
  }

  // QA render inputs: edge polylines with per-point status, classified strips, summary lines.
  const measurementsDoc = {...baseMeasurements,
    strips: kerbDoc.kerbs.map((k: any) => ({id: k.id, detected: k.provenance === "imagery",
      polygon: k.polygon.map((p: {x: number; y: number}) => unprojectToLonLat(p.x, p.y, origin))})),
    summaryLines: [
      `${id} — Esri World Imagery z${result.zoom} (${mpp.toFixed(2)} m/px), ${tiles.length} tiles`,
      `length ${(length / 1000).toFixed(3)} km | width ${widthRange[0].toFixed(1)}-${widthRange[1].toFixed(1)} m | measured ${(pctMeasured * 100).toFixed(0)}% (interp ${fused.status.filter(s => s === "interpolated").length}, fallback ${fused.status.filter(s => s === "fallback").length}) | kerbs ${imageryKerbs}/${kerbDoc.kerbs.length} imagery`,
    ],
  };
  await writeFile(measurementsPath, JSON.stringify(measurementsDoc));
  runPython(["render", "--job", jobPath, "--measurements", measurementsPath, "--qa", join(qaDir, `${id}.png`)]);

  rows.push(`${id} | z${result.zoom} | ${tiles.length} tiles | ${(pctMeasured * 100).toFixed(1)}% measured | width ${widthRange[0].toFixed(1)}-${widthRange[1].toFixed(1)} m | kerbs ${imageryKerbs}/${kerbDoc.kerbs.length} | ${kerbProvenance}/${widthProvenance}`);
}

console.log("circuit | zoom | tiles | measured | width range | kerbs | provenance");
for (const row of rows) console.log(row);
