"""Copy Asset Lab meshes into the Orrun runtime library.

The Asset Lab at ASSET_LAB_ROOT owns generation: JSON specs in assets/specs are
the source of truth and assets/out is regenerable output. Orrun only consumes
the .glb files, so this script copies what the prop catalog asks for and
reports anything the Asset Lab has not built yet.

    python tools/sync_assets.py
    python tools/sync_assets.py --asset-lab D:/other/AssetGenerator
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CATALOG = PROJECT_ROOT / "assets" / "catalog" / "props.json"
LIBRARY = PROJECT_ROOT / "assets" / "library"
DEFAULT_ASSET_LAB = Path("C:/Projekte/AssetGenerator")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--asset-lab",
        type=Path,
        default=DEFAULT_ASSET_LAB,
        help="Asset Lab checkout that produces assets/out/*.glb",
    )
    args = parser.parse_args()

    out_dir = args.asset_lab / "assets" / "out"
    if not out_dir.is_dir():
        print(f"error: no Asset Lab output at {out_dir}")
        print("fix: run `python tools/regenerate_assets.py` in the Asset Lab first")
        return 2

    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    LIBRARY.mkdir(parents=True, exist_ok=True)

    copied: list[str] = []
    missing: list[str] = []
    for prop in catalog["props"]:
        source = out_dir / prop["source"]
        if not source.is_file():
            missing.append(f"{prop['id']} ({prop['source']})")
            continue
        shutil.copy2(source, LIBRARY / source.name)
        copied.append(source.name)

    textures_src = out_dir / "textures"
    if textures_src.is_dir():
        textures_dst = LIBRARY / "textures"
        textures_dst.mkdir(exist_ok=True)
        for texture in textures_src.glob("*.png"):
            shutil.copy2(texture, textures_dst / texture.name)

    for name in copied:
        print(f"  synced {name}")
    if missing:
        print("\nnot built by the Asset Lab yet:")
        for name in missing:
            print(f"  - {name}")
        print("fix: add a spec under assets/specs and run `python tools/ag.py generate <id>`")

    wanted = catalog.get("wanted_from_asset_lab", [])
    if wanted:
        print("\nstill wanted from the Asset Lab:")
        for item in wanted:
            print(f"  - {item}")

    print(f"\n{len(copied)} mesh(es) in {LIBRARY}")
    return 0 if copied else 1


if __name__ == "__main__":
    sys.exit(main())
