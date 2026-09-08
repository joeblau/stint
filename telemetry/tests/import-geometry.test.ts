import { describe, expect, test } from "bun:test";
import { alignClosedLoops, applyTransform, fitSimilarity, parseCircuitGeojson, parseTumftmCsv, resampleClosed, synthesizeKerbs, type CenterlinePoint } from "../src/trackimport";

// Asymmetric closed loop (rounded triangle-ish blob) so phase and direction are identifiable.
const loop: CenterlinePoint[] = Array.from({length: 720}, (_, i) => {
  const t = i / 720 * 2 * Math.PI, r = 400 + 120 * Math.sin(t) + 60 * Math.cos(2 * t) + 30 * Math.sin(3 * t);
  return {x: r * Math.cos(t), y: r * Math.sin(t) * .8, wr: 6 + Math.sin(t), wl: 7 + Math.cos(t)};
});

test("TUMFTM CSV parses header comment, rows and widths; rejects bad rows", () => {
  const csv = "# x_m,y_m,w_tr_right_m,w_tr_left_m\n3.1,0.1,7.185,7.433\n6.4,-3.6,7.141,7.434\n9.7,-7.4,7.143,7.435\n";
  expect(parseTumftmCsv(csv)).toEqual([
    {x: 3.1, y: 0.1, wr: 7.185, wl: 7.433},
    {x: 6.4, y: -3.6, wr: 7.141, wl: 7.434},
    {x: 9.7, y: -7.4, wr: 7.143, wl: 7.435},
  ]);
  expect(() => parseTumftmCsv("1,2,3\n")).toThrow(/4 finite numbers/);
  expect(() => parseTumftmCsv("1,2,-3,4\n")).toThrow(/non-positive width/);
});

test("circuit GeoJSON projects equirectangularly and applies constant width", () => {
  // 4-point square around lat 43.7, lon 7.4; one degree lat ~= 111194.9 m.
  const square = (dlon: number, dlat: number) => [7.4 + dlon, 43.7 + dlat];
  const doc = JSON.stringify({type: "FeatureCollection", features: [{type: "Feature",
    properties: {id: "test", Name: "Test Circuit", length: 1000},
    geometry: {type: "LineString", coordinates: [square(-.001, -.001), square(.001, -.001), square(.001, .001), square(-.001, .001)]}}]});
  const {name, lengthM, points} = parseCircuitGeojson(doc, 11);
  expect(name).toBe("Test Circuit"); expect(lengthM).toBe(1000);
  for (const p of points) {expect(p.wr).toBe(5.5); expect(p.wl).toBe(5.5);}
  const dy = points[2].y - points[1].y, dx = points[1].x - points[0].x;
  expect(dy).toBeCloseTo(2 * .001 * Math.PI * 6378137 / 180, 3);
  expect(dx).toBeCloseTo(dy * Math.cos(43.7 * Math.PI / 180), 3);
  expect(Math.abs(points[0].x + points[2].x)).toBeLessThan(1e-9); // centered on mean lon
  expect(() => parseCircuitGeojson(doc, 2)).toThrow(/4\.\.30/);
});

test("alignment recovers a known similarity transform despite start-index rotation and reversal", () => {
  const scale = 1.37, theta = 2.1, tx = -1234.5, ty = 987.6;
  const known = {scale, cos: Math.cos(theta), sin: Math.sin(theta), tx, ty};
  const rotated = loop.slice(137).concat(loop.slice(0, 137));
  const target = rotated.map(p => applyTransform(p, known));
  for (const reversed of [false, true]) {
    const reference = reversed ? loop.slice().reverse() : loop;
    const result = alignClosedLoops(reference, target, 720);
    expect(result.reversed).toBe(reversed);
    expect(result.rms).toBeLessThan(.5);
    expect(result.transform.scale).toBeCloseTo(scale, 3);
    // Map the resampled reference through the recovered transform: it must land on the target loop.
    const mapped = result.reference.map(p => applyTransform(p, result.transform));
    const targetResampled = resampleClosed(target, 720);
    for (let i = 0; i < 720; i += 60) {
      const nearest = Math.min(...targetResampled.map(q => Math.hypot(q.x - mapped[i].x, q.y - mapped[i].y)));
      expect(nearest).toBeLessThan(1);
    }
    // Inverting the recovered transform maps target points back onto the reference loop.
    const t = result.transform;
    expect(t.scale).toBeGreaterThan(0); // rotation + uniform scale, never a reflection
    for (const p of [loop[0], loop[500]]) {
      const q = applyTransform(p, known);
      const px = q.x - t.tx, py = q.y - t.ty;
      const back = {x: (t.cos * px + t.sin * py) / t.scale, y: (-t.sin * px + t.cos * py) / t.scale};
      expect(back.x).toBeCloseTo(p.x, 0); expect(back.y).toBeCloseTo(p.y, 0);
    }
  }
});

test("fitSimilarity is exact for an identity correspondence", () => {
  const {transform, rms} = fitSimilarity(loop, loop);
  expect(rms).toBe(0);
  expect(transform.scale).toBe(1); expect(transform.tx).toBe(0); expect(transform.ty).toBe(0);
});

test("synthetic kerbs appear inside high-curvature corners and outside their exits", () => {
  // Stadium shape resampled finely: two 180-degree corners, two straights.
  const stadium: CenterlinePoint[] = [];
  const R = 50, straight = 300;
  for (let i = 0; i < 200; i++) stadium.push({x: -straight / 2 + i * straight / 200, y: -R, wr: 6, wl: 6});
  for (let i = 0; i < 200; i++) {const a = -Math.PI / 2 + i * Math.PI / 200; stadium.push({x: straight / 2 + R * Math.cos(a), y: R * Math.sin(a), wr: 6, wl: 6});}
  for (let i = 0; i < 200; i++) stadium.push({x: straight / 2 - i * straight / 200, y: R, wr: 6, wl: 6});
  for (let i = 0; i < 200; i++) {const a = Math.PI / 2 + i * Math.PI / 200; stadium.push({x: -straight / 2 + R * Math.cos(a), y: R * Math.sin(a), wr: 6, wl: 6});}
  const kerbs = synthesizeKerbs(resampleClosed(stadium, 1600));
  expect(kerbs.length).toBe(4); // 2 corners x (apex-inside + exit-outside)
  for (const k of kerbs) {
    expect(k.widthM).toBe(2);
    expect(k.polygon.length).toBeGreaterThan(6);
    for (const p of k.polygon) {expect(Number.isFinite(p.x)).toBe(true); expect(Number.isFinite(p.y)).toBe(true);}
  }
  const apex = kerbs.filter(k => k.kind === "apex-inside"), exit = kerbs.filter(k => k.kind === "exit-outside");
  expect(apex.length).toBe(2); expect(exit.length).toBe(2);
  // CCW traversal: corners turn left, so apex kerbs sit on the left side.
  expect(apex.every(k => k.side === "left")).toBe(true);
  expect(exit.every(k => k.side === "right")).toBe(true);
});
