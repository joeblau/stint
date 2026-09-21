/** Strict, two-dimensional imagery export. No width priors, mirrored edges or synthetic kerbs. */
import { asphaltScore, edgeCandidates, intensity, type RgbProfile } from "./imagery";
import { applyTransform, fitSimilarity, projectLonLat, unprojectToLonLat, type GeoOrigin } from "./trackimport";

export type XY = {x: number; y: number};
export type LonLat = [number, number];
export type Side = "left" | "right";
export const SECTOR_COLORS = ["#00FFFF", "#FF00FF", "#FFFF00"] as const;
export interface TimingLine {id: "finish" | "s1" | "s2"; coordinates: [LonLat, LonLat]}
export interface Timing {year: number; source: string; placementSource: string; lines: TimingLine[]}
export interface Station extends XY {distanceM: number; normal: XY}
export interface Observation {offsetM: number; confidence: number; reasons: string[]; inferred?: boolean; reviewID?: string}
export interface MeasuredStation {left: Observation | null; right: Observation | null;
  kerbLeft: Observation | null; kerbRight: Observation | null}
export interface SurfaceFeature {type: "Feature"; properties: Record<string, unknown>;
  geometry: {type: "LineString"; coordinates: LonLat[]} | {type: "Polygon"; coordinates: LonLat[][]}}

export function validCoordinate(c: unknown): c is LonLat {
  return Array.isArray(c) && c.length === 2 && c.every(Number.isFinite) && Math.abs(c[0]) <= 180 && Math.abs(c[1]) <= 85;
}
const cross = (a: XY, b: XY) => a.x * b.y - a.y * b.x;
const minus = (a: XY, b: XY): XY => ({x: a.x - b.x, y: a.y - b.y});
const lerp = (a: XY, b: XY, t: number): XY => ({x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t});
export const signedArea = (p: XY[]) => p.reduce((s, a, i) => s + cross(a, p[(i + 1) % p.length]), 0) / 2;

/** Match the app's centripetal Catmull-Rom traversal, avoiding discontinuous normals
 * at the sparse community centerline's vertices. This interpolates the reference only;
 * surface widths still come exclusively from observations.
 */
export function smoothSurfaceReference(input: XY[], spacingM = 1): XY[] {
  const ps = input.filter((p, i) => !i || p.x !== input[i - 1].x || p.y !== input[i - 1].y);
  if (ps.length > 1 && ps[0].x === ps.at(-1)!.x && ps[0].y === ps.at(-1)!.y) ps.pop();
  const out: XY[] = [], n = ps.length;
  const blend = (a: XY, b: XY, lo: number, hi: number, t: number) => lerp(a, b, (t - lo) / (hi - lo));
  for (let i = 0; i < n; i++) {
    const [a, b, c, d] = [-1, 0, 1, 2].map(k => ps[(i + k + n) % n]);
    const knot = (p: XY, q: XY) => Math.max(0.001, Math.sqrt(Math.hypot(q.x - p.x, q.y - p.y)));
    const t0 = 0, t1 = knot(a, b), t2 = t1 + knot(b, c), t3 = t2 + knot(c, d);
    const steps = Math.max(2, Math.ceil(Math.hypot(c.x - b.x, c.y - b.y) / spacingM));
    for (let j = 0; j < steps; j++) {
      const t = t1 + (t2 - t1) * j / steps;
      const a1 = blend(a, b, t0, t1, t), a2 = blend(b, c, t1, t2, t), a3 = blend(c, d, t2, t3, t);
      out.push(blend(blend(a1, a2, t0, t2, t), blend(a2, a3, t1, t3, t), t1, t2, t));
    }
  }
  return out;
}

/** Proper segment crossing, including the first endpoint but excluding the last to avoid duplicates. */
export function crossing(a: XY, b: XY, c: XY, d: XY): number | null {
  const r = minus(b, a), s = minus(d, c), det = cross(r, s);
  if (Math.abs(det) < 1e-10) return null;
  const t = cross(minus(c, a), s) / det, u = cross(minus(c, a), r) / det;
  return t >= -1e-9 && t < 1 - 1e-9 && u >= -1e-9 && u <= 1 + 1e-9 ? Math.max(0, t) : null;
}

