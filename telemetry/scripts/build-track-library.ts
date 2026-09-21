/** Build the standalone 2026 F1 season track library: one geometry file per circuit (24 circuits from the
 *  original calendar, including cancelled Bahrain and Saudi Arabia), NOT keyed to any telemetry session.
 *  Widths come from TUMFTM racetrack-database where its layout matches the current F1 circuit (Group A)
 *  and are constant documented defaults elsewhere (Group B/C).
 *  Every emitted point carries WGS84: the bacinger/f1-circuits GeoJSON loop is the geo-referenced reference, the
 *  width-source centerline is similarity-aligned onto it, and the inverse equirectangular projection attaches
 *  lat/lon. Sources are cached under geometry/reference/ with SHA-256 recorded in the manifest. Output refuses to
 *  overwrite prior output without --force. z is 0 everywhere (no elevation source). Everything is unverified.
 *
 *  bun telemetry/scripts/build-track-library.ts [--force] [--only <circuit-id>] */
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { sha256 } from "../src/archive";
import { Route, type CircuitGeometryDefinition, type Point } from "../src/geometry";
import { alignClosedLoops, applyTransform, densifyClosed, parseCircuitGeojson, parseTumftmCsv, projectLonLat,
  resampleClosed, synthesizeKerbs, unprojectToLonLat, type CenterlinePoint, type GeoOrigin } from "../src/trackimport";

type WidthSource = {kind: "tumftm"; track: string} | {kind: "constant"; meters: number; note: string};
interface CircuitSpec {id: string; name: string; country: string; bacinger: string; width: WidthSource; notes?: string}

// Group A: TUMFTM has satellite-derived per-point widths for the current F1 layout.
// Group B: TUMFTM missing or wrong layout; bacinger centerline + constant default width.
// Group C: madrid — brand-new Madring circuit; bacinger es-2026, Overpass fallback.
const ROSTER: CircuitSpec[] = [
  {id: "melbourne", name: "Albert Park Circuit", country: "Australia", bacinger: "au-1953", width: {kind: "tumftm", track: "Melbourne"}},
  {id: "shanghai", name: "Shanghai International Circuit", country: "China", bacinger: "cn-2004", width: {kind: "tumftm", track: "Shanghai"}},
  {id: "suzuka", name: "Suzuka International Racing Course", country: "Japan", bacinger: "jp-1962", width: {kind: "tumftm", track: "Suzuka"}},
  {id: "sakhir", name: "Bahrain International Circuit", country: "Bahrain", bacinger: "bh-2002", width: {kind: "tumftm", track: "Sakhir"},
    notes: "cancelled in the 2026 calendar reshuffle; kept for the full original roster"},
  {id: "jeddah", name: "Jeddah Corniche Circuit", country: "Saudi Arabia", bacinger: "sa-2021",
    width: {kind: "constant", meters: 12, note: "12 m FIA-minimum nominal width. Cancelled in the 2026 calendar reshuffle; kept for the full original roster."}},
  {id: "montreal", name: "Circuit Gilles Villeneuve", country: "Canada", bacinger: "ca-1978", width: {kind: "tumftm", track: "Montreal"}},
  {id: "catalunya", name: "Circuit de Barcelona-Catalunya", country: "Spain", bacinger: "es-1991", width: {kind: "tumftm", track: "Catalunya"}},
  {id: "spielberg", name: "Red Bull Ring", country: "Austria", bacinger: "at-1969", width: {kind: "tumftm", track: "Spielberg"}},
  {id: "silverstone", name: "Silverstone Circuit", country: "United Kingdom", bacinger: "gb-1948", width: {kind: "tumftm", track: "Silverstone"}},
  {id: "spa", name: "Circuit de Spa-Francorchamps", country: "Belgium", bacinger: "be-1925", width: {kind: "tumftm", track: "Spa"}},
  {id: "budapest", name: "Hungaroring", country: "Hungary", bacinger: "hu-1986", width: {kind: "tumftm", track: "Budapest"}},
  {id: "monza", name: "Autodromo Nazionale Monza", country: "Italy", bacinger: "it-1922", width: {kind: "tumftm", track: "Monza"}},
  {id: "austin", name: "Circuit of the Americas", country: "United States", bacinger: "us-2012", width: {kind: "tumftm", track: "Austin"}},
  {id: "mexico-city", name: "Autódromo Hermanos Rodríguez", country: "Mexico", bacinger: "mx-1962", width: {kind: "tumftm", track: "MexicoCity"}},
  {id: "sao-paulo", name: "Autódromo José Carlos Pace (Interlagos)", country: "Brazil", bacinger: "br-1940", width: {kind: "tumftm", track: "SaoPaulo"}},
  {id: "zandvoort", name: "Circuit Zandvoort", country: "Netherlands", bacinger: "nl-1948",
    width: {kind: "constant", meters: 12, note: "TUMFTM Zandvoort.csv is believed to be the pre-2020 DTM layout; bacinger F1 centerline used for geometry, 12 m FIA-minimum nominal width."}},
  {id: "monaco", name: "Circuit de Monaco", country: "Monaco", bacinger: "mc-1929",
    width: {kind: "constant", meters: 11, note: "Street circuit narrower than the FIA 12 m minimum in places; 11 m nominal."}},
  {id: "miami", name: "Miami International Autodrome", country: "United States", bacinger: "us-2022",
    width: {kind: "constant", meters: 12, note: "12 m FIA-minimum nominal width."}},
  {id: "baku", name: "Baku City Circuit", country: "Azerbaijan", bacinger: "az-2016",
    width: {kind: "constant", meters: 10, note: "10 m nominal; the old-town section narrows to ~7.6 m, so this default is optimistic there."}},
  {id: "singapore", name: "Marina Bay Street Circuit", country: "Singapore", bacinger: "sg-2008",
    width: {kind: "constant", meters: 12, note: "12 m FIA-minimum nominal width."}},
  {id: "las-vegas", name: "Las Vegas Strip Circuit", country: "United States", bacinger: "us-2023",
    width: {kind: "constant", meters: 12, note: "12 m nominal; the Strip itself is wider, but 12 m keeps overlays on the racing line corridor."}},
  {id: "lusail", name: "Lusail International Circuit", country: "Qatar", bacinger: "qa-2004",
    width: {kind: "constant", meters: 12, note: "12 m FIA-minimum nominal width."}},
  {id: "yas-marina", name: "Yas Marina Circuit", country: "United Arab Emirates", bacinger: "ae-2009",
    width: {kind: "constant", meters: 12, note: "TUMFTM YasMarina.csv exists but predates the 2021 reprofiling; bacinger ae-2009 matches the current 5.281 km layout. 12 m nominal width."}},
  {id: "madrid", name: "Circuito de Madring", country: "Spain", bacinger: "es-2026",
    width: {kind: "constant", meters: 12, note: "Brand-new hybrid circuit (first race 2026); no measured widths exist anywhere. 12 m FIA-minimum nominal width."},
    notes: "verify name/coordinates; Overpass fallback if bacinger lacks it"},
];

