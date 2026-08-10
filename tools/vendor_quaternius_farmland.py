"""Vendor Quaternius farmland packs into assets/library.

Sources (CC0):
  https://quaternius.com/packs/ultimatecrops.html
  https://quaternius.com/packs/farmbuildings.html
  https://quaternius.com/packs/farmanimal.html
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

CROPS_PAGE = "https://opengameart.org/content/lowpoly-crops-pack"
CROPS_ZIP_FALLBACK = (
	"https://opengameart.org/sites/default/files/nature_crops_pack_by_quaternius.zip"
)
# Poly Pizza hosts FBX/GLTF bundles with direct download paths that change;
# itch name-your-price needs a session. Prefer Drive folder via gdown when OGA fails.
FARM_BUILDINGS_ITCH = "https://quaternius.itch.io/lowpoly-farm-buildings"
FARM_ANIMALS_PAGE = "https://quaternius.com/packs/farmanimal.html"

RANK = {".glb": 0, ".gltf": 1, ".fbx": 2, ".obj": 3, ".blend": 4}

CROPS_ATTR = """# Crop assets

Source: Quaternius — Ultimate Crops Pack
URL: https://quaternius.com/packs/ultimatecrops.html
Mirror: https://opengameart.org/content/lowpoly-crops-pack
License: CC0 / Public Domain

Vendored mesh files live under `assets/library/crops/`.
Do not edit these meshes in Orrun; replace from the upstream pack if needed.
"""

FARM_ATTR = """# Farm building assets

Source: Quaternius — Farm Buildings Pack
URL: https://quaternius.com/packs/farmbuildings.html
Mirror: https://quaternius.itch.io/lowpoly-farm-buildings
License: CC0 / Public Domain

Vendored mesh files live under `assets/library/farm/`.
Do not edit these meshes in Orrun; replace from the upstream pack if needed.
"""

FARM_ANIMAL_ATTR = """# Farm animal assets

Source: Quaternius — Farm Animal Pack
URL: https://quaternius.com/packs/farmanimal.html
License: CC0 / Public Domain

