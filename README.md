# Stint

A native, map-first F1-style race viewer for **Mac and iPad**, built with SwiftUI, Apple MapKit, and procedural SceneKit cars. XcodeGen is the source of truth for the Xcode project.

## Run

Requires Xcode 26 or newer and XcodeGen. Targets macOS 15+ and iPadOS 18+.

With Bun installed, generate the project, build, and launch either app:

```sh
bun mac:stint
bun ipad:stint      # physical 13-inch iPad Pro
bun ipad:stint:sim  # iPad simulator
```

The iPad command finds your paired physical **13-inch iPad Pro**, builds with automatic development signing, installs Stint, and launches it. Connect/trust the iPad and enable Developer Mode before the first deployment. It never falls back to a simulator. To target a particular physical iPad, use `bun ipad:stint <UDID>` or `STINT_DEVICE=<UDID> bun ipad:stint`. The project uses team `K78G42H4U2`; override it with `STINT_DEVELOPMENT_TEAM` if needed.

For a simulator, use `bun ipad:stint:sim`. It prefers an already booted iPad; select another with `bun ipad:stint:sim 'iPad Pro 11-inch (M5)'` or its UDID.

To open the project in Xcode instead:

```sh
brew install xcodegen # if needed
xcodegen generate
open Stint.xcodeproj
```

Choose the **Stint** scheme, select **My Mac** or an **iPad simulator**, and Run. For a physical iPad, select your development team under Signing & Capabilities. No API key is needed; Apple Maps imagery requires a network connection.

```sh
# Build Mac without signing
xcodebuild -project Stint.xcodeproj -scheme Stint \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# Build iPad simulator without signing
xcodebuild -project Stint.xcodeproj -scheme Stint \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# Model tests and Mac UI smoke test
xcodebuild -project Stint.xcodeproj -scheme Stint \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test

# iPad UI smoke test (replace the simulator name with one installed locally)
xcodebuild -project Stint.xcodeproj -scheme Stint-iPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -derivedDataPath build-ipad CODE_SIGNING_ALLOWED=NO test
```

## Use

- A centered floating **Calendar / Race** segmented control switches between the season globe and the race viewer. The native top bar is removed on both platforms, and the iPad status bar is hidden. The standings and gauge share the segmented control’s top edge; the standings and right-side controls share the player’s bottom edge. Race and Calendar panels share a consistent 16-point outer inset, without an extra bottom safe-area gap on iPad. Fading the controls does not shift the map. Calendar pauses replay progression while you browse. Switching modes flies the camera continuously between the globe and the track, preserving follow/overview mode. Reduce Motion skips the camera flight.
- Calendar opens at globe scale with arcs joining consecutive rounds of the 2026 season. Completed weekends use lime markers and solid arcs; upcoming weekends use muted markers and dashed arcs. Drag the globe to see other continents. Nearby venues cluster; click a cluster to zoom into its races.
- Choose a venue on the globe, a race-weekend date in the month calendar, or a track in the ordered schedule. Clicking an individual globe pin zooms into its physical circuit, even when already selected. **Open race** loads that circuit’s simulated replay. Swipe left/right across the month calendar to advance or go back a month; the arrow buttons remain available. **Entire globe** resets the camera. Calendar controls remain visible while browsing.
- Weekend dates use the venue’s local time zone. Completion follows the end of the scheduled weekend; calendar data is a bundled snapshot rather than a live results feed.

