"""Exercise the real CLI in subprocesses, without network or production writes."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "telemetry/scripts/extract-surface.ts"
CONFIG = ROOT / "telemetry/geometry/surface-config/miami.json"


def run(config, *args):
    return subprocess.run([shutil.which("bun"), str(SCRIPT), str(config), *args],
                          cwd=ROOT, capture_output=True, text=True, timeout=30)


class MiamiSurfaceCLI(unittest.TestCase):
    def test_actual_miami_plan(self):
        result = run(CONFIG, "--plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["circuit"], "miami")
        self.assertEqual(plan["zoom"], 19)
        self.assertEqual(plan["marginM"], 200)
        self.assertTrue(plan["noNetworkRequests"])
        self.assertGreater(plan["stations"], 5400)
        self.assertAlmostEqual(plan["nominalMetersPerPixel"], 0.26846, places=4)

    def test_other_tracks_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"circuit": "monaco"}))
            result = run(path, "--plan")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("limited to Miami", result.stderr)

    def test_missing_inputs_preserve_existing_asset_even_with_force(self):
        with tempfile.TemporaryDirectory() as directory:
            config = json.loads(CONFIG.read_text())
            config["centerline"] = str(ROOT / "telemetry/geometry/reference/bacinger-us-2022.geojson")
            output = Path(directory) / "miami.surface.geojson"
            config.update(output=str(output), imagery=None, controls=[], timing=None)
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config))
            output.write_text("existing asset")
            result = run(path, "--force")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("control-point pairs required", result.stderr)
            self.assertEqual(output.read_text(), "existing asset")


if __name__ == "__main__":
    unittest.main()
