import { Route, wrap, type Point } from "./geometry";
import { asOf, upperBound } from "./timeline";
import { carTelemetry, stateAt, type DriverDataset } from "./normalize";

export interface DriverState {
  position: Point | null; heading: number | null; distanceAlongTrack: number | null;
  absoluteRaceDistance: number | null; speed: number | null; lap: number | null;
  racePosition: number | null; gapToLeader: unknown; interval: unknown;
  gear: number | null; rpm: number | null; throttle: number | null; brake: number | null; drs: boolean | null;
  raceState: string; availability: "pending" | "active" | "held" | "unavailable"; opacity: number;
  interpolation: {previousSampleTime: number | null; nextSampleTime: number | null; confidence: number; method: "linear" | "hold" | "none"};
}
/** Timestamp is session-relative integer MICROSECONDS. No extrapolation or hidden playback offset. */
export class Replay {
  private drivers = new Map<string, DriverDataset>();
  private routes = new Map<string, Map<string, Route>>();
  add(dataset: DriverDataset) {
    const key = `${dataset.sessionKey}/${dataset.driverNumber}`;
    if (dataset.version !== 1 || dataset.timestampUnit !== "microseconds" || dataset.geometry.sessionKey !== dataset.sessionKey) throw new Error("Unsupported or mismatched replay schema");
    const routes = new Map(dataset.geometry.routes.map(r => [r.id, new Route(r)]));
    if (routes.size !== dataset.geometry.routes.length) throw new Error("Duplicate route IDs");
    for (let i = 0; i < dataset.keyframes.length; i++) {
      const a = dataset.keyframes[i], b = dataset.keyframes[i + 1];
      if (!Number.isSafeInteger(a.timestamp) || (i && a.timestamp < dataset.keyframes[i - 1].timestamp)
        || ![a.rawX, a.rawY, a.rawZ, a.confidence].every(Number.isFinite) || a.confidence < 0 || a.confidence > 1)
        throw new Error("Invalid normalized keyframe");
      if (a.routeId !== null && (!routes.has(a.routeId) || a.routeDistance === null || !Number.isFinite(a.routeDistance))) throw new Error("Invalid keyframe route");
      if (a.interpolationAllowed && (!b || b.timestamp <= a.timestamp || b.timestamp - a.timestamp > dataset.policy.maximumUS || a.segment !== b.segment || !a.routeId || !b.routeId)) throw new Error("Invalid interpolation edge");
    }
    this.drivers.set(key, dataset);
    this.routes.set(key, routes);
  }
  getDriverState(sessionKey: number, driverNumber: number, timestamp: number): DriverState {
    if (!Number.isSafeInteger(timestamp)) throw new Error("Expected integer microseconds");
    const key = `${sessionKey}/${driverNumber}`, dataset = this.drivers.get(key);
    if (!dataset) throw new Error(`Driver dataset not loaded: ${key}`);
    const frames = dataset.keyframes, index = upperBound(frames, timestamp, k => k.timestamp) - 1;
    const a = frames[index], b = frames[index + 1];
    const telemetry = carTelemetry(asOf(dataset.events.car_data, timestamp, dataset.policy.telemetryMaxAgeUS));
    const classification = asOf(dataset.events.position, timestamp)?.data.position;
    const intervals = asOf(dataset.events.intervals, timestamp)?.data;
    const result: DriverState = {position: null, heading: null, distanceAlongTrack: null, absoluteRaceDistance: null,
      ...telemetry, lap: null, racePosition: typeof classification === "number" && Number.isInteger(classification) && classification > 0 ? classification : null,
      gapToLeader: intervals?.gap_to_leader ?? null, interval: intervals?.interval ?? null,
      raceState: stateAt(dataset.raceStates, timestamp), availability: a ? "unavailable" : "pending", opacity: 0,
      interpolation: {previousSampleTime: a?.timestamp ?? null, nextSampleTime: b?.timestamp ?? null, confidence: 0, method: "none"}};
    if (!a?.routeId || a.routeDistance === null) return result;
    let route = this.routes.get(key)!.get(a.routeId)!;
    const interpolate = b && a.interpolationAllowed && b.segment === a.segment && b.timestamp > a.timestamp;
    let d = a.routeDistance, absolute = a.absoluteRaceDistance;
    if (interpolate) {
      const fraction = (timestamp - a.timestamp) / (b.timestamp - a.timestamp);
      let delta = b.routeDistance! - a.routeDistance;
      if (route.definition.closed && delta < -route.length / 2) delta += route.length;
      d += delta * fraction;
      if (a.edgeParts) {
        let remaining = a.edgeParts.reduce((sum, p) => sum + p.to - p.from, 0) * fraction;
        for (const part of a.edgeParts) {
          route = this.routes.get(key)!.get(part.routeId)!;
          d = part.from + Math.min(remaining, part.to - part.from);
          if (remaining <= part.to - part.from) break;
          remaining -= part.to - part.from;
        }
        absolute = null; // Pit path length is not racing-centerline progress.
      }
      if (absolute !== null && b.absoluteRaceDistance !== null) absolute += (b.absoluteRaceDistance - absolute) * fraction;
      result.interpolation.confidence = Math.min(a.confidence, b.confidence) * ((b.timestamp - a.timestamp > dataset.policy.normalUS) ? .7 : 1);
      result.interpolation.method = "linear"; result.availability = "active"; result.opacity = 1;
    } else {
      const age = timestamp - a.timestamp;
      result.opacity = Math.max(0, Math.min(1, 1 - (age - dataset.policy.holdUS) / dataset.policy.fadeUS));
      if (!result.opacity) return result;
      result.availability = age === 0 ? "active" : "held"; result.interpolation.method = "hold";
      result.interpolation.confidence = a.confidence * result.opacity;
    }
    // A discontinuous reacquisition fades in at its known location, never flies across the map.
    const first = index === 0 || frames[index - 1].segment !== a.segment;
    if (first && index > 0) result.opacity *= Math.min(1, (timestamp - a.timestamp) / dataset.policy.fadeUS);
    const at = route.at(d);
    result.position = at.point; result.heading = at.heading; result.lap = a.lapNumber;
    result.distanceAlongTrack = route.definition.kind === "track" ? wrap(d, route.length) : null;
    result.absoluteRaceDistance = absolute;
    return result;
  }
}
export function renderTimestamp(playbackTimestampUS: number, interpolationBufferUS = 0): number {
  if (!Number.isSafeInteger(interpolationBufferUS) || interpolationBufferUS < 0) throw new Error("Invalid interpolation buffer");
  return Math.round(playbackTimestampUS - interpolationBufferUS);
}