export function controlPointAlignment(controls: {image: LonLat; reference: LonLat; label: string}[], origin: GeoOrigin, maxRmsM = 1.5) {
  if (controls.length < 3 || !Number.isFinite(maxRmsM) || maxRmsM <= 0 ||
      controls.some(c => !c.label.trim() || !validCoordinate(c.image) || !validCoordinate(c.reference)))
    throw new Error("At least three labeled, valid control points and a positive RMS limit are required");
  const source = controls.map(c => projectLonLat(...c.image, origin));
  const target = controls.map(c => projectLonLat(...c.reference, origin));
  // Collinear/clustered controls cannot establish a track-wide registration.
  const spread = (ps: XY[]) => Math.max(...ps.slice(2).map(p => Math.abs(cross(minus(ps[1], ps[0]), minus(p, ps[0])))));
  if (spread(source) < 10 || spread(target) < 10) throw new Error("Control points must span a non-collinear area");
  const {transform} = fitSimilarity(source, target);
  if (!Object.values(transform).every(Number.isFinite) || transform.scale < 0.95 || transform.scale > 1.05)
    throw new Error("Control-point registration has an invalid or implausible scale");
  const residuals = source.map((p, i) => {
    const q = applyTransform(p, transform);
    return {label: controls[i].label, residualM: Math.hypot(q.x - target[i].x, q.y - target[i].y)};
  });
  const rmsM = Math.sqrt(residuals.reduce((s, p) => s + p.residualM ** 2, 0) / residuals.length);
  if (rmsM > maxRmsM || residuals.some(r => r.residualM > maxRmsM * 2)) throw new Error(`Control-point residual exceeds ${maxRmsM} m`);
  return {transform, rmsM, residuals, controls, note: "Registration residuals are not absolute ground-truth accuracy."};
}

/** Each side is detected independently. A missing side stays missing. */
export function measureStrict(profile: RgbProfile | null): MeasuredStation {
  const empty = {left: null, right: null, kerbLeft: null, kerbRight: null};
  if (!profile) return empty;
  const {r, g, b, stepM, rangeM} = profile;
  if (!(stepM > 0 && rangeM > 0) || r.length !== g.length || r.length !== b.length ||
      r.length !== Math.round(2 * rangeM / stepM) + 1 ||
      [...r, ...g, ...b].some(v => !Number.isFinite(v) || v < 0 || v > 255)) throw new Error("Invalid RGB profile");
  const center = Math.round(rangeM / stepM);
  if (intensity(r[center], g[center], b[center]) < 42 || asphaltScore(r[center], g[center], b[center]) < 0.25) return empty;
  const detect = (sign: 1 | -1): Observation | null => {
    const cs = edgeCandidates(profile, sign), best = cs[0];
    if (!best || best.score < 0.45 || (best.offsetM >= 15 - stepM && best.kind !== "white-line")) return null;
    const ambiguous = cs.length > 1 && cs[1].score > best.score * 0.85;
    return {offsetM: best.offsetM, confidence: Math.min(0.8, best.score / 1.5) * (ambiguous ? 0.5 : 1),
      reasons: [best.kind, ...(ambiguous ? ["ambiguous parallel edge"] : [])]};
  };
  const left = detect(1), right = detect(-1);
  if (left && right && (left.offsetM + right.offsetM < 7 || left.offsetM + right.offsetM > 30)) return empty;
  // Paint evidence only: the raster cannot establish whether a kerb is raised, nor its actual width.
  const kerb = (edge: Observation | null, sign: 1 | -1): Observation | null => {
    if (!edge || edge.confidence < 0.3) return null;
    const reds: number[] = []; let whites = 0;
    for (let d = Math.max(0, edge.offsetM - 0.5); d <= edge.offsetM + 2; d += stepM) {
      const i = Math.round(center + sign * d / stepM);
      if (i < 0 || i >= r.length) continue;
      if (r[i] > 110 && r[i] > g[i] * 1.4 && r[i] > b[i] * 1.4) reds.push(d);
      if (Math.min(r[i], g[i], b[i]) > 185 && Math.max(r[i], g[i], b[i]) - Math.min(r[i], g[i], b[i]) < 45) whites++;
    }
    return reds.length >= 2 && whites >= 1 ? {offsetM: reds.reduce((a, v) => a + v, 0) / reds.length,
      confidence: Math.min(0.3, edge.confidence), reasons: ["red/white paint candidate", "raised geometry unverified", "low confidence"]} : null;
  };
  return {left, right, kerbLeft: kerb(left, 1), kerbRight: kerb(right, -1)};
}

/** Miami's marked racing corridor has turquoise borders, including where both sides
 * are asphalt parking aprons. Use the observed paint transition, rather than the apron
 * boundary. Thresholds are relative chroma, so the county raster's muted exposure works.
 */
