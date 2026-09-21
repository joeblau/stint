/** Satellite-imagery measurement math: Web-Mercator tile geometry, track-edge detection from sampled RGB
 *  cross-profiles, width smoothing/interpolation, kerb-strip classification and cross-validation statistics.
 *  Everything here is pure: no network, no filesystem, no image decoding. The Python worker
 *  (scripts/imagery/measure.py) does tile download, mosaicking and pixel sampling; this module turns the
 *  sampled numbers into measured widths and kerb decisions. Unit-tested offline on synthetic profiles. */

export const ESRI_ATTRIBUTION = "Esri, Maxar, Earthstar Geographics, and the GIS User Community";
export const ESRI_TILE_URL = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile";

/** Full-width plausibility band (m). Half-widths are scanned within [HALF_MIN, HALF_MAX]; the band is
 *  enforced on the full width at pair level because reference centerlines are not necessarily centered. */
export const HALF_WIDTH_MIN = 2;
export const HALF_WIDTH_MAX = 15;
/** Cross-profile sampling: +/-PROFILE_RANGE_M at PROFILE_STEP_M. */
export const PROFILE_RANGE_M = 25;
export const PROFILE_STEP_M = 0.25;

// ---------------------------------------------------------------- Web-Mercator tile math

export const metersPerPixel = (latDeg: number, z: number) =>
  156543.03392 * Math.cos(latDeg * Math.PI / 180) / Math.pow(2, z);

/** Global pixel coordinates at zoom z (x right/east, y down/south), range [0, 256*2^z). */
export function lonLatToGlobalPx(lon: number, lat: number, z: number): {x: number; y: number} {
  const clamped = Math.max(-85.05112878, Math.min(85.05112878, lat));
  const s = Math.sin(clamped * Math.PI / 180), n = Math.pow(2, z);
  return {x: (lon + 180) / 360 * 256 * n, y: (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * 256 * n};
}

export interface TileRef {z: number; x: number; y: number}

/** Set of z-tiles intersecting discs of bufferM around each lon/lat point (deduplicated). */
export function tilesForBuffer(points: {lon: number; lat: number}[], bufferM: number, z: number): TileRef[] {
  const tiles = new Map<string, TileRef>();
  const maxTile = Math.pow(2, z) - 1;
  for (const p of points) {
    const mpp = metersPerPixel(p.lat, z), c = lonLatToGlobalPx(p.lon, p.lat, z), r = bufferM / mpp;
    for (let x = Math.floor((c.x - r) / 256); x <= Math.floor((c.x + r) / 256); x++)
      for (let y = Math.floor((c.y - r) / 256); y <= Math.floor((c.y + r) / 256); y++)
        if (x >= 0 && y >= 0 && x <= maxTile && y <= maxTile) tiles.set(`${x},${y}`, {z, x, y});
  }
  return [...tiles.values()].sort((a, b) => a.x - b.x || a.y - b.y);
}

// ---------------------------------------------------------------- profile feature extraction

/** Sampled cross-profile: parallel RGB arrays indexed by offset k*stepM - rangeM, k = 0..count-1. */
export interface RgbProfile {r: number[]; g: number[]; b: number[]; stepM: number; rangeM: number}

export const intensity = (r: number, g: number, b: number) => 0.299 * r + 0.587 * g + 0.114 * b;

/** Asphalt-likeness in [0,1]: gray (low chroma) and mid-dark to mid-bright. Excludes green/tan/red/blue
 *  surfaces and very bright paint/concrete. */
export function asphaltScore(r: number, g: number, b: number): number {
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), i = intensity(r, g, b);
  const grayness = 1 - Math.min(1, (mx - mn) / 70);
  const band = Math.max(0, Math.min(1, (i - 32) / 22)) * Math.max(0, Math.min(1, (218 - i) / 30));
  return grayness * band;
}

/** Green (grass) dominance, >0 means greener than gray. */
export const greenness = (r: number, g: number, b: number) => g - (r + b) / 2;

