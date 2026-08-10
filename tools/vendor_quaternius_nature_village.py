"""Vendor Quaternius Ultimate Nature + Medieval Village packs into assets/library.

Sources (CC0):
  https://quaternius.com/packs/ultimatenature.html
  https://quaternius.com/packs/medievalvillage.html
Mirrors used when Drive throttles gdown:
  OpenGameArt (same packs).
"""
from __future__ import annotations

import re
import shutil
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UA = {"User-Agent": "OrrunAssetFetch/1.0"}

NATURE_PAGE = "https://opengameart.org/content/low-poly-nature-pack-1"
VILLAGE_ZIP = (
	"https://opengameart.org/sites/default/files/medieval_village_pack_-_dec_2020.zip"
)
RANK = {".glb": 0, ".gltf": 1, ".fbx": 2, ".obj": 3, ".blend": 4}

NATURE_ATTR = """# Nature assets

Source: Quaternius — Ultimate Nature Pack (150 models)
URL: https://quaternius.com/packs/ultimatenature.html
Mirror: https://opengameart.org/content/low-poly-nature-pack-1
License: CC0 / Public Domain

Vendored mesh files live under `assets/library/nature/`.
Do not edit these meshes in Orrun; replace from the upstream pack if needed.
"""

VILLAGE_ATTR = """# Village assets

Source: Quaternius — Medieval Village Pack
URL: https://quaternius.com/packs/medievalvillage.html
Mirror: https://opengameart.org/content/lowpoly-medieval-village-pack
License: CC0 / Public Domain

Vendored mesh files live under `assets/library/village/`.
Do not edit these meshes in Orrun; replace from the upstream pack if needed.
"""


def fetch(url: str, dest: Path) -> None:
	req = urllib.request.Request(url, headers=UA)
	with urllib.request.urlopen(req, timeout=180) as resp, open(dest, "wb") as out:
		shutil.copyfileobj(resp, out)


def vendor_zip(zip_path: Path, out_dir: Path) -> int:
	if out_dir.exists():
		shutil.rmtree(out_dir)
	out_dir.mkdir(parents=True)
	extract = zip_path.parent / f"{out_dir.name}_extract"
	if extract.exists():
		shutil.rmtree(extract)
	extract.mkdir()
	with zipfile.ZipFile(zip_path) as zf:
		zf.extractall(extract)

	best: dict[str, Path] = {}
	for path in extract.rglob("*"):
		if not path.is_file():
			continue
		ext = path.suffix.lower()
		if ext not in RANK:
			continue
		key = path.stem.lower()
		prev = best.get(key)
		if prev is None or RANK[ext] < RANK[prev.suffix.lower()]:
			best[key] = path

	for src in best.values():
		shutil.copy2(src, out_dir / f"{src.stem}{src.suffix.lower()}")
		for sib in src.parent.iterdir():
			if not sib.is_file():
				continue
			if sib.stem.lower() == src.stem.lower() and sib.suffix.lower() in {
				".mtl",
				".png",
				".jpg",
				".jpeg",
			}:
				shutil.copy2(sib, out_dir / sib.name)

	for path in extract.rglob("*"):
		if path.is_file() and path.name.lower() in {
			"license.txt",
			"licence.txt",
			"readme.txt",
			"cc0.txt",
		}:
			shutil.copy2(path, out_dir / path.name)
	return len(best)


def main() -> None:
	tmp = Path(tempfile.mkdtemp(prefix="orrun_q_nv_"))
	print("tmp", tmp)

	page = urllib.request.urlopen(
		urllib.request.Request(NATURE_PAGE, headers=UA)
	).read().decode("utf-8", "replace")
	nature_urls = re.findall(
		r"https://opengameart.org/sites/default/files/[^\"']+\.zip", page
	)
	assert nature_urls, "Ultimate Nature zip URL not found on OpenGameArt page"

	nature_zip = tmp / "nature.zip"
	print("Downloading nature…")
	fetch(nature_urls[0], nature_zip)
	n = vendor_zip(nature_zip, ROOT / "assets" / "library" / "nature")
	(ROOT / "assets" / "library" / "nature" / "ATTRIBUTION.md").write_text(
		NATURE_ATTR, encoding="utf-8"
	)
	print("nature meshes", n)

	village_zip = tmp / "village.zip"
	print("Downloading village…")
	fetch(VILLAGE_ZIP, village_zip)
	v = vendor_zip(village_zip, ROOT / "assets" / "library" / "village")
	(ROOT / "assets" / "library" / "village" / "ATTRIBUTION.md").write_text(
		VILLAGE_ATTR, encoding="utf-8"
	)
	print("village meshes", v)
	assert n == 150, f"expected 150 nature meshes, got {n}"
	assert v == 44, f"expected 44 village meshes, got {v}"
	print("OK")


if __name__ == "__main__":
	main()