/** Experimental anchor-constrained velocity profile. Never used implicitly by production playback. */
export function integratedFraction(profile: {time: number; speedMPS: number}[], time: number): number | null {
  if (profile.length < 2 || profile.some((p, i) => !Number.isFinite(p.speedMPS) || p.speedMPS < 0 || p.speedMPS > 125 || (i > 0 && p.time <= profile[i - 1].time))) return null;
  let total = 0, partial = 0;
  for (let i = 1; i < profile.length; i++) {
    const a = profile[i - 1], b = profile[i], dt = b.time - a.time;
    total += dt * (a.speedMPS + b.speedMPS) / 2;
    const elapsed = Math.max(0, Math.min(dt, time - a.time));
    partial += elapsed * (a.speedMPS + (b.speedMPS - a.speedMPS) * elapsed / dt / 2);
  }
  return total > 0 ? partial / total : null;
}
/** Endpoint slopes limited to a monotone Hermite segment. Derivative bound must also be checked. */
export function monotoneFraction(f: number, startSlope: number, endSlope: number): number {
  const a = Math.max(0, startSlope), b = Math.max(0, endSlope), scale = Math.max(1, Math.hypot(a, b) / 3);
  return (f ** 3 - 2 * f * f + f) * a / scale + (-2 * f ** 3 + 3 * f * f) + (f ** 3 - f * f) * b / scale;
}