export interface EdgeCandidate {offsetM: number; score: number; kind: "asphalt-drop" | "white-line" | "gradient"}
export interface SideMeasurement {offsetM: number; confidence: number; candidates: EdgeCandidate[]}
export interface WidthMeasurement {
  /** Half-widths in meters (null when no plausible edge was found on that side). */
  leftM: number | null; rightM: number | null;
  confidence: number; dark: boolean; reasons: string[];
}

const mean = (vs: number[]) => vs.reduce((a, v) => a + v, 0) / Math.max(1, vs.length);

function windowMean(a: number[], from: number, to: number): number {
  let sum = 0, n = 0;
  const lo = Math.max(0, Math.round(Math.min(from, to))), hi = Math.min(a.length - 1, Math.round(Math.max(from, to)));
  for (let i = lo; i <= hi; i++) {sum += a[i]; n++;}
  return n ? sum / n : 0;
}

function windowMax(a: number[], from: number, to: number): number {
  let best = 0;
  const lo = Math.max(0, Math.round(Math.min(from, to))), hi = Math.min(a.length - 1, Math.round(Math.max(from, to)));
  for (let i = lo; i <= hi; i++) best = Math.max(best, a[i]);
  return best;
}

/** Find edge candidates on one side of a cross-profile. Side +1 scans positive offsets (left of the
 *  centerline normal), -1 scans negative offsets (right). Evidence per offset combines three cues:
 *  asphalt-to-non-asphalt drop that persists outward, a bright painted edge line (white ridge), and a
 *  pure intensity step (walls/barriers/concrete at street circuits). Candidates sorted by score. */
export function edgeCandidates(profile: RgbProfile, side: 1 | -1): EdgeCandidate[] {
  const {r, g, b, stepM, rangeM} = profile, n = r.length, center = rangeM / stepM;
  const A = r.map((_, i) => asphaltScore(r[i], g[i], b[i]));
  const I = r.map((_, i) => intensity(r[i], g[i], b[i]));
  const G = r.map((_, i) => greenness(r[i], g[i], b[i]));
  const W = r.map((_, i) => { // painted white line ridge: bright, achromatic
    const mx = Math.max(r[i], g[i], b[i]), mn = Math.min(r[i], g[i], b[i]);
    return I[i] > 185 && mx - mn < 42 ? Math.min(1, (I[i] - 185) / 55) : 0;
  });
  const candidates: EdgeCandidate[] = [];
  const from = HALF_WIDTH_MIN, to = Math.min(HALF_WIDTH_MAX, (n - 1 - center) * stepM - 1);
  for (let d = from; d <= to; d += stepM) {
    const k = center + side * d / stepM, ki = Math.round(k), w = Math.round(1 / stepM); // 1 m window
    if (ki - 3 * w < 0 || ki + 3 * w >= n) continue;
    // "before" = toward the centerline (asphalt), "after"/"beyond" = outward. Windows flip with side.
    const before = windowMean(A, k - side * 1.5 * w, k - side * 0.5 * w), after = windowMean(A, k + side * 0.5 * w, k + side * 2 * w);
    const beyond = windowMean(A, k + side * 0.5 * w, k + side * 3 * w); // persistence: stays non-asphalt outward
    const drop = before - after;
    const grad = Math.abs(windowMean(I, k + side * 0.5 * w, k + side * 1.5 * w) - windowMean(I, k - side * 1.5 * w, k - side * 0.5 * w));
    const green = windowMean(G, k + side * 0.5 * w, k + side * 2 * w);
    const white = windowMax(W, k - w / 2, k + w / 2); // thin line: peak, not average (mean dilutes 1-2 px lines)
    const dropE = before > 0.3 && beyond < 0.5 ? Math.max(0, drop) : 0;
    const whiteE = white * (before > 0.45 ? 1 : 0.4); // edge paint is meaningful only next to track-like surface
    const gradE = Math.abs(green) < 18 ? Math.min(grad, 80) / 160 : 0;
    const score = dropE + 0.9 * whiteE + gradE + (dropE > 0 ? Math.max(0, green) / 120 + Math.min(grad, 60) / 300 : 0);
    if (score < 0.3) continue;
    const kind: EdgeCandidate["kind"] = dropE >= 0.18 ? "asphalt-drop" : whiteE >= gradE ? "white-line" : "gradient";
    candidates.push({offsetM: d, score, kind});
  }
  // A marked white edge line inward of a paved-apron edge means the outer pavement is runoff, not track:
  // discount outer non-line candidates. Without any line candidate, grass/dirt-bounded edges stand.
  const innermostLine = Math.min(...candidates.filter(c => c.kind === "white-line").map(c => c.offsetM), Infinity);
  for (const c of candidates)
    if (c.kind !== "white-line" && c.offsetM > innermostLine + 1.5) c.score *= 0.45;
  // Non-maximum suppression within 1.5 m so one edge yields one candidate.
  const sorted = candidates.sort((a, b) => b.score - a.score), kept: EdgeCandidate[] = [];
  for (const c of sorted) if (!kept.some(k => Math.abs(k.offsetM - c.offsetM) < 1.5)) kept.push(c);
  return kept.slice(0, 6);
}

