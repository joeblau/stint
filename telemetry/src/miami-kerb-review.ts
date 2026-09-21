/** Reviewed Miami paint strips. Onboard video establishes presence, while the licensed
 * georeferenced raster supplies positions. Hidden positions remain explicit estimates. */
import type {RgbProfile} from "./imagery";
import type {MeasuredStation, Side, Station} from "./surface-overlay";

interface Anchor {distanceM: number; offsetM: number}
export interface PaintSpan {
  id: string; side: Side; startM: number; endM: number; anchors?: Anchor[]; evidence: string;
}
export interface ReviewedKerb extends PaintSpan {
  turns: number[]; onboardSeconds: [number, number]; presence: "seen-onboard"; endpointUncertaintyM: number;
}
export interface MiamiKerbReview {
  schemaVersion: number; circuit: string; year: number; imagerySha256: string; centerlineSha256: string;
  sources: {onboard: {url: string; publisher: string; durationS: number}};
  curbs: ReviewedKerb[]; boundaryGuides: PaintSpan[];
  occlusions?: {startM: number; endM: number; reason: string}[];
  turns: {turn: number; reviewStatus: string; kerbIDs: string[]; onboardFinding: string}[];
}
export interface TracedSpan {
  span: PaintSpan; samples: {station: number; offsetM: number; observed: boolean; score: number}[];
}
const wrap = (value: number, length: number) => (value % length + length) % length;

export function validateMiamiKerbReview(review: MiamiKerbReview, imageHash: string, centerlineHash: string, lengthM: number) {
  if (review.schemaVersion !== 1 || review.circuit !== "miami" || review.year !== 2026 ||
      review.imagerySha256 !== imageHash || review.centerlineSha256 !== centerlineHash)
    throw new Error("Miami kerb review does not match the circuit, event or source hashes");
  if (!review.sources?.onboard?.url.startsWith("https://") || review.sources.onboard.publisher !== "FORMULA 1")
    throw new Error("Miami kerb review requires its official onboard reference");
  const ids = new Set<string>();
  for (const gap of review.occlusions ?? []) if (!Number.isFinite(gap.startM) || !Number.isFinite(gap.endM) ||
    gap.startM < 0 || gap.endM >= lengthM || gap.endM <= gap.startM || !gap.reason.trim())
    throw new Error("Invalid reviewed imagery occlusion");
  for (const span of [...review.curbs, ...review.boundaryGuides]) {
    if (!span.id || ids.has(span.id) || !["left", "right"].includes(span.side) || !span.evidence?.trim() ||
        ![span.startM, span.endM].every(d => Number.isFinite(d) && d >= 0 && d < lengthM) ||
        wrap(span.endM - span.startM, lengthM) < 2 || wrap(span.endM - span.startM, lengthM) > lengthM / 4)
      throw new Error("Invalid or duplicate reviewed Miami paint span");
    ids.add(span.id);
    if (span.anchors) {
      const distances = span.anchors.map(a => wrap(a.distanceM - span.startM, lengthM));
      if (span.anchors.length < 2 || span.anchors.some((a, i) => !Number.isFinite(a.offsetM) || a.offsetM < 1 || a.offsetM > 20 ||
          !Number.isFinite(a.distanceM) || a.distanceM < 0 || a.distanceM >= lengthM || distances[i] > wrap(span.endM - span.startM, lengthM) ||
          (i > 0 && distances[i] <= distances[i - 1]))) throw new Error("Invalid Miami paint guide anchors");
    }
  }
  for (const kerb of review.curbs) if (kerb.presence !== "seen-onboard" || !kerb.turns.length ||
    kerb.turns.some(t => !Number.isInteger(t) || t < 1 || t > 19) || !Number.isFinite(kerb.endpointUncertaintyM) || kerb.endpointUncertaintyM <= 0 ||
    kerb.onboardSeconds.length !== 2 || !kerb.onboardSeconds.every(Number.isFinite) ||
    kerb.onboardSeconds[0] < 0 || kerb.onboardSeconds[1] <= kerb.onboardSeconds[0] || kerb.onboardSeconds[1] > review.sources.onboard.durationS)
    throw new Error("Reviewed kerbs require valid turn, uncertainty and onboard timestamp evidence");
  if (review.turns.length !== 19 || new Set(review.turns.map(t => t.turn)).size !== 19 ||
      review.turns.some(t => t.turn < 1 || t.turn > 19 || t.reviewStatus !== "reviewed" || !t.onboardFinding ||
        JSON.stringify([...t.kerbIDs].sort()) !== JSON.stringify(review.curbs.filter(k => k.turns.includes(t.turn)).map(k => k.id).sort())))
    throw new Error("Miami requires a complete, consistent review of all 19 turns");
}

