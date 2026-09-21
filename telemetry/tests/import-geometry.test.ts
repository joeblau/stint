import { describe, expect, test } from "bun:test";
import { alignClosedLoops, applyTransform, densifyClosed, fitSimilarity, parseCircuitGeojson, parseTumftmCsv, projectLonLat, resampleClosed, synthesizeKerbs, unprojectToLonLat, type CenterlinePoint, type GeoOrigin } from "../src/trackimport";

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
  const {name, lengthM, origin, points} = parseCircuitGeojson(doc, 11);
  expect(name).toBe("Test Circuit"); expect(lengthM).toBe(1000);
  expect(origin.lat0).toBeCloseTo(43.7, 9); expect(origin.lon0).toBeCloseTo(7.4, 9);
  for (const p of points) {expect(p.wr).toBe(5.5); expect(p.wl).toBe(5.5);}
  const dy = points[2].y - points[1].y, dx = points[1].x - points[0].x;
  expect(dy).toBeCloseTo(2 * .001 * Math.PI * 6378137 / 180, 3);
  expect(dx).toBeCloseTo(dy * Math.cos(43.7 * Math.PI / 180), 3);
  expect(Math.abs(points[0].x + points[2].x)).toBeLessThan(1e-9); // centered on mean lon
  expect(() => parseCircuitGeojson(doc, 2)).toThrow(/4\.\.30/);
});

test("equirectangular projection round-trips lon/lat through local meters", () => {
  const origin: GeoOrigin = {lat0: 34.8431, lon0: 136.541}; // Suzuka-ish
  for (const [lon, lat] of [[136.541, 34.8431], [136.55, 34.85], [136.53, 34.84], [-80.237, 25.959], [4.5405, 52.3884]]) {
    const xy = projectLonLat(lon, lat, origin);
    const back = unprojectToLonLat(xy.x, xy.y, origin);
    expect(back.lon).toBeCloseTo(lon, 10);
    expect(back.lat).toBeCloseTo(lat, 10);
  }
  // 1 degree of latitude is METERS_PER_DEGREE everywhere; longitude shrinks by cos(lat0).
  const north = projectLonLat(origin.lon0, origin.lat0 + 1, origin);
  expect(north.y).toBeCloseTo(Math.PI * 6378137 / 180, 6);
  const east = projectLonLat(origin.lon0 + 1, origin.lat0, origin);
  expect(east.x).toBeCloseTo(Math.PI * 6378137 / 180 * Math.cos(origin.lat0 * Math.PI / 180), 6);
});

test("aligned width-source centerline recovers WGS84 of the geo-referenced reference", () => {
  // Geo-referenced "reference" loop: the test loop projected to fake lon/lat, as parseCircuitGeojson would emit.
  const origin: GeoOrigin = {lat0: 52.3884, lon0: 4.5405}; // Zandvoort-ish
  const reference = loop.map(p => {
    const ll = unprojectToLonLat(p.x, p.y, origin);
    return {...projectLonLat(ll.lon, ll.lat, origin), wr: 6, wl: 6}; // identity projection; establishes origin plumbing
  });
  // Width source: the same loop under a known similarity transform, with measured widths.
  const known = {scale: 1.02, cos: Math.cos(-.7), sin: Math.sin(-.7), tx: 55, ty: -20};
  const source: CenterlinePoint[] = loop.map(p => ({...applyTransform(p, known), wr: p.wr, wl: p.wl}));
  const alignment = alignClosedLoops(source, reference, 720);
  expect(alignment.rms).toBeLessThan(.5);
  // The emitted pipeline: transform source points into the reference frame, then unproject to WGS84.
  for (const i of [0, 200, 500]) {
    const q = applyTransform(source[i], alignment.transform);
    const ll = unprojectToLonLat(q.x, q.y, origin);
    const expected = unprojectToLonLat(loop[i].x, loop[i].y, origin);
    expect(ll.lat).toBeCloseTo(expected.lat, 5); // ~1 m at mid latitudes
    expect(ll.lon).toBeCloseTo(expected.lon, 5);
  }
});

test("densifyClosed caps segment length and interpolates widths", () => {
  const square: CenterlinePoint[] = [{x: 0, y: 0, wr: 5, wl: 7}, {x: 100, y: 0, wr: 9, wl: 11}, {x: 100, y: 100, wr: 5, wl: 7}, {x: 0, y: 100, wr: 5, wl: 7}];
  const dense = densifyClosed(square, 25);
  expect(dense.length).toBe(16);
  for (let i = 0; i < dense.length; i++) {
    const a = dense[i], b = dense[(i + 1) % dense.length];
    expect(Math.hypot(b.x - a.x, b.y - a.y)).toBeLessThanOrEqual(25);
  }
  const mid = dense[2]; // halfway along the first edge
  expect(mid).toEqual({x: 50, y: 0, wr: 7, wl: 9});
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
