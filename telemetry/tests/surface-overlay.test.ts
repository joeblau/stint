import {describe, expect, test} from "bun:test";
import {continuousMiamiSurface, controlPointAlignment, exportSurface, requireCompleteSurface, measureStrict, measureMiamiCounty, refineMiamiBoundaries, measureKerbsAlongTrack, rejectDiscontinuities, validCoordinate, type MeasuredStation, type Station, type Timing, type LonLat} from "../src/surface-overlay";
import {unprojectToLonLat} from "../src/trackimport";

const origin = {lat0: 25.958, lon0: -80.239};
const ll = (x: number, y: number): LonLat => {const p = unprojectToLonLat(x, y, origin); return [p.lon, p.lat];};
const stations: Station[] = Array.from({length: 120}, (_, i) => {
  const a = i * Math.PI / 60;
  return {x: 100 * Math.cos(a), y: 100 * Math.sin(a), distanceM: i * 200 * Math.sin(Math.PI / 120), normal: {x: -Math.cos(a), y: -Math.sin(a)}};
});
const observations = (): MeasuredStation[] => stations.map(() => ({left: {offsetM: 4, confidence: 0.7, reasons: []},
  right: {offsetM: 9, confidence: 0.6, reasons: []}, kerbLeft: null, kerbRight: null}));
const timing: Timing = {year: 2026, source: "https://www.fia.com/synthetic-test", placementSource: "Synthetic radial timing lines; not Miami data",
  lines: (["finish", "s1", "s2"] as const).map((id, i) => {const angle = [0.123, 1.31, 4.83][i];
    return {id, coordinates: [ll(70 * Math.cos(angle), 70 * Math.sin(angle)), ll(130 * Math.cos(angle), 130 * Math.sin(angle))]};})};

describe("strict imagery edges", () => {
  const profile = (left: number, right: number, missingRight = false) => {
    const r: number[] = [], g: number[] = [], b: number[] = [];
    for (let i = 0; i <= 200; i++) {
      const offset = i * 0.25 - 25, road = offset <= left && (missingRight || offset >= -right);
      r.push(road ? 100 : 50); g.push(road ? 100 : 140); b.push(road ? 100 : 45);
    }
    return {r, g, b, stepM: 0.25, rangeM: 25};
  };
  test("recovers asymmetric widths independently", () => {
    const result = measureStrict(profile(4, 10));
    expect(Math.abs(result.left!.offsetM - 4)).toBeLessThan(1);
    expect(Math.abs(result.right!.offsetM - 10)).toBeLessThan(1);
    expect(result.kerbLeft).toBeNull(); expect(result.kerbRight).toBeNull();
  });
  test("never mirrors a single observed boundary", () => {
    const result = measureStrict(profile(4, 10, true));
    expect(result.left).not.toBeNull(); expect(result.right).toBeNull();
  });
  test("missing imagery stays missing and corrupt RGB is rejected", () => {
    expect(measureStrict(null).left).toBeNull();
    const p = profile(4, 10); p.r[5] = NaN;
    expect(() => measureStrict(p)).toThrow();
  });
  test("continuity removes an isolated outlier without inventing a replacement", () => {
    const ms = observations(); ms[5].left!.offsetM = 14;
    expect(rejectDiscontinuities(ms)[5].left).toBeNull();
    expect(ms[5].left!.offsetM).toBe(14);
  });
});

