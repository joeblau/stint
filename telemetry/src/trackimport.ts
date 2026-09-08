/** Import of external open circuit geometry (TUMFTM racetrack-database CSV, bacinger/f1-circuits GeoJSON)
 *  and its alignment into a session's experimental local meter frame. Everything here is pure:
 *  no network, no filesystem — the CLI in scripts/import-geometry.ts does IO. */
import { wrap, type Point } from "./geometry";

const distance = (a: {x: number; y: number}, b: {x: number; y: number}) => Math.hypot(a.x - b.x, a.y - b.y);

export interface CenterlinePoint { x: number; y: number; wr: number; wl: number }
export interface SimilarityTransform { scale: number; cos: number; sin: number; tx: number; ty: number }
export interface AlignmentResult {
  transform: SimilarityTransform; rms: number; reversed: boolean; offset: number; samples: number;
  /** Reference resampled uniformly along arc length, in source coordinates, original traversal order. */
  reference: CenterlinePoint[];
}
export interface KerbStrip { id: string; corner: number; kind: "apex-inside" | "exit-outside"; side: "left" | "right"; cornerDirection: "left" | "right"; widthM: number; polygon: {x: number; y: number}[] }

const finite = (v: number) => Number.isFinite(v);

/** TUMFTM racetrack-database track CSV: one `# x_m,y_m,w_tr_right_m,w_tr_left_m` header comment, then rows. */
export function parseTumftmCsv(text: string): CenterlinePoint[] {
  const points: CenterlinePoint[] = [];
  for (const [lineNumber, raw] of text.split("\n").entries()) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const fields = line.split(",").map(Number);
    if (fields.length !== 4 || !fields.every(finite)) throw new Error(`TUMFTM CSV line ${lineNumber + 1}: expected 4 finite numbers`);
    const [x, y, wr, wl] = fields;
    if (wr <= 0 || wl <= 0) throw new Error(`TUMFTM CSV line ${lineNumber + 1}: non-positive width`);
    points.push({x, y, wr, wl});
  }
  if (points.length < 3) throw new Error("TUMFTM CSV: too few centerline points");
  return points;
}

/** Equirectangular projection origin (mean latitude/longitude of the source coordinates). */
export interface GeoOrigin { lat0: number; lon0: number }
const METERS_PER_DEGREE = Math.PI * 6378137 / 180;
export const projectLonLat = (lon: number, lat: number, origin: GeoOrigin): {x: number; y: number} =>
  ({x: (lon - origin.lon0) * Math.cos(origin.lat0 * Math.PI / 180) * METERS_PER_DEGREE, y: (lat - origin.lat0) * METERS_PER_DEGREE});
export const unprojectToLonLat = (x: number, y: number, origin: GeoOrigin): {lat: number; lon: number} =>
  ({lat: y / METERS_PER_DEGREE + origin.lat0, lon: x / (Math.cos(origin.lat0 * Math.PI / 180) * METERS_PER_DEGREE) + origin.lon0});

/** bacinger/f1-circuits GeoJSON: a LineString of [lon, lat]; projected equirectangularly about the mean latitude.
 *  No measured widths exist there, so a constant total width is split evenly left/right.
 *  The projection origin is returned so local-meter points can be mapped back to WGS84 via unprojectToLonLat. */
export function parseCircuitGeojson(text: string, defaultWidthM: number): {name: string; lengthM?: number; origin: GeoOrigin; points: CenterlinePoint[]} {
  if (!(defaultWidthM >= 4 && defaultWidthM <= 30)) throw new Error("default width must be within 4..30 m");
  const doc = JSON.parse(text);
  const feature = (doc.features ?? []).find((f: any) => f?.geometry?.type === "LineString");
  if (!feature) throw new Error("GeoJSON: no LineString feature found");
  const coordinates: number[][] = feature.geometry.coordinates;
  if (!Array.isArray(coordinates) || coordinates.length < 3 || !coordinates.every(c => Array.isArray(c) && c.length >= 2 && c.every(finite)))
    throw new Error("GeoJSON: invalid LineString coordinates");
  const origin: GeoOrigin = {lat0: coordinates.reduce((a, c) => a + c[1], 0) / coordinates.length,
    lon0: coordinates.reduce((a, c) => a + c[0], 0) / coordinates.length};
  const half = defaultWidthM / 2;
  const points = coordinates.map(([lon, lat]) => ({...projectLonLat(lon, lat, origin), wr: half, wl: half}));
  return {name: feature.properties?.Name ?? "unknown", lengthM: feature.properties?.length, origin, points};
}

