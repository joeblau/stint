# Race replay data investigation

Verified September 7, 2026 with direct HTTP requests and the native replay importer.

## Monaco 2026: missing upstream positions

The app selects the correct race: OpenF1 session **11299**, meeting **1286**, June 7, Monte Carlo. Session matching is not the failure.

- Race timing starts at **13:03:11.903 UTC**.
- The location responses for cars **12, 16 and 44** each contain 8,087 samples including the pre-race period. Their last nonzero position is **13:09:42.799 UTC**, only **6 minutes 31 seconds** after the race start.
- Leclerc's lap records continue to approximately **14:28:55 UTC**. Antonelli's final recorded lap finishes at **15:26:43.770 UTC**.
- A later location query returns HTTP 404 with `{"detail":"No results found."}`. A car telemetry query for the same later minute returns 221 samples. The location feed is missing; the whole API is not offline.
- Downloading and decoding F1's public `Position.z.jsonStream` reproduces the same cutoff. Its `CarData.z.jsonStream` continues to **15:30:10 UTC**.

OpenF1's maintainer [confirmed that the source stopped broadcasting locations](https://github.com/br-g/openf1/issues/414#issuecomment-4646686480). FastF1's maintainer [independently confirmed missing source positions while car telemetry remains available](https://github.com/theOehrly/Fast-F1/issues/928#issuecomment-4644156746).

Retrying, subscribing to OpenF1, or changing the map alignment cannot reconstruct this missing feed. A timing-based approximation would need to be explicitly identified as estimated.

Reproduction sources:

- [OpenF1 location, Leclerc](https://api.openf1.org/v1/location?session_key=11299&driver_number=16)
- [OpenF1 lap timing](https://api.openf1.org/v1/laps?session_key=11299)
- [F1 position archive](https://livetiming.formula1.com/static/2026/2026-06-07_Monaco_Grand_Prix/2026-06-07_Race/Position.z.jsonStream)
- [F1 car telemetry archive](https://livetiming.formula1.com/static/2026/2026-06-07_Monaco_Grand_Prix/2026-06-07_Race/CarData.z.jsonStream)

## Monza 2026: invalid optional telemetry

OpenF1 session **11361** contains out-of-range gear values. The response inspected includes 1,447 Leclerc samples after 13:03 UTC with gear values above 8, including **128**. For example, at 13:08:15.749 UTC the feed reports gear 10 and RPM 3,559.

The importer previously passed gear/RPM through unchanged, so one invalid optional reading failed validation of the entire saved replay. It now treats gear outside 0–8 and RPM outside 0–25,000 as unavailable, preserving the remaining sample fields. The existing gauge estimator supplies its usual fallback where a recorded channel is unavailable.

## Free source comparison

| Source | Use for this app | Monaco limitation |
| --- | --- | --- |
| [OpenF1](https://openf1.org/docs/) | Keep as the primary JSON API; historical data is free without authentication. | Missing location feed after the first few minutes. |
| [FastF1](https://github.com/theOehrly/Fast-F1) / F1 archive | Useful secondary ingestion path and bulk historical processing, independent of OpenF1's HTTP service. | Uses the same underlying positions; does not recover this race. Python processing or a native archive decoder would be required. |
| [TracingInsights](https://github.com/TracingInsights/2026) | Public, preprocessed per-lap JSON; convenient for telemetry comparisons. | Inspected Leclerc lap 2 has coordinates, but [lap 10](https://raw.githubusercontent.com/TracingInsights/2026/main/Monaco%20Grand%20Prix/Race/LEC/10_tel.json) has the string `"None"` for every x/y/z value. Not an independent recovery source. |
| [Jolpica](https://github.com/jolpica/jolpica-f1/blob/main/docs/README.md) | Results, lap timing, schedules and standings. | Does not provide the continuous XY telemetry needed for an exact map replay. |

Recommendation: retain OpenF1, validate individual channels, resume interrupted downloads, and distinguish unavailable source data from transient network errors. A secondary archive importer can improve service resilience, but no complete free Monaco position source was found in this investigation.

## Downloader changes

- Retry transient connection errors, HTTP 429 and HTTP 5xx with backoff; preserve cancellation.
- Cache successful nonempty session responses for 24 hours, capped at 512 MB, so a new downloader can resume. Refresh session discovery and empty responses; evict location feeds rejected for incomplete coverage or failed alignment.
- Interpret OpenF1's specific `No results found.` 404 as an empty feed, while retaining other HTTP errors.
- Keep recorded laps beyond the scheduled session finish. Monaco's scheduled end is 15:00 UTC, earlier than its actual finish.
- Report unavailable map data without promising that retrying later will repair the source.

Regression checks cover channel sanitization and saved-file reopening, extended races, network/server retries, cancellation, missing data, resuming across downloader instances and refetching incomplete positions.

Verification: **21 regression tests passed**, and the optional **live Monza download, validation, save and reopen test passed** in approximately 163 seconds. The iPad simulator build passed. These checks used an isolated checkout containing the downloader changes because unrelated globe changes were in progress in the shared workspace.

Run the optional full Monza download check from `apple/`:

```sh
TEST_RUNNER_STINT_OPENF1_LIVE=1 TEST_RUNNER_STINT_OPENF1_CIRCUIT=monza \
xcodebuild -project Stint.xcodeproj -scheme Stint \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:StintTests/OpenF1DownloadTests/testLiveOpenF1DownloadWhenRequested test
```
