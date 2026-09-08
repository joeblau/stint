import type { RawRecord } from "./archive";
import { Route, distance, wrap, type Point, type GeometryDefinition } from "./geometry";
import { asOf, markTimestampConflicts, bounded, epochUS, finite, gapPolicy, timeline, upperBound, type Event, type GapPolicy, type Issue } from "./timeline";

export interface DriverInput {
  sessionKey: number; driverNumber: number; origin: string; end: string;
  location: RawRecord[]; car_data: RawRecord[]; laps: RawRecord[]; pit: RawRecord[];
  position: RawRecord[]; intervals: RawRecord[]; stints: RawRecord[]; race_control: RawRecord[];
}
export interface EdgePart { routeId: string; from: number; to: number }
export interface Keyframe {
  timestamp: number; rawIndex: number; rawX: number; rawY: number; rawZ: number;
  routeId: string | null; routeDistance: number | null; trackDistance: number | null;
  absoluteRaceDistance: number | null; lapNumber: number | null;
  speed: number | null; heading: number | null; confidence: number;
  disposition: "projected" | "ignored"; reasons: string[];
  /** Permission for the OUTGOING edge to the next keyframe, never across a rejected row. */
  interpolationAllowed: boolean; edgeParts?: EdgePart[]; segment: number; method: "linear" | "hold";
}
export interface RaceState { time: number; state: "unknown" | "green" | "yellow" | "safety-car" | "virtual-safety-car" | "suspended" | "finished" }
export interface DriverDataset {
  version: 1; sessionKey: number; driverNumber: number; origin: string; timestampUnit: "microseconds";
  policy: GapPolicy; keyframes: Keyframe[]; issues: Issue[]; untimed: Record<string, number[]>;
  events: {car_data: Event[]; laps: Event[]; pit: Event[]; position: Event[]; intervals: Event[]; race_control: Event[]};
  stints: RawRecord[]; raceStates: RaceState[]; geometry: GeometryDefinition;
}
export function raceStates(events: Event[]): RaceState[] {
  const result: RaceState[] = []; let state: RaceState["state"] = "unknown";
  for (const event of events) {
    const {category, flag, scope} = event.data, message = String(event.data.message ?? "").toUpperCase();
    let next: RaceState["state"] = state;
    if ((flag === "RED" && scope === "Track") || message.includes("RED FLAG - RACE SUSPENDED")) next = "suspended";
    else if (category === "SessionStatus" && message === "SESSION STARTED") next = "green";
    else if (scope === "Track" && flag === "CHEQUERED") next = "finished";
    else if (state !== "suspended" && state !== "finished") {
      if (category === "SafetyCar" && /VIRTUAL SAFETY CAR DEPLOYED/.test(message)) next = "virtual-safety-car";
      else if (category === "SafetyCar" && /SAFETY CAR DEPLOYED/.test(message)) next = "safety-car";
      else if (scope === "Track" && flag === "GREEN") next = "green";
      else if (scope === "Track" && (flag === "YELLOW" || flag === "DOUBLE YELLOW")) next = "yellow";
    }
    if (next !== state) { result.push({time: event.time, state: next}); state = next; }
  }
  return result;
}
export function stateAt(states: RaceState[], time: number) { return states[upperBound(states, time, e => e.time) - 1]?.state ?? "unknown"; }
export function carTelemetry(event: Event | undefined) {
  const row = event && !event.conflict ? event.data : {};
  const drs = row.drs;
  return {speed: bounded(row.speed, 0, 450), gear: Number.isInteger(row.n_gear) ? bounded(row.n_gear, 0, 8) : null, rpm: Number.isInteger(row.rpm) ? bounded(row.rpm, 0, 20000) : null,
    throttle: bounded(row.throttle, 0, 100), brake: bounded(row.brake, 0, 100),
    drs: drs === 10 || drs === 12 || drs === 14 ? true : drs === 0 || drs === 1 || drs === 8 ? false : null};
}
export function normalizeDriver(input: DriverInput, geometry: GeometryDefinition): DriverDataset {
  const origin = epochUS(input.origin), end = epochUS(input.end);
  if (origin === null || end === null || end <= origin) throw new Error("Invalid session timeline");
  if (geometry.sessionKey !== input.sessionKey || !finite(geometry.metersPerUnit) || geometry.metersPerUnit <= 0) throw new Error("Geometry coordinate frame must match the session");
  const byDriver = (rows: RawRecord[]) => rows.filter(r => r && r.driver_number === input.driverNumber);
  const rawLocations = timeline(input.location, origin, "date", input.sessionKey);
  const issues = [...rawLocations.issues], untimed: Record<string, number[]> = {location: rawLocations.untimed};
  const events = {} as DriverDataset["events"];
  for (const endpoint of ["car_data", "laps", "pit", "position", "intervals", "race_control"] as const) {
    const result = timeline(endpoint === "race_control" ? input[endpoint] : byDriver(input[endpoint]), origin, endpoint === "laps" ? "date_start" : "date", input.sessionKey);
    if (["car_data", "laps", "position", "intervals"].includes(endpoint)) markTimestampConflicts(result.events);
    events[endpoint] = result.events; untimed[endpoint] = result.untimed;
  }
  // Scheduled end isn't actual end. Retain a documented 2h extension, and 1h pre-session.
  // Stale previous-day packets must not become the first interpolation anchor.
  const locations = rawLocations.events.filter(e => {
    let reason: string | null = null;
    if (e.data.driver_number !== input.driverNumber) reason = "wrong-driver";
    else if (e.time < -3_600_000_000 || e.time > end - origin + 7_200_000_000) reason = "outside-session-window";
    else if (![e.data.x, e.data.y, e.data.z].every(finite)) reason = "invalid-coordinate";
    if (reason) { issues.push({rawIndex: e.rawIndex, reason}); return false; } return true;
  });
  const invalidCoordinateTimes = rawLocations.events.filter(e => ![e.data.x, e.data.y, e.data.z].every(finite)).map(e => e.time);
  const policy = gapPolicy(locations.map(e => e.time));
  const routes = geometry.routes.map(r => new Route(r)), track = routes.find(r => r.definition.kind === "track");
  if (!track) throw new Error("A track route is required");
  const states = raceStates(events.race_control);
  const pitLaps = new Set(events.pit.map(e => Number(e.data.lap_number)));
  const points = locations.map(e => ({x: Number(e.data.x) * geometry.metersPerUnit, y: Number(e.data.y) * geometry.metersPerUnit, z: Number(e.data.z) * geometry.metersPerUnit}));
  const keyframes: Keyframe[] = []; let segment = 0;
  for (let i = 0; i < locations.length; i++) {
    const e = locations[i], p = points[i], previous = keyframes.at(-1);
    const dt = previous ? (e.time - previous.timestamp) / 1e6 : Infinity;
    const telemetry = carTelemetry(asOf(events.car_data, e.time, policy.telemetryMaxAgeUS));
    const lapEvent = asOf(events.laps, e.time);
    const lap = Number.isInteger(lapEvent?.data.lap_number) ? bounded(lapEvent?.data.lap_number, 1, 1000) : null;
    const reasons: string[] = [];
    const conflict = locations[i - 1]?.time === e.time || locations[i + 1]?.time === e.time;
    if (conflict) reasons.push("conflicting-timestamp");
    const pitPossible = (lap !== null && pitLaps.has(lap)) || lapEvent?.data.is_pit_out_lap === true;
    // /pit.date is an event/report timestamp from several upstream topics, not a guaranteed entry time.
    // Use geometry for route choice; without pit geometry, exclude the whole affected lap conservatively.
    const pitRoutes = routes.filter(r => r.definition.kind === "pit");
    if (pitPossible && !pitRoutes.length) reasons.push("pit-geometry-unavailable");
    // A single spike is retained and marked, not silently moved onto the circuit.
    if (i > 0 && i + 1 < points.length) {
      const before = (e.time - locations[i - 1].time) / 1e6, after = (locations[i + 1].time - e.time) / 1e6;
      if (before > 0 && after > 0 && distance(points[i - 1], p) > 125 * before + 10 && distance(p, points[i + 1]) > 125 * after + 10 && distance(points[i - 1], points[i + 1]) <= 125 * (before + after) + 10) reasons.push("isolated-position-spike");
    }
    const continuous = previous?.routeId && previous.confidence > 0 && dt > 0 && dt * 1e6 <= policy.maximumUS;
    const routeOptions = routes; // Geometry can identify an unreported pit visit too.
    const matches = reasons.length ? [] : routeOptions.map(route => {
      const hint = continuous && previous.routeId === route.definition.id ? previous.routeDistance! : undefined;
      return {route, projection: route.project(p, hint, telemetry.speed === null || !Number.isFinite(dt) ? 0 : telemetry.speed / 3.6 * dt, 125 * dt)};
    }).filter(r => r.projection !== null).sort((a, b) => a.projection!.residual - b.projection!.residual);
    let match: (typeof matches)[number] | undefined = matches[0];
    if (matches[1] && Math.abs(matches[1].projection!.residual - match!.projection!.residual) < 3) { reasons.push("ambiguous-route"); match = undefined; }
    if (!match && !reasons.length) reasons.push("projection-or-topology-rejected");
    const route = match?.route, projection = match?.projection;
    let routeDistance = projection?.distance ?? null;
    let trackDistance = route?.definition.kind === "track" ? wrap(routeDistance!, track.length) : null;
    let absolute: number | null = null;
    let connect = Boolean(continuous && route && previous.routeId === route.definition.id);
    let edgeParts: EdgePart[] | undefined;
    if (connect && routeDistance !== null) {
      let delta = routeDistance - previous!.routeDistance!;
      if (route!.definition.closed && delta < -route!.length / 2) delta += route!.length;
      if (delta < 0 && delta >= -3) { routeDistance = previous!.routeDistance!; trackDistance = route!.definition.kind === "track" ? wrap(routeDistance, track.length) : null; reasons.push("reverse-jitter-held"); delta = 0; }
      if (delta < 0 || delta > 125 * dt + 3) { connect = false; reasons.push("implausible-progress"); }
      else if (previous!.absoluteRaceDistance !== null && trackDistance !== null) absolute = previous!.absoluteRaceDistance + delta;
      if (telemetry.speed !== null && previous!.speed !== null) {
        const expected = (telemetry.speed + previous!.speed) / 7.2 * dt;
        // An engineering tolerance for positioning noise, not an inferred timing correction.
        if (Math.abs(delta - expected) > Math.max(8, expected * .6)) { connect = false; reasons.push("speed-position-disagreement"); }
      }
      // Lap starts are approximate. Only contradictory changes beyond ±1 lap are rejected;
      // absolute geometry remains continuous through the approximate timestamp boundary.
      if (lap !== null && previous!.lapNumber !== null && (lap < previous!.lapNumber || lap > previous!.lapNumber + 1)) { connect = false; reasons.push("lap-conflict"); }
    }
    if (continuous && route && previous.routeId !== route.definition.id && geometry.verified) {
      const priorRoute = routes.find(r => r.definition.id === previous.routeId)!;
      // An explicitly linked pit route includes its entry/exit connectors. Only join it when the
      // surveyed endpoint agrees with the racing route and the entire edge is physically reachable.
      const entering = priorRoute === track && route.definition.kind === "pit";
      const leaving = route === track && priorRoute.definition.kind === "pit";
      if (entering && route.definition.entryTrackDistance !== undefined) {
        const entry = route.definition.entryTrackDistance;
        const remaining = wrap(entry - previous.routeDistance!, track.length);
        if (distance(track.at(entry).point, route.at(0).point) <= 3 && remaining + routeDistance! <= 125 * dt)
          edgeParts = [{routeId: track.definition.id, from: previous.routeDistance!, to: previous.routeDistance! + remaining}, {routeId: route.definition.id, from: 0, to: routeDistance!}];
      } else if (leaving && priorRoute.definition.exitTrackDistance !== undefined) {
        const exit = priorRoute.definition.exitTrackDistance;
        const progressed = wrap(routeDistance! - exit, track.length);
        if (distance(track.at(exit).point, priorRoute.at(priorRoute.length).point) <= 3 && priorRoute.length - previous.routeDistance! + progressed <= 125 * dt)
          edgeParts = [{routeId: priorRoute.definition.id, from: previous.routeDistance!, to: priorRoute.length}, {routeId: track.definition.id, from: exit, to: exit + progressed}];
      }
      if (edgeParts) connect = true;
    }
    if (previous && invalidCoordinateTimes[upperBound(invalidCoordinateTimes, previous.timestamp, t => t)] <= e.time) { connect = false; reasons.push("invalid-sample-barrier"); }
    if (trackDistance !== null && absolute === null && lap !== null) absolute = (lap - 1) * track.length + trackDistance;
    const changedState = previous && states.some(s => s.time > previous.timestamp && s.time <= e.time && (s.state === "suspended" || stateAt(states, s.time - 1) === "suspended"));
    if (changedState) { connect = false; reasons.push("session-interruption-boundary"); }
    if (!connect) segment++;
    // Never animate across route switches, rejected frames or telemetry holes. Verified connector
    // geometry can be supplied as a single pit route; transitions remain explicit reacquisitions.
    if (previous) { previous.interpolationAllowed = connect; if (connect && edgeParts) previous.edgeParts = edgeParts; }
    const confidence = projection ? Math.max(.1, geometry.confidence * (1 - projection.residual / 40)) * (reasons.length ? .65 : 1) : 0;
    keyframes.push({timestamp: e.time, rawIndex: e.rawIndex, rawX: Number(e.data.x), rawY: Number(e.data.y), rawZ: Number(e.data.z),
      routeId: route?.definition.id ?? null, routeDistance, trackDistance, absoluteRaceDistance: absolute, lapNumber: lap,
      speed: telemetry.speed, heading: route && routeDistance !== null ? route.at(routeDistance).heading : null, confidence,
      disposition: projection ? "projected" : "ignored", reasons, interpolationAllowed: false, segment, method: "hold"});
  }
  for (const k of keyframes) k.method = k.interpolationAllowed ? "linear" : "hold";
  return {version: 1, sessionKey: input.sessionKey, driverNumber: input.driverNumber, origin: input.origin, timestampUnit: "microseconds", policy,
    keyframes, issues, untimed, events, stints: byDriver(input.stints), raceStates: states, geometry};
}
