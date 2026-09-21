import {describe, expect, test} from "bun:test";
import {applyReviewedMiamiKerbs, traceReviewedMiamiPaint, validateMiamiKerbReview, type MiamiKerbReview} from "../src/miami-kerb-review";
import type {MeasuredStation, Station} from "../src/surface-overlay";
import type {RgbProfile} from "../src/imagery";
import actualReview from "../geometry/reference/miami-kerb-review.json";

const stations: Station[] = Array.from({length: 100}, (_, i) => ({x: i, y: 0, normal: {x: 0, y: 1}, distanceM: i}));
const widths = (): MeasuredStation[] => stations.map(() => ({left: {offsetM: 7, confidence: 0.7, reasons: []},
  right: {offsetM: 5, confidence: 0.7, reasons: []}, kerbLeft: null, kerbRight: null}));
function review(startM = 20, endM = 70): MiamiKerbReview {
  return {schemaVersion: 1, circuit: "miami", year: 2026, imagerySha256: "image", centerlineSha256: "centerline",
    sources: {onboard: {url: "https://example.com/synthetic", publisher: "FORMULA 1", durationS: 100}},
    curbs: [{id: "test-strip", side: "left", startM, endM, turns: [1], evidence: "Synthetic warm/white strip",
      presence: "seen-onboard", onboardSeconds: [1, 2], endpointUncertaintyM: 8}], boundaryGuides: [],
    turns: Array.from({length: 19}, (_, i) => ({turn: i + 1, reviewStatus: "reviewed", kerbIDs: i ? [] : ["test-strip"], onboardFinding: "Synthetic fixture"}))};
}
function profiles(): RgbProfile[] {
  return stations.map((_, i) => {
    const channels = {r: Array(201).fill(80), g: Array(201).fill(80), b: Array(201).fill(80)};
    for (let k = 128; k <= 132; k++) {
      channels.r[k] = i % 6 < 3 ? 175 : 150;
      channels.g[k] = i % 6 < 3 ? 175 : 125;
      channels.b[k] = i % 6 < 3 ? 175 : 95;
    }
    // A brighter parking stripe beyond the reviewed racing corridor is a distractor.
    for (let k = 156; k <= 160; k++) for (const channel of Object.values(channels)) channel[k] = 255;
    return {...channels, stepM: 0.25, rangeM: 25};
  });
}

describe("reviewed Miami kerb inventory", () => {
  test("actual inventory covers all 19 turns and binds its source rasters", () => {
    const r = actualReview as unknown as MiamiKerbReview;
    expect(() => validateMiamiKerbReview(r, r.imagerySha256, r.centerlineSha256, 5431.94)).not.toThrow();
    expect(r.curbs).toHaveLength(25);
    expect(r.turns.filter(t => !t.kerbIDs.length).map(t => t.turn)).toEqual([9, 10]);
    expect(() => validateMiamiKerbReview(r, "different image", r.centerlineSha256, 5431.94)).toThrow("source hashes");
    const incomplete = structuredClone(r); incomplete.turns.pop();
    expect(() => validateMiamiKerbReview(incomplete, r.imagerySha256, r.centerlineSha256, 5431.94)).toThrow("all 19 turns");
  });
  test("follows faded warm/white paint without jumping to brighter parking stripes", () => {
    const r = review(), before = widths(), source = structuredClone(before);
    const result = traceReviewedMiamiPaint(stations, profiles(), source, widths(), r, 100);
    expect(source).toEqual(before);
    expect(result.traces[0].samples.every(s => s.offsetM >= 7 && s.offsetM <= 8)).toBe(true);
    expect(result.traces[0].samples.every(s => s.observed)).toBe(true);
    expect(result.measured[40].left!.offsetM).toBeLessThan(8);
    expect(result.measured[40].right!.offsetM).toBe(5);
  });
  test("keeps reviewed exit kerbs on straights and flags occluded positions", () => {
    const r = review(), ps = profiles();
    for (let i = 40; i <= 47; i++) for (const c of [ps[i].r, ps[i].g, ps[i].b]) c.fill(0);
    const traced = traceReviewedMiamiPaint(stations, ps, widths(), widths(), r, 100);
    const output = applyReviewedMiamiKerbs(widths(), traced.traces, r);
    expect(output.audit[0].inferredStations).toEqual([40, 41, 42, 43, 44, 45, 46, 47]);
    for (let i = 20; i <= 70; i++) {
      expect(output.measured[i].kerbLeft!.reviewID).toBe("test-strip");
      expect(output.measured[i].kerbLeft!.confidence).toBeLessThanOrEqual(0.3);
    }
    expect(output.measured[43].kerbLeft!.inferred).toBe(true);
    expect(output.measured[19].kerbLeft).toBeNull();
    expect(output.measured[71].kerbLeft).toBeNull();
  });
  test("traces through the lap seam without dropping the start/finish strip", () => {
    const r = review(85, 15);
    const traced = traceReviewedMiamiPaint(stations, profiles(), widths(), widths(), r, 100);
    expect(traced.traces[0].samples.map(s => s.station)).toEqual([...Array.from({length: 15}, (_, i) => i + 85), ...Array.from({length: 16}, (_, i) => i)]);
    const output = applyReviewedMiamiKerbs(widths(), traced.traces, r);
    expect(output.measured[99].kerbLeft).not.toBeNull();
    expect(output.measured[0].kerbLeft).not.toBeNull();
    expect(output.measured[50].kerbLeft).toBeNull();
  });
  test("a missing trace cannot silently remove a reviewed kerb", () => {
    expect(() => applyReviewedMiamiKerbs(widths(), [], review())).toThrow("Missing reviewed kerb trace");
  });
  test("bridge deck pixels cannot masquerade as observed road or kerbs", () => {
    const r = review(); r.occlusions = [{startM: 40, endM: 47, reason: "Synthetic bridge"}];
    const traced = traceReviewedMiamiPaint(stations, profiles(), widths(), widths(), r, 100);
    for (let i = 40; i <= 47; i++) {
      expect(traced.measured[i].left).toBeNull();
      expect(traced.measured[i].right).toBeNull();
    }
    const output = applyReviewedMiamiKerbs(widths(), traced.traces, r);
    expect(output.audit[0].inferredStations).toEqual([40, 41, 42, 43, 44, 45, 46, 47]);
    expect(output.measured[43].kerbLeft!.inferred).toBe(true);
  });
  test("reviewed road guides correct an overlapping kerb's erroneous apron prior", () => {
    const r = review(), prior = widths();
    for (const m of prior) m.left!.offsetM = 14;
    r.boundaryGuides = [{id: "road-guide", side: "left", startM: 20, endM: 70, evidence: "Synthetic observed racing boundary",
      anchors: [{distanceM: 20, offsetM: 7.5}, {distanceM: 70, offsetM: 7.5}]}];
    const output = traceReviewedMiamiPaint(stations, profiles(), widths(), prior, r, 100);
    expect(output.traces.find(t => t.span.id === "test-strip")!.samples.every(s => s.offsetM >= 7 && s.offsetM <= 8)).toBe(true);
  });
});
