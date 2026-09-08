import { describe, expect, test } from "bun:test";
import { normalizeDriver, raceStates, stateAt, carTelemetry, type DriverInput } from "../src/normalize";
import { Route, type GeometryDefinition } from "../src/geometry";
import { epochUS, timeline, gapPolicy } from "../src/timeline";
import { Replay, integratedFraction, monotoneFraction } from "../src/playback";
import { archiveResponse, sha256 } from "../src/archive";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
const origin = "2026-09-06T13:00:00Z";
const iso = (s: number) => new Date(Date.parse(origin) + s * 1000).toISOString();
const geometry: GeometryDefinition = {version: 1, sessionKey: 1, metersPerUnit: 1, confidence: 1, verified: true, provenance: "Synthetic circle",
  routes: [{id: "track", kind: "track", closed: true, points: Array.from({length: 360}, (_, i) => ({x: 100 * Math.cos(i * Math.PI / 180), y: 100 * Math.sin(i * Math.PI / 180), z: 0}))}]};
const route = new Route(geometry.routes[0]);
function input(samples: [number, number][]): DriverInput {
  return {sessionKey: 1, driverNumber: 1, origin, end: "2026-09-06T15:00:00Z",
    location: samples.map(([t, d]) => ({session_key: 1, driver_number: 1, date: iso(t), ...route.at(d).point})),
    car_data: [], laps: [{session_key: 1, driver_number: 1, date_start: origin, lap_number: 1}],
    pit: [], position: [], intervals: [], stints: [], race_control: []};
}
function player(data: DriverInput) {const dataset = normalizeDriver(data, geometry), replay = new Replay(); replay.add(dataset); return {dataset, replay};}

