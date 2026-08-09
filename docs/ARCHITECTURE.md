# Orrun — world architecture

Orrun generates a finite, seeded fantasy wilderness (12.3 km square) and streams
it around the player. Everything you can walk on is derived, in a fixed order,
from one integer seed. Nothing is authored by hand and nothing is saved: the same
seed always rebuilds the same world.

This document describes the layer order and the contracts between layers. The
order is the design. Most of the ways a procedural landscape goes wrong are
really one layer overwriting a decision an earlier layer had already made.

## Layer order

| # | Layer | Code | Scope | Built |
|---|-------|------|-------|-------|
| 0 | Config and noise | `WorldConfig`, `NoiseSet` | whole world | at boot |
| 1 | Macro terrain | `MacroTerrain` | 384x384 cells of 32 m | once, on a worker |
| 2 | Hydrology | `Hydrology` | same grid | once, on a worker |
| 3 | Claims | `ClaimMask` | world space | once, on a worker |
| 4 | Paths | `PathNetwork` | same grid | once, on a worker |
| 5 | Region data | `RegionData` | 1024 m tile | on demand |
| 6 | Density field | `DensityField` | one chunk | per chunk, on a worker |
| 7 | Mesh, water, props | `MeshExtract`, `WaterSurface`, `PropPlacer` | one chunk | per chunk, on a worker |
| 8 | Scene | `ChunkNode`, `Streamer` | one chunk | main thread, budgeted |

Layers 1-4 are the *bake*, about five seconds, and produce the `WorldMap` every
chunk job reads. Layers 5-7 are pure functions of the bake plus a chunk
coordinate, which is what makes them safe to run on `WorkerThreadPool`. Only
layer 8 touches the SceneTree.

`FarTerrain` sits outside this pipeline: one static mesh built from layer 1 at
bake time, covering the whole map at 128 m resolution. It is the horizon, not a
surface — nothing collides with it, and it is sunk three metres so a streamed
chunk always wins where the two overlap.

## The contracts

### Water has no global level

There is no sea level and no water plane. Every river station carries its own
`water_z`, monotonically descending downstream; every lake carries the spill
elevation of its own basin. Two lakes a kilometre apart sit at different heights
and both are correct. The tests assert this directly: `lakes are NOT on one
global water level` fails if the spread ever collapses.

### Depressions are breached before they are filled

A priority flood on its own answers "how high does this hollow fill before it
spills", and on a broad lowland the answer is "until it is a sea" — the first
version of this world was 18.6% water with one 7 km² lake in it. Real drainage
does the opposite first: the outflow cuts its own notch through the rim, and the
hollow only stays wet if the rim is too high to cut.

So `Hydrology` breaches before it accepts a lake. Each depression gets one
attempt at an outlet along its flow path, capped at `breach_limit` (14 m) —
except basins over `breach_area_cells` (900 cells, just under a square
kilometre), which are breached at any depth, because a lake that large is not a
lake, it is a basin the drainage never got out of. The channel is widened one
cell either side per 9 m of cut, so a deep breach leaves a valley rather than a
32 m slot; without that the drainage surface ends up tens of metres below
interpolated ground and the contract below cannot hold. Two rounds of breach and
re-flood converge.

The result is 2.5% water, 26 lakes, and a river network that reaches Strahler 4
instead of 3. The gorges the deep breaches leave behind are a feature.

### The drainage-surface contract

Layer 6 assembles the solid world in this order, and the order is load-bearing:

1. macro height — the drainage surface every other layer agreed on
2. hydrology and road carves — beds, banks, benched roadways
3. relief and overhangs, **multiplied by the corridor mask**
4. caves, never under a river bed

The corridor mask is `smoothstep(corridor_inner, corridor_outer, distance to the
nearest channel, shore or road)`. It is zero on the water and one out in open
country. Because 3D detail is multiplied by it, no amount of relief noise can
lift the ground through a river or drop it out from under a road.

