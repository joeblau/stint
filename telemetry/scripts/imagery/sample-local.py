"""Sample a licensed local, georeferenced raster. No downloading or extrapolation.

Input job: imagePath, profiles [{start:[x,y], end:[x,y]}], count.
Out-of-image or transparent profiles are null; never clamp pixels at the image boundary.
"""
import argparse
import json
import numpy as np
from PIL import Image


def sample(job):
    image = np.asarray(Image.open(job["imagePath"]).convert("RGBA"))
    h, w = image.shape[:2]
    count = job["count"]
    if not isinstance(count, int) or count < 3 or count > 2001:
        raise ValueError("Invalid profile sample count")
    result = []
    for profile in job["profiles"]:
        xs = np.linspace(profile["start"][0], profile["end"][0], count)
        ys = np.linspace(profile["start"][1], profile["end"][1], count)
        if not np.isfinite(xs).all() or not np.isfinite(ys).all() or xs.min() < 0 or ys.min() < 0 or xs.max() >= w - 1 or ys.max() >= h - 1:
            result.append(None)
            continue
        ix, iy = xs.astype(int), ys.astype(int)
        fx, fy = (xs - ix)[:, None], (ys - iy)[:, None]
        corners = [image[iy, ix], image[iy, ix+1], image[iy+1, ix], image[iy+1, ix+1]]
        if any((c[:, 3] < 255).any() for c in corners):
            result.append(None)
            continue
        a, b, c, d = [p[:, :3].astype(float) for p in corners]
        rgb = a*(1-fx)*(1-fy) + b*fx*(1-fy) + c*(1-fx)*fy + d*fx*fy
        result.append({"r": rgb[:, 0].round(2).tolist(), "g": rgb[:, 1].round(2).tolist(), "b": rgb[:, 2].round(2).tolist()})
    return {"size": [w, h], "samples": result}


def validate(doc):
    # Topology is checked on the actual exported lon/lat rings, including containment of holes.
    from shapely.geometry import shape
    from shapely.validation import explain_validity
    issues = []
    for feature in doc["features"]:
        geometry = shape(feature["geometry"])
        if not geometry.is_valid or not geometry.is_simple or geometry.is_empty:
            issues.append(explain_validity(geometry))
    if issues:
        raise ValueError("Invalid output topology: " + "; ".join(issues[:8]))
    if (doc.get("metadata", {}).get("refinement") or {}).get("mode") == "continuous-visualization":
        from shapely.ops import linemerge, unary_union
        roads = [shape(f["geometry"]) for f in doc["features"] if f["properties"]["kind"] == "road_surface"]
        if len(roads) != 1 or len(roads[0].interiors) != 1:
            raise ValueError("Continuous Miami must be one road polygon with one infield hole")
        boundaries = []
        for side in ("left", "right"):
            lines = [shape(f["geometry"]) for f in doc["features"]
                     if f["properties"]["kind"] == "sector_edge" and f["properties"]["side"] == side]
            ring = linemerge(lines)
            if ring.geom_type != "LineString" or not ring.is_ring:
                raise ValueError(f"{side} sector edges must join into one continuous closed boundary")
            boundaries.append(ring)
        if unary_union(boundaries).hausdorff_distance(roads[0].boundary) > 1e-9:
            raise ValueError("Sector edges must follow the continuous road boundary")
        review = doc["metadata"].get("kerbReview")
        if review:
            expected = {s["id"] for s in review["curbs"]}
            kerbs = [f for f in doc["features"] if f["properties"]["kind"] == "kerb"]
            if {f["properties"].get("reviewID") for f in kerbs} != expected:
                raise ValueError("Every reviewed Miami kerb must be exported, without unreviewed additions")
            # Check the full span, including occlusions and the lap seam, not just its ID.
            from shapely.geometry import LineString
            widths = doc["metadata"]["widths"]
            for strip in review["tracedKerbs"]:
                lines = unary_union([shape(f["geometry"]) for f in kerbs if f["properties"]["reviewID"] == strip["id"]])
                if lines.is_empty or len(strip["samples"]) < 2:
                    raise ValueError("Reviewed kerb span is empty")
                # The rendered offset can differ from the source pixels after smoothing;
                # the per-station audit must nevertheless cover the complete reviewed span.
                distances = [widths[s["station"]]["distanceM"] for s in strip["samples"]]
                length = doc["metadata"]["totalLengthM"]
                covered = sorted((d - strip["startM"]) % length for d in distances)
                requested = (strip["endM"] - strip["startM"]) % length
                if covered[0] > 2 or requested - covered[-1] > 2 or any(b - a > 2 for a, b in zip(covered, covered[1:])):
                    raise ValueError("Reviewed kerb audit has missing intervals")
                expected_line = LineString(strip["renderedCoordinates"])
                if lines.hausdorff_distance(expected_line) > 1e-9:
                    raise ValueError("Reviewed kerb geometry dropped part of its traced span")


def assemble(doc):
    """Dissolve shared borders between observed quads without filling missing intervals."""
    from shapely.geometry import shape, mapping
    from shapely.geometry.polygon import orient
    from shapely.ops import unary_union
    surfaces = [f for f in doc["features"] if f["properties"]["kind"] == "road_surface"]
    polygons = [shape(f["geometry"]) for f in surfaces]
    if any(not p.is_valid or p.is_empty for p in polygons):
        raise ValueError("Invalid observed surface patch; review boundary observations")
    merged = unary_union(polygons)
    parts = list(merged.geoms) if merged.geom_type == "MultiPolygon" else [merged]
    properties = {"kind": "road_surface", "verified": False, "fill": "#303030", "coverage": "observed-patch"}
    doc["features"] = [{"type": "Feature", "properties": properties, "geometry": mapping(orient(p, 1))} for p in parts] + [
        f for f in doc["features"] if f["properties"]["kind"] != "road_surface"]
    doc["metadata"]["roadPolygons"] = len(parts)
    doc["metadata"]["assembly"] = "Union of adjacent observed quadrilaterals; no gap filling or topology repair"
    return doc


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["sample", "validate", "assemble"])
    parser.add_argument("input")
    parser.add_argument("output", nargs="?")
    args = parser.parse_args()
    with open(args.input) as file:
        doc = json.load(file)
    if args.command == "assemble":
        with open(args.input, "w") as file:
            json.dump(assemble(doc), file, allow_nan=False)
    elif args.command == "validate":
        validate(doc)
    else:
        result = sample(doc)
        with open(args.output, "w") as file:
            json.dump(result, file, allow_nan=False)
