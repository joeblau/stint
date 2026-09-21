import { describe, expect, test } from "bun:test";
import { asphaltScore, classifyKerb, edgeCandidates, fuseWidths, intensity, lonLatToGlobalPx, measureWidth,
  medianSmooth, metersPerPixel, pearson, tilesForBuffer, HALF_WIDTH_MAX, HALF_WIDTH_MIN,
  type KerbStripStats, type LapMeasurement, type RgbProfile } from "../src/imagery";

/** Synthetic cross-profile: a gray asphalt band of half-widths [leftM, rightM] on a colored background. */
function syntheticProfile(leftM: number, rightM: number, inside: [number, number, number], outside: [number, number, number],
  noise = 5): RgbProfile {
  const stepM = 0.25, rangeM = 25, n = Math.round(2 * rangeM / stepM) + 1;
  const r: number[] = [], g: number[] = [], b: number[] = [];
  let seed = 42;
  const rand = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff - 0.5;
  for (let k = 0; k < n; k++) {
    const d = k * stepM - rangeM; // negative = right side, positive = left side
    const on = d >= -rightM && d <= leftM ? inside : outside;
    r.push(on[0] + rand() * noise * 2); g.push(on[1] + rand() * noise * 2); b.push(on[2] + rand() * noise * 2);
  }
  return {r, g, b, stepM, rangeM};
}

const ASPHALT: [number, number, number] = [100, 100, 100];
const GRASS: [number, number, number] = [45, 115, 45];

describe("Web-Mercator tile math", () => {
  test("meters per pixel matches known z18 resolutions", () => {
    expect(metersPerPixel(0, 18)).toBeCloseTo(0.5972, 3);
    expect(metersPerPixel(34.84, 18)).toBeCloseTo(0.4904, 3); // Suzuka latitude
    expect(metersPerPixel(43.7, 17)).toBeCloseTo(0.863, 2); // Monaco-ish latitude, one zoom out doubles m/px
  });
  test("global pixel origin and scale", () => {
    expect(lonLatToGlobalPx(-180, 85.05112878, 18).x).toBeCloseTo(0, 6);
    expect(lonLatToGlobalPx(180, -85.05112878, 18).y).toBeCloseTo(256 * 2 ** 18, 0);
    const a = lonLatToGlobalPx(136.54, 34.84, 18), b = lonLatToGlobalPx(136.54, 34.84, 19);
    expect(b.x / a.x).toBeCloseTo(2, 9); expect(b.y / a.y).toBeCloseTo(2, 6);
  });
  test("tilesForBuffer covers the buffered disc and dedupes", () => {
    const points = [{lon: 136.541, lat: 34.843}, {lon: 136.5415, lat: 34.8432}];
    const tiles = tilesForBuffer(points, 60, 18);
    expect(tiles.length).toBeGreaterThanOrEqual(4);
    const keys = new Set(tiles.map(t => `${t.x},${t.y}`));
    expect(keys.size).toBe(tiles.length);
    for (const p of points) {
      const c = lonLatToGlobalPx(p.lon, p.lat, 18);
      expect(keys.has(`${Math.floor(c.x / 256)},${Math.floor(c.y / 256)}`)).toBe(true);
    }
  });
});

describe("surface scoring", () => {
  test("asphalt gray scores high; grass, gravel, red paint and bright white score low", () => {
    expect(asphaltScore(100, 100, 100)).toBeGreaterThan(0.9);
    expect(asphaltScore(70, 70, 70)).toBeGreaterThan(0.9);
    expect(asphaltScore(...GRASS)).toBeLessThan(0.2);
    expect(asphaltScore(170, 150, 110)).toBeLessThan(0.5); // tan gravel
    expect(asphaltScore(200, 40, 40)).toBe(0); // red kerb paint
    expect(asphaltScore(245, 245, 245)).toBe(0); // bright paint/concrete excluded
    expect(asphaltScore(30, 45, 80)).toBeLessThan(0.3); // water/blue
  });
  test("intensity weights green dominant", () => {
    expect(intensity(0, 255, 0)).toBeGreaterThan(intensity(255, 0, 0));
  });
});