/** Paint likelihood at a profile offset, including faded warm/white kerbs. A spatial
 * path tracks the band longitudinally; individual bright parking lines cannot yank it. */
function paintScore(profile: RgbProfile | null, offsetM: number, side: Side) {
  if (!profile) return 0;
  const center = Math.round(profile.rangeM / profile.stepM), sign = side === "left" ? 1 : -1;
  const index = Math.round(center + sign * offsetM / profile.stepM);
  if (index < 2 || index >= profile.r.length - 2) return 0;
  const light = (i: number) => (profile.r[i] + profile.g[i] + profile.b[i]) / 3;
  if (light(center) < 35) return 0;
  const rgb = [profile.r[index], profile.g[index], profile.b[index]];
  const chroma = Math.max(...rgb) - Math.min(...rgb);
  const neutral = Math.max(0, 1 - chroma / 65);
  const brightness = Math.max(0, (light(index) - light(center) - 8) / 55) * neutral;
  const warm = Math.max(0, Math.min(1, (rgb[0] - rgb[2] - 10) / 25)) *
    Math.max(0, Math.min(1, (light(index) - light(center) + 5) / 25));
  const contrast = Math.max(0, (light(index) - Math.min(light(index - 2), light(index + 2))) / 60);
  return Math.min(2, brightness + warm * 0.45 + contrast * 0.35);
}

/** Trace only review-selected strips. Guides narrow the search; measured pixels choose
 * the final position. Occluded intervals use a smooth path with observed=false. */
