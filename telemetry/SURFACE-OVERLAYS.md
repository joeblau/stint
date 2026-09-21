# Miami imagery surface overlay

Miami now bundles `apple/Stint/Resources/miami.surface.geojson`. Race and calendar flyover maps load this asset instead of the constant 12 m fallback. Other circuit assets are unchanged by this rollout.

The source is Miami-Dade County aerial imagery, approved in place of Google imagery. Two export requests cover the circuit and more than a 200 m margin at zoom-19 equivalent sampling (0.268 m/pixel). The service advertises 2025 imagery, but other service fields say 2024; an exact capture date is not supplied. Native sensor resolution and surveyed positional accuracy are not established by the pixel grid.

## What is bundled

- Independent widths sampled at 5,432 stations, approximately 1 m apart. About 89% of the two edges have observations; about 80% of road intervals have both edges observed at both ends.
- One continuous neutral asphalt polygon with one infield hole. Independent widths are smoothed from reliable imagery observations; obscured and weak sections are interpolated around the closed lap. These display estimates are explicitly distinguished from the original observations.
- Continuous cyan, magenta and yellow sector edges split using the official FIA timing-line axes, including through the interpolated sections.
- 25 reviewed red/white kerb strips, covering entries, apexes and exits after checking all 19 turns. Presence and side were checked against F1’s official 2026 pole-lap video; geolocation follows the county raster. Turns 9 and 10 have ordinary edge markings and no identified kerb. Endpoints and hidden positions remain approximate. No physical kerb width or height is exported.
- EPSG:4326 `[longitude, latitude]` coordinates only. Sector colors never fill road polygons. Sector lines are 2 device pixels, with 0.05 m stored only as an appearance reference. Kerbs use 6 device pixels: solid white beneath alternating red dashes, with sector lines above them.

All geographic geometry remains unverified. Kerb presence is visually corroborated; this does not establish survey-grade coordinates. Miami has no TUMFTM reference. The report retains the original observations (including nulls), lists inferred stations, and records independent confidence, control pairs, alignment residuals and timing provenance. `observedRoadFraction` describes the source coverage; `displayRoadFraction` is 1. The `widths` table describes the refined visualization, not raw measurements. `observedRoadFraction` retains the initial detector’s coverage. `kerbReview` records every strip, onboard timestamps, pixel support, inferred stations, intended rendered coordinates and all 19 turn reviews. The imagery-to-reference registration uses three visually identified corridor midpoints (RMS approximately 0.67 m); this residual is not absolute ground accuracy.

## Sources and registration