const args = process.argv.slice(2);
const force = args.includes("--force");
const only = (() => {const i = args.indexOf("--only"); return i === -1 ? undefined : args[i + 1];})();
const MAX_RMS = 15;
const referenceDir = join(import.meta.dir, "../geometry/reference");
const outDir = join(import.meta.dir, "../geometry/tracks2026");

async function load(cacheName: string, url: string): Promise<{body: string; sha256: string; url: string; cache: string}> {
  const cachePath = join(referenceDir, cacheName);
  let body: string;
  if (existsSync(cachePath)) body = await readFile(cachePath, "utf8");
  else {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Download failed: ${response.status} ${url}`);
    body = await response.text();
    await mkdir(referenceDir, {recursive: true});
    await writeFile(cachePath, body);
  }
  return {body, sha256: sha256(body), url, cache: cacheName};
}

/** Overpass fallback for circuits absent from bacinger: highway=raceway ways near (lat, lon), stitched into the
 *  longest closed loop by matching way endpoints. Returns null when no usable closed loop exists. */
async function fetchOverpassLoop(lat: number, lon: number, cacheName: string): Promise<{points: CenterlinePoint[]; origin: GeoOrigin; source: {url: string; sha256: string; cache: string}} | null> {
  const d = 0.03, url = "https://overpass-api.de/api/interpreter";
  const query = `[out:json];way["highway"="raceway"](${lat - d},${lon - d},${lat + d},${lon + d});out geom;`;
  const cachePath = join(referenceDir, cacheName);
  let body: string;
  if (existsSync(cachePath)) body = await readFile(cachePath, "utf8");
  else {
    const response = await fetch(url, {method: "POST", body: "data=" + encodeURIComponent(query)});
    if (!response.ok) return null;
    body = await response.text();
    await mkdir(referenceDir, {recursive: true});
    await writeFile(cachePath, body);
  }
  const source = {url: `${url} data=${query}`, sha256: sha256(body), cache: cacheName};
  const doc = JSON.parse(body);
  const ways: {lat: number; lon: number}[][] = (doc.elements ?? [])
    .filter((e: any) => e?.type === "way" && Array.isArray(e.geometry) && e.geometry.length >= 3)
    .map((e: any) => e.geometry.map((g: any) => ({lat: g.lat, lon: g.lon})));
  const near = (a: {lat: number; lon: number}, b: {lat: number; lon: number}) => Math.hypot(a.lat - b.lat, a.lon - b.lon) < 1e-5;
  // Greedily stitch ways into chains by shared endpoints; keep the longest closed chain.
  let best: {lat: number; lon: number}[] | null = null;
  for (let start = 0; start < ways.length; start++) {
    const used = new Set([start]);
    let chain = ways[start].slice();
    for (;;) {
      let extended = false;
      for (let w = 0; w < ways.length && !extended; w++) {
        if (used.has(w)) continue;
        const way = ways[w], head = chain[0], tail = chain[chain.length - 1];
        if (near(tail, way[0])) {chain = chain.concat(way.slice(1)); used.add(w); extended = true;}
        else if (near(tail, way[way.length - 1])) {chain = chain.concat(way.slice(0, -1).reverse()); used.add(w); extended = true;}
        else if (near(head, way[way.length - 1])) {chain = way.slice(0, -1).concat(chain); used.add(w); extended = true;}
        else if (near(head, way[0])) {chain = way.slice(1).reverse().concat(chain); used.add(w); extended = true;}
      }
      if (!extended) break;
    }
    if (chain.length >= 8 && near(chain[0], chain[chain.length - 1]) && (!best || chain.length > best.length)) best = chain;
  }
  if (!best) return null;
  const origin: GeoOrigin = {lat0: best.reduce((a, p) => a + p.lat, 0) / best.length, lon0: best.reduce((a, p) => a + p.lon, 0) / best.length};
  const half = 6;
  return {origin, source, points: best.slice(0, -1).map(p => ({...projectLonLat(p.lon, p.lat, origin), wr: half, wl: half}))};
}

interface ManifestEntry {
  id: string; name: string; country: string; status: "ok" | "missing";
  sources: {url: string; sha256: string; cache: string}[];
  widthProvenance?: "tumftm-satellite" | "constant-default"; widthNote?: string;
  alignmentRms?: number; alignmentWarning?: string;
  lengthM?: number; points?: number; confidence?: number; kerbStrips?: number;
  verified: false; detail?: string;
}

const circuits = only ? ROSTER.filter(c => c.id === only) : ROSTER;
if (circuits.length === 0) throw new Error(`Unknown circuit id: ${only}`);
const manifest: ManifestEntry[] = [];
const qa: string[] = [];

for (const spec of circuits) {
  const outPath = join(outDir, `${spec.id}.json`), kerbPath = join(outDir, `${spec.id}.kerbs.json`);
  if ((existsSync(outPath) || existsSync(kerbPath)) && !force) throw new Error(`${outPath} or ${kerbPath} exists; pass --force to overwrite`);
  const sources: {url: string; sha256: string; cache: string}[] = [];
  // Geo-referenced reference loop: bacinger GeoJSON (equirectangular projection). Madrid falls back to Overpass.
  let geo: {name: string; origin: GeoOrigin; points: CenterlinePoint[]} | null = null;
  let geoSourceLabel = "bacinger/f1-circuits";
  let overpassAttempted = false;
  try {
    const bac = await load(`bacinger-${spec.bacinger}.geojson`, `https://raw.githubusercontent.com/bacinger/f1-circuits/master/circuits/${spec.bacinger}.geojson`);
    sources.push({url: bac.url, sha256: bac.sha256, cache: bac.cache});
    const constantWidth = spec.width.kind === "constant" ? spec.width.meters : 12;
    const parsed = parseCircuitGeojson(bac.body, constantWidth);
    if (spec.id === "madrid") {
      const c = parsed.points[0];
      if (!/madring|madrid/i.test(parsed.name)) throw new Error(`bacinger ${spec.bacinger}: unexpected name "${parsed.name}"`);
      const ll = unprojectToLonLat(c.x, c.y, parsed.origin);
      if (Math.hypot(ll.lat - 40.465, ll.lon + 3.617) > 0.05) throw new Error(`bacinger ${spec.bacinger}: coordinates not near IFEMA Madrid`);
    }
    geo = parsed;
  } catch (error) {
    if (spec.id !== "madrid") throw error;
    overpassAttempted = true;
    const overpass = await fetchOverpassLoop(40.465, -3.617, "overpass-madrid-raceway.json");
    if (overpass) {
      sources.push(overpass.source);
      geoSourceLabel = "OpenStreetMap via Overpass (highway=raceway)";
      geo = {name: spec.name, origin: overpass.origin, points: overpass.points};
    }
  }
  if (!geo) {
    manifest.push({id: spec.id, name: spec.name, country: spec.country, status: "missing", sources, verified: false,
      detail: `MISSING: bacinger ${spec.bacinger} unusable${overpassAttempted ? " and Overpass highway=raceway query near 40.465N 3.617W yielded no closed loop" : ""}. No geometry fabricated.`});
    qa.push(`${spec.id} | none | - | - | - | 0 | MISSING`);
    continue;
  }

  let points: Point[], rms: number, reversed = false, scale = 1, offset = 0, samples = 0;
  let widthProvenance: ManifestEntry["widthProvenance"], widthNote: string | undefined, widthRange: [number, number];
  let kerbLoop: CenterlinePoint[], alignmentPart: string;
  if (spec.width.kind === "tumftm") {
    const tum = await load(`tumftm-${spec.width.track}.csv`, `https://raw.githubusercontent.com/TUMFTM/racetrack-database/master/tracks/${spec.width.track}.csv`);
    sources.push({url: tum.url, sha256: tum.sha256, cache: tum.cache});
    const source = parseTumftmCsv(tum.body);
    const alignment = alignClosedLoops(source, geo.points);
    ({rms, reversed, offset, samples} = alignment);
    scale = alignment.transform.scale;
    points = densifyClosed(source).map(p => {
      const q = applyTransform(p, alignment.transform);
      return {x: q.x, y: q.y, z: 0, wr: reversed ? p.wl : p.wr, wl: reversed ? p.wr : p.wl, ...unprojectToLonLat(q.x, q.y, geo.origin)};
    });
    kerbLoop = alignment.reference.map(p => applyTransform(p, alignment.transform));
    const half = source.flatMap(p => [p.wr, p.wl]);
    widthRange = [Math.min(...half), Math.max(...half)];
    widthProvenance = "tumftm-satellite";
    alignmentPart = `Similarity-aligned to the bacinger loop: RMS ${rms.toFixed(2)} m over ${samples} arc-length samples, scale ${scale.toFixed(4)}, ${reversed ? "reversed" : "matching"} direction, phase offset ${offset}. Widths: TUMFTM satellite-derived per-point left/right widths (half-width range ${widthRange[0].toFixed(2)}–${widthRange[1].toFixed(2)} m).`;
  } else {
    rms = 0;
    points = densifyClosed(geo.points).map(p => ({x: p.x, y: p.y, z: 0, wr: p.wr, wl: p.wl, ...unprojectToLonLat(p.x, p.y, geo.origin)}));
    kerbLoop = resampleClosed(geo.points, 4096);
    widthRange = [spec.width.meters / 2, spec.width.meters / 2];
    widthProvenance = "constant-default";
    widthNote = spec.width.note;
    alignmentPart = `Centerline is the bacinger loop itself (no alignment needed). Widths: constant ${spec.width.meters} m default (${spec.width.note}) — the source has no measured widths.`;
  }

  // Zandvoort diagnostic: quantify how wrong the TUMFTM DTM layout is against the bacinger F1 layout.
  let zandvoortNote = "";
  if (spec.id === "zandvoort") {
    const tum = await load("tumftm-Zandvoort.csv", "https://raw.githubusercontent.com/TUMFTM/racetrack-database/master/tracks/Zandvoort.csv");
    sources.push({url: tum.url, sha256: tum.sha256, cache: tum.cache});
    const check = alignClosedLoops(parseTumftmCsv(tum.body), geo.points);
    zandvoortNote = ` TUMFTM Zandvoort.csv cross-check fits the bacinger F1 loop at ${check.rms.toFixed(2)} m RMS — centerlines agree closely, so the CSV is not a grossly different layout, but its pre-2020 DTM provenance means its widths may not match the reprofiled banked corners; rejected as width source per roster policy.`;
    widthNote = (widthNote ?? "") + zandvoortNote;
  }

  const route = {id: "track", kind: "track" as const, closed: true, points};
  const checked = new Route(route); // validates finiteness and <=100 m segments
  const lengthM = Math.round(checked.length);
  const confidence = Math.min(.8, Math.max(.3, Math.round((.85 - rms * .03) * 100) / 100));
  const alignmentWarning = spec.width.kind === "tumftm" && rms > MAX_RMS
    ? `TUMFTM-to-bacinger fit RMS ${rms.toFixed(2)} m exceeds ${MAX_RMS} m; emitted anyway, treat layout agreement as suspect` : undefined;
  const definition: CircuitGeometryDefinition = {version: 1, circuit: spec.id, name: spec.name, country: spec.country,
    metersPerUnit: 1, confidence, verified: false, projection: {lat0: geo.origin.lat0, lon0: geo.origin.lon0},
    provenance: `${geoSourceLabel} ${sources[0].url} sha256:${sources[0].sha256} (WGS84 reference centerline "${geo.name}", equirectangular projection about lat0=${geo.origin.lat0.toFixed(6)}, lon0=${geo.origin.lon0.toFixed(6)}). ` +
      (spec.width.kind === "tumftm" ? `TUMFTM racetrack-database ${sources[1].url} sha256:${sources[1].sha256}. ` : "") +
      `${alignmentPart} z = 0 everywhere (no elevation source). Local x/y are meters in the projection frame; lat/lon are the inverse projection of the aligned centerline.${zandvoortNote} ` +
      `Unverified; start/finish approximate; not surveyed.`,
    routes: [route]};
  await mkdir(outDir, {recursive: true});
  await writeFile(outPath, JSON.stringify(definition));

  const kerbs = synthesizeKerbs(kerbLoop);
  await writeFile(kerbPath, JSON.stringify({version: 1, circuit: spec.id, synthetic: true,
    provenance: `Synthetic kerbs synthesized from curvature of tracks2026/${spec.id}.json centerline (curvature >= 0.012/m, 2 m strips at track edge). NOT measured geometry. Same local meter frame and equirectangular projection as the circuit file.`,
    kerbs}, null, 2));

  manifest.push({id: spec.id, name: spec.name, country: spec.country, status: "ok", sources,
    widthProvenance, ...(widthNote ? {widthNote} : {}), alignmentRms: +rms.toFixed(3),
    ...(alignmentWarning ? {alignmentWarning} : {}), lengthM, points: points.length, confidence,
    kerbStrips: kerbs.length, verified: false});
  qa.push(`${spec.id} | ${spec.width.kind === "tumftm" ? "tumftm+bacinger" : "bacinger"} | ${(widthRange[0] * 2).toFixed(1)}-${(widthRange[1] * 2).toFixed(1)} m | ${(lengthM / 1000).toFixed(3)} km | ${rms.toFixed(2)} m | ${kerbs.length} | ${alignmentWarning ? "WARN" : "ok"}`);
}

const manifestPath = join(outDir, "manifest.json");
if (existsSync(manifestPath)) {
  // Merge: keep entries for circuits not rebuilt this run.
  const prior: {circuits: ManifestEntry[]} = JSON.parse(await readFile(manifestPath, "utf8"));
  const rebuilt = new Set(manifest.map(m => m.id));
  manifest.push(...prior.circuits.filter(m => !rebuilt.has(m.id)));
}
manifest.sort((a, b) => ROSTER.findIndex(c => c.id === a.id) - ROSTER.findIndex(c => c.id === b.id));
await mkdir(outDir, {recursive: true});
await writeFile(manifestPath, JSON.stringify({version: 1, generated: new Date().toISOString(),
  note: "2026 F1 season track library (24 circuits from the original calendar, including cancelled Bahrain and Saudi Arabia). Standalone per-circuit geometry: local meter frame + per-point WGS84. Widths satellite-derived where TUMFTM-sourced, constant defaults elsewhere; kerbs synthetic; z = 0; all verified: false.",
  circuits: manifest}, null, 2));

console.log("circuit | source | width range | length | align RMS | #kerbs | status");
for (const row of qa) console.log(row);
console.log(`manifest: ${manifestPath}`);
