"""Fetch the two recorded Miami-Dade aerial exports, preserving their exact pixel frame.

Requires Pillow. Uses only the Miami requests in the checked-in acquisition manifest.
Existing parts are reused only if their request URL and dimensions match the manifest.
"""
import hashlib
import json
from pathlib import Path
import urllib.request
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
MANIFEST = ROOT / "telemetry/geometry/reference/miami-county-imagery-source.json"
OUT = ROOT / "telemetry/geometry/imagery/miami-county"


def main():
    source = json.loads(MANIFEST.read_text())
    requests = source["requests"]
    if not 1 <= len(requests) <= 4 or source["zoom"] != 19:
        raise ValueError("Expected a small Miami-only acquisition at zoom 19")
    OUT.mkdir(parents=True, exist_ok=True)
    prior = json.loads((OUT / "mosaic.json").read_text()) if (OUT / "mosaic.json").exists() else {}
    image = Image.new("RGB", tuple(source["size"]))
    for request in requests:
        url = request["url"]
        if not url.startswith(source["source"] + "/export?"):
            raise ValueError("Unexpected source in Miami acquisition manifest")
        filename = request["file"]
        if Path(filename).name != filename:
            raise ValueError("Invalid image part filename")
        path = OUT / filename
        cached = any(p["url"] == url and p["file"] == filename for p in prior.get("requests", []))
        if not path.exists() or not cached:
            print("Fetching", filename, flush=True)
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
            temporary = path.with_suffix(".tmp")
            temporary.write_bytes(data)
            with Image.open(temporary) as part:
                if list(part.size) != request["size"]:
                    raise ValueError("County returned an unexpected raster size")
            temporary.replace(path)
        with Image.open(path) as part:
            if list(part.size) != request["size"]:
                raise ValueError("Cached part dimensions disagree with the acquisition manifest")
            image.paste(part, tuple(request["offsetPx"]))
    image.save(OUT / "mosaic.png")
    metadata = {k: v for k, v in source.items() if k not in ["licenseMetadata", "imageSha256"]}
    metadata["imageSha256"] = hashlib.sha256((OUT / "mosaic.png").read_bytes()).hexdigest()
    (OUT / "mosaic.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("Miami mosaic ready:", OUT / "mosaic.png")


if __name__ == "__main__":
    main()