export function measureMiamiCounty(profile: RgbProfile | null): MeasuredStation {
  const baseline = measureStrict(profile);
  if (!profile) return baseline;
  const p = profile, center = Math.round(p.rangeM / p.stepM);
  if (intensity(p.r[center], p.g[center], p.b[center]) < 45) return {left: null, right: null, kerbLeft: null, kerbRight: null};
  for (const [side, sign] of [["left", 1], ["right", -1]] as const) {
    if (!baseline[side]) {
      const candidate = edgeCandidates(p, sign)[0];
      if (candidate && candidate.score >= 0.3 && candidate.offsetM < 14.75)
        baseline[side] = {offsetM: candidate.offsetM, confidence: Math.min(0.35, candidate.score / 1.5), reasons: ["weak observed contrast boundary", candidate.kind]};
    }
    for (let d = 2; d <= 20; d += p.stepM) {
      const k = Math.round(center + sign * d / p.stepM), next = k + sign;
      const cyan = (i: number) => i >= 0 && i < p.r.length && p.b[i] - p.r[i] > 8 && p.g[i] - p.r[i] > 8 && p.g[i] > 65;
      if (cyan(k) && cyan(next)) {
        baseline[side] = {offsetM: d, confidence: 0.6, reasons: ["observed turquoise racing-corridor boundary"]};
        break;
      }
    }
    const edge = baseline[side];
    if (edge?.reasons.includes("observed turquoise racing-corridor boundary")) {
      const white: number[] = [];
      const centerLight = intensity(p.r[center], p.g[center], p.b[center]);
      for (let d = Math.max(0, edge.offsetM - 1.5); d <= edge.offsetM + 1.5; d += p.stepM) {
        const k = Math.round(center + sign * d / p.stepM), rgb = [p.r[k], p.g[k], p.b[k]];
        if (Math.min(...rgb) > 140 && Math.max(...rgb) - Math.min(...rgb) < 30 && intensity(...rgb as [number, number, number]) > centerLight + 35)
          white.push(d);
      }
      // A broad observed light strip, next to turquoise paint, is only a candidate.
      // Thin racing lines alone cannot establish a kerb; height remains unverified.
      if (white.length >= 4 && white.at(-1)! - white[0] <= 1.5)
        baseline[side === "left" ? "kerbLeft" : "kerbRight"] = {
          offsetM: white.reduce((s, d) => s + d, 0) / white.length, confidence: 0.2,
          reasons: ["broad white strip adjoining turquoise paint", "kerb or painted shoulder unresolved", "raised geometry unverified"],
        };
    }
  }
  return baseline;
}

/** Follow a locally observed paint band through exposure/paint-color changes. A neighbor
 * narrows the search; a new station still needs its own color or light-strip evidence.
 */
export function refineMiamiBoundaries(profiles: (RgbProfile | null)[], measured: MeasuredStation[], spacingM: number): MeasuredStation[] {
  const n = measured.length, result = measured.map(m => ({...m}));
  const radius = Math.max(1, Math.floor(8 / spacingM));
  const median = (xs: number[]) => xs.sort((a, b) => a - b)[Math.floor(xs.length / 2)];
  for (const side of ["left", "right"] as const) for (let i = 0; i < n; i++) {
    const p = profiles[i]; if (!p) continue;
    const center = Math.round(p.rangeM / p.stepM), light = intensity(p.r[center], p.g[center], p.b[center]);
    if (light < 45) continue;
    const neighbors: number[] = [];
    for (let k = -radius; k <= radius; k++) {
      const obs = measured[(i + k + n) % n][side];
      if (k && obs && obs.confidence >= 0.5) neighbors.push(obs.offsetM);
    }
    if (neighbors.length < 4) continue;
    const expected = median(neighbors), current = measured[i][side];
    if (current && Math.abs(current.offsetM - expected) < 0.75) continue;
    const sign = side === "left" ? 1 : -1;
    let best: {d: number; score: number} | undefined;
    for (let d = Math.max(2, expected - 1); d <= Math.min(20, expected + 1); d += p.stepM) {
      const k = Math.round(center + sign * d / p.stepM), rgb = [p.r[k], p.g[k], p.b[k]];
      const cyan = p.g[k] - p.r[k] > 5 && p.b[k] - p.r[k] > 0 && p.g[k] > 55;
      const white = Math.max(...rgb) - Math.min(...rgb) < 35 && intensity(...rgb as [number, number, number]) > light + 25;
      if (!cyan && !white) continue;
      const score = Math.abs(d - expected);
      if (!best || score < best.score) best = {d, score};
    }
    if (best) result[i][side] = {offsetM: best.d, confidence: 0.3, reasons: ["neighbor-guided observed paint transition", "low contrast"]};
    else if (current && Math.abs(current.offsetM - expected) > 3) {
      result[i][side] = null; result[i][side === "left" ? "kerbLeft" : "kerbRight"] = null;
    }
  }
  return result;
}