/** Measure left/right half-widths from one cross-profile. Positive offsets are the left side. */
export function measureWidth(profile: RgbProfile): WidthMeasurement {
  const {r, g, b, stepM, rangeM} = profile, center = Math.round(rangeM / stepM);
  const reasons: string[] = [];
  const centerI = windowMean(r.map((_, i) => intensity(r[i], g[i], b[i])), center - 8, center + 8);
  const dark = centerI < 42; // tunnel / deep shadow: edges in shadow are unreliable
  if (dark) reasons.push(`dark center (intensity ${centerI.toFixed(0)}) — shadow/tunnel suspect`);
  const sides = ([1, -1] as const).map(side => {
    const candidates = edgeCandidates(profile, side);
    return {side, candidates, best: candidates[0] as EdgeCandidate | undefined};
  });
  // Pair selection with a mild symmetry prior over the top candidates of both sides.
  let bestPair: {l: EdgeCandidate; r: EdgeCandidate; score: number} | undefined;
  const lefts = sides[0].candidates.slice(0, 4), rights = sides[1].candidates.slice(0, 4);
  for (const l of lefts.length ? lefts : [undefined]) for (const r of rights.length ? rights : [undefined]) {
    if (!l && !r) continue;
    const wl = l?.offsetM ?? r!.offsetM, wr = r?.offsetM ?? l!.offsetM; // mirror a single-sided detection
    const full = wl + wr;
    if (full < 7 || full > 30) continue;
    const score = (l?.score ?? 0.18) + (r?.score ?? 0.18) - 0.25 * Math.abs(wl - wr) / (wl + wr);
    if (!bestPair || score > bestPair.score)
      bestPair = {l: l ?? {...r!, offsetM: r!.offsetM}, r: r ?? {...l!, offsetM: l!.offsetM}, score};
  }
  if (!bestPair) return {leftM: null, rightM: null, confidence: 0, dark, reasons: [...reasons, "no plausible edge pair"]};
  if (!lefts.length || !rights.length) reasons.push("single-sided detection, mirrored to the other side");
  const full = bestPair.l.offsetM + bestPair.r.offsetM;
  let confidence = Math.max(0, Math.min(1, bestPair.score / 1.5));
  if (bestPair.l.kind === "gradient" || bestPair.r.kind === "gradient") {confidence *= 0.75; reasons.push("gradient-only edge (wall/barrier/concrete)");}
  if (dark) confidence *= 0.4;
  if (full < 8 || full > 20) {confidence *= 0.85; reasons.push(`full width ${full.toFixed(1)} m near plausibility band edge`);}
  // An edge sitting exactly at the scan limit means the true boundary may lie beyond the profile —
  // under cloud/haze the detector locks onto cloud-shadow gradients out there. A marked white line
  // at the limit is still trustworthy (paint is unambiguous); anything else is demoted.
  const atLimit = (c: EdgeCandidate) => c.offsetM >= HALF_WIDTH_MAX - stepM && c.kind !== "white-line";
  if (atLimit(bestPair.l) || atLimit(bestPair.r)) {confidence *= 0.5; reasons.push("edge at scan-range limit (15 m) — true edge may lie beyond the profile (cloud/haze suspect)");}
  return {leftM: bestPair.l.offsetM, rightM: bestPair.r.offsetM, confidence: Math.round(confidence * 1000) / 1000, dark, reasons};
}

