#!/usr/bin/env python3
"""Satellite-imagery pixel worker for the 2026 track library.

This script owns everything that needs PIL/numpy: Esri World Imagery tile download (with cache,
gray-placeholder detection and per-tile zoom fallback), mosaic stitching, cross-profile RGB sampling,
kerb-strip rasterization and QA rendering. All measurement DECISIONS (edge detection, confidence,
smoothing, kerb classification) live in telemetry/src/imagery.ts so they are unit-testable offline;
this worker only extracts pixels and draws pictures.

Invoked by telemetry/scripts/measure-imagery.ts:

  python3 measure.py build  --job job.json --out result.json [--force]
  python3 measure.py render --job job.json --measurements measurements.json --qa qa.png

Requires PIL and numpy (verified with /opt/homebrew/bin/python3: PIL 12.1.1, numpy 2.4.3).
Tiles: https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}
Attribution (recorded in every output): Esri, Maxar, Earthstar Geographics, and the GIS User Community.
"""

import argparse
import hashlib
import io
import json
import math
import os
import time
import urllib.request
from datetime import datetime, timezone

import numpy as np
from PIL import Image, ImageDraw, ImageFont

TILE_URL = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
ATTRIBUTION = "Esri, Maxar, Earthstar Geographics, and the GIS User Community"
USER_AGENT = "lightsout-telemetry track-width research (single sequential client)"
FETCH_DELAY_S = 0.12
MIN_ZOOM = 15


def meters_per_pixel(lat_deg, z):
    return 156543.03392 * math.cos(math.radians(lat_deg)) / (2 ** z)