`Field.contract_error` records, per column, how far the finished ground pokes
above a water surface it should sit below. The test `drainage-surface contract
holds` fails if any sampled column exceeds `corridor_epsilon` (1.25 m). It is
currently 0.000 m. This is the single most important invariant in the project:
if it drifts, rivers start floating over the terrain and every downstream fix is
cosmetic.

Overhangs use the mask *squared*. An undercut needs more clearance than a bump,
and at half strength on the edge of a carved bank surface nets produces shards.

### Water is drawn from the same field the ground was meshed from

`WaterSurface` does not know about rivers or lakes. It reads `water_top` and
`surface_z` out of the finished density field and emits a sheet wherever the
first is above the second. The shoreline therefore lands where the ground
crosses the water at mesh resolution, not on a macro cell boundary 32 m away.

The sheet's outer rim is still a voxel staircase, so the water shader fades alpha
to zero over the last 0.9 m of depth. What you see is the contour where terrain
meets water, which is smooth.

### Determinism

Every layer seeds its noise from `WorldConfig.layer_seed(name)`, and every job
builds its own `NoiseSet` rather than sharing one. Jobs may therefore run in any
order on any thread. `WorldConfig.content_hash()` fingerprints every value that
changes generated content.

### Floating origin

World coordinates run to 12 km, which float32 cannot carry without visible
jitter. `WorldOrigin` keeps scene space near zero: world positions are absolute
and authoritative, scene positions are `world - offset`, and the streamer
rebases on a chunk boundary when the player drifts too far, then refreshes every
chunk node and the far terrain.

## Streaming

`Streamer`, once per frame:

1. rebase the origin if needed
2. recompute the desired chunk set and its LOD ring (`3, 6, 10, 16` chunks at
   `2, 4, 8, 16` m voxels)
3. ensure the region is ready, then queue the chunk
4. instantiate a budgeted number of finished chunks
5. drop chunks outside the ring plus hysteresis

Only step 4 allocates scene nodes, so generation cost never lands on one frame.
LOD rings meet at hairline seams, hidden by short downward skirts that borrow
the vertex's own normal and colour.

## Reserved ground

`ClaimMask` marks areas that later content owns: bridge decks, and dungeon
mouths that no settlement or road may build over. It exists now, before there is
any settlement generator, because a claim added later cannot retroactively stop
a river from having been routed through a town square.

## Assets

Meshes come from the Asset Lab at `C:/Projekte/AssetGenerator`
(`assets/specs` -> `assets/out/*.glb`) and are copied in by
`tools/sync_assets.py`. Orrun never edits a `.glb`; a wrong mesh is fixed in its
spec and regenerated. `assets/catalog/props.json` declares placement rules
(footprint, slope limit, water avoidance, road clearance, per-biome weight) and
lists what the Asset Lab still owes us.

Bridges are procedural boxes until the Asset Lab ships a span kit. The catalog
id (`procedural_timber`, `procedural_stone`, `ford`) is the seam where a real
kit drops in.

## Testing

- `tools/tests/world_tests.gd` — headless, ~15 s. Asserts the invariants above
  over the whole map: descending rivers, flat lakes at distinct levels, connected
  networks, crossings on their roads, meshing at every LOD, the contract, props
  out of the water, determinism.
- `tools/tests/runtime_smoke.gd` — runs the real scene, walks the player, checks
  chunks stream and the origin rebases. It covers ground the world test never
  samples, so it is the one that finds location-specific contract breaks; it
  reports the offending chunk, and `tools/tests/probe_chunk.gd <cx> <cz>` then
  prints the columns and the carve that produced them.
- `tools/tests/screenshots.gd` — opens a window and writes `docs/shots`. This is
  how the landscape is judged. `--only=`, `--no-water`, `--no-skirts`,
  `--debug-view=`, `--plain-light` and `--mark-sky` exist because a suspicious
  screenshot is otherwise impossible to diagnose: unlit ground and ground that
  was never drawn look identical.

Run them with:

```
godot --headless --path <project> --script res://tools/tests/world_tests.gd
godot --path <project> --resolution 1600x900 res://tools/tests/screenshots.tscn
```