// ---------------------------------------------------------------- along-lap smoothing / interpolation

export interface StationEdges {left: EdgeCandidate[]; right: EdgeCandidate[]}

/** Continuity pass: track width varies smoothly, so when a station's chosen edge deviates strongly from
 *  the neighbor consensus (or is missing) but a decent candidate sits near the expected offset, adopt it.
 *  Guards: deviation must exceed 2.5 m, the candidate must lie within 2 m of the expectation and score
 *  >= 0.3; adopted edges are confidence-capped and flagged guided. Returns null where nothing changed. */
export function continuityGuided(stations: StationEdges[], expectedL: (number | null)[], expectedR: (number | null)[],
  current: {leftM: number | null; rightM: number | null; confidence: number}[]):
  {leftM: number | null; rightM: number | null; confidence: number; guided: boolean}[] {
  const pick = (candidates: EdgeCandidate[], expected: number | null, chosen: number | null) => {
    if (expected === null) return chosen;
    if (chosen !== null && Math.abs(chosen - expected) <= 2.5) return chosen;
    let best: EdgeCandidate | undefined;
    for (const c of candidates)
      if (c.score >= 0.3 && Math.abs(c.offsetM - expected) <= 2 && (!best || Math.abs(c.offsetM - expected) < Math.abs(best.offsetM - expected)))
        best = c;
    return best ? best.offsetM : chosen;
  };
  return stations.map((s, i) => {
    const leftM = pick(s.left, expectedL[i], current[i].leftM);
    const rightM = pick(s.right, expectedR[i], current[i].rightM);
    const guided = leftM !== current[i].leftM || rightM !== current[i].rightM;
    return {leftM, rightM, confidence: guided ? Math.min(0.55, Math.max(current[i].confidence, 0.5)) : current[i].confidence, guided};
  });
}

export interface LapMeasurement {
  index: number; distanceM: number;
  leftM: number | null; rightM: number | null; confidence: number; dark: boolean;
}

/** Circular median filter over a possibly-gappy half-width series; nulls are skipped, window counts valid entries. */
export function medianSmooth(values: (number | null)[], window: number): (number | null)[] {
  const n = values.length, half = Math.floor(window / 2);
  return values.map((v, i) => {
    if (v === null) return null;
    const around: number[] = [];
    for (let k = -half; k <= half; k++) {const u = values[(i + k + n) % n]; if (u !== null) around.push(u);}
    around.sort((a, b) => a - b);
    return around[Math.floor(around.length / 2)];
  });
}

export type PointStatus = "measured" | "interpolated" | "fallback";

/** Fuse per-station measurements into final half-widths. Confident measurements are median-smoothed;
 *  short gaps (<= maxBridgeM) are linearly interpolated from measured neighbors; longer gaps keep the
 *  prior width (TUMFTM or constant default) and are flagged "fallback". Circular around the lap. */
export function fuseWidths(measurements: LapMeasurement[], prior: {leftM: number; rightM: number}[],
  spacingM: number, minConfidence = 0.45, maxBridgeM = 60): {leftM: number[]; rightM: number[]; status: PointStatus[]} {
  const n = measurements.length;
  if (prior.length !== n) throw new Error("fuseWidths: prior length mismatch");
  const confident = measurements.map(m =>
    m.leftM !== null && m.rightM !== null && m.confidence >= minConfidence && !m.dark);
  const smoothL = medianSmooth(measurements.map(m => m.leftM), 9);
  const smoothR = medianSmooth(measurements.map(m => m.rightM), 9);
  const clamp = (v: number) => Math.max(HALF_WIDTH_MIN, Math.min(HALF_WIDTH_MAX, v));
  const base = measurements.map((_, i) => confident[i] ? {l: clamp(smoothL[i]!), r: clamp(smoothR[i]!)} : null);
  const status: PointStatus[] = base.map(b => b ? "measured" : "fallback");
  const leftM = base.map(b => b?.l ?? 0), rightM = base.map(b => b?.r ?? 0);
  const maxBridge = Math.round(maxBridgeM / spacingM);
  // Walk the lap from a confident anchor so circular runs are handled linearly; a run reaching the end of
  // the walk terminates at the (confident) start anchor. A fully-unmeasured lap stays all-fallback.
  if (confident.some(Boolean)) {
    const start = confident.findIndex(Boolean);
    let i = 1;
    while (i < n) {
      if (confident[(start + i) % n]) {i++; continue;}
      let len = 0;
      while (i + len < n && !confident[(start + i + len) % n]) len++;
      const a = (start + i - 1 + n) % n, bIdx = (start + i + len) % n;
      for (let k = 0; k < len; k++) {
        const at = (start + i + k) % n;
        if (len <= maxBridge) {
          const f = (k + 1) / (len + 1);
          leftM[at] = leftM[a] + (leftM[bIdx] - leftM[a]) * f;
          rightM[at] = rightM[a] + (rightM[bIdx] - rightM[a]) * f;
          status[at] = "interpolated";
        } else {
          leftM[at] = prior[at].leftM; rightM[at] = prior[at].rightM;
        }
      }
      i += len;
    }
  } else {
    for (let i = 0; i < n; i++) {leftM[i] = prior[i].leftM; rightM[i] = prior[i].rightM;}
  }
  return {leftM, rightM, status};
}

