# Miami finishing review

The complete lap was reviewed against Miami-Dade County imagery and [FORMULA 1’s public 2026 pole-lap onboard](https://www.youtube.com/watch?v=7pGVugNI59c). The result retains 25 identified racing-edge kerb strips across entries, apexes and exits, with all 19 turns recorded in [the inventory](kerb-inventory.md). Turns 9 and 10 have ordinary edge markings with no identified kerb.

`continuous-road.png` shows the final neutral road, sector boundaries and requested red/white kerb livery. `imagery-review.jpg` compares the final geometry against the calibrated county image. Five `turns-*.jpg` sheets show all 19 corners at closer range. Geographic positions and endpoints remain approximate; the eight bridge/shadow masks are explicitly interpolated. Video establishes presence and side, not geographic coordinates. No video frames are redistributed here.

`review-metrics.json` records the actual final asset checks. It has one valid road polygon with one infield hole, two closed sector-edge loops matching the road, and coverage of the complete 5,432-station centerline. Every reviewed kerb is exported over its full intended span, including the lap seam. The 25 strips occupy 26 GeoJSON LineStrings because the start-straight strip crosses that seam.

The earlier `observed-coverage.png` is retained as a before image showing the extraction-only gaps. `timing-registration.png` records the FIA timing-axis placement.

Verification: 34 TypeScript extraction/review/refinement tests, 3 CLI tests, 9 actual-asset geometry tests, and 12 native renderer/parser tests passed. TypeScript type checking and the macOS Release build passed. Native tests verify opaque alternating red/white pixels and reject a bundle missing a reviewed kerb. In-app screenshot automation remains unavailable in this environment (macOS timed out enabling automation mode in the preceding pass); the full-lap atlas and native renderer tests provide the available visual/rendering verification.