test("raw archive preserves every byte and is content-addressed", async () => {
  const root = await mkdtemp(join(tmpdir(), "stint-raw-"));
  try {const body = new TextEncoder().encode('[ {"x": 1.00, "date":"2026-09-06T13:00:00.123456Z"} ]\n');
    const entry = await archiveResponse(root, "location", "https://example.invalid", body);
    expect(await readFile(join(root, entry.path))).toEqual(Buffer.from(body)); expect(entry.sha256).toBe(sha256(body));
    expect((await archiveResponse(root, "location", "https://example.invalid", body)).path).toBe(entry.path);
  } finally {await rm(root, {recursive: true, force: true});}
});
test("single microsecond timeline supports offsets, out-of-order and exact duplicates", () => {
  expect(epochUS("2026-09-06T15:00:00.123456+02:00")! - epochUS(origin)!).toBe(123456);
  expect(epochUS("not a date")).toBeNull();
  const a = {date: iso(1), x: 1}, b = {date: iso(0), x: 2};
  const result = timeline([a, b, {...a}], epochUS(origin)!);
  expect(result.events.map(e => e.time)).toEqual([0, 1e6]); expect(result.issues[0].reason).toBe("exact-duplicate");
});
test("start/finish wraps forward along the track at 60fps", () => {
  const {dataset, replay} = player(input([[0, route.length - 10], [.25, 0], [.5, 10]]));
  expect(dataset.keyframes[1].absoluteRaceDistance!).toBeGreaterThan(dataset.keyframes[0].absoluteRaceDistance!);
  let last = -Infinity;
  for (let t = 0; t < 500000; t += 16667) {const s = replay.getDriverState(1, 1, t); expect(s.absoluteRaceDistance!).toBeGreaterThanOrEqual(last); last = s.absoluteRaceDistance!; expect(Math.hypot(s.position!.x, s.position!.y)).toBeCloseTo(100, 1);}
});
test("duplicate conflicts, wrong day and isolated outliers cannot create interpolation", () => {
  const data = input([[0, 0], [.25, 10], [.5, 20], [.75, 30]]);
  data.location.push({...data.location[1], x: 9000});
  data.location.unshift({...data.location[0], date: "2026-09-05T13:00:00Z"});
  const {dataset} = player(data);
  expect(dataset.issues.some(i => i.reason === "outside-session-window")).toBe(true);
  expect(dataset.keyframes.filter(k => k.reasons.includes("conflicting-timestamp")).length).toBe(2);
  expect(dataset.keyframes[0].interpolationAllowed).toBe(false);
  data.location = input([[0, 0], [.25, 10], [.5, 20]]).location; data.location[1].x = 99999;
  expect(player(data).dataset.keyframes[1].reasons).toContain("isolated-position-spike");
});
test("gaps hold then hide; no extrapolation before entry or after exit", () => {
  const {dataset, replay} = player(input([[1, 0], [1.25, 10], [10, 100], [10.25, 110]]));
  expect(dataset.keyframes[1].interpolationAllowed).toBe(false);
  expect(replay.getDriverState(1, 1, 0).availability).toBe("pending");
  expect(replay.getDriverState(1, 1, 1400000).availability).toBe("held");
  expect(replay.getDriverState(1, 1, 5000000).position).toBeNull();
  expect(replay.getDriverState(1, 1, 10000000).opacity).toBe(0);
  expect(replay.getDriverState(1, 1, 20000000).position).toBeNull();
});
test("unknown pedals and DRS remain unknown, source classification uses as-of events", () => {
  expect(carTelemetry({time: 0, rawIndex: 0, data: {throttle: 104, brake: 104, drs: null}})).toMatchObject({throttle: null, brake: null, drs: null});
  const data = input([[0, 0], [.25, 10]]);
  data.position = [{session_key: 1, driver_number: 1, date: iso(.2), position: 2}];
  data.intervals = [{session_key: 1, driver_number: 1, date: iso(0), gap_to_leader: "+1 LAP"}];
  const {replay} = player(data);
  expect(replay.getDriverState(1, 1, 100000).racePosition).toBeNull();
  expect(replay.getDriverState(1, 1, 200000).racePosition).toBe(2);
  expect(replay.getDriverState(1, 1, 200000).gapToLeader).toBe("+1 LAP");
});
test("pit telemetry is never forced onto track without pit geometry", () => {
  const data = input([[0, 0], [.25, 10]]); data.pit = [{session_key: 1, driver_number: 1, date: iso(1), lap_number: 1, lane_duration: 20}];
  expect(player(data).dataset.keyframes.every(k => k.routeId === null && !k.interpolationAllowed)).toBe(true);
});
test("nearby topology does not jump to the other side of a hairpin", () => {
  const r = new Route({id: "hairpin", kind: "pit", closed: false, points: [{x: 0,y:0,z:0},{x:100,y:0,z:0},{x:100,y:5,z:0},{x:0,y:5,z:0}]});
  expect(r.project({x: 20,y:4,z:0}, 10, 10, 30)?.distance).toBeCloseTo(20);
  expect(r.project({x: 20,y:2.5,z:0})).toBeNull();
});
test("experimental interpolation is anchored, monotone, and rejects invalid speed", () => {
  const profile = [{time:0,speedMPS:20},{time:1,speedMPS:40}];
  expect(integratedFraction(profile, 0)).toBe(0); expect(integratedFraction(profile, 1)).toBe(1);
  expect(integratedFraction([{time:0,speedMPS:-1},profile[1]], .5)).toBeNull();
  let previous = 0;
  for (let i = 0; i <= 100; i++) {const v = monotoneFraction(i / 100, 8, 6); expect(v).toBeGreaterThanOrEqual(previous); expect(v).toBeLessThanOrEqual(1); previous = v;}
});

describe("offline actual 2026 sessions", () => {
  for (const [session, driver] of [[11361,1],[11361,63],[11299,1],[11253,1]]) {
    test(`${session}/${driver}: deterministic normalization, finite playback, raw remains untouched`, async () => {
      const fixture = await Bun.file(join(import.meta.dir, `fixtures/${session}-${driver}.json`)).json();
      const shape = await Bun.file(join(import.meta.dir, `../geometry/${session}.experimental.json`)).json();
      const before = JSON.stringify(fixture.input), result = normalizeDriver(fixture.input, shape);
      expect(JSON.stringify(fixture.input)).toBe(before);
      expect(JSON.stringify(normalizeDriver(fixture.input, shape))).toBe(JSON.stringify(result));
      const replay = new Replay(); replay.add(result);
      for (let i = 0; i < result.keyframes.length - 1; i++) {
        const a = result.keyframes[i], b = result.keyframes[i + 1];
        if (a.interpolationAllowed) {
          expect(b.timestamp - a.timestamp).toBeLessThanOrEqual(result.policy.maximumUS);
          expect(a.segment).toBe(b.segment);
          const state = replay.getDriverState(session, driver, Math.round((a.timestamp + b.timestamp) / 2));
          expect(state.position).not.toBeNull(); expect(Number.isFinite(state.position!.x)).toBe(true);
          if (a.absoluteRaceDistance !== null && b.absoluteRaceDistance !== null) expect(b.absoluteRaceDistance).toBeGreaterThanOrEqual(a.absoluteRaceDistance);
        }
      }
      for (const event of result.events.position.filter(e => !e.conflict)) {
        expect(replay.getDriverState(session, driver, event.time).racePosition).toBe(event.data.position as number);
      }
      expect(result.events.car_data.some(e => Number(e.data.speed) > 280)).toBe(true);
      if (session === 11361) {
        expect(result.raceStates.some(s => s.state === "safety-car")).toBe(true);
        const t = epochUS("2026-09-06T13:30:00Z")! - epochUS(fixture.input.origin)!;
        expect(stateAt(result.raceStates, t)).toBe("suspended");
      }
      if (session === 11299) expect(result.keyframes.some((k, i) => i > 0 && k.timestamp - result.keyframes[i - 1].timestamp > 10e6)).toBe(true);
    });
  }
});