// ---------------------------------------------------------------- kerb classification

/** Per-strip pixel statistics emitted by the Python sampler (best 1 m offset row of a +/-5 m search band). */
export interface KerbStripStats {
  id: string; total: number; red: number; white: number;
  /** Longest contiguous along-strip run of stations whose red fraction >= 0.12, in meters. */
  maxRedRunM: number;
  /** Number of red<->white dominant alternations along the strip (stripedness). */
  alternations: number;
  stationRed: number[]; stationWhite: number[];
  /** Offset (m, outward from the synthetic strip's inner edge) of the reddest 1 m row, if any red was seen. */
  bestRowM: number | null;
  /** Tightened lon/lat quad around the observed red run (emitted when >= ~4 m of red exists). */
  polygon: {lon: number; lat: number}[] | null;
}

/** Red/white painted kerb present? Requires meaningful red coverage and an elongated red run, plus one
 *  piece of kerb evidence: red/white alternation, substantial white paint mixed in, or very strong red
 *  coverage (at 0.5-0.6 m/px the white stripes of a kerb often blur into the concrete, so striping is
 *  sufficient but not necessary). Bare specks of red paint do not qualify. */
export function classifyKerb(stats: KerbStripStats): {detected: boolean; confidence: number; reason: string} {
  if (stats.total < 20) return {detected: false, confidence: 0, reason: "too few pixels sampled"};
  const redFrac = stats.red / stats.total, whiteFrac = stats.white / stats.total;
  const evidence = stats.alternations >= 1 || whiteFrac >= 0.05 || redFrac >= 0.15;
  const detected = redFrac >= 0.06 && stats.maxRedRunM >= 6 && evidence;
  const confidence = detected
    ? Math.round(Math.min(1, redFrac * 4 + Math.min(stats.maxRedRunM, 40) / 80 + Math.min(stats.alternations, 8) / 16) * 1000) / 1000
    : 0;
  const reason = detected
    ? `red fraction ${(redFrac * 100).toFixed(1)}%, longest red run ${stats.maxRedRunM.toFixed(0)} m, ${stats.alternations} red/white alternations`
    : `insufficient striped red (red ${(redFrac * 100).toFixed(1)}%, run ${stats.maxRedRunM.toFixed(0)} m, alternations ${stats.alternations}, white ${(whiteFrac * 100).toFixed(1)}%)`;
  return {detected, confidence, reason};
}

// ---------------------------------------------------------------- cross-validation

export function pearson(x: number[], y: number[]): number {
  const n = Math.min(x.length, y.length);
  if (n < 3) return NaN;
  const mx = mean(x.slice(0, n)), my = mean(y.slice(0, n));
  let sxy = 0, sx = 0, sy = 0;
  for (let i = 0; i < n; i++) {const dx = x[i] - mx, dy = y[i] - my; sxy += dx * dy; sx += dx * dx; sy += dy * dy;}
  return sx > 0 && sy > 0 ? sxy / Math.sqrt(sx * sy) : NaN;
}
