# Telemetry audit and benchmark

Measured locally on macOS 27, Apple Silicon, Bun 1.4.0. Network download time is excluded. Full reproducible values and metric definitions are in the JSON reports and `scripts/benchmark.ts`.

## Existing implementation

`apple/Stint/Models/RaceData.swift` interpolates latitude/longitude directly, clamps to the first/last fix, and has no gap or entry/exit policy. `TelemetryEstimator` infers missing gear/RPM/pedals/DRS; that is suitable for a labeled demo but not source-faithful historical telemetry. `RaceTiming` can derive race progress geometrically. The new API instead reads official classification events as-of. No OpenF1 ingestion service was present in this checkout; the new package is separate from the native importer.

The checked-in Monza version-1 replay is 14.21 MB with 160,688 samples for 22 drivers. Its first driver has 1,000 ms median spacing (maximum 2,000 ms); source XYZ and original dates are absent, as are speed/car telemetry. Downsampling was already performed upstream, but that upstream converter is absent, so the exact cause of the downsampling cannot be established here. Interpolating those geographic points cuts corners and permits motion across missing intervals. Raw data cannot be reconstructed from that derived file.

## Actual OpenF1 data

| Session | Drivers downloaded | Position fixes after quarantine | p50 / p95 / p99 interval (driver 1) | Largest in-window gap |
|---|---:|---:|---|---|
| 11361 | 22 | 861,146 | 241 / 440 / 520 ms | 1.359 s |
| 11299 | 2 | 16,174 | 240 / 420 / 520 ms | 3011.436 s |
| 11253 | 2 | 71,466 | 240 / 420 / 520 ms | 3.900 s |

Monza 11361 includes a previous-day location packet and a previous-day car-data packet per driver despite the correct session key. These remain archived and are excluded from the position timeline. Monaco 11299 contains a roughly 50-minute location hole; a successfully downloaded response does not mean the source covers the whole race. Both position and car data have approximately 240 ms median intervals in Monza; car data is not uniformly higher frequency. Their clocks are phase-shifted, and source sampling variation remains visible.

Monza provides actual safety-car and red-flag cases: SC at 13:06:49 UTC, suspension at 13:07:43, and the explicit session restart at 13:39:00.102. “RACE WILL RESUME” announcements before that time must not clear the suspension. Driver 63 has a 1,846.2 s lane-duration report around resumption; `/pit.date` is not treated as a guaranteed entry time. Pedal values of 104 and null DRS occur and remain unknown in the normalized telemetry.

## Matched comparison and costs

Full Monza normalization processed 861,146 keyframes in **3.41 s**. Reading/validating archives took 0.83 s; serialization and compression took 3.32 s. Total measured local work was about 7.57 s, plus benchmark queries.

Raw response bodies occupy 258.1 MB. The normalized output adds 43.8 MB compressed (513.1 MB if expanded to verbose JSON). Raw and normalized archives are both retained. No 60 FPS frame expansion is stored.

| Metric | Baseline raw XY interpolation/projection proxy | Normalized |
|---|---:|---:|
| Random driver-state lookup, mean | 0.254 µs | 0.873 µs |
| Absolute implied acceleration p95, average across drivers | 185.1 m/s² | 174.1 m/s² |
| Backward edges >3 m, matched accepted subset | 44 | 0 |
| Teleport guards violated | 280 over all raw edges | 0 over accepted edges |
| Mean absolute lateral residual change, jitter proxy | 0.056 m | 0 by construction |

Accepted interpolation coverage is **71.8% of raw edges** averaged across the 22 drivers. The remainder includes pre/post-session off-route samples, uncertain pit laps, topology failures and speed inconsistencies. Zero teleports is partly achieved by withholding uncertain motion; it is not evidence that missing locations have been recovered. Acceleration remains high: this pipeline has not eliminated longitudinal source jitter. The lateral residual metric is zero by projection and must not be sold as proof of true positional accuracy.

The baseline CPU benchmark implements the old coordinate interpolation algorithm in Bun. It is not an Instruments measurement of the Swift app, and the new lookup does more work (state, telemetry, confidence and availability). Its low absolute cost does not establish a MapKit/SceneKit frame-rate improvement.

## Interpolation experiment

Every other eligible normalized fix is withheld between two known anchors. All compared methods use the same subset. Errors are measured against the withheld projected fix, not an independent tracking system. Speed integration must agree with anchor distance within a 0.7–1.3 ratio and satisfy the speed bound.

| Session | Linear mean error | Monotone Hermite mean error | Anchored speed-profile mean error |
|---|---:|---:|---:|
| 11361 | 2.453 m | 2.391 m | 2.426 m |
| 11299 | 1.669 m | 1.587 m | 1.611 m |
| 11253 | 2.009 m | 1.957 m | 1.987 m |

Decision: retain linear route-distance interpolation as the default. Improvements are small and inconsistent, and smoother velocity is not sufficient evidence of more accurate motion. Experimental functions are available for further testing but are not enabled implicitly. Catmull–Rom is not used because unconstrained splines can overshoot and cut the route.

## Validation and rollout limit

18 automated tests run offline against four actual fixture subsets from three 2026 sessions plus adversarial/synthetic scenarios. Coverage includes microsecond/offset timestamps, ordering and duplicate conflicts, immutable raw storage, start/finish crossings, source classification changes, high-speed telemetry, nearby hairpin topology, gaps/reacquisition, malformed samples, stationary suspension, SC/red flags, and verified synthetic pit entry/lane/exit connectors. TypeScript strict type checking also passes.

The native gauge/icon change was built for Mac and deployed to the physical iPad; 65 native regression tests passed. These native checks do not validate the new telemetry package in the Apple renderer.

The experiment-derived geometry uses one covered lap per circuit, a declared 0.1 m/raw-unit hypothesis checked against integrated car speed, and a modest confidence cap. This is not a surveyed centerline or an independently verified coordinate calibration. Its approximate finish-line origin can leave an uncertain continuous-distance lap offset after reacquisition. Missing surveyed pit paths, precise lateral/overtake truth, channel clock offsets, native WGS84 integration, and full-race source completeness remain unresolved. The existing native replay path is intentionally not replaced with this unverified data. See README for the exact integration contract and safeguards.

Primary references: [OpenF1 documentation](https://openf1.org/docs/), [OpenF1 pit ingestion source](https://github.com/br-g/openf1/blob/main/src/openf1/services/ingestor_livetiming/core/processing/collections/pit.py).