Vendored scenes live under `assets/library/fauna/<id>/`.
Do not edit these meshes in Orrun; replace from the upstream pack if needed.
"""


def fetch(url: str, dest: Path) -> None:
	req = urllib.request.Request(url, headers=UA)
	with urllib.request.urlopen(req, timeout=180) as resp, open(dest, "wb") as out:
		shutil.copyfileobj(resp, out)


def vendor_flat_zip(zip_path: Path, out_dir: Path) -> int:
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
				".bin",
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


def vendor_fauna_from_extract(extract: Path, out_root: Path) -> list[str]:
	"""Copy animal glTF/FBX into fauna/<id>/<id>.ext. Returns new ids."""
	best: dict[str, Path] = {}
	for path in extract.rglob("*"):
		if not path.is_file():
			continue
		ext = path.suffix.lower()
		if ext not in RANK:
			continue
		# Skip animation-only or shared junk
		stem = path.stem
		if stem.lower() in {"license", "readme"}:
			continue
		key = stem.lower().replace(" ", "_")
		prev = best.get(key)
		if prev is None or RANK[ext] < RANK[prev.suffix.lower()]:
			best[key] = path

	# Avoid clobbering Ultimate Animated Animal Pack species already vendored.
	reserved = {
		"deer",
		"stag",
		"wolf",
		"fox",
		"horse",
		"horse_white",
		"cow",
		"bull",
		"donkey",
		"alpaca",
		"husky",
		"shiba",
		"shibainu",
	}
	added: list[str] = []
	for key, src in sorted(best.items()):
		animal_id = key
		if animal_id in reserved or animal_id.replace("_", "") in reserved:
			# Distinct farm-pack id when overlapping names appear.
			animal_id = f"farm_{key}"
		dest_dir = out_root / animal_id
		dest_dir.mkdir(parents=True, exist_ok=True)
		for old in dest_dir.iterdir():
			old.unlink()
		dest = dest_dir / f"{animal_id}{src.suffix.lower()}"
		shutil.copy2(src, dest)
		# Sidecars (bin / textures) for glTF
		for sib in src.parent.iterdir():
			if not sib.is_file():
				continue
			if sib == src:
				continue
			if sib.stem.lower() == src.stem.lower() or sib.suffix.lower() in {
				".bin",
				".png",
				".jpg",
				".jpeg",
			}:
				shutil.copy2(sib, dest_dir / sib.name)
		added.append(animal_id)
		print("  fauna", animal_id, dest.name)
	return added


def resolve_oga_zip(page_url: str, fallback: str) -> str:
	try:
		html = urllib.request.urlopen(
			urllib.request.Request(page_url, headers=UA), timeout=60
		).read().decode("utf-8", "replace")
		urls = re.findall(
			r"https://opengameart.org/sites/default/files/[^\"']+\.zip", html
		)
		if urls:
			return urls[0]
	except Exception as exc:
		print("OGA page scrape failed:", exc)
	return fallback


def try_gdown_folder(folder_url: str, dest: Path) -> bool:
	try:
		import gdown
	except ImportError:
		print("gdown not installed")
		return False
	try:
		gdown.download_folder(
			folder_url, output=str(dest), quiet=False, use_cookies=False
		)
		return dest.exists()
	except Exception as exc:
		print("gdown failed:", exc)
		return False


def drive_folder_from_page(page_url: str) -> str | None:
	try:
		html = urllib.request.urlopen(
			urllib.request.Request(page_url, headers=UA), timeout=60
		).read().decode("utf-8", "replace")
	except Exception as exc:
		print("page fetch failed", page_url, exc)
		return None
	m = re.search(
		r"https://drive\.google\.com/drive/folders/[a-zA-Z0-9_-]+", html
	)
	return m.group(0) if m else None


def main() -> None:
	tmp = Path(tempfile.mkdtemp(prefix="orrun_q_farm_"))
	print("tmp", tmp)

	# --- Crops (OGA zip) ---
	crops_url = resolve_oga_zip(CROPS_PAGE, CROPS_ZIP_FALLBACK)
	crops_zip = tmp / "crops.zip"
	print("Downloading crops…", crops_url)
	fetch(crops_url, crops_zip)
	n_crops = vendor_flat_zip(crops_zip, ROOT / "assets" / "library" / "crops")
	(ROOT / "assets" / "library" / "crops" / "ATTRIBUTION.md").write_text(
		CROPS_ATTR, encoding="utf-8"
	)
	print("crops meshes", n_crops)
	assert n_crops >= 50, f"expected many crop meshes, got {n_crops}"

	# --- Farm buildings ---
	farm_dir = ROOT / "assets" / "library" / "farm"
	n_farm = 0
	# Try Drive from quaternius page, then poly.pizza-style mirrors are manual.
	farm_page = "https://quaternius.com/packs/farmbuildings.html"
	folder = drive_folder_from_page(farm_page)
	if folder:
		print("Farm buildings Drive", folder)
		out = tmp / "farm_drive"
		# Prefer FBX subfolder even if gdown aborts mid-OBJ download.
		try_gdown_folder(folder + "?usp=sharing", out)
		fbx_root = out / "FBX"
		mesh_root = fbx_root if fbx_root.is_dir() else out
		if any(p.suffix.lower() in RANK for p in mesh_root.rglob("*") if p.is_file()):
			zpath = tmp / "farm_from_drive.zip"
			with zipfile.ZipFile(zpath, "w") as zf:
				for path in mesh_root.rglob("*"):
					if path.is_file() and path.suffix.lower() in {".fbx", ".glb", ".gltf", ".obj", ".mtl"}:
						zf.write(path, path.relative_to(mesh_root).as_posix())
			n_farm = vendor_flat_zip(zpath, farm_dir)
	if n_farm == 0:
		# Direct itch CDN sometimes works for free games; try known OGA buildings pack
		# as last resort is wrong pack — fail loud.
		raise RuntimeError(
			"Could not vendor Farm Buildings. Download "
			f"{FARM_BUILDINGS_ITCH} and place FBX under assets/library/farm/, "
			"or fix Drive folder scrape."
		)
	(farm_dir / "ATTRIBUTION.md").write_text(FARM_ATTR, encoding="utf-8")
	print("farm buildings", n_farm)
	assert n_farm >= 10, f"expected ~13 farm buildings, got {n_farm}"

	# --- Farm animals ---
	fauna_out = ROOT / "assets" / "library" / "fauna"
	fauna_out.mkdir(parents=True, exist_ok=True)
	animal_folder = drive_folder_from_page(FARM_ANIMALS_PAGE)
	added: list[str] = []
	if animal_folder:
		print("Farm animals Drive", animal_folder)
		out = tmp / "farm_animals_drive"
		try_gdown_folder(animal_folder + "?usp=sharing", out)
		# Prefer FBX; ignore incomplete OBJ sibling downloads.
		fbx = out / "FBX"
		extract = fbx if fbx.is_dir() else out
		if any(p.suffix.lower() == ".fbx" for p in extract.rglob("*")):
			# Only unique livestock (skip cow/horse already in Ultimate Animated pack).
			want = {"pig": "Pig.fbx", "sheep": "Sheep.fbx", "llama": "Llama.fbx"}
			for animal_id, filename in want.items():
				src = extract / filename
				if not src.is_file():
					continue
				dest_dir = fauna_out / animal_id
				dest_dir.mkdir(parents=True, exist_ok=True)
				for old in dest_dir.iterdir():
					old.unlink()
				dest = dest_dir / f"{animal_id}.fbx"
				shutil.copy2(src, dest)
				added.append(animal_id)
				print("  fauna", animal_id, dest.name)
	if not added:
		raise RuntimeError(
			"Could not vendor Farm Animal Pack from Drive. "
			f"Check {FARM_ANIMALS_PAGE}"
		)
	# Append attribution note (do not wipe existing Ultimate Animated note)
	attr_path = fauna_out / "ATTRIBUTION.md"
	existing = attr_path.read_text(encoding="utf-8") if attr_path.exists() else ""
	if "Farm Animal Pack" not in existing:
		attr_path.write_text(
			existing.rstrip() + "\n\n" + FARM_ANIMAL_ATTR, encoding="utf-8"
		)
	print("farm animals added", added)
	print("OK")


if __name__ == "__main__":
	main()