/** Uniform arc-length resampling of a closed loop. Extra numeric fields (wr, wl, z) are linearly interpolated. */
export function resampleClosed<T extends {x: number; y: number}>(points: T[], n: number): T[] {
  if (points.length < 3 || n < 8) throw new Error("resampleClosed: need >=3 points and >=8 samples");
  const count = points.length, cumulative = [0];
  for (let i = 1; i <= count; i++) cumulative.push(cumulative[i - 1] + distance(points[i - 1], points[i % count]));
  const length = cumulative[count], step = length / n, result: T[] = [];
  let segment = 0;
  for (let i = 0; i < n; i++) {
    const d = i * step;
    while (segment < count - 1 && cumulative[segment + 1] < d) segment++;
    const a = points[segment], b = points[(segment + 1) % count];
    const f = (d - cumulative[segment]) / (cumulative[segment + 1] - cumulative[segment] || 1);
    const out: any = {x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f};
    for (const key of ["wr", "wl", "z"] as const)
      if (typeof (a as any)[key] === "number" && typeof (b as any)[key] === "number") out[key] = (a as any)[key] + ((b as any)[key] - (a as any)[key]) * f;
    result.push(out);
  }
  return result;
}

export const applyTransform = <T extends {x: number; y: number}>(p: T, t: SimilarityTransform): T =>
  ({...p, x: t.scale * (t.cos * p.x - t.sin * p.y) + t.tx, y: t.scale * (t.sin * p.x + t.cos * p.y) + t.ty});

/** Insert linearly interpolated points (widths included) so no segment of a closed loop exceeds maxStep meters. */
export function densifyClosed(points: CenterlinePoint[], maxStep = 25): CenterlinePoint[] {
  const dense: CenterlinePoint[] = [];
  for (let i = 0; i < points.length; i++) {
    const a = points[i], b = points[(i + 1) % points.length];
    dense.push(a);
    const span = Math.hypot(b.x - a.x, b.y - a.y), parts = Math.ceil(span / maxStep);
    for (let k = 1; k < parts; k++)
      dense.push({x: a.x + (b.x - a.x) * k / parts, y: a.y + (b.y - a.y) * k / parts,
        wr: a.wr + (b.wr - a.wr) * k / parts, wl: a.wl + (b.wl - a.wl) * k / parts});
  }
  return dense;
}

/** Optimal similarity fit (no reflection) mapping source onto target, index-corresponded. */
export function fitSimilarity(source: {x: number; y: number}[], target: {x: number; y: number}[]): {transform: SimilarityTransform; rms: number} {
  const n = source.length;
  if (n !== target.length || n < 3) throw new Error("fitSimilarity: equal length >=3 required");
  const mean = (ps: {x: number; y: number}[]) => ({x: ps.reduce((a, p) => a + p.x, 0) / n, y: ps.reduce((a, p) => a + p.y, 0) / n});
  const cs = mean(source), ct = mean(target);
  let sre = 0, sim = 0, ss = 0, st = 0;
  for (let i = 0; i < n; i++) {
    const px = source[i].x - cs.x, py = source[i].y - cs.y, qx = target[i].x - ct.x, qy = target[i].y - ct.y;
    sre += qx * px + qy * py; sim += qy * px - qx * py; ss += px * px + py * py; st += qx * qx + qy * qy;
  }
  if (ss < 1e-9) throw new Error("fitSimilarity: degenerate source");
  const magnitude = Math.hypot(sre, sim), scale = magnitude / ss, cos = sre / magnitude, sin = sim / magnitude;
  const rms = Math.sqrt(Math.max(0, (st - magnitude * magnitude / ss) / n));
  return {transform: {scale, cos, sin, tx: ct.x - scale * (cos * cs.x - sin * cs.y), ty: ct.y - scale * (sin * cs.x + cos * cs.y)}, rms};
}

/** Align two closed loops by searching phase offset and traversal direction, keeping the best similarity fit.
 *  Centroids are phase-invariant on a closed loop, so each candidate costs one O(n) cross-correlation sum. */
