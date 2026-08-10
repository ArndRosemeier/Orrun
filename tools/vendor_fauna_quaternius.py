"""Vendor Quaternius Ultimate Animated Animal Pack glTFs into assets/library/fauna.

Downloads only the glTF folder from the official Google Drive share, writes
ATTRIBUTION.md, and places one `<id>/<id>.gltf` per species.
"""
from __future__ import annotations

import tempfile
from pathlib import Path

import gdown

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "library" / "fauna"
# Public pack folder on Quaternius's Drive (see pack page).
FOLDER_URL = (
    "https://drive.google.com/drive/folders/1uJ3N5HfB7jKTseJUNQr3N4YaN0UuEtHk?usp=sharing"
)

ANIMALS = {
    "deer": "Deer.gltf",
    "stag": "Stag.gltf",
    "wolf": "Wolf.gltf",
    "fox": "Fox.gltf",
    "horse": "Horse.gltf",
    "horse_white": "Horse_White.gltf",
    "cow": "Cow.gltf",
    "bull": "Bull.gltf",
    "donkey": "Donkey.gltf",
    "alpaca": "Alpaca.gltf",
    "husky": "Husky.gltf",
    "shiba": "ShibaInu.gltf",
}

ATTRIBUTION = """# Fauna assets

Source: Quaternius — Ultimate Animated Animal Pack
URL: https://quaternius.com/packs/ultimateanimatedanimals.html
License: CC0 / Public Domain (free for personal and commercial use)

Vendored glTF scenes live under `assets/library/fauna/<id>/<id>.gltf`.
Do not edit these meshes in Orrun; replace from the upstream pack if needed.
"""


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="orrun_fauna_"))
    print("Downloading into", tmp)
    gdown.download_folder(FOLDER_URL, output=str(tmp / "drive"), quiet=False, use_cookies=False)
    gltf_dir = tmp / "drive" / "glTF"
    assert gltf_dir.is_dir(), f"Expected glTF folder at {gltf_dir}"
    for animal, filename in ANIMALS.items():
        src = gltf_dir / filename
        assert src.is_file(), f"Missing {filename}"
        dest_dir = OUT / animal
        dest_dir.mkdir(parents=True, exist_ok=True)
        # Remove any previous stray files from older vendor runs.
        for old in dest_dir.iterdir():
            old.unlink()
        dest = dest_dir / f"{animal}.gltf"
        dest.write_bytes(src.read_bytes())
        print("vendored", animal, dest.stat().st_size)
    license_src = tmp / "drive" / "License.txt"
    if license_src.is_file():
        (OUT / "License.txt").write_bytes(license_src.read_bytes())
    (OUT / "ATTRIBUTION.md").write_text(ATTRIBUTION, encoding="utf-8")
    print("OK", OUT)


if __name__ == "__main__":
    main()
