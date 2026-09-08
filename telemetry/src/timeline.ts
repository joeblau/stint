import type { RawRecord } from "./archive";

/** ISO UTC/offset timestamps to integer microseconds. Never drop sub-millisecond precision. */
export function epochUS(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const m = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!m) return null;
  const civil = Date.parse(m[1] + "Z");
  if (!Number.isFinite(civil) || new Date(civil).toISOString().slice(0, 19) !== m[1]) return null;
  const ms = Date.parse(m[1] + m[3]);
  if (!Number.isFinite(ms)) return null;
  const result = ms * 1000 + Number((m[2] ?? "").padEnd(6, "0"));
  return Number.isSafeInteger(result) ? result : null;
}
export interface Event { time: number; rawIndex: number; data: RawRecord; conflict?: boolean }
export interface Issue { rawIndex: number; reason: string }
export interface Timeline { events: Event[]; issues: Issue[]; untimed: number[] }
const canonical = (row: RawRecord) => JSON.stringify(Object.fromEntries(Object.entries(row).sort(([a], [b]) => a.localeCompare(b))));
/** Events keep source data; ordering is internal only. Untimed stints remain lap-indexed. */
export function timeline(rows: RawRecord[], originUS: number, field = "date", sessionKey?: number): Timeline {
  const events: Event[] = [], issues: Issue[] = [], untimed: number[] = [];
  rows.forEach((data, rawIndex) => {
    if (!data || typeof data !== "object" || Array.isArray(data)) { issues.push({rawIndex, reason: "invalid-record"}); return; }
    if (sessionKey !== undefined && data.session_key !== sessionKey) { issues.push({rawIndex, reason: "wrong-session"}); return; }
    const epoch = epochUS(data[field]);
    if (epoch === null) { untimed.push(rawIndex); return; }
    events.push({time: epoch - originUS, rawIndex, data});
  });
  events.sort((a, b) => a.time - b.time || a.rawIndex - b.rawIndex);
  // Multiple drivers and race-control messages may legitimately share a timestamp.
  // Deduplicate within identity; only location/car_data callers mark positional conflicts.
  const seen = new Set<string>();
  const unique = events.filter(e => {
    const signature = canonical(e.data);
    if (seen.has(signature)) { issues.push({rawIndex: e.rawIndex, reason: "exact-duplicate"}); return false; }
    seen.add(signature); return true;
  });
  return {events: unique, issues, untimed};
}
export function upperBound<T>(rows: readonly T[], time: number, key: (row: T) => number): number {
  let low = 0, high = rows.length;
  while (low < high) { const middle = (low + high) >>> 1; if (key(rows[middle]) <= time) low = middle + 1; else high = middle; }
  return low;
}
export function asOf(rows: readonly Event[], time: number, maximumAge = Infinity): Event | undefined {
  const row = rows[upperBound(rows, time, e => e.time) - 1];
  return row && !row.conflict && time - row.time <= maximumAge ? row : undefined;
}
export function quantile(sorted: number[], fraction: number): number {
  if (!sorted.length) return 0;
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * fraction))];
}
export function distribution(times: number[]) {
  const deltas = times.slice(1).map((t, i) => t - times[i]).filter(t => t > 0).sort((a, b) => a - b);
  return {count: deltas.length, mean: deltas.reduce((a, b) => a + b, 0) / (deltas.length || 1), p50: quantile(deltas, .5), p95: quantile(deltas, .95), p99: quantile(deltas, .99), max: deltas.at(-1) ?? 0};
}
export function gapPolicy(times: number[]) {
  const intervals = distribution(times);
  // Multipliers are conservative policy, not a claim that quantiles prove motion validity.
  const normalUS = Math.min(1_000_000, Math.max(intervals.p95, intervals.p50 * 2));
  const maximumUS = Math.min(2_000_000, Math.max(normalUS, intervals.p99 * 3));
  return {intervals, normalUS, maximumUS, telemetryMaxAgeUS: Math.min(1_500_000, Math.max(500_000, intervals.p99 * 2)),
    recommendedStreamingBufferUS: Math.min(1_500_000, intervals.p95 + intervals.p50), historicalBufferUS: 0,
    holdUS: Math.min(500_000, maximumUS), fadeUS: 200_000};
}
export type GapPolicy = ReturnType<typeof gapPolicy>;
export const finite = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);
export const bounded = (n: unknown, min: number, max: number): number | null => finite(n) && n >= min && n <= max ? n : null;

export function markTimestampConflicts(events: Event[]): void {
  for (let i = 0; i < events.length;) {
    let end = i + 1; while (end < events.length && events[end].time === events[i].time) end++;
    if (end - i > 1) for (let j = i; j < end; j++) events[j].conflict = true;
    i = end;
  }
}