/** Reject offsets that fold backwards around a tight reference corner. */
export function rejectFoldedEdges(stations: Station[], measured: MeasuredStation[]): MeasuredStation[] {
  const result = measured.map(m => ({...m})), n = stations.length;
  for (const side of ["left", "right"] as const) for (let i = 0; i < n; i++) {
    const j = (i + 1) % n, a = stations[i], b = stations[j], ma = measured[i][side], mb = measured[j][side];
    if (!ma || !mb) continue;
    const sign = side === "left" ? 1 : -1;
    const dx = b.x + sign * b.normal.x * mb.offsetM - a.x - sign * a.normal.x * ma.offsetM;
    const dy = b.y + sign * b.normal.y * mb.offsetM - a.y - sign * a.normal.y * ma.offsetM;
    if (dx * (a.normal.y + b.normal.y) - dy * (a.normal.x + b.normal.x) <= 0) {
      for (const k of [i, j]) {result[k][side] = null; result[k][side === "left" ? "kerbLeft" : "kerbRight"] = null;}
    }
  }
  return result;
}

/** Kerb stripes alternate along the circuit, so a single cross-profile can be entirely
 * red or entirely white. Require nearby, aligned observations of both colors, and only
 * emit stations with actual paint pixels. Shadows and unobserved profiles remain gaps.
 */
export function measureKerbsAlongTrack(profiles: (RgbProfile | null)[], measured: MeasuredStation[], spacingM: number): MeasuredStation[] {
  if (profiles.length !== measured.length || !Number.isFinite(spacingM) || spacingM <= 0)
    throw new Error("Kerb detection requires corresponding profiles and positive station spacing");
  const result = measured.map(m => ({...m}));
  const radius = Math.min(Math.floor(3 / spacingM), Math.floor(profiles.length / 2));
  for (const side of ["left", "right"] as const) {
    const key = side === "left" ? "kerbLeft" : "kerbRight", sign = side === "left" ? 1 : -1;
    const paint = profiles.map((p, i) => {
      const edge = measured[i][side];
      if (!p || !edge || edge.confidence < 0.3) return null;
      const reds: number[] = [], whites: number[] = [];
      for (let d = Math.max(0, edge.offsetM - 0.5); d <= edge.offsetM + 2; d += p.stepM) {
        const k = Math.round((p.rangeM + sign * d) / p.stepM);
        if (k < 0 || k >= p.r.length) continue;
        const r = p.r[k], g = p.g[k], b = p.b[k];
        if (r > 110 && r > g * 1.4 && r > b * 1.4) reds.push(d);
        if (Math.min(r, g, b) > 185 && Math.max(r, g, b) - Math.min(r, g, b) < 45) whites.push(d);
      }
      const offsets = reds.length >= 2 ? reds : whites.length >= 2 ? whites : null;
      return offsets ? {color: reds.length >= 2 ? "red" : "white", offsetM: offsets.reduce((s, d) => s + d, 0) / offsets.length} : null;
    });
    for (let i = 0; i < profiles.length; i++) {
      const candidate = paint[i];
      if (!candidate || result[i][key]) continue;
      let alternating = false;
      for (const direction of [-1, 1]) for (let distance = 1; distance <= radius; distance++) {
        const j = (i + direction * distance + profiles.length) % profiles.length, neighbor = paint[j];
        // Never bridge a shadow, absent edge, or discontinuous paint band.
        if (!neighbor || Math.abs(candidate.offsetM - neighbor.offsetM) > 0.75) break;
        if (candidate.color !== neighbor.color) { alternating = true; break; }
      }
      if (alternating) result[i][key] = {offsetM: candidate.offsetM, confidence: Math.min(0.3, measured[i][side]!.confidence),
        reasons: ["longitudinal red/white paint candidate", "raised geometry unverified", "low confidence"]};
    }
  }
  return result;
}

