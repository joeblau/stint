"""Regression checks on the actual bundled Miami road, using the export validator."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("surface_worker", ROOT / "telemetry/scripts/imagery/sample-local.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class MiamiSurfaceTopology(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.asset = json.loads((ROOT / "apple/Stint/Resources/miami.surface.geojson").read_text())

    def test_bundled_road_is_continuous_and_edges_match_its_boundary(self):
        worker.validate(self.asset)
        metadata = self.asset["metadata"]
        self.assertEqual(metadata["displayRoadFraction"], 1)
        self.assertLess(metadata["observedRoadFraction"], 1)
        self.assertTrue(metadata["refinement"]["inferredStations"])
        self.assertTrue(any(o["left"] is None for o in metadata["refinement"]["sourceObservations"]))

    def test_rejects_fragmented_road(self):
        doc = copy.deepcopy(self.asset)
        doc["features"].append(copy.deepcopy(doc["features"][0]))
        with self.assertRaisesRegex(ValueError, "one road polygon"):
            worker.validate(doc)

    def test_rejects_missing_sector_edge(self):
        doc = copy.deepcopy(self.asset)
        index = next(i for i, f in enumerate(doc["features"]) if f["properties"]["kind"] == "sector_edge")
        doc["features"].pop(index)
        with self.assertRaisesRegex(ValueError, "continuous closed boundary"):
            worker.validate(doc)

    def test_rejects_edge_that_leaves_the_road_boundary(self):
        doc = copy.deepcopy(self.asset)
        edge = next(f for f in doc["features"] if f["properties"]["kind"] == "sector_edge")
        points = edge["geometry"]["coordinates"]
        # Keep the loop closed but shortcut a curved section of the original boundary.
        del points[2:20]
        with self.assertRaisesRegex(ValueError, "follow the continuous road boundary"):
            worker.validate(doc)

    def test_every_reviewed_kerb_is_present_in_full(self):
        review = self.asset["metadata"]["kerbReview"]
        self.assertEqual(len(review["turns"]), 19)
        self.assertEqual(len(review["curbs"]), 25)
        self.assertEqual({f["properties"]["reviewID"] for f in self.asset["features"] if f["properties"]["kind"] == "kerb"},
                         {s["id"] for s in review["curbs"]})
        worker.validate(self.asset)

    def test_rejects_missing_reviewed_kerb(self):
        doc = copy.deepcopy(self.asset)
        doc["features"] = [f for f in doc["features"] if f["properties"].get("reviewID") != "t8-exit"]
        with self.assertRaisesRegex(ValueError, "Every reviewed Miami kerb"):
            worker.validate(doc)

    def test_rejects_partial_kerb_even_when_its_id_remains(self):
        doc = copy.deepcopy(self.asset)
        kerb = next(f for f in doc["features"] if f["properties"].get("reviewID") == "t8-exit")
        del kerb["geometry"]["coordinates"][:10]
        with self.assertRaisesRegex(ValueError, "dropped part"):
            worker.validate(doc)

    def test_widths_vary_smoothly_through_the_lap_seam_and_bridges(self):
        widths = self.asset["metadata"]["widths"]
        spacing = self.asset["metadata"]["totalLengthM"] / len(widths)
        for side in ("leftM", "rightM"):
            steps = [abs(widths[(i + 1) % len(widths)][side] - w[side]) / spacing for i, w in enumerate(widths)]
            self.assertLess(max(steps), 0.5, "No sudden width spikes at shadows, bridges or the lap seam")
        totals = [w["leftM"] + w["rightM"] for w in widths]
        self.assertGreater(max(totals) - min(totals), 5, "Keep the observed variable widths")
        self.assertGreater(max(abs(w["leftM"] - w["rightM"]) for w in widths), 3, "Do not mirror the two edges")

    def test_road_contains_all_bacinger_reference_anchors(self):
        from shapely.geometry import Point, shape
        reference = json.loads((ROOT / "telemetry/geometry/reference/bacinger-us-2022.geojson").read_text())
        road = shape(next(f["geometry"] for f in self.asset["features"] if f["properties"]["kind"] == "road_surface"))
        for coordinate in reference["features"][0]["geometry"]["coordinates"]:
            self.assertTrue(road.covers(Point(coordinate)), f"Reference anchor is outside the road: {coordinate}")


if __name__ == "__main__":
    unittest.main()