describe("longitudinal kerb stripes", () => {
  const painted = (color: "red" | "white" | "grass", offsetM = 5) => {
    const r: number[] = [], g: number[] = [], b: number[] = [];
    for (let i = 0; i <= 200; i++) {
      const d = i * 0.25 - 25;
      const rgb = d >= offsetM && d <= offsetM + 0.75
        ? color === "red" ? [210, 40, 35] : color === "white" ? [235, 235, 235] : [45, 140, 45]
        : Math.abs(d) <= 4.75 ? [100, 100, 100] : [45, 140, 45];
      r.push(rgb[0]); g.push(rgb[1]); b.push(rgb[2]);
    }
    return {r, g, b, stepM: 0.25, rangeM: 25};
  };
  const edges = (count: number): MeasuredStation[] => Array.from({length: count}, () => ({
    left: {offsetM: 5, confidence: 0.7, reasons: []}, right: {offsetM: 5, confidence: 0.7, reasons: []},
    kerbLeft: null, kerbRight: null,
  }));
  test("recovers alternating paint when each cross-profile contains only one color", () => {
    const ps = [painted("red"), painted("red"), painted("white"), painted("white"), painted("red"), painted("white")];
    const result = measureKerbsAlongTrack(ps, edges(ps.length), 1);
    expect(result.every(m => m.kerbLeft !== null)).toBe(true);
    expect(result.every(m => m.kerbRight === null)).toBe(true);
    for (const m of result) {
      expect(m.kerbLeft!.confidence).toBeLessThanOrEqual(0.3);
      expect(m.kerbLeft!.offsetM).toBeCloseTo(5.375);
    }
  });
  test("plain white road markings and isolated red paint are not alternating kerbs", () => {
    for (const color of ["white", "red"] as const) {
      const ps = Array.from({length: 8}, () => painted(color));
      expect(measureKerbsAlongTrack(ps, edges(ps.length), 1).every(m => m.kerbLeft === null)).toBe(true);
    }
  });
  test("does not bridge missing imagery or misaligned paint bands", () => {
    const ps = [null, painted("red"), null, painted("white"), null, painted("red"), painted("white", 6.5), null];
    expect(measureKerbsAlongTrack(ps, edges(ps.length), 1).every(m => m.kerbLeft === null)).toBe(true);
  });
  test("search distance is in meters, rather than a fixed number of samples", () => {
    const ps = [null, painted("red"), painted("red"), painted("red"), painted("white"), null];
    expect(measureKerbsAlongTrack(ps, edges(ps.length), 2)[1].kerbLeft).toBeNull();
    expect(measureKerbsAlongTrack(ps, edges(ps.length), 0.5)[1].kerbLeft).not.toBeNull();
  });
});

describe("Miami county imagery", () => {
  const profile = (paint: boolean) => {
    const r: number[] = [], g: number[] = [], b: number[] = [];
    for (let i = 0; i <= 200; i++) {
      const d = i * 0.25 - 25;
      const cyan = paint && ((d >= 4 && d <= 4.5) || (d <= -9 && d >= -9.5));
      r.push(cyan ? 100 : 105); g.push(cyan ? 145 : 106); b.push(cyan ? 150 : 96);
    }
    return {r, g, b, stepM: 0.25, rangeM: 25};
  };
  test("detects asymmetric turquoise boundaries between asphalt and paved aprons", () => {
    const m = measureMiamiCounty(profile(true));
    expect(m.left!.offsetM).toBeCloseTo(4); expect(m.right!.offsetM).toBeCloseTo(9);
    expect(m.kerbLeft).toBeNull(); expect(m.kerbRight).toBeNull();
  });
  test("neighbor guidance cannot invent an edge on uniform asphalt", () => {
    const ps = Array.from({length: 25}, () => profile(true)); ps[12] = profile(false);
    const result = refineMiamiBoundaries(ps, ps.map(measureMiamiCounty), 1);
    expect(result[12].left).toBeNull(); expect(result[12].right).toBeNull();
  });
});

describe("control-point registration", () => {
  test("fits observed translation and records residuals", () => {
    const cs = [[0, 0], [100, 0], [0, 100], [100, 100]].map(([x, y], i) => ({image: ll(x, y), reference: ll(x + 3, y - 2), label: `control ${i}`}));
    const fit = controlPointAlignment(cs, origin);
    expect(fit.transform.tx).toBeCloseTo(3, 5); expect(fit.transform.ty).toBeCloseTo(-2, 5);
    expect(fit.rmsM).toBeLessThan(0.00001);
  });
  test("rejects collinear controls and excessive residuals", () => {
    const cs = [[0, 0], [100, 0], [200, 0]].map(([x, y], i) => ({image: ll(x, y), reference: ll(x, y), label: `${i}`}));
    expect(() => controlPointAlignment(cs, origin)).toThrow("non-collinear");
    cs[2] = {image: ll(100, 100), reference: ll(107, 94), label: "bad"};
    expect(() => controlPointAlignment(cs, origin, 0.1)).toThrow();
  });
});