/** Reject isolated jumps without filling gaps or replacing measurements with guessed widths. */
export function rejectDiscontinuities(input: MeasuredStation[]): MeasuredStation[] {
  return input.map((m, i) => {
    const result = {...m};
    for (const side of ["left", "right"] as const) {
      const a = input[(i - 1 + input.length) % input.length][side], b = input[(i + 1) % input.length][side], p = m[side];
      if (p && a && b && Math.abs(a.offsetM - b.offsetM) < 2 && Math.abs(p.offsetM - (a.offsetM + b.offsetM) / 2) > 3) {
        result[side] = null; result[side === "left" ? "kerbLeft" : "kerbRight"] = null;
      }
    }
    return result;
  });
}

/** Miami display geometry, deliberately separate from the unchanged image observations.
 * Periodic filtering keeps the lap seam continuous. Each side is processed independently;
 * obscured sections interpolate between observations, never from a nominal road width.
 */
export function continuousMiamiSurface(stations: Station[], input: MeasuredStation[], spacingM: number) {
  if (stations.length !== input.length || input.length < 3 || !(spacingM > 0)) throw new Error("Invalid Miami refinement input");
  const n = input.length, wrap = (i: number) => (i % n + n) % n;
  const output: MeasuredStation[] = input.map(() => ({left: null, right: null, kerbLeft: null, kerbRight: null}));
  const medianRadius = Math.ceil(6 / spacingM), blurRadius = Math.ceil(12 / spacingM);
  const sigma = 4 / spacingM;
  for (const side of ["left", "right"] as const) {
    const observed = input.flatMap((m, i) => m[side] && m[side]!.confidence >= 0.5 ? [i] : []);
    if (observed.length < n * 0.55) throw new Error(`Insufficient ${side} evidence for continuous Miami visualization`);
    const filtered = input.map((m, i) => {
      if (!m[side] || m[side]!.confidence < 0.5) return null;
      const nearby: number[] = [];
      for (let k = -medianRadius; k <= medianRadius; k++) {
        const candidate = input[wrap(i + k)][side];
        if (candidate && candidate.confidence >= 0.5) nearby.push(candidate.offsetM);
      }
      nearby.sort((a, b) => a - b);
      return nearby[Math.floor(nearby.length / 2)];
    });
    // Traverse from an observed station so gaps spanning the lap seam get both anchors.
    const filled = filtered.slice() as number[];
    for (let a = 0; a < observed.length; a++) {
      const start = observed[a], end = observed[(a + 1) % observed.length], count = wrap(end - start);
      for (let k = 1; k < count; k++) filled[wrap(start + k)] = filtered[start]! + (filtered[end]! - filtered[start]!) * k / count;
    }
    for (let i = 0; i < n; i++) {
      let sum = 0, weight = 0;
      for (let k = -blurRadius; k <= blurRadius; k++) {
        const w = Math.exp(-0.5 * (k / sigma) ** 2);
        sum += filled[wrap(i + k)] * w; weight += w;
      }
      const original = input[i][side];
      output[i][side] = {offsetM: sum / weight, confidence: Math.min(original?.confidence ?? 0.15, 0.35),
        inferred: !original || original.confidence < 0.5, reasons: [original && original.confidence >= 0.5 ? "Spatially smoothed imagery boundary" : "Interpolated across obscured or weak imagery for continuous visualization"]};
    }
    // Offset curves fold when an inside width exceeds the reference bend radius.
    // Approach that geometric limit gradually, instead of dropping road intervals.
    const safeWidths = output.map((m, i) => {
      let limit = Infinity;
      for (let k = -Math.ceil(30 / spacingM); k <= Math.ceil(30 / spacingM); k++) {
        const j = wrap(i + k), a = stations[wrap(j - 1)].normal, b = stations[wrap(j + 1)].normal;
        const curvature = Math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y) / (2 * spacingM);
        const insideCurvature = curvature * (side === "left" ? 1 : -1);
        if (insideCurvature > 0) limit = Math.min(limit, 0.85 / insideCurvature + Math.abs(k) * spacingM * 0.15);
      }
      return Math.min(m[side]!.offsetM, limit);
    });
    // Fair the limit's transitions as well, so narrowing at a chicane has no sharp
    // corners in the width curve. A local radius guard still prevents inside folds.
    for (let i = 0; i < n; i++) {
      let sum = 0, weight = 0;
      for (let k = -Math.ceil(6 / spacingM); k <= Math.ceil(6 / spacingM); k++) {
        const w = Math.exp(-0.5 * (k * spacingM / 2) ** 2);
        sum += safeWidths[wrap(i + k)] * w; weight += w;
      }
      const a = stations[wrap(i - 1)].normal, b = stations[wrap(i + 1)].normal;
      const curvature = Math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y) / (2 * spacingM) * (side === "left" ? 1 : -1);
      const value = Math.min(sum / weight, curvature > 0 ? 0.95 / curvature : Infinity);
      if (safeWidths[i] < output[i][side]!.offsetM) {
        output[i][side]!.inferred = true;
        output[i][side]!.reasons.push("Inside offset constrained by bend radius to prevent folding");
      }
      output[i][side]!.offsetM = value;
    }
    // Keep coherent paint strips near the refined edge. Isolated white markings and
    // strips on straights are not enough evidence to label a raised racing kerb.
    const key = side === "left" ? "kerbLeft" : "kerbRight";
    const turnRadius = Math.max(1, Math.round(10 / spacingM));
    const supported = input.map((m, i) => {
      const kerb = m[key], edge = output[i][side]!;
      const a = stations[wrap(i - turnRadius)].normal, b = stations[wrap(i + turnRadius)].normal;
      const turn = Math.abs(Math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y));
      return !!kerb && Math.abs(kerb.offsetM - edge.offsetM) <= 1.5 && turn > 0.12;
    });
    const mask = supported.slice(), maxGap = Math.ceil(3 / spacingM);
    // Bridge at most three metres inside a supported strip, not whole missing kerbs.
    for (let i = 0; i < n; i++) if (supported[i]) {
      for (let k = 2; k <= maxGap + 1; k++) if (supported[wrap(i + k)]) {
        for (let j = 1; j < k; j++) mask[wrap(i + j)] = true;
        break;
      }
    }
    const firstMissing = mask.indexOf(false);
    if (firstMissing < 0) throw new Error("Kerb detection unexpectedly covers the entire circuit");
    let run: number[] = [];
    const commit = () => {
      if (run.length * spacingM >= 8 && run.filter(i => supported[i]).length / run.length >= 0.65) {
        for (const i of run) output[i][key] = {offsetM: output[i][side]!.offsetM + 0.3, confidence: 0.2,
          inferred: !supported[i], reasons: ["Coherent corner paint candidate, aligned to smoothed boundary", "Red/white presentation; raised geometry and source stripe colors unverified"]};
      }
      run = [];
    };
    for (let k = 1; k <= n; k++) {const i = wrap(firstMissing + k); if (mask[i]) run.push(i); else commit();}
  }
  return {measured: output, audit: {
    mode: "continuous-visualization", smoothing: "Independent 6 m median and 4 m Gaussian width filters on confidence >=0.5 observations; periodic interpolation through missing/weak observations; inside offsets constrained by bend radius with a 2 m transition filter",
    sourceObservations: input.map((m, i) => ({distanceM: stations[i].distanceM, left: m.left, right: m.right, kerbLeft: m.kerbLeft, kerbRight: m.kerbRight})),
    inferredStations: output.flatMap((m, i) => (["left", "right"] as const).flatMap(side => m[side]?.inferred ? [{station: i, side}] : [])),
    kerbs: "Only coherent corner paint runs >=8 m, >=65% support; gaps <=3 m; low confidence; red/white illustrative styling"
  }};
}

