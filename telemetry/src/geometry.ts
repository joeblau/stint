export interface Point { x: number; y: number; z: number }
export interface RouteDefinition {
  id: string; kind: "track" | "pit"; closed: boolean; points: Point[];
  /** Track distances at the endpoints of an open pit route, if surveyed/verified. */
  entryTrackDistance?: number; exitTrackDistance?: number;
}
export interface GeometryDefinition {
  version: 1; sessionKey: number; metersPerUnit: number;
  provenance: string; confidence: number; verified: boolean;
  routes: RouteDefinition[];
}
export interface Projection { distance: number; residual: number; point: Point; heading: number; segment: number }
export const distance = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y);
export const wrap = (d: number, length: number) => ((d % length) + length) % length;

/** Dense polyline with spatial buckets. Construction O(n); local projection O(candidates). */
export class Route {
  readonly cumulative: number[] = [0]; readonly length: number;
  private grid = new Map<string, number[]>();
  private readonly cell = 40;
  readonly points: Point[];
  constructor(readonly definition: RouteDefinition) {
    if (definition.points.length < 2 || definition.points.some(p => ![p.x, p.y, p.z].every(Number.isFinite))) throw new Error("Invalid route geometry");
    this.points = definition.points.slice();
    if (definition.closed && distance(this.points[0], this.points.at(-1)!) > .001) this.points.push(this.points[0]);
    for (let i = 1; i < this.points.length; i++) {
      const a = this.points[i - 1], b = this.points[i];
      const length = distance(a, b);
      if (length > 100) throw new Error("Route segments must be <=100m; do not bridge geometry gaps");
      this.cumulative.push(this.cumulative.at(-1)! + length);
      for (let x = Math.floor(Math.min(a.x, b.x) / this.cell); x <= Math.floor(Math.max(a.x, b.x) / this.cell); x++)
        for (let y = Math.floor(Math.min(a.y, b.y) / this.cell); y <= Math.floor(Math.max(a.y, b.y) / this.cell); y++) {
          const key = `${x},${y}`, bucket = this.grid.get(key) ?? []; bucket.push(i - 1); this.grid.set(key, bucket);
        }
    }
    this.length = this.cumulative.at(-1)!;
    if (this.length < 1) throw new Error("Zero-length route");
  }
  at(d: number): {point: Point; heading: number} {
    d = this.definition.closed ? wrap(d, this.length) : Math.max(0, Math.min(this.length, d));
    let lo = 0, hi = this.cumulative.length - 1;
    while (lo + 1 < hi) { const mid = (lo + hi) >>> 1; if (this.cumulative[mid] <= d) lo = mid; else hi = mid; }
    const a = this.points[lo], b = this.points[lo + 1], length = this.cumulative[lo + 1] - this.cumulative[lo];
    const f = length ? (d - this.cumulative[lo]) / length : 0;
    return {point: {x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, z: a.z + (b.z - a.z) * f}, heading: Math.atan2(b.x - a.x, b.y - a.y) * 180 / Math.PI};
  }
  candidates(p: Point, radius = 30): Projection[] {
    const indices = new Set<number>();
    for (let x = Math.floor((p.x - radius) / this.cell); x <= Math.floor((p.x + radius) / this.cell); x++)
      for (let y = Math.floor((p.y - radius) / this.cell); y <= Math.floor((p.y + radius) / this.cell); y++)
        for (const index of this.grid.get(`${x},${y}`) ?? []) indices.add(index);
    const result: Projection[] = [];
    for (const segment of indices) {
      const a = this.points[segment], b = this.points[segment + 1], dx = b.x - a.x, dy = b.y - a.y;
      const f = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy || 1)));
      const point = {x: a.x + dx * f, y: a.y + dy * f, z: a.z + (b.z - a.z) * f};
      const residual = distance(point, p);
      if (residual <= radius) result.push({point, residual, segment, distance: this.cumulative[segment] + f * (this.cumulative[segment + 1] - this.cumulative[segment]), heading: Math.atan2(dx, dy) * 180 / Math.PI});
    }
    return result;
  }
  project(p: Point, previous?: number, expectedTravel = 0, maximumTravel = Infinity): Projection | null {
    const candidates = this.candidates(p).map(c => {
      let delta = previous === undefined ? 0 : c.distance - previous;
      if (this.definition.closed && delta < -this.length / 2) delta += this.length;
      if (this.definition.closed && delta > this.length / 2) delta -= this.length;
      return {...c, delta, score: c.residual + (previous === undefined ? 0 : Math.abs(delta - expectedTravel) * .3)};
    }).filter(c => previous === undefined || (c.delta >= -3 && c.delta <= maximumTravel + 3)).sort((a, b) => a.score - b.score);
    const best = candidates[0]; if (!best) return null;
    // Nearby parallel or crossing sections need a decisive topology match.
    const alternate = candidates.find(c => {
      const d = Math.abs(c.distance - best.distance);
      return (this.definition.closed ? Math.min(d, this.length - d) : d) > 80;
    });
    if (alternate && alternate.score - best.score < 3) return null;
    return best;
  }
}
