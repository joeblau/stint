# Historical telemetry

A standalone Bun/TypeScript ingestion, normalization and random-access playback package. It never replaces the byte-exact OpenF1 archive. Sparse position fixes remain sparse; there is no persisted 60 FPS expansion.

**Integration status:** the native app still reads its version-1 geographic JSON format. This package is an opt-in preprocessing/playback API, not yet the native renderer's data source. Automatically replacing that importer with uncalibrated OpenF1 X/Y would produce incorrect map locations. The three included geometry files are explicitly experimental reference trajectories, not surveyed centerlines. Production geometry needs a reviewed coordinate scale, start/finish alignment, pit connectors and a WGS84 transform for Apple Maps. The CLI refuses unverified geometry unless `--experimental` is passed. No historical replay in the app was silently overwritten.

## Run

From the repository root:

```sh
bun install --cwd telemetry
bun telemetry/scripts/ingest.ts 11361 all
bun telemetry/scripts/audit.ts 11361
bun telemetry/scripts/normalize.ts 11361 /absolute/path/to/verified-geometry.json
bun test telemetry/tests
telemetry/node_modules/.bin/tsc --noEmit -p telemetry/tsconfig.json
```

Evaluation with the downloaded archives:

```sh
bun telemetry/scripts/derive-geometry.ts 11361 1
bun telemetry/scripts/normalize.ts 11361 telemetry/geometry/11361.experimental.json --experimental
bun telemetry/scripts/benchmark.ts 11361
bun telemetry/scripts/baseline-legacy.ts
```

Repeat with `11299` (Monaco) or `11253` (Suzuka). The checked-in fixtures run offline. `scripts/fixtures.ts` regenerates extracted test subsets from downloaded archives; it does not claim those subsets are byte-exact API responses.

External reference geometry can be imported and aligned into a session's experimental local frame:

```sh
bun telemetry/scripts/import-geometry.ts 11253 --tumftm Suzuka --kerbs
bun telemetry/scripts/import-geometry.ts 11361 --tumftm Monza --kerbs
bun telemetry/scripts/import-geometry.ts 11299 --geojson mc-1929 --default-width 11 --kerbs --max-rms 40
```