def lonlat_to_global_px(lon, lat, z):
    lat = max(-85.05112878, min(85.05112878, lat))
    s = math.sin(math.radians(lat))
    n = 2 ** z
    return ((lon + 180) / 360 * 256 * n, (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * 256 * n)


def is_placeholder(data):
    """Esri returns a small uniform-gray 'Map data not yet available' JPEG beyond available zooms."""
    if len(data) > 6000:
        return False
    try:
        img = np.asarray(Image.open(io.BytesIO(data)).convert("L"), dtype=np.float32)
        return bool(img.std() < 3.0)
    except Exception:
        return False


def fetch_tile(z, x, y, cache_dir, force):
    """Download (or reuse from cache) one tile, walking zoom out past gray placeholders.
    Returns (PIL image 256x256 at requested footprint, manifest entry)."""
    os.makedirs(cache_dir, exist_ok=True)
    level, dz = z, 0
    while True:
        path = os.path.join(cache_dir, f"{level}_{x}_{y}.jpg")
        if os.path.exists(path) and not force:
            with open(path, "rb") as f:
                data = f.read()
            source = "cache"
        else:
            url = TILE_URL.format(z=level, y=y, x=x)
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            last_error = None
            for attempt in range(4):
                try:
                    with urllib.request.urlopen(req, timeout=30) as response:
                        data = response.read()
                    break
                except Exception as error:  # noqa: BLE001 - retried with backoff, then raised
                    last_error = error
                    time.sleep(2 ** attempt)
            else:
                raise RuntimeError(f"tile download failed: {url}: {last_error}")
            with open(path, "wb") as f:
                f.write(data)
            source = "download"
            time.sleep(FETCH_DELAY_S)
        if not is_placeholder(data) or level <= MIN_ZOOM:
            img = Image.open(io.BytesIO(data)).convert("RGB")
            if dz:  # parent tile covers 2**dz requested tiles per axis: crop this tile's quadrant, upscale
                k = 2 ** dz
                img = img.crop(((x % k) * 256 // k, (y % k) * 256 // k,
                                (x % k + 1) * 256 // k, (y % k + 1) * 256 // k)).resize((256, 256), Image.LANCZOS)
            return img, {"z": level, "requestedZ": z, "x": x, "y": y, "file": os.path.basename(path),
                         "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
                         "placeholder": bool(is_placeholder(data)),
                         "zoomFallback": dz, "source": source,
                         "fetchedAt": datetime.now(timezone.utc).isoformat()}
        level -= 1
        dz += 1
        x, y = x // 2, y // 2


def bilinear(arr, xs, ys):
    """Vectorized bilinear sampling of an HxWx3 uint8 array at float coordinates."""
    h, w = arr.shape[:2]
    xs = np.clip(xs, 0, w - 1.001)
    ys = np.clip(ys, 0, h - 1.001)
    x0 = xs.astype(np.int32)
    y0 = ys.astype(np.int32)
    fx = (xs - x0)[:, None]
    fy = (ys - y0)[:, None]
    c00 = arr[y0, x0].astype(np.float32)
    c10 = arr[y0, x0 + 1].astype(np.float32)
    c01 = arr[y0 + 1, x0].astype(np.float32)
    c11 = arr[y0 + 1, x0 + 1].astype(np.float32)
    out = c00 * (1 - fx) * (1 - fy) + c10 * fx * (1 - fy) + c01 * (1 - fx) * fy + c11 * fx * fy
    return np.round(out).astype(np.uint8)


def build_mosaic(job, force):
    imagery_dir = job["imageryDir"]
    z = job["zoom"]
    mosaic_path = os.path.join(imagery_dir, "mosaic.jpg")
    mosaic_meta_path = os.path.join(imagery_dir, "mosaic.json")
    if os.path.exists(mosaic_path) and os.path.exists(mosaic_meta_path) and not force:
        with open(mosaic_meta_path) as f:
            return mosaic_path, json.load(f)
    xs = [t["x"] for t in job["tiles"]]
    ys = [t["y"] for t in job["tiles"]]
    min_x, min_y, max_x, max_y = min(xs), min(ys), max(xs), max(ys)
    mosaic = Image.new("RGB", ((max_x - min_x + 1) * 256, (max_y - min_y + 1) * 256))
    entries = []
    for tile in job["tiles"]:
        img, entry = fetch_tile(z, tile["x"], tile["y"], os.path.join(imagery_dir, "tiles"), force)
        mosaic.paste(img, ((tile["x"] - min_x) * 256, (tile["y"] - min_y) * 256))
        entries.append(entry)
    os.makedirs(imagery_dir, exist_ok=True)
    mosaic.save(mosaic_path, quality=88)
    zooms = {}
    for e in entries:
        zooms[str(e["z"])] = zooms.get(str(e["z"]), 0) + 1
    meta = {"z": z, "originPx": [min_x * 256, min_y * 256], "size": list(mosaic.size),
            "tileCount": len(entries), "zooms": zooms,
            "zoomFallbacks": sum(1 for e in entries if e["zoomFallback"] > 0),
            "attribution": ATTRIBUTION, "tileUrl": TILE_URL,
            "builtAt": datetime.now(timezone.utc).isoformat()}
    with open(os.path.join(imagery_dir, "tiles.json"), "w") as f:
        json.dump({"attribution": ATTRIBUTION, "tiles": entries}, f, indent=1)
    with open(mosaic_meta_path, "w") as f:
        json.dump(meta, f, indent=1)
    return mosaic_path, meta


def sample_profiles(job, arr, origin):
    z = job["zoom"]
    step, rng, count = job["profile"]["stepM"], job["profile"]["rangeM"], None
    count = int(round(2 * rng / step)) + 1
    offsets = np.arange(count) * step - rng
    out = []
    for s in job["samples"]:
        cx, cy = lonlat_to_global_px(s["lon"], s["lat"], z)
        mpp = meters_per_pixel(s["lat"], z)
        xs = cx - origin[0] + s["nE"] * offsets / mpp
        ys = cy - origin[1] - s["nN"] * offsets / mpp
        rgb = bilinear(arr, xs, ys)
        out.append({"index": s["index"], "r": rgb[:, 0].tolist(), "g": rgb[:, 1].tolist(), "b": rgb[:, 2].tolist()})
    return out


def global_px_to_lonlat(x, y, z):
    n = 2 ** z
    lon = x / (256 * n) * 360 - 180
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / (256 * n)))))
    return {"lon": lon, "lat": lat}