test("malformed coordinates form a barrier rather than silently bridging valid neighbors", () => {
  const data = input([[0,0],[.25,10],[.5,20]]); data.location[1].x = null;
  expect(player(data).dataset.keyframes[0].interpolationAllowed).toBe(false);
});
test("stationary cars survive suspension and resume announcements do not restart the race", () => {
  const events = timeline([
    {date:iso(0), category:"SessionStatus", message:"SESSION STARTED"},
    {date:iso(.1), category:"Other", message:"RED FLAG - RACE SUSPENDED"},
    {date:iso(.2), category:"Other", message:"RACE WILL RESUME AT 15:39"},
    {date:iso(.3), category:"Flag", scope:"Sector", flag:"GREEN"},
    {date:iso(1), category:"SessionStatus", message:"SESSION STARTED"}
  ],epochUS(origin)!).events;
  const states=raceStates(events); expect(stateAt(states,500000)).toBe("suspended"); expect(stateAt(states,1000000)).toBe("green");
  const data=input([[0,0],[.25,0],[.5,0],[.75,0],[1,0]]); data.race_control=events.map(e=>({...e.data,session_key:1}));
  const {dataset}=player(data);expect(dataset.keyframes.every(k=>k.confidence>0)).toBe(true);
  expect(dataset.keyframes[0].interpolationAllowed).toBe(false); expect(dataset.keyframes[1].interpolationAllowed).toBe(true);
});
test("verified pit connectors interpolate along their own route, never through the infield", () => {
  const definition: GeometryDefinition = {...geometry, routes:[{id:"track",kind:"track",closed:true,points:[{x:0,y:0,z:0},{x:100,y:0,z:0},{x:100,y:100,z:0},{x:0,y:100,z:0}]},
    {id:"pit",kind:"pit",closed:false,entryTrackDistance:20,exitTrackDistance:80,points:[{x:20,y:0,z:0},{x:30,y:-10,z:0},{x:70,y:-10,z:0},{x:80,y:0,z:0}]}]};
  const data=input([]);data.location=[{date:iso(0),x:10,y:0,z:0},{date:iso(.5),x:40,y:-10,z:0},{date:iso(1),x:60,y:-10,z:0},{date:iso(1.5),x:90,y:0,z:0}].map(r=>({...r,session_key:1,driver_number:1}));
  data.pit=[{date:iso(1.5),session_key:1,driver_number:1,lap_number:1,lane_duration:1}];
  const dataset=normalizeDriver(data,definition),replay=new Replay();replay.add(dataset);
  expect(dataset.keyframes.map(k=>k.routeId)).toEqual(["track","pit","pit","track"]);
  expect(dataset.keyframes.slice(0,-1).every(k=>k.interpolationAllowed)).toBe(true);
  expect(replay.getDriverState(1,1,750000).position!.y).toBe(-10);
  expect(replay.getDriverState(1,1,750000).distanceAlongTrack).toBeNull();
});

test("invalid civil dates and malformed rows are quarantined; conflicting telemetry stays unknown", () => {
  expect(epochUS("2026-02-31T12:00:00Z")).toBeNull();
  expect(timeline([null, 123] as any, epochUS(origin)!).issues).toHaveLength(2);
  const data=input([[0,0],[.25,10]]);
  data.car_data=[{date:iso(0),speed:100,drs:12},{date:iso(0),speed:200,drs:0}].map(r=>({...r,driver_number:1,session_key:1}));
  const state=player(data).replay.getDriverState(1,1,100000);expect(state.speed).toBeNull();expect(state.drs).toBeNull();
});

test("playback rejects tampered timestamps and interpolation edges", () => {
  const result=normalizeDriver(input([[0,0],[.25,10]]),geometry);result.keyframes[1].timestamp=-1;
  expect(()=>new Replay().add(result)).toThrow();
});