export function traceReviewedMiamiPaint(stations: Station[], profiles: (RgbProfile | null)[], input: MeasuredStation[],
  prior: MeasuredStation[], review: MiamiKerbReview, lengthM: number) {
  if (stations.length !== profiles.length || stations.length !== input.length || stations.length !== prior.length)
    throw new Error("Miami paint tracing inputs have different station counts");
  const measured = input.map(m => ({...m})), traces: TracedSpan[] = [];
  const spacing = lengthM / stations.length;
  const hidden = stations.map(s => (review.occlusions ?? []).some(g => s.distanceM >= g.startM && s.distanceM <= g.endM));
  const sourceAt = (i: number) => hidden[i] ? null : profiles[i];
  for (const span of [...review.curbs, ...review.boundaryGuides]) {
    const spanLength = wrap(span.endM - span.startM, lengthM);
    const indices = stations.flatMap((s, station) => {
      const d = wrap(s.distanceM - span.startM, lengthM); return d <= spanLength ? [{station, d}] : [];
    }).sort((a, b) => a.d - b.d);
    const guideAt = (station: number, d: number) => {
      // A reviewed road guide also constrains overlapping kerbs. Otherwise an old
      // apron detection could remain in the kerb audit after the road was corrected.
      const guide = span.anchors ? span : review.boundaryGuides.find(g => g.side === span.side && g.anchors &&
        wrap(stations[station].distanceM - g.startM, lengthM) <= wrap(g.endM - g.startM, lengthM));
      if (!guide?.anchors) return prior[station][span.side]!.offsetM + 0.25;
      const distance = wrap(stations[station].distanceM - guide.startM, lengthM);
      const anchors = guide.anchors.map(a => ({...a, d: wrap(a.distanceM - guide.startM, lengthM)}));
      const hi = anchors.findIndex(a => a.d >= distance);
      if (hi === 0) return anchors[0].offsetM;
      if (hi < 0) return anchors.at(-1)!.offsetM;
      const a = anchors[hi - 1], b = anchors[hi];
      return a.offsetM + (b.offsetM - a.offsetM) * (distance - a.d) / (b.d - a.d);
    };
    const positions = indices.map(({station, d}) => {
      const guide = guideAt(station, d);
      return Array.from({length: 21}, (_, k) => Math.max(1.25, Math.min(20, guide + (k - 10) * 0.25)));
    });
    let costs = new Float64Array(21);
    const back: Int16Array[] = [];
    for (let i = 0; i < indices.length; i++) {
      const next = new Float64Array(21), links = new Int16Array(21);
      for (let k = 0; k < 21; k++) {
        const offset = positions[i][k], unary = -paintScore(sourceAt(indices[i].station), offset, span.side) + ((k - 10) * 0.25) ** 2 * 0.06;
        let best = Infinity, previous = 0;
        if (i) for (let q = 0; q < 21; q++) {
          const delta = offset - positions[i - 1][q];
          const cost = costs[q] + delta ** 2 * 3 / spacing;
          if (cost < best) {best = cost; previous = q;}
        }
        next[k] = unary + (i ? best : 0); links[k] = previous;
      }
      costs = next; back.push(links);
    }
    let state = costs.indexOf(Math.min(...costs));
    const samples: TracedSpan["samples"] = [];
    for (let i = indices.length - 1; i >= 0; i--) {
      const station = indices[i].station, offsetM = positions[i][state], score = paintScore(sourceAt(station), offsetM, span.side);
      const observed = score >= 0.3;
      samples.push({station, offsetM, observed, score});
      measured[station][span.side] = observed ? {offsetM: Math.max(1, offsetM - 0.25), confidence: 0.65,
        reasons: [`Reviewed paint trace: ${span.id}`, span.evidence]} : null;
      state = back[i][state];
    }
    samples.reverse(); traces.push({span, samples});
  }
  for (let i = 0; i < measured.length; i++) if (hidden[i]) {measured[i].left = null; measured[i].right = null;}
  return {measured, traces};
}

export function applyReviewedMiamiKerbs(measured: MeasuredStation[], traces: TracedSpan[], review: MiamiKerbReview) {
  const result = measured.map(m => ({...m, kerbLeft: null, kerbRight: null} as MeasuredStation));
  const audit = review.curbs.map(kerb => {
    const trace = traces.find(t => t.span.id === kerb.id);
    if (!trace || trace.samples.length < 2) throw new Error(`Missing reviewed kerb trace: ${kerb.id}`);
    for (const sample of trace.samples) {
      const edge = result[sample.station][kerb.side];
      if (!edge) throw new Error("Reviewed kerbs require a continuous road boundary");
      result[sample.station][kerb.side === "left" ? "kerbLeft" : "kerbRight"] = {
        offsetM: edge.offsetM + 0.3, confidence: sample.observed ? 0.25 : 0.15, inferred: !sample.observed,
        reviewID: kerb.id, reasons: [kerb.evidence, `Onboard: ${review.sources.onboard.url}, ${kerb.onboardSeconds.join("–")} s`,
          "Paint presence reviewed; geolocation and endpoints approximate; red/white display styling"]};
    }
    return {...kerb, observedFraction: trace.samples.filter(s => s.observed).length / trace.samples.length,
      inferredStations: trace.samples.filter(s => !s.observed).map(s => s.station),
      samples: trace.samples};
  });
  return {measured: result, audit};
}