def sample_kerb_search(job, arr, origin, search):
    """Sample narrow bands just outside each MEASURED track edge within a synthetic strip's corner zone.
    Each entry references a job sample (lat/lon + left-normal) and carries the measured half-width for
    the strip's side; pixels are taken at offsets -1.0..+3.5 m relative to that measured edge, so the
    kerb (which sits at the asphalt boundary) is covered regardless of synthetic-strip placement error.
    Emits red/white stats per 2 m station bin and a tightened lon/lat polygon around the red run."""
    z = job["zoom"]
    results = []
    samples = job["samples"]
    bin_m = 5.0  # grid stations are ~5 m apart: one entry per station bin
    off_min, off_max, off_step = -1.0, 3.5, 0.25
    offsets_m = np.arange(round((off_max - off_min) / off_step) + 1) * off_step + off_min
    for strip in search:
        entries = strip["entries"]
        empty = {"id": strip["id"], "total": 0, "red": 0, "white": 0, "maxRedRunM": 0,
                 "alternations": 0, "stationRed": [], "stationWhite": [], "bestRowM": None, "polygon": None}
        if not entries:
            results.append(empty)
            continue
        all_red, all_white, all_total = [], [], []
        station_bins = []
        anchors = []  # per-bin representative (chain points at edge-0.25 and edge+2) for the polygon
        for start in range(0, len(entries), max(1, round(bin_m / 5))):
            bin_entries = entries[start:start + max(1, round(bin_m / 5))]
            red_n = white_n = total_n = 0
            for e in bin_entries:
                s = samples[e["sample"]]
                mpp = meters_per_pixel(s["lat"], z)
                cx, cy = lonlat_to_global_px(s["lon"], s["lat"], z)
                base = np.array([cx - origin[0], cy - origin[1]])
                normal = np.array([s["nE"], -s["nN"]])  # east is +x, north is -y in pixel space
                for anchor in e["edgesM"]:
                    pts = base + normal[None, :] * ((anchor + offsets_m) / mpp)[:, None]
                    rgb = bilinear(arr, pts[:, 0].astype(np.float32), pts[:, 1].astype(np.float32)).astype(np.int32)
                    r, g, b = rgb[:, 0], rgb[:, 1], rgb[:, 2]
                    red = (r > 110) & (r > 1.5 * g) & (r > 1.5 * b)
                    white = (r > 165) & (g > 165) & (b > 165) & ((np.maximum.reduce([r, g, b]) - np.minimum.reduce([r, g, b])) < 45)
                    red_n += int(red.sum())
                    white_n += int(white.sum())
                    total_n += len(r)
            all_red.append(red_n)
            all_white.append(white_n)
            all_total.append(total_n)
            mid = bin_entries[len(bin_entries) // 2]
            s = samples[mid["sample"]]
            mpp = meters_per_pixel(s["lat"], z)
            cx, cy = lonlat_to_global_px(s["lon"], s["lat"], z)
            normal = np.array([s["nE"], -s["nN"]])
            anchors.append((np.array([cx - origin[0], cy - origin[1]]), normal, mid["edgesM"][0], mpp))
        red_frac = np.array(all_red) / np.maximum(all_total, 1)
        white_frac = np.array(all_white) / np.maximum(all_total, 1)
        run = best = 0
        best_end = 0
        for i, (f, t) in enumerate(zip(red_frac, all_total)):
            run = run + 1 if (f >= 0.12 and t >= 10) else 0
            if run > best:
                best, best_end = run, i + 1
        dominant = np.where((red_frac >= 0.12) & (red_frac > white_frac), 1,
                            np.where((white_frac >= 0.2) & (white_frac > red_frac), -1, 0))
        alternations = int(sum(1 for i in range(1, len(dominant))
                               if dominant[i] != 0 and dominant[i - 1] != 0 and dominant[i] != dominant[i - 1]))
        polygon = None
        if best >= 2:
            lo_chain, hi_chain = [], []
            for i in range(best_end - best, best_end):
                base, normal, edge_m, mpp = anchors[i]
                for chain, off in ((lo_chain, -0.25), (hi_chain, 2.0)):
                    gx2, gy2 = base + normal * ((edge_m + off) / mpp)
                    chain.append(global_px_to_lonlat(gx2 + origin[0], gy2 + origin[1], z))
            if lo_chain and hi_chain:
                polygon = lo_chain + hi_chain[::-1]
        results.append({"id": strip["id"], "total": int(sum(all_total)), "red": int(sum(all_red)),
                        "white": int(sum(all_white)), "maxRedRunM": round(best * bin_m, 1),
                        "alternations": alternations, "bestRowM": None,
                        "stationRed": [round(float(f), 3) for f in red_frac],
                        "stationWhite": [round(float(f), 3) for f in white_frac],
                        "polygon": polygon})
    return results



def cmd_build(args):
    with open(args.job) as f:
        job = json.load(f)
    mosaic_path, meta = build_mosaic(job, args.force)
    arr = np.asarray(Image.open(mosaic_path).convert("RGB"))
    origin = tuple(meta["originPx"])
    result = {"circuit": job["circuit"], "attribution": ATTRIBUTION, "zoom": meta["z"],
              "mosaic": {"path": mosaic_path, "size": meta["size"], "tileCount": meta["tileCount"],
                         "zooms": meta["zooms"], "zoomFallbacks": meta["zoomFallbacks"]},
              "samples": sample_profiles(job, arr, origin)}
    with open(args.out, "w") as f:
        json.dump(result, f)
    print(json.dumps({"circuit": job["circuit"], "tiles": meta["tileCount"], "zooms": meta["zooms"],
                      "zoomFallbacks": meta["zoomFallbacks"], "mosaic": meta["size"],
                      "samples": len(result["samples"])}))


def cmd_kerbs(args):
    with open(args.job) as f:
        job = json.load(f)
    with open(args.measurements) as f:
        m = json.load(f)
    with open(os.path.join(job["imageryDir"], "mosaic.json")) as f:
        meta = json.load(f)
    arr = np.asarray(Image.open(os.path.join(job["imageryDir"], "mosaic.jpg")).convert("RGB"))
    results = sample_kerb_search(job, arr, tuple(meta["originPx"]), m["kerbSearch"])
    with open(args.out, "w") as f:
        json.dump({"circuit": job["circuit"], "attribution": ATTRIBUTION, "strips": results}, f)
    print(json.dumps({"circuit": job["circuit"], "strips": len(results),
                      "withRed": sum(1 for r in results if r["red"] > 0)}))


STATUS_COLORS = {"measured": (0, 230, 118, 255), "interpolated": (255, 214, 0, 255), "fallback": (255, 23, 68, 255)}


def cmd_render(args):
    with open(args.job) as f:
        job = json.load(f)
    with open(args.measurements) as f:
        m = json.load(f)
    with open(os.path.join(job["imageryDir"], "mosaic.json")) as f:
        meta = json.load(f)
    base = Image.open(os.path.join(job["imageryDir"], "mosaic.jpg")).convert("RGB")
    z, origin = meta["z"], np.array(meta["originPx"])

    def to_px(p):
        gx, gy = lonlat_to_global_px(p["lon"], p["lat"], z)
        return (gx - origin[0], gy - origin[1])

    max_dim = 3200
    scale = min(1.0, max_dim / max(base.size))
    if scale < 1.0:
        base = base.resize((round(base.size[0] * scale), round(base.size[1] * scale)), Image.LANCZOS)
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    width = max(2, round(3 * scale)) if scale < 1 else 3

    for strip in m["strips"]:
        poly = [to_px(p) for p in strip["polygon"]]
        scaled = [(x * scale, y * scale) for x, y in poly]
        if strip["detected"]:
            draw.polygon(scaled, fill=(255, 0, 0, 70), outline=(255, 30, 30, 230))
        else:
            draw.line(scaled + [scaled[0]], fill=(0, 229, 255, 170), width=1)

    def draw_track_line(points, key):
        for a, b in zip(points, points[1:] + points[:1]):
            pa, pb = to_px(a), to_px(b)
            color = STATUS_COLORS[a[key]] if key else (255, 255, 255, 255)
            draw.line([(pa[0] * scale, pa[1] * scale), (pb[0] * scale, pb[1] * scale)], fill=color, width=width)

    draw_track_line(m["centerline"], None)
    draw_track_line(m["left"], "status")
    draw_track_line(m["right"], "status")
    out = Image.alpha_composite(base.convert("RGBA"), overlay).convert("RGB")

    draw = ImageDraw.Draw(out)
    try:
        font = ImageFont.load_default(size=18)
        small = ImageFont.load_default(size=15)
    except TypeError:
        font = small = ImageFont.load_default()
    lines = m["summaryLines"]
    box_w = max(draw.textlength(line, font=small) for line in lines) + 24
    draw.rectangle([8, 8, 8 + box_w, 16 + len(lines) * 22], fill=(0, 0, 0, 200))
    for i, line in enumerate(lines):
        draw.text((20, 16 + i * 22), line, fill=(255, 255, 255), font=small if i else font)
    legend_y = 24 + len(lines) * 22
    for label, color in [("centerline", (255, 255, 255)), ("measured edge", STATUS_COLORS["measured"]),
                         ("interpolated", STATUS_COLORS["interpolated"]), ("fallback (prior width)", STATUS_COLORS["fallback"]),
                         ("imagery kerb", (255, 30, 30)), ("synthetic kerb", (0, 229, 255))]:
        draw.rectangle([20, legend_y + 4, 34, legend_y + 14], fill=color)
        draw.text((42, legend_y), label, fill=(255, 255, 255), font=small)
        legend_y += 20
    draw.rectangle([8, 8, 8 + box_w, legend_y + 4], outline=(0, 0, 0, 200))
    os.makedirs(os.path.dirname(args.qa), exist_ok=True)
    out.save(args.qa)
    print(json.dumps({"qa": args.qa, "size": list(out.size)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p_build = sub.add_parser("build")
    p_build.add_argument("--job", required=True)
    p_build.add_argument("--out", required=True)
    p_build.add_argument("--force", action="store_true")
    p_kerbs = sub.add_parser("kerbs")
    p_kerbs.add_argument("--job", required=True)
    p_kerbs.add_argument("--measurements", required=True)
    p_kerbs.add_argument("--out", required=True)
    p_render = sub.add_parser("render")
    p_render.add_argument("--job", required=True)
    p_render.add_argument("--measurements", required=True)
    p_render.add_argument("--qa", required=True)
    args = parser.parse_args()
    {"build": cmd_build, "kerbs": cmd_kerbs, "render": cmd_render}[args.command](args)