describe("edge detection and width measurement", () => {
  test("recovers a known 24 m symmetric asphalt band on grass within 1 m", () => {
    const m = measureWidth(syntheticProfile(12, 12, ASPHALT, GRASS));
    expect(m.leftM).not.toBeNull(); expect(m.rightM).not.toBeNull();
    expect(Math.abs(m.leftM! - 12)).toBeLessThanOrEqual(1);
    expect(Math.abs(m.rightM! - 12)).toBeLessThanOrEqual(1);
    expect(m.confidence).toBeGreaterThan(0.8);
  });
  test("recovers asymmetric half-widths (13 m left, 8 m right)", () => {
    const m = measureWidth(syntheticProfile(13, 8, ASPHALT, GRASS));
    expect(Math.abs(m.leftM! - 13)).toBeLessThanOrEqual(1);
    expect(Math.abs(m.rightM! - 8)).toBeLessThanOrEqual(1);
  });
  test("narrow street-circuit band of 9 m full width stays inside the plausibility band", () => {
    const m = measureWidth(syntheticProfile(4.5, 4.5, ASPHALT, GRASS));
    expect(m.leftM! + m.rightM!).toBeGreaterThanOrEqual(7);
    expect(Math.abs(m.leftM! - 4.5)).toBeLessThanOrEqual(1);
  });
  test("band wider than the 30 m plausibility cap yields no edge (honest null, not a clamp)", () => {
    const m = measureWidth(syntheticProfile(18, 18, ASPHALT, GRASS));
    expect(m.leftM).toBeNull(); expect(m.rightM).toBeNull(); expect(m.confidence).toBe(0);
  });
  test("gradient-only edge (asphalt to light concrete wall) is detected at reduced confidence", () => {
    const m = measureWidth(syntheticProfile(6, 6, [95, 95, 95], [175, 175, 175]));
    expect(m.leftM).not.toBeNull();
    expect(Math.abs(m.leftM! - 6)).toBeLessThanOrEqual(1);
    expect(m.confidence).toBeLessThan(0.75);
    expect(m.reasons.join(" ")).toMatch(/gradient/);
  });
  test("uniform grass yields no measurement", () => {
    const m = measureWidth(syntheticProfile(0, 0, GRASS, GRASS));
    expect(m.leftM).toBeNull(); expect(m.rightM).toBeNull(); expect(m.confidence).toBe(0);
  });
  test("dark profile (tunnel/shadow) is flagged and de-confidenced", () => {
    const m = measureWidth(syntheticProfile(6, 6, [36, 36, 36], [30, 30, 30]));
    expect(m.dark).toBe(true);
    expect(m.confidence).toBeLessThan(0.45);
  });
  test("edgeCandidates localizes within the plausibility window", () => {
    const c = edgeCandidates(syntheticProfile(10, 10, ASPHALT, GRASS), 1);
    expect(c.length).toBeGreaterThan(0);
    expect(c[0].offsetM).toBeGreaterThanOrEqual(HALF_WIDTH_MIN);
    expect(Math.abs(c[0].offsetM - 10)).toBeLessThanOrEqual(1);
  });
});

describe("along-lap fusion", () => {
  const mk = (n: number, left: (number | null)[], conf: number[]): LapMeasurement[] =>
    Array.from({length: n}, (_, i) => ({index: i, distanceM: i * 5, leftM: left[i], rightM: left[i], confidence: conf[i], dark: false}));
  test("medianSmooth ignores nulls and kills spikes", () => {
    const out = medianSmooth([6, 6, 12, 6, null, 6, 6], 5);
    expect(out[2]).toBe(6); expect(out[4]).toBeNull();
  });
  test("confident measurements pass through, short gaps interpolate, long gaps fall back to prior", () => {
    const n = 40, prior = Array.from({length: n}, () => ({leftM: 5.5, rightM: 5.5}));
    const left = Array.from({length: n}, () => 7 as number | null), conf = Array.from({length: n}, () => 0.9);
    for (let i = 10; i < 14; i++) {left[i] = null; conf[i] = 0;} // 20 m gap -> interpolated
    for (let i = 20; i < 36; i++) {left[i] = null; conf[i] = 0;} // 80 m gap -> fallback
    const fused = fuseWidths(mk(n, left, conf), prior, 5);
    expect(fused.status[0]).toBe("measured");
    expect(fused.status[12]).toBe("interpolated");
    expect(fused.leftM[12]).toBeGreaterThan(5.5); expect(fused.leftM[12]).toBeLessThanOrEqual(7);
    expect(fused.status[28]).toBe("fallback");
    expect(fused.leftM[28]).toBe(5.5);
  });
  test("fully unmeasured lap keeps all prior widths", () => {
    const n = 10, prior = Array.from({length: n}, () => ({leftM: 6, rightM: 6}));
    const fused = fuseWidths(mk(n, Array(n).fill(null), Array(n).fill(0)), prior, 5);
    expect(fused.status.every(s => s === "fallback")).toBe(true);
    expect(fused.leftM.every(v => v === 6)).toBe(true);
  });
});

describe("kerb classification", () => {
  const stats = (over: Partial<KerbStripStats>): KerbStripStats =>
    ({id: "s", total: 400, red: 80, white: 60, maxRedRunM: 18, alternations: 5, stationRed: [], stationWhite: [],
      bestRowM: 1, polygon: null, ...over});
  test("striped red/white kerb detected", () => {
    expect(classifyKerb(stats({})).detected).toBe(true);
  });
  test("strong solid-red kerb band detected even when white stripes blur out", () => {
    expect(classifyKerb(stats({white: 0, alternations: 0})).detected).toBe(true);
  });
  test("weak red runoff paint without white or striping is not a kerb", () => {
    expect(classifyKerb(stats({red: 30, white: 0, alternations: 0})).detected).toBe(false);
  });
  test("isolated red specks without an elongated run are not a kerb", () => {
    expect(classifyKerb(stats({maxRedRunM: 2})).detected).toBe(false);
  });
  test("too few pixels is honest ignorance", () => {
    expect(classifyKerb(stats({total: 5})).reason).toMatch(/too few/);
  });
});

describe("cross-validation statistics", () => {
  test("pearson of identical series is 1, of inverted is -1", () => {
    const x = [1, 2, 3, 4, 5, 6], y = [2, 4, 5, 8, 9, 13];
    expect(pearson(x, x)).toBeCloseTo(1, 9);
    expect(pearson(x, x.map(v => -v))).toBeCloseTo(-1, 9);
    expect(Math.abs(pearson(x, y))).toBeLessThanOrEqual(1);
  });
});
