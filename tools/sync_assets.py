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
PROP_CATALOG = PROJECT_ROOT / "assets" / "catalog" / "props.json"
BRIDGE_CATALOG = PROJECT_ROOT / "assets" / "catalog" / "bridges.json"
CLUTTER_CATALOG = PROJECT_ROOT / "assets" / "catalog" / "clutter.json"
LIBRARY = PROJECT_ROOT / "assets" / "library"
DEFAULT_ASSET_LAB = Path("C:/Projekte/AssetGenerator")


def _sync_sources(
    out_dir: Path, entries: list[dict], id_key: str, source_key: str
) -> tuple[list[str], list[str]]:
    copied: list[str] = []
    missing: list[str] = []
    for entry in entries:
        source = out_dir / entry[source_key]
        if not source.is_file():
            missing.append(f"{entry[id_key]} ({entry[source_key]})")
            continue
        shutil.copy2(source, LIBRARY / source.name)
        copied.append(source.name)
    return copied, missing


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

    catalog = json.loads(PROP_CATALOG.read_text(encoding="utf-8"))
    LIBRARY.mkdir(parents=True, exist_ok=True)

    copied, missing = _sync_sources(out_dir, catalog["props"], "id", "source")

    if BRIDGE_CATALOG.is_file():
        bridges = json.loads(BRIDGE_CATALOG.read_text(encoding="utf-8"))
        mid_copied, mid_missing = _sync_sources(
            out_dir, bridges["kits"], "id", "mid_source"
        )
        copied.extend(mid_copied)
        missing.extend(mid_missing)
        end_entries = [
            {"id": f"{kit['id']}_end", "end_source": kit["end_source"]}
            for kit in bridges["kits"]
            if "end_source" in kit
        ]
        end_copied, end_missing = _sync_sources(
            out_dir, end_entries, "id", "end_source"
        )
        copied.extend(end_copied)
        missing.extend(end_missing)

    if CLUTTER_CATALOG.is_file():
        clutter = json.loads(CLUTTER_CATALOG.read_text(encoding="utf-8"))
        clutter_copied, clutter_missing = _sync_sources(
            out_dir, clutter["clutter"], "id", "source"
        )
        copied.extend(clutter_copied)
        missing.extend(clutter_missing)

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
    if copied:
        print(
            "note: new .glb files need a Godot import before play "
            "(open the editor, or: godot --path . --headless --editor --import)"
        )
    return 0 if copied else 1


if __name__ == "__main__":
    sys.exit(main())