[County aerial service](https://gisweb.miamidade.gov/arcgis/rest/services/MapCache/MDCImagery_WebMercator/MapServer), [county public-use statement](https://www.arcgis.com/home/item.html?id=df9bba0031c0453da91ef55371c697f2), [bacinger centerline](https://github.com/bacinger/f1-circuits/blob/master/circuits/us-2022.geojson).

The [FIA 2026 Miami circuit map](https://www.fia.com/system/files/decision-document/2026_miami_grand_prix_-_competition_notes_-_circuit_map_pit_lane_drawing_emergency_exits_map_and_red_zone.pdf), document 5, page 2, supplies the finish/S1/S2 timing symbols. Their vector axes were registered to the community centerline using a robust similarity fit of the diagram's medial axis (approximately 1.13 m RMS). Sector lengths are 1,866 / 1,730 / 1,816 m; S1 is 110 m after T8 and S2 is 70 m after T16. These lengths are a cross-check, not equal-thirds placement. The diagram is used only for timing registration, never for road widths.

Acquisition URLs, source metadata and image hash are in `geometry/reference/miami-county-imagery-source.json`. Timing endpoints, transformation and registration residual are in `geometry/reference/miami-fia-timing-registration.json`. Configuration and geographic controls are in `geometry/surface-config/miami.json`. The complete kerb inventory is in `geometry/reference/miami-kerb-review.json`. It is bound to the raster and centerline hashes so a changed source cannot silently reuse old extents. The [official onboard](https://www.youtube.com/watch?v=7pGVugNI59c) establishes presence and side; it is not a source of geographic coordinates. The footage shows orange/white paint; red/white remains the requested display styling. No video or frames are bundled. QA images and the [turn-by-turn inventory](reports/miami-surface-qa/kerb-inventory.md) are in `reports/miami-surface-qa/`.

## Rebuild

```sh
uv venv --python 3.12 /tmp/stint-miami-venv
uv pip install --python /tmp/stint-miami-venv/bin/python -r telemetry/scripts/imagery/requirements-surface.txt
export STINT_IMAGERY_PYTHON=/tmp/stint-miami-venv/bin/python

# Reuse the local county raster, or fetch the two Miami exports if it is missing.
python3 telemetry/scripts/imagery/fetch-miami-county.py
bun telemetry/scripts/extract-surface.ts telemetry/geometry/surface-config/miami.json --force
bun mac:stint
```

Use the environment's Python with Pillow for the download command. The raster cache is ignored by Git. The extraction command itself makes no network requests. `--plan` prints prerequisites and bounds; `--diagnostic` writes to `telemetry/reports/miami.surface.diagnostic.geojson`, preserving the bundled app asset. Existing outputs require `--force`.

The Miami configuration enables `continuousVisualization`. It requires reliable observations at at least 55% of stations on each side before interpolation is allowed. Shapely rejects invalid geometry before replacing any app asset and additionally requires one polygon with one hole, two closed sector-edge loops, and exact agreement between the road and those loops. It also checks every reviewed kerb ID and compares the full exported geometry to its intended traced span, so a partial strip cannot silently disappear. The strict extraction and diagnostic patch modes remain available without continuous refinement.

## Extraction and rendering

The reference follows the same centripetal spline interpolation as the app. Image profiles extend 25 m to either side in 0.25 m steps. Asphalt segmentation, contrast and turquoise boundary paint identify independent sides. Neighbor guidance narrows the search through exposure changes, but every accepted station still requires its own visible color or light-strip evidence. Reversed/folded offsets and isolated outliers are rejected.

The reviewed strips guide a longitudinal paint trace that recognizes faded warm/white paint. Pixel scores determine the positions within a narrow search corridor, with continuity penalties preventing jumps to parking markings. Reviewed road-edge guides correct false apron/grass boundaries near Turns 3, 4, 6, 8 and 9, the north straight, and the start straight. Eight bridge/shadow masks prevent bridge-deck pixels being mistaken for road or kerbs.

For display, confidence >=0.5 boundaries pass through an independent 6 m median filter, periodic interpolation and 4 m Gaussian filter. Inside offsets approach bend-radius limits gradually, with a further 2 m transition filter to avoid creases. Every reviewed kerb span is retained through entry/exit straights and across occlusions. Unobserved positions are flagged as inferred with confidence 0.15; visible paint positions remain low confidence (0.25). The kerb line follows the smoothed road edge with a 0.3 m outward display offset. Endpoints carry approximately 8 m uncertainty; this is an estimate, not a measured error bound. The earlier curvature-only filter remains available for unreviewed diagnostics but no longer determines the bundled Miami kerb coverage. Native MapKit renders neutral polygons beneath thin edge lines at `.aboveRoads`; Miami requests Apple's realistic terrain and supplies no elevation. Terrain availability and perspective foreshortening are MapKit-dependent. Cars still use the existing screen-composited scene.

```sh
bun test telemetry/tests/surface-overlay.test.ts telemetry/tests/miami-kerb-review.test.ts
python3 telemetry/tests/test_miami_surface_cli.py
$STINT_IMAGERY_PYTHON telemetry/tests/test_miami_surface_topology.py
bun run --cwd telemetry typecheck
```

Regenerate the overview, all 19 turn crops and inventory table with `$STINT_IMAGERY_PYTHON telemetry/scripts/imagery/render-miami-review.py` (add `--diagnostic` for the diagnostic asset).

Native `CircuitEdgeOverlayTests` load the actual bundled Miami asset and verify the single road polygon, three sector colors, all 25 reviewed strips, rejection of missing kerbs, pixel strokes, opaque red/white stripe rendering, and absence of the fallback. Synthetic fixtures are never used as Miami production data.