export function exportSurface(stations: Station[], measured: MeasuredStation[], origin: GeoOrigin, timing: Timing | null,
  metadata: Record<string, unknown>, strokePixels = 2, observedPatches = false) {
  if (stations.length < 3 || stations.length !== measured.length || !Number.isFinite(strokePixels) || strokePixels <= 0 || strokePixels > 8)
    throw new Error("Invalid stations or strokePixels (0..8 required)");
  const features: SurfaceFeature[] = [], issues: string[] = [];
  const coord = (p: XY): LonLat => {const g = unprojectToLonLat(p.x, p.y, origin); return [g.lon, g.lat];};
  const common = {verified: false, strokeUnits: "screen-pixels", strokePixels, appearanceReferenceM: 0.05};
  const leftIsInner = signedArea(stations) > 0;
  const edgePoint = (i: number, side: Side, kerb = false): XY | null => {
    const key = kerb ? side === "left" ? "kerbLeft" : "kerbRight" : side;
    const m = measured[i][key];
    if (!m) return null;
    const s = stations[i], sign = side === "left" ? 1 : -1;
    return {x: s.x + s.normal.x * m.offsetM * sign, y: s.y + s.normal.y * m.offsetM * sign};
  };
  const n = stations.length;
  const lengths = stations.map((p, i) => Math.hypot(p.x - stations[(i + 1) % n].x, p.y - stations[(i + 1) % n].y));
  const total = stations[n - 1].distanceM + lengths[n - 1];
  let boundaries: {id: TimingLine["id"]; a: XY; b: XY; distance: number}[] = [];
  if (timing) {
    if (!Number.isInteger(timing.year) || !timing.source.startsWith("https://") || !timing.placementSource.trim() ||
        timing.lines.length !== 3 || new Set(timing.lines.map(l => l.id)).size !== 3 ||
        timing.lines.some(l => !["finish", "s1", "s2"].includes(l.id) || l.coordinates.length !== 2 || !l.coordinates.every(validCoordinate)))
      throw new Error("Timing requires three sourced WGS84 timing lines (finish, s1, s2), year and placement provenance");
    boundaries = timing.lines.map(line => {
      const [a, b] = line.coordinates.map(c => projectLonLat(...c, origin));
      const hits = stations.flatMap((p, i) => {const t = crossing(p, stations[(i + 1) % n], a, b);
        return t === null ? [] : [stations[i].distanceM + lengths[i] * t];});
      if (hits.length !== 1) throw new Error(`${line.id}: timing line must cross the centerline exactly once`);
      return {id: line.id, a, b, distance: hits[0]};
    });
    const finish = boundaries.find(b => b.id === "finish")!.distance;
    const afterFinish = (d: number) => (d - finish + total) % total;
    if (afterFinish(boundaries.find(b => b.id === "s1")!.distance) >= afterFinish(boundaries.find(b => b.id === "s2")!.distance))
      throw new Error("Timing lines disagree with traversal direction: expected finish, s1, s2");
    boundaries.sort((a, b) => a.distance - b.distance);
  } else issues.push("Official timing-line coordinates missing: no sector colors exported.");
  for (const side of ["left", "right"] as const) {
    const edgeSide = (side === "left") === leftIsInner ? "inner" : "outer";
    const edgeBoundaries = boundaries.map(line => {
      const hits = stations.flatMap((_, i) => {
        const a = edgePoint(i, side), b = edgePoint((i + 1) % n, side);
        const t = a && b ? crossing(a, b, line.a, line.b) : null;
        return t === null ? [] : [i + t];
      });
      // A timing line hidden by a bridge does not invalidate every observed sector edge.
      // Carry its official centerline station across the gap; emit no invented edge there.
      let i = 0;
      while (i + 1 < n && stations[i + 1].distanceM <= line.distance) i++;
      const position = i + (line.distance - stations[i].distanceM) / lengths[i];
      const hidden = !measured[i][side] || !measured[(i + 1) % n][side];
      return {id: line.id, hits: !hits.length && hidden ? [position] : hits};
    });
    const canColor = !!timing && edgeBoundaries.every(b => b.hits.length === 1);
    if (timing && !canColor) issues.push(`${side}: timing lines do not each cross one observed edge segment; sector colors withheld.`);
    const ordered = edgeBoundaries.flatMap(b => b.hits.map(position => ({id: b.id, position}))).sort((a, b) => a.position - b.position);
    const sectorAt = (position: number) => {
      const previous = ordered.filter(b => b.position <= position).at(-1) ?? ordered.at(-1)!;
      return previous.id === "finish" ? 1 : previous.id === "s1" ? 2 : 3;
    };
    for (const isKerb of [false, true]) {
      // Merge contiguous pieces with equal styling, never across an unobserved interval.
      let active: SurfaceFeature | undefined;
      for (let i = 0; i < n; i++) {
        const j = (i + 1) % n, a = edgePoint(i, side, isKerb), b = edgePoint(j, side, isKerb);
        if (!a || !b) {active = undefined; continue;}
        const key = isKerb ? side === "left" ? "kerbLeft" : "kerbRight" : side;
        const confidence = Math.min(isKerb ? 0.3 : 1, measured[i][key]!.confidence, measured[j][key]!.confidence);
        const cuts = [{t: 0, distance: stations[i].distanceM}, {t: 1, distance: stations[i].distanceM + lengths[i]}];
        if (!isKerb) for (const line of boundaries) {
          const t = crossing(a, b, line.a, line.b);
          if (t !== null && t > 1e-8 && t < 1 - 1e-8) cuts.push({t, distance: line.distance});
        }
        cuts.sort((a, b) => a.t - b.t);
        for (let k = 1; k < cuts.length; k++) {
          const lo = cuts[k - 1], hi = cuts[k];
          const sector = !isKerb && canColor ? sectorAt(i + (lo.t + hi.t) / 2) : undefined;
          const weak = isKerb || confidence < 0.4;
          const start = coord(lerp(a, b, lo.t)), end = coord(lerp(a, b, hi.t));
          const kind = isKerb ? "kerb" : sector === undefined ? "road_edge" : "sector_edge";
          if (active && active.properties.sector === sector && active.properties.weak === weak && active.properties.reviewID === measured[i][key]!.reviewID && active.geometry.type === "LineString" &&
              JSON.stringify(active.geometry.coordinates.at(-1)) === JSON.stringify(start)) {
            active.geometry.coordinates.push(end);
            active.properties.confidence = Math.min(active.properties.confidence as number, confidence);
          } else {
            active = {type: "Feature", properties: {...common, kind, side, edgeSide, confidence, weak,
              ...(isKerb ? {raised: "unverified", evidence: measured[i][key]!.reasons.join("; "), confidenceLabel: "low",
                strokePixels: 6, pattern: "red-white", stripeColors: ["#FFFFFF", "#E52222"], reviewID: measured[i][key]!.reviewID} : {}),
              ...(sector === undefined ? {} : {sector, color: SECTOR_COLORS[sector - 1], timingYear: timing!.year, timingSource: timing!.source})},
              geometry: {type: "LineString", coordinates: [start, end]}};
            features.push(active);
          }
        }
      }
    }
  }
  const missing = measured.flatMap((m, i) => ["left", "right"].flatMap(side => m[side as Side] ? [] : [{station: i, distanceM: stations[i].distanceM, side}]));
  let observedRoadSegments = 0;
  for (let i = 0; i < n; i++) {
    const j = (i + 1) % n;
    if (measured[i].left && measured[i].right && measured[j].left && measured[j].right) observedRoadSegments++;
  }
  if (!missing.length) {
    const left = stations.map((_, i) => edgePoint(i, "left")!), right = stations.map((_, i) => edgePoint(i, "right")!);
    const outer = leftIsInner ? right : left, inner = leftIsInner ? left : right;
    const ring = (ps: XY[], ccw: boolean) => {
      const ordered = (signedArea(ps) > 0) === ccw ? ps : [...ps].reverse();
      return [...ordered, ordered[0]].map(coord);
    };
    features.unshift({type: "Feature", properties: {kind: "road_surface", verified: false, fill: "#303030"},
      geometry: {type: "Polygon", coordinates: [ring(outer, true), ring(inner, false)]}});
  } else if (observedPatches) {
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n;
      const quad = [edgePoint(i, "left"), edgePoint(j, "left"), edgePoint(j, "right"), edgePoint(i, "right")];
      if (quad.some(p => !p)) continue;
      const ring = quad as XY[];
      if (signedArea(ring) < 0) ring.reverse();
      features.unshift({type: "Feature", properties: {kind: "road_surface", verified: false, fill: "#303030", coverage: "observed-patch"},
        geometry: {type: "Polygon", coordinates: [[...ring, ring[0]].map(coord)]}});
    }
    issues.push(`${missing.length} unobserved side/stations left open; road polygons contain only observed patches.`);
  } else issues.push(`Road polygon omitted: ${missing.length} unobserved side/stations; gaps are not bridged.`);
  return {type: "FeatureCollection" as const, features, metadata: {...metadata, coordinateReference: "EPSG:4326",
    innerOuterConvention: "Interior/exterior of the closed circuit ring; side is left/right in configured traversal direction.",
    timing, totalLengthM: total, missing, issues, observedRoadFraction: observedRoadSegments / n,
    widths: measured.map((m, i) => ({distanceM: stations[i].distanceM, leftM: m.left?.offsetM ?? null, rightM: m.right?.offsetM ?? null,
      leftConfidence: m.left?.confidence ?? null, rightConfidence: m.right?.confidence ?? null})),
    kerbConfidence: "low everywhere; paint does not establish raised kerb geometry"}};
}

/** A production asset must contain an observed road and all official sectors on both edges.
 * Kerbs remain optional: absence of paint evidence never justifies inventing one.
 */
export function requireCompleteSurface(doc: ReturnType<typeof exportSurface>, observedPatches = false): void {
  if (!doc.features.some(f => f.properties.kind === "road_surface") ||
      (observedPatches ? doc.metadata.observedRoadFraction < 0.7 : doc.metadata.missing.length || doc.metadata.issues.length))
    throw new Error("Incomplete Miami surface: use --diagnostic to inspect missing observations without replacing the app asset");
  for (const side of ["left", "right"]) for (const sector of [1, 2, 3]) {
    if (!doc.features.some(f => f.properties.kind === "sector_edge" && f.properties.side === side && f.properties.sector === sector))
      throw new Error("Miami requires official sectors 1, 2 and 3 on both observed edges");
  }
}