- The top-right glass panel combines the track name and **Data source**, which opens a searchable library of 40 circuits and JSON replay import.
- Pan, pinch to zoom, rotate, and tilt the Apple Map using native gestures. Pinching releases the follow camera at its current position so it does not fight manual zoom; use Follow car to resume tracking. Pinch zoom also works on the calendar globe. The 2D/3D control eases the camera pitch in either direction, including during paused playback; reversing a transition starts from the current view. Reduce Motion switches immediately.
- The standard map with buildings is the default; satellite imagery is available in Map appearance.
- The lighting button beside Layers offers **Day**, **Night**, and **Race time**. Every race selection defaults to Race time, independent of the current clock. Race time uses the bundled [published local start times](https://www.formula1.com/en/latest/article/official-grand-prix-start-times-for-2026-f1-season-confirmed.2UgPfArqH76tzlOYh21jSG.2UgPfArqH76tzlOYh21jSG) plus replay elapsed time and estimates solar elevation at the circuit. The standard map crossfades between its day and night appearance while the car lighting fades with it; Apple imagery is not a historical sky/weather simulation. Unknown start times (including relocated Sepang) and imported replays without calendar metadata use a labeled 15:00 demo fallback. For circuits outside the calendar, the fallback uses September 7, 2026 and an approximate local offset from longitude.
- Follow/overview changes use a 1.8-second eased camera flight, including while replay is paused. Reversing the toggle mid-flight starts from the current camera. Reduce Motion switches immediately.
- The row of five icons above the standings switches the last column. Four favorites (**Gap**, **Interval**, **Tyres**, and **Time** by default) sit beside a fifth button that opens the full list: **Sectors** (purple for the session's fastest, green for a personal best, yellow otherwise), **Best**, **Pit**, **Diff** (positions gained or lost from the grid), and **Laps**. Tap a row to show that column; drag rows to reorder them, and the top four become the favorite buttons. Choices persist.
- Select a driver in the full-width left standings list or tap their car. Follow/overview mode and the selected driver persist when switching circuits (a missing driver falls back to the new replay’s first driver). The button beneath Layers on the right toggles between **Follow car** and **Zoom out** to the whole circuit. Follow enters the closest low-angle view supported by MapKit and turns behind the driver; zoom and tilt remain adjustable. Disable **Rotate with followed driver** in Map appearance to hold a fixed heading.
- The compact bottom-center player supports play/pause (Space on Mac), scrubbing, restart, and cycling 0.5×–4× speed.
- Click the gauge speed readout to switch between km/h and mph; both the number and outer scale change, and the preference is saved. The circular gauge uses the same Liquid Glass material as the other panels. Speed labels sit inside the blue-to-cyan outer band, while throttle and brake labels follow their own inner bands; throttle fills green-to-lime. Pedal fills animate in proportion to their values (Reduce Motion disables animation).
- The bottom-right eye button toggles **Auto-hide HUD**, and the choice is saved across launches. With auto-hide enabled, the segmented control, panels, car labels, selection rings, and app controls fade after five seconds without input. With auto-hide off, the full HUD stays visible. Move the mouse or touch the map to reveal them. Popovers, scrubbing, file import, and VoiceOver keep controls visible. The native map scale and compass stay hidden. Apple Maps attribution remains visible.
- The Stint palette reserves red (`#E10600`) for primary actions, the active tab, and race selection; black, asphalt, pit gray, and off-white support lightly tinted glass, silver telemetry, and neutral globe routes. Team colors and green throttle/DRS indicators retain their meaning.
- Front wheels steer from replay-path curvature, with a tighter angle on the inside wheel. The hinged rear-wing flap follows the same DRS state as the gauge, including recorded telemetry overrides. Seeking snaps the articulation to the replay position; normal playback eases steering and wing movement.
- Panels use native Liquid Glass on macOS/iPadOS 26+, with a translucent material fallback on older supported systems.

## Data sources

Bundled demos use geographic circuit outlines with a **simulated**, constant-speed field. A closed centripetal Catmull–Rom spline adds points roughly every two meters, including through corners and across the start/finish seam. Demo positions are sampled at 30 Hz and interpolated during playback. This smooths the approximate demo centerline; imported GPS samples retain their original path. The field includes all 22 drivers across the 11 official 2026 teams, with team names, car numbers, and distinct team colors. Race order, gaps, and lap times are simulated; these are not actual race results. No live feed is connected.

The circuit library includes all 23 venues on the [current 2026 calendar](https://www.formula1.com/en/racing/2026), plus 17 additional/historic venues, including Sakhir and Jeddah. Calendar membership is a snapshot as of September 7, 2026. Geographic outlines are community-maintained and may represent older configurations. The grid follows the [official teams](https://www.formula1.com/en/teams) and [2026 driver numbers](https://www.formula1.com/en/latest/article/all-the-2026-f1-driver-numbers-confirmed-in-full.5rh7o9mPntG7NerzVk9onc).

Import `Examples/monaco-replay.json` through the data-source popover to try file playback. The format is:

```json
{
  "version": 1,
  "title": "My race replay",
  "circuit": [
    {"latitude": 43.739404, "longitude": 7.427191},
    {"latitude": 43.739494, "longitude": 7.427171},
    {"latitude": 43.739575, "longitude": 7.427199}
  ],
  "recordings": [{
    "driver": {"id": "CAR", "name": "Example Driver", "number": 7, "color": "#FF8700"},
    "samples": [
      {"time": 0, "latitude": 43.739404, "longitude": 7.427191, "heading": 350, "speedKPH": 180},
      {"time": 1, "latitude": 43.739494, "longitude": 7.427171, "heading": 10, "speedKPH": 180}
    ]
  }]
}
```

Time is seconds from session start. Every driver starts at zero and has at least two strictly increasing timestamps. Heading is clockwise degrees from geographic north in `[0, 360)`. Speed is optional. Coordinates are WGS84 latitude/longitude (latitude restricted to ±85° for the map). Maximums: 24 drivers, 200,000 samples per driver, 24 hours, and a 50 MB file. Positions and headings interpolate between samples; drivers with shorter recordings hold their final position until the session ends. Import failures preserve the current session.

Replay samples may supply optional `throttle` and `brake` fractions from 0 to 1 (for example, `0.75` means 75%). Recorded values interpolate between samples and drive the gauge directly. When absent, pedal values are estimates from acceleration; the constant-speed demo therefore shows no changing pedal input. An optional Boolean `drs` field controls the DRS indicator directly; enabled DRS glows lime. Without it DRS is estimated, as are gear and RPM.

Optional timing metadata per recording: `gridPosition` (1–24), `stints` (`[{"startLap": 1, "compound": "M"}]` with compounds S, M, H, I, W) and `pitStops` (`[{"lap": 12, "entryTime": 1180.5, "exitTime": 1203.2, "stationary": 2.4}]`, times in session seconds). The replay may also carry `totalLaps`. Laps, lap times, sectors, gaps, and intervals are derived from track progress: the first circuit point is the start/finish line, sectors split the lap into three equal distances, and gaps compare when two cars reached the same track distance. `gapToLeader` in samples takes precedence when present. Without stints or pit stops the Tyres and Pit columns show a dash.

**OpenF1 / FastF1 adapters:** Raw telemetry X/Y values are not latitude/longitude. A future adapter must calibrate translation, scale, and rotation against the correct circuit, transform positions into WGS84, and emit the replay schema. There is deliberately no guessed placement of raw telemetry. See [OpenF1 location documentation](https://openf1.org/docs/#location).

## Rendering

For imported standings, samples may include optional `racePosition` (1–24) and `gapToLeader` (nonnegative seconds). Position changes take effect at the sample timestamp; gaps interpolate between samples. Missing standings values appear as dashes. Demo standings use the simulated field order and gaps, not real race results.

`RaceMapSurface` places one transparent SceneKit scene above an `MKMapView`. MapKit projects each car coordinate and two nearby ground points into view coordinates. Those vectors form a per-car local transform, including map heading and pitch. A vertical orthographic camera aligns the scene with the map's logical pixels on both platforms. Original procedural meshes contain bodywork, front and rear wings, open wheels, suspension, a cockpit, and a halo.

Cars are deliberately enlarged at circuit zoom to remain legible. The scene passes gestures through to the map; map taps select the nearest car. Flat map elevation avoids a terrain mismatch. This is a screen-composited 3D overlay: buildings/terrain do not occlude cars, and circuit elevation is not modeled. SceneKit is deprecated in the newest Apple SDKs but remains available at the deployment targets; the isolated renderer can later be replaced with RealityKit or Metal.

Both map renderers remain mounted across mode switches so their tiles and camera state can be reused. Inactive views stop rendering. Globe arcs cache their spherical coordinates; pin labels and accessibility metadata update only when group membership changes, and drawing runs at most once per 60 Hz timer tick when dirty. Demo generation for calendar-to-race transitions runs off the main thread.

`RaceSession` owns playback and source changes. Playback and rendering target approximately 60 Hz; background windows suspend the playback clock. Replay decoding and validation run off the main actor. There are no third-party Swift dependencies.

The UI smoke tests exercise pause/play state, circuit switching, driver selection, follow/overview mode, and appearance controls. They retain screenshots in the test result bundle. The app icon is generated by `swift Scripts/generate-icon.swift`, which writes both the Icon Composer bundle (`Stint/Resources/AppIcon.icon`, rendered as Liquid Glass on iOS/macOS 26+) and the flat PNG fallbacks in the asset catalog for iOS 18 / macOS 15.

## Credits

Inspired by the spatial race-viewing concept of [Lapz](https://www.lapz.io/), with original UI and car geometry. Not affiliated with Lapz or Formula 1.

Circuit GeoJSON: [Tomislav Bacinger / f1-circuits](https://github.com/bacinger/f1-circuits), MIT. The license is included in `Stint/Resources/Circuit-LICENSE.txt`. Circuit outlines may represent historical layouts. Apple Maps retains its native attribution.