`import-geometry.ts` downloads an open centerline ([TUMFTM racetrack-database](https://github.com/TUMFTM/racetrack-database) with per-point left/right widths, or [bacinger/f1-circuits](https://github.com/bacinger/f1-circuits) WGS84 GeoJSON projected equirectangularly), caches the exact source under `geometry/reference/` and records its SHA-256 in provenance. A similarity transform (scale/rotation/translation, best phase and direction by cross-correlation, then ICP refinement) aligns the centerline onto the session's experimental geometry; a fit worse than 15 m RMS is refused unless explicitly overridden with `--max-rms`. Output is `<sessionKey>.tumftm.json`/`.bacinger.json`: `verified: false`, confidence capped at 0.8 and reduced by fit RMS, never overwriting `.experimental.json` (re-runs need `--force`). TUMFTM widths are satellite-derived; the GeoJSON path has no measured widths and uses a constant default. There is still no WGS84 transform and z is copied from the nearest experimental point. `--kerbs` writes a separate synthetic `<sessionKey>.kerbs.json` (curvature-derived 2 m strips at corner apexes and exits), not measured geometry and not part of the version-1 format. Suzuka/Monza align at ~2 m RMS, but the Monaco experimental lap is geometrically distorted (~2.5 km vs the 3.3 km circuit), so its fit reaches ~36 m RMS at confidence 0.3 — it needs the explicit override and should be treated as approximate.

Run only one ingestion process per IP at a time. The client spaces requests by 2.1 seconds for OpenF1's public 30/minute tier, retries throttling/server/network failures with bounded backoff and preserves resumable progress. A per-session lock prevents competing manifest writers. A stale lock after a forced process kill must be removed only after checking its PID is no longer running. Responses exceeding 100 MB fail explicitly; split requests into smaller time windows rather than raising memory limits. Automatic window subdivision and distributed rate limiting are not implemented.

## Archive and timeline

`data/<session>/raw_position/<sha256>.json` contains exact `/location` response bodies, including whitespace, numeric spelling and source timestamps. Other exact response bodies are in `raw_events/`. Files are installed with create-only atomic links. Reads verify SHA-256; ingestion resumes only after checking existing response hashes. A manifest records endpoint URL, driver selection, counts, retrieval time and hashes. `complete` means the requested download completed, not that OpenF1 supplied a complete race. Coverage explicitly distinguishes selected drivers from the full entry list on newly completed ingestions.

`normalized_position/<revision>/` stores independently compressed driver datasets and a manifest containing raw provenance, geometry, processing measurements, encoding and pipeline source hash. The revision depends on source code, raw hashes and geometry. Raw files never get rewritten by normalization.

All timed endpoints use one session origin (`sessions.date_start`). Internal timestamps are **integer microseconds relative to that origin**, including negative pre-session events. ISO offsets and six-digit fractional seconds are preserved. No stream receives an independent zero or a guessed clock correction. Suspension time stays on the timeline. Positions outside a one-hour pre-session/two-hour post-scheduled-end window are quarantined; this explicit policy catches previous-day packets and must be adjusted for exceptionally delayed sessions. Original dates remain in the raw archive. Untimed/malformed rows are diagnosed, not assigned invented times. Stints remain lap-indexed because they do not contain absolute timestamps.

Each normalized keyframe stores original X/Y/Z, its input row index, track/route distance, continuous race distance when justified, source lap, source speed, heading, confidence, disposition/reasons, segment and permission for its **outgoing** interpolation edge. Dataset headers hold the session and driver identities once. Exact duplicates are removed only from the normalized timeline. Conflicting location timestamps disable both anchors; conflicting state/telemetry timestamps return unknown rather than arbitrarily choosing a value. Sorting does not change raw ordering.

## Position and route policy

A dense polyline is sufficient; an unconstrained spline is deliberately avoided. A spatial grid finds nearby candidate segments. Projection scoring includes the previous route distance, observed speed and a forward travel bound. Ambiguous nearby but topologically distant segments are rejected. Three-point checks identify isolated spikes. Small reverse projections (at most 3 m) are held at the previous route distance with reduced confidence and an explicit correction reason. Larger reverse motion starts a new segment; it is not animated backward as ordinary racing.

Track distance wraps modulo route length; continuous race distance unwraps through the finish line. Source lap timestamps are approximate, so the lap label stays sourced as-of rather than being fabricated from projection. Inconsistent source lap jumps break interpolation. Continuous distance is segment-scoped following gaps/reacquisition; it is **not** a substitute for official classification and can have an uncertain lap offset near an approximate lap boundary.

The physical motion bound is 125 m/s plus positional tolerance. An additional speed/position consistency check disables edges whose distance differs from the mean endpoint car speed by more than `max(8 m, 60% of expected travel)`. These are documented engineering guards, not fitted evidence that every accepted position is correct. Lateral projection can move an anchor by up to the 30 m search corridor; confidence decreases with residual. Unverified geometry caps confidence at its declared value.

Pit routes are separate open polylines including entry/exit geometry, with explicit `entryTrackDistance` and `exitTrackDistance`. Verified endpoints must meet the track within 3 m, and an entire cross-route interpolation edge must satisfy the travel bound. Playback walks the two route portions instead of drawing a chord through the infield. Pit distance is not misrepresented as racing-centerline distance. When no pit route exists, affected pit/in-out laps are excluded conservatively. This loses valid racing coverage on those laps but avoids snapping pit cars onto the track. Geometry can also identify unreported pit visits. Incomplete/unrecorded pit events remain a limitation.

OpenF1's `/pit.date` comes from several upstream event/report topics; the API does not establish precise entry and exit timestamps. The pipeline does **not** subtract `lane_duration` and assert the result is a measured pit entry. Monza's long red-flag pit duration illustrates why that distinction matters.

## Playback

```ts
import { Replay, renderTimestamp } from "./src/playback";

const replay = new Replay();
// JSON.parse(new TextDecoder().decode(Bun.gunzipSync(await Bun.file(path).bytes())))
replay.add(driverDataset);
const state = replay.getDriverState(11361, 1, renderTimestamp(60_000_000));
```

State contains XYZ **in the geometry's local meter frame**, heading, track distance, continuous race distance, lap, official `racePosition`, gaps, gear, RPM, pedals, DRS, race state and interpolation metadata. A renderer uses `availability` and `opacity`: hold briefly across a hole, fade out, then fade in at a newly observed fix. It never extrapolates or flies a car across an unknown gap. Before the first fix and after a stale final fix, location is unavailable; this does not assert that a driver retired.

Classification, gear, DRS, flags and gaps use as-of source events. `+1 LAP` is retained as a string. Missing/stale telemetry is null; invalid pedal values such as the observed 104 are not clamped into full throttle/brake. No gear, RPM, DRS or race order is inferred from movement. Race-control red flags latch until an actual session-start event; announcements that the race “will resume” and sector-green messages do not restart it. Sector/driver flags remain available in the source event stream and do not globally change track status. Safety-car/VSC state changes rely on explicit messages/track flags; unknown variants are preserved without guessing.

Default interpolation is linear distance along the route. The buffer default for an already loaded historical race is **zero**: future anchors are available, so an artificial delay provides no benefit. A streaming recommendation (`p95 + p50`, capped at 1.5 s) is exposed separately. Pass the same render timestamp to position, telemetry, classification and race state.

Gap policy is derived per driver/session: normal edges up to `min(1 s, max(p95, 2*p50))`, conservative edges up to `min(2 s, max(normal, 3*p99))`; longer gaps never interpolate. Conservative edges reduce confidence. Hold time is at most 500 ms, followed by a 200 ms fade. These multipliers and hard caps are policy, distinct from measured quantiles. Exact source dates remain available for future calibration.

Experimental monotone Hermite and anchor-constrained speed integration are evaluated by the benchmark but are not selected implicitly in production. Integration never accumulates drift across anchors; incompatible speed integrals are rejected. The comparison did not demonstrate a material enough improvement to justify enabling either universally.

## Validation and remaining work

See [AUDIT.md](AUDIT.md) and machine-readable [reports](reports/). Tests cover actual 2026 Monza, Monaco and Suzuka subsets, classification changes, SC/red-flag data and synthetic adversarial cases. Pit geometry/connector traversal is tested synthetically because no verified surveyed pit routes are available. There is no independent centimeter-accurate reference for those sessions, so “correct centerline projection” is not claimed to recover precise lateral placement or prove accurate overtakes. Projecting every driver to one reference line cannot reproduce side-by-side racing.

Before replacing native playback: review/calibrate actual circuit and pit geometry; define/version its WGS84 transform; port or bridge the replay contract into Swift; carry unknown values and availability through the HUD; benchmark actual MapKit/SceneKit frame times. The old importer synthesizes missing car telemetry through `TelemetryEstimator`; the normalized API intentionally does not. Its output must not be fed into that fallback without carrying provenance and null semantics.

Clock offsets across independently reported channels cannot be uniquely inferred from these data. No automatic correction is attempted. The source's sparse/jittery longitudinal fixes still produce significant implied acceleration even after projection. Confidence/gap handling prevents several classes of false motion, but this is not a claim of universally smooth or independently validated historical playback.

Sources: [OpenF1 API documentation](https://openf1.org/docs/), [public rate limits](https://openf1.org/), [OpenF1 pit ingestion implementation](https://github.com/br-g/openf1/blob/main/src/openf1/services/ingestor_livetiming/core/processing/collections/pit.py).