export function alignClosedLoops(reference: CenterlinePoint[], target: {x: number; y: number}[], samples = 4096): AlignmentResult {
  const q = resampleClosed(target, samples);
  const cq = {x: q.reduce((a, p) => a + p.x, 0) / samples, y: q.reduce((a, p) => a + p.y, 0) / samples};
  const qx = q.map(p => p.x - cq.x), qy = q.map(p => p.y - cq.y);
  const st = qx.reduce((a, v, i) => a + v * v + qy[i] * qy[i], 0);
  let best: AlignmentResult | undefined;
  for (const reversed of [false, true]) {
    const ordered = reversed ? reference.slice().reverse() : reference;
    const p = resampleClosed(ordered, samples);
    const cp = {x: p.reduce((a, v) => a + v.x, 0) / samples, y: p.reduce((a, v) => a + v.y, 0) / samples};
    const px = p.map(v => v.x - cp.x), py = p.map(v => v.y - cp.y);
    const ss = px.reduce((a, v, i) => a + v * v + py[i] * py[i], 0);
    if (ss < 1e-9) throw new Error("alignClosedLoops: degenerate reference");
    for (let offset = 0; offset < samples; offset++) {
      let sre = 0, sim = 0;
      for (let i = 0; i < samples; i++) {
        const j = (i + offset) % samples;
        sre += qx[i] * px[j] + qy[i] * py[j]; sim += qy[i] * px[j] - qx[i] * py[j];
      }
      const magnitude = Math.hypot(sre, sim);
      const rms = Math.sqrt(Math.max(0, (st - magnitude * magnitude / ss) / samples));
      if (!best || rms < best.rms) {
        const scale = magnitude / ss, cos = sre / magnitude, sin = sim / magnitude;
        best = {rms, reversed, offset, samples, reference: reversed ? p : resampleClosed(reference, samples),
          transform: {scale, cos, sin, tx: cq.x - scale * (cos * cp.x - sin * cp.y), ty: cq.y - scale * (sin * cp.x + cos * cp.y)}};
      }
    }
  }
  // ICP refinement: point-to-polyline correspondence removes phase quantization and arc-length mismatch.
  const ref = best!.reference;
  let transform = best!.transform, rms = best!.rms;
  for (let iteration = 0; iteration < 5; iteration++) {
    const mapped = ref.map(p => applyTransform(p, transform));
    const correspondence = mapped.map(m => {
      let bestPoint = q[0], d = Infinity;
      for (let s = 0; s < samples; s++) {
        const a = q[s], b = q[(s + 1) % samples], dx = b.x - a.x, dy = b.y - a.y;
        const f = Math.max(0, Math.min(1, ((m.x - a.x) * dx + (m.y - a.y) * dy) / (dx * dx + dy * dy || 1)));
        const point = {x: a.x + dx * f, y: a.y + dy * f}, h = distance(m, point);
        if (h < d) {d = h; bestPoint = point;}
      }
      return bestPoint;
    });
    const fit = fitSimilarity(mapped, correspondence);
    if (fit.rms >= rms - 1e-6) break;
    transform = compose(fit.transform, transform);
    rms = fit.rms;
  }
  return {...best!, transform, rms};
}

/** Similarity composition: apply b, then a. */
export function compose(a: SimilarityTransform, b: SimilarityTransform): SimilarityTransform {
  return {scale: a.scale * b.scale,
    cos: a.cos * b.cos - a.sin * b.sin, sin: a.sin * b.cos + a.cos * b.sin,
    tx: a.scale * (a.cos * b.tx - a.sin * b.ty) + a.tx,
    ty: a.scale * (a.sin * b.tx + a.cos * b.ty) + a.ty};
}

/** Curvature (1/m) of a uniformly resampled closed loop, lightly smoothed. Positive = turning left. */
export function curvatureProfile(points: {x: number; y: number}[], smoothing = 3): {kappa: number[]; ds: number} {
  const n = points.length;
  let length = 0;
  for (let i = 0; i < n; i++) length += distance(points[i], points[(i + 1) % n]);
  const ds = length / n, headings: number[] = [];
  for (let i = 0; i < n; i++) {
    const a = points[(i - 1 + n) % n], b = points[(i + 1) % n];
    headings.push(Math.atan2(b.y - a.y, b.x - a.x));
  }
  const raw = headings.map((h, i) => wrap(h - headings[(i - 1 + n) % n] + Math.PI, 2 * Math.PI) / ds - Math.PI / ds);
  const kappa = raw.map((_, i) => {
    let sum = 0;
    for (let k = -smoothing; k <= smoothing; k++) sum += raw[(i + k + n) % n];
    return sum / (2 * smoothing + 1);
  });
  return {kappa, ds};
}

/** Synthetic kerb strips from centerline curvature: an inside strip around each corner apex and an outside
 *  strip at each corner exit, ~widthM wide, offset outward from the track edge. NOT measured geometry. */