describe("GeoJSON surface export", () => {
  test("kerbs on both sides stay weak, uncolored and capped at low confidence", () => {
    const ms = observations();
    for (const m of ms) {
      m.kerbLeft = {offsetM: 4.5, confidence: 0.8, reasons: ["paint candidate"]};
      m.kerbRight = {offsetM: 9.5, confidence: 0.8, reasons: ["paint candidate"]};
    }
    const kerbs = exportSurface(stations, ms, origin, timing, {}).features.filter(f => f.properties.kind === "kerb");
    expect(new Set(kerbs.map(f => f.properties.edgeSide))).toEqual(new Set(["inner", "outer"]));
    for (const f of kerbs) {
      expect(f.geometry.type).toBe("LineString");
      expect(f.properties).toMatchObject({weak: true, confidence: 0.3, raised: "unverified", appearanceReferenceM: 0.05});
      expect(f.properties.color).toBeUndefined();
      expect(f.properties.sector).toBeUndefined();
    }
  });
  test("only complete observed geometry with official sectors is eligible for the app", () => {
    expect(() => requireCompleteSurface(exportSurface(stations, observations(), origin, timing, {}))).not.toThrow();
    expect(() => requireCompleteSurface(exportSurface(stations, observations(), origin, null, {}))).toThrow("--diagnostic");
    const missing = observations(); missing[20].left = null;
    expect(() => requireCompleteSurface(exportSurface(stations, missing, origin, timing, {}))).toThrow("--diagnostic");
  });
  test("records independent widths and missing evidence for review", () => {
    const ms = observations(); ms[20].left = null;
    const doc = exportSurface(stations, ms, origin, timing, {});
    expect(doc.metadata.widths[0]).toMatchObject({leftM: 4, rightM: 9});
    expect(doc.metadata.widths[20]).toMatchObject({leftM: null, rightM: 9, leftConfidence: null});
  });
  test("rejects malformed coordinates and multi-segment timing lines", () => {
    for (const c of [null, {}, [1], [1, 2, 3], [NaN, 2], ["1", 2]]) expect(validCoordinate(c)).toBe(false);
    const invalid = structuredClone(timing);
    (invalid.lines[0].coordinates as LonLat[]).push(ll(500, 500));
    expect(() => exportSurface(stations, observations(), origin, invalid, {})).toThrow("three sourced");
  });
  test("uses actual unequal timing cuts, closes rings and never colors the polygon", () => {
    const doc = exportSurface(stations, observations(), origin, timing, {});
    const road = doc.features.find(f => f.properties.kind === "road_surface")!;
    expect(road.geometry.type).toBe("Polygon"); expect(road.properties.color).toBeUndefined();
    if (road.geometry.type === "Polygon") for (const ring of road.geometry.coordinates) {
      expect(ring[0]).toEqual(ring.at(-1)!); expect(ring.every(p => p.length === 2)).toBe(true);
    }
    const edges = doc.features.filter(f => f.properties.kind === "sector_edge");
    expect(new Set(edges.map(f => f.properties.sector))).toEqual(new Set([1, 2, 3]));
    for (const side of ["left", "right"]) {
      const sizes = [1, 2, 3].map(sector => edges.filter(f => f.properties.side === side && f.properties.sector === sector)
        .reduce((n, f) => n + f.geometry.coordinates.length, 0));
      expect(sizes[1]).toBeGreaterThan(sizes[0] * 2);
    }
    expect(doc.metadata.issues).toEqual([]);
  });
  test("preserves observed gaps instead of emitting a fabricated full polygon", () => {
    const ms = observations(); ms[20].left = null;
    const doc = exportSurface(stations, ms, origin, timing, {});
    expect(doc.features.some(f => f.geometry.type === "Polygon")).toBe(false);
    expect(doc.metadata.missing).toHaveLength(1);
  });
  test("no official timing means no colored edges", () => {
    const doc = exportSurface(stations, observations(), origin, null, {});
    expect(doc.features.every(f => f.properties.sector === undefined && f.properties.color === undefined)).toBe(true);
  });
  test("rejects timing lines that miss the circuit or disagree with direction", () => {
    const invalid = structuredClone(timing); invalid.lines[1].coordinates = [ll(500, 500), ll(600, 600)];
    expect(() => exportSurface(stations, observations(), origin, invalid, {})).toThrow("exactly once");
    const reversed = structuredClone(timing);
    [reversed.lines[1].coordinates, reversed.lines[2].coordinates] = [reversed.lines[2].coordinates, reversed.lines[1].coordinates];
    expect(() => exportSurface(stations, observations(), origin, reversed, {})).toThrow("traversal");
  });
  test("a hidden timing crossing keeps observed sectors colored without bridging the gap", () => {
    const ms = observations(); ms[2].left = null; ms[3].left = null;
    const doc = exportSurface(stations, ms, origin, timing, {});
    expect(new Set(doc.features.filter(f => f.properties.side === "left").map(f => f.properties.sector))).toEqual(new Set([1, 2, 3]));
    expect(doc.metadata.missing).toHaveLength(2);
    expect(doc.features.some(f => f.properties.side === "right" && f.properties.sector === 1)).toBe(true);
  });
  test("observed patches preserve a missing station and require substantial surface coverage", () => {
    const ms = observations(); ms[20].left = null;
    const doc = exportSurface(stations, ms, origin, timing, {}, 2, true);
    expect(doc.features.filter(f => f.properties.kind === "road_surface")).toHaveLength(118);
    expect(doc.metadata.observedRoadFraction).toBeCloseTo(118 / 120);
    expect(() => requireCompleteSurface(doc, true)).not.toThrow();
    expect(() => requireCompleteSurface(doc)).toThrow();
    for (let i = 0; i < 80; i++) ms[i].left = null;
    expect(() => requireCompleteSurface(exportSurface(stations, ms, origin, timing, {}, 2, true), true)).toThrow();
  });
});


