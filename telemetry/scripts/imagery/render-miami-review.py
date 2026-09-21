"""Render a full-lap Miami review atlas from the actual exported asset and county raster.

Usage: python render-miami-review.py [--diagnostic]
The onboard is referenced by URL/time only; no video content is redistributed.
"""
import json
import math
from pathlib import Path
import sys
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
asset = ROOT / ("telemetry/reports/miami.surface.diagnostic.geojson" if "--diagnostic" in sys.argv
                else "apple/Stint/Resources/miami.surface.geojson")
doc = json.loads(asset.read_text())
meta = doc["metadata"]
review = meta["kerbReview"]
origin, transform, raster = meta["origin"], meta["alignment"]["transform"], meta["imagery"]
image = Image.open(ROOT / "telemetry/geometry/imagery/miami-county/mosaic.png").convert("RGB")
out = ROOT / "telemetry/reports/miami-surface-qa"
out.mkdir(parents=True, exist_ok=True)
units = math.pi * 6378137 / 180
cos_lat = math.cos(math.radians(origin["lat0"]))


def pixel(coordinate):
    """Undo registration for a faithful comparison against the original aerial image."""
    x = (coordinate[0] - origin["lon0"]) * cos_lat * units - transform["tx"]
    y = (coordinate[1] - origin["lat0"]) * units - transform["ty"]
    a = (transform["cos"] * x + transform["sin"] * y) / transform["scale"]
    b = (-transform["sin"] * x + transform["cos"] * y) / transform["scale"]
    lon, lat = a / (cos_lat * units) + origin["lon0"], b / units + origin["lat0"]
    world = 256 * 2 ** raster["zoom"]
    return ((lon + 180) / 360 * world - raster["originPx"][0],
            (0.5 - math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)) / (2 * math.pi)) * world - raster["originPx"][1])


def striped(draw, points, width=3):
    draw.line(points, fill="white", width=width)
    distance = 0
    for a, b in zip(points, points[1:]):
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        consumed = 0
        while consumed < length:
            block = math.floor(distance / 5)
            take = min(length - consumed, (block + 1) * 5 - distance)
            if take < 1e-8:
                distance += 1e-7
                continue
            if block % 2 == 0:
                start, end = consumed / length, (consumed + take) / length
                draw.line([(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t) for t in (start, end)], fill="#E52222", width=width)
            consumed += take
            distance += take


lines = [(f["properties"], [pixel(c) for c in f["geometry"]["coordinates"]])
         for f in doc["features"] if f["geometry"]["type"] == "LineString"]
factor = 2200 / image.width
overview = image.resize((2200, round(image.height * factor)))
road_view = Image.new("RGB", overview.size, "#f7f7f0")
d = ImageDraw.Draw(road_view)
for f in doc["features"]:
    if f["geometry"]["type"] == "Polygon":
        for i, ring in enumerate(f["geometry"]["coordinates"]):
            d.polygon([(x * factor, y * factor) for x, y in map(pixel, ring)], fill="#303030" if i == 0 else "#f7f7f0")
for target in (overview, road_view):
    d = ImageDraw.Draw(target)
    for props, points in sorted(lines, key=lambda pair: pair[0]["kind"] != "kerb"):
        ps = [(x * factor, y * factor) for x, y in points]
        if props["kind"] == "kerb":
            striped(d, ps, 3)
        else:
            d.line(ps, fill=props.get("color", "white"), width=1)
overview.save(out / "imagery-review.jpg", quality=92)
road_view.save(out / "continuous-road.png")

# Locate each turn using its reviewed centerline reference coordinate.
for start in range(0, 19, 4):
    sheet = Image.new("RGB", (1400, 1480), "white")
    for tile, turn in enumerate(review["turns"][start:start + 4]):
        cx, cy = pixel(turn["referenceCoordinate"])
        left, top, size = round(cx - 325), round(cy - 325), 650
        crop = image.crop((left, top, left + size, top + size)).resize((700, 700))
        d = ImageDraw.Draw(crop)
        for props, points in lines:
            if props["kind"] == "kerb":
                striped(d, [((x - left) * 700 / size, (y - top) * 700 / size) for x, y in points], 2)
        x, y = tile % 2 * 700, tile // 2 * 740
        sheet.paste(crop, (x, y + 40))
        caption = f"Turn {turn['turn']}: " + (", ".join(turn["kerbIDs"]) or "no kerb identified; edge markings only")
        ImageDraw.Draw(sheet).text((x + 8, y + 10), caption, fill="black")
    sheet.save(out / f"turns-{start + 1:02d}-{min(start + 4, 19):02d}.jpg", quality=92)

table = ["# Miami kerb inventory", "", f"Reviewed all 19 turns against county aerial imagery and [F1’s official 2026 pole lap]({review['sources']['onboard']['url']}).",
         "", "Distances follow the configured bacinger spline origin, not the FIA finish line. A decreasing range crosses the lap seam. Pixel support is evidence availability, not positional accuracy. Every geographic kerb remains low confidence; endpoints have approximate 8 m uncertainty and bridge positions are interpolated. Red/white is the requested display livery; the onboard shows orange/white.",
         "", "| Strip | Turns | Side | Distance (m) | Visible pixel support | Inferred stations | Onboard (s) |",
         "|---|---|---|---:|---:|---:|---:|"]
for s in review["tracedKerbs"]:
    table.append(f"| {s['id']} | {', '.join(map(str, s['turns']))} | {s['side']} | {s['startM']}–{s['endM']} | {s['observedFraction']:.0%} | {len(s['inferredStations'])} | {s['onboardSeconds'][0]}–{s['onboardSeconds'][1]} |")
table += ["", "Turns 9 and 10 were reviewed: no kerb was identified on either side through these fast kinks. The ordinary edge lines continue.",
          "", "## Occlusions", ""]
for gap in review.get("occlusions", []):
    table.append(f"- {gap['startM']}–{gap['endM']} m: {gap['reason']}.")
(out / "kerb-inventory.md").write_text("\n".join(table) + "\n")
print(f"Rendered all 19 turns and {len(review['curbs'])} reviewed kerb strips to {out}")