export function synthesizeKerbs(loop: CenterlinePoint[], options: {minCurvature?: number; widthM?: number; minCornerM?: number; mergeGapM?: number} = {}): KerbStrip[] {
  const kMin = options.minCurvature ?? 0.012, widthM = options.widthM ?? 2;
  const n = loop.length;
  if (n < 32) throw new Error("synthesizeKerbs: loop too coarse");
  const {kappa, ds} = curvatureProfile(loop);
  const inCorner = kappa.map(k => Math.abs(k) >= kMin);
  const minLen = Math.max(2, Math.round((options.minCornerM ?? 15) / ds));
  const mergeGap = Math.round((options.mergeGapM ?? 20) / ds);
  // Bridge short straight gaps inside a corner complex.
  for (let i = 0; i < n; i++) if (!inCorner[i]) {
    let gap = 0;
    while (gap < n && !inCorner[(i + gap) % n]) gap++;
    if (gap > 0 && gap <= mergeGap && inCorner[(i - 1 + n) % n] && gap < n)
      for (let k = 0; k < gap; k++) inCorner[(i + k) % n] = true;
    i += gap;
  }
  // Circular contiguous runs.
  const runs: [number, number][] = []; // [start, length) in unwrapped index space
  let anchor = inCorner.findIndex(v => !v); // start walk on a straight so runs do not straddle index 0
  if (anchor === -1) anchor = 0;
  let i = 0;
  while (i < n) {
    const at = (anchor + i) % n;
    if (inCorner[at]) {
      let len = 0;
      while (len < n - i && inCorner[(anchor + i + len) % n]) len++;
      runs.push([at, len]); i += len;
    } else i++;
  }
  const kerbs: KerbStrip[] = [];
  let corner = 0;
  for (const [start, len] of runs) {
    if (len < minLen) continue;
    corner++;
    const at = (k: number) => loop[(start + k) % n];
    const sign = Math.sign(Array.from({length: len}, (_, k) => kappa[(start + k) % n]).reduce((a, b) => a + b, 0)) || 1;
    let apex = 0, peak = 0;
    for (let k = 0; k < len; k++) if (Math.abs(kappa[(start + k) % n]) > peak) {peak = Math.abs(kappa[(start + k) % n]); apex = k;}
    const normals = (k: number) => {
      const a = at(k), b = at(k + 1), h = Math.hypot(b.x - a.x, b.y - a.y) || 1;
      return {left: {x: -(b.y - a.y) / h, y: (b.x - a.x) / h}, right: {x: (b.y - a.y) / h, y: -(b.x - a.x) / h}};
    };
    const strip = (from: number, to: number, side: "left" | "right", kind: KerbStrip["kind"]): KerbStrip => {
      const inner: {x: number; y: number}[] = [], outer: {x: number; y: number}[] = [];
      for (let k = from; k <= to; k++) {
        const p = at(k), normal = normals(k)[side], edge = side === "left" ? p.wl : p.wr;
        inner.push({x: p.x + normal.x * edge, y: p.y + normal.y * edge});
        outer.push({x: p.x + normal.x * (edge + widthM), y: p.y + normal.y * (edge + widthM)});
      }
      return {id: `corner-${corner}-${kind}`, corner, kind, side, cornerDirection: sign > 0 ? "left" : "right", widthM, polygon: [...inner, ...outer.reverse()]};
    };
    const inside = sign > 0 ? "left" : "right", outside = sign > 0 ? "right" : "left";
    const halfApex = Math.max(2, Math.min(Math.round(len / 4), Math.round(25 / ds)));
    kerbs.push(strip(Math.max(0, apex - halfApex), Math.min(len - 1, apex + halfApex), inside, "apex-inside"));
    const exitBack = Math.max(2, Math.min(Math.round(len * .3), Math.round(30 / ds))), exitFwd = Math.round(10 / ds);
    kerbs.push(strip(Math.max(0, len - 1 - exitBack), len - 1 + exitFwd, outside, "exit-outside"));
  }
  return kerbs;
}

/** Nearest experimental-frame point, used to donate z (sources carry no elevation). */
export function nearestZ(p: {x: number; y: number}, experimental: Point[]): {z: number; horizontal: number} {
  let best = experimental[0], d = Infinity;
  for (const e of experimental) {const h = distance(p, e); if (h < d) {d = h; best = e;}}
  return {z: best.z, horizontal: d};
}