describe("Miami continuous display refinement", () => {
  const spacing = 200 * Math.sin(Math.PI / 120);
  test("closes shadow gaps and the lap seam without mirroring widths or losing evidence", () => {
    const ms = observations();
    for (const i of [0, 1, 2, 118, 119, 45, 46, 47]) ms[i].left = null;
    const before = structuredClone(ms);
    const refined = continuousMiamiSurface(stations, ms, spacing);
    expect(ms).toEqual(before);
    expect(refined.audit.inferredStations).toHaveLength(8);
    for (const m of refined.measured) {
      expect(m.left!.offsetM).toBeCloseTo(4, 8);
      expect(m.right!.offsetM).toBeCloseTo(9, 8);
    }
    const doc = exportSurface(stations, refined.measured, origin, timing, {});
    expect(doc.features.filter(f => f.properties.kind === "road_surface")).toHaveLength(1);
    expect(doc.metadata.missing).toHaveLength(0);
    expect(() => requireCompleteSurface(doc)).not.toThrow();
  });
  test("rejects isolated width spikes and weak apron detections while preserving gradual widening", () => {
    const ms = observations();
    ms[30].left!.offsetM = 18;
    for (let i = 45; i < 55; i++) ms[i].right = {offsetM: 20, confidence: 0.2, reasons: ["shadow"]};
    for (let i = 70; i < 100; i++) ms[i].right!.offsetM = 9 + 3 * Math.sin((i - 70) * Math.PI / 30);
    const result = continuousMiamiSurface(stations, ms, spacing).measured;
    expect(result[30].left!.offsetM).toBeCloseTo(4);
    expect(result[50].right!.offsetM).toBeCloseTo(9);
    expect(result[85].right!.offsetM).toBeGreaterThan(11.5);
    expect(result[50].right!.inferred).toBe(true);
  });
  test("retains coherent corner paint but discards isolated markings and absent kerbs", () => {
    const ms = observations();
    ms[4].kerbLeft = {offsetM: 4, confidence: 0.2, reasons: ["white mark"]};
    for (let i = 40; i < 50; i++) ms[i].kerbLeft = {offsetM: 4, confidence: 0.2, reasons: ["corner paint"]};
    const result = continuousMiamiSurface(stations, ms, spacing).measured;
    expect(result[4].kerbLeft).toBeNull();
    expect(result[45].kerbLeft!.confidence).toBeLessThanOrEqual(0.3);
    expect(result.every(m => m.kerbRight === null)).toBe(true);
  });
  test("refuses to invent a circuit without enough reliable imagery", () => {
    const ms = observations();
    for (let i = 0; i < 70; i++) ms[i].left = null;
    expect(() => continuousMiamiSurface(stations, ms, spacing)).toThrow("Insufficient left evidence");
  });
  test("constrains inside offsets through tight bends instead of creating folds or gaps", () => {
    const tight = stations.map(s => ({...s, x: s.x / 20, y: s.y / 20, distanceM: s.distanceM / 20}));
    const ms = observations();
    for (const m of ms) m.left!.offsetM = 7;
    const result = continuousMiamiSurface(tight, ms, spacing / 20).measured;
    for (const m of result) {
      expect(m.left!.offsetM).toBeGreaterThan(4);
      expect(m.left!.offsetM).toBeLessThan(5);
      expect(m.right!.offsetM).toBeCloseTo(9);
      expect(m.left!.inferred).toBe(true);
    }
  });
});
