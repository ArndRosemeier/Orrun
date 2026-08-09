# Orrun — world architecture

Orrun generates a seeded fantasy continent and streams it around the player.
Everything you can walk on is derived, in a fixed order, from one integer seed.
Nothing is authored by hand and nothing is saved: the same seed always rebuilds
the same world.

The world has no boundary you can reach. It is as large as the atlas says the
continent is — 256 km square at the runtime default, 1000 km at the design
target — and it is built in immutable 8 km pieces around wherever the player
happens to be.

This document describes the layer order and the contracts between layers. The
order is the design. Most of the ways a procedural landscape goes wrong are
really one layer overwriting a decision an earlier layer had already made.

## Three scales

| Scale | Size | Owns | Code |
|-------|------|------|------|
| Atlas cell | 1 km | climate, coast, lakes, major rivers, roads, population | `scripts/atlas/` |
| Generation sector | 8 km | macro terrain, hydrology, claims, local paths | `WorldSector` |
| Chunk | 64 m | mesh, collision, water, props | `ChunkNode` |

The sizes divide exactly, and that is the point: 8 km is 8 atlas cells, 250
macro cells and 125 chunks. Every chunk in the world therefore has exactly one
owning sector, found by a division rather than by a decision, and no chunk is
ever built twice or has to choose between two versions of a river.

The atlas is described in [`CONTINENT_ATLAS.md`](CONTINENT_ATLAS.md). It is
generated once, is immutable, and is the authority for everything at the
kilometre scale. The 3D world refines it; it never contradicts it.

## Layer order

| # | Layer | Code | Scope | Built |
|---|-------|------|-------|-------|
| 0 | Config and noise | `WorldConfig`, `NoiseSet` | whole world | at boot |
| 0b | Continent atlas | `ContinentAtlas` | 256 km (1 km cells) | once, at boot |
| 0c | Atlas fields and corridors | `AtlasFields`, `AtlasCorridors` | whole continent | once, after the atlas |
| 0d | Continental surface | `ContinentalTerrain` | a pure function of metres | never — sampled |
| 1 | Macro terrain | `MacroTerrain` | one sector window, 32 m cells | per sector, on a worker |
| 2 | Edge contracts | `SectorEdgeContract` | one sector boundary | per sector, on a worker |
| 3 | Hydrology | `Hydrology` | same grid | per sector, on a worker |
| 4 | Claims and paths | `ClaimMask`, `PathNetwork` | same grid | per sector, on a worker |
| 5 | Region data | `RegionData` | 1024 m page | on demand |
| 6 | Density field | `DensityField` | one chunk | per chunk, on a worker |
| 7 | Mesh, water, props | `MeshExtract`, `WaterSurface`, `PropPlacer` | one chunk | per chunk, on a worker |
| 8 | Scene | `ChunkNode`, `Streamer` | one chunk | main thread, budgeted |

`WorldContext` holds layers 0-0c: config, atlas, fields, corridors. It is
immutable and shared by every thread. Layers 1-4 are the *sector bake*, about
eight seconds, and produce the `WorldSector` every chunk job reads. Layers 5-7
are pure functions of a sector plus a chunk coordinate. Only layer 8 touches the
SceneTree.

`FarTerrain` sits outside this pipeline: a moving 128 m patch around the player,
sampled from `ContinentalTerrain` directly rather than from any sector, so the
horizon exists in ground nobody has baked. Nothing collides with it, and it is
sunk three metres so a streamed chunk always wins where the two overlap.

## The contracts

### The continental surface is a pure function

`ContinentalTerrain` answers height, relief budget, moisture, temperature,
signed shore distance and water-plane height for any pair of continental metres,
using nothing but the atlas and noise. No sector, no window, no neighbourhood.

This is what makes seams impossible rather than merely unlikely. Two adjacent
sectors do not negotiate their shared edge; they each ask the same function the
same question and get the same answer, bit for bit, in whatever order they were
generated. `MacroTerrain` is only a cached window onto it, sampled at global
macro cell centres, so overlapping windows hold identical numbers in the overlap.

The old world had a drainage dome, a latitude proxy and an edge falloff, all of
which were functions of the window rather than of the place. They are gone.

### Water has no global level, but the sea does

Every river station carries its own `water_z`, monotonically descending
downstream; every local lake carries the spill elevation of its own basin. Two
lakes a kilometre apart sit at different heights and both are correct.

The ocean and the atlas lakes are the exception, and they have to be: a body of
water that spans sectors cannot have a level that any one sector computes.
Their surface comes from the atlas, and `ContinentalTerrain.water_plane_at`
returns it for any point. The waterline is the zero crossing of one global
signed shoreline function, so two sectors sharing a coast draw the same beach.

### Depressions are not breached, they are drained by the atlas

A priority flood on its own answers "how high does this hollow fill before it
spills", and on a broad lowland the answer is "until it is a sea". The previous
generator solved that by breaching: cutting a notch through each basin rim and
re-flooding. That cannot survive sectors. Breaching rewrites the terrain grid,
and a rewrite is local knowledge — the neighbour, which flooded a different
8 km of catchment, would cut a different notch in the same metre of ground.

Instead the drainage comes from above. `ContinentalTerrain` carves a valley
along every atlas river corridor, wide and deep enough that the trunk network
actually drains, and it does so as a pure function of continental metres. What
is left for `Hydrology` to solve is genuinely local: detail-noise hollows inside
one sector.

Those become local lakes only if they are small (`lake_max_cells`), deep enough
(`lake_min_depth`), and wholly inside the sector's local domain. Anything larger
is rejected as a basin the drainage never left — and rejected identically by
both neighbours, because the test is on the pure surface, not on who asked.

### Local features keep out of the boundary

A sector publishes its 8 km core and bakes a 1024 m halo it never publishes.
Inside the core, a further `local_keepout_metres` (160 m) band along each edge
is off limits to anything sector-local: no local lake, no local brook, no local
track, no local landmark.

The reason is the same one that killed breaching. A brook shapes the ground
around it out to its valley plus `corridor_outer`; if one sat on the boundary,
the neighbour would mesh the same metre without it. Only two kinds of feature
may come closer, and both are things the neighbour derives identically:

- **Atlas features** — trunk rivers and roads, reconstructed from
  `AtlasCorridors` rather than routed locally, so both sides get the same
  polyline, the same width and the same bed.
- **Edge-contract ports** — see below.

### Sector edge contracts

`SectorEdgeContract` is keyed by the *shared edge*, not by either sector: both
neighbours call `SectorEdgeContract.canonical()` and get the same two sector
coordinates in the same order, then build the identical contract.

A port on that edge carries continental position, flow or travel direction,
tangent, grade, surface height, width, bed or road depth, valley radius, carve
transition length, feature class and stable feature id. Position alone would not
be enough: two rivers that meet at a point but disagree about their tangent form
a visible kink, and two that disagree about width form a step.

Ports come from two places. Atlas rivers and roads crossing the boundary
contribute one port each, directly from the corridor geometry. Minor drainage
contributes ports derived from the shared edge terrain profile itself — a local
minimum in the boundary height profile with enough fall behind it — so a stream
can cross without either sector inventing an endpoint the other has not heard
of. Each such port grows a short shared river stub on both sides, and local
brooks snap onto the stub rather than onto the boundary.

### The drainage-surface contract

Layer 6 assembles the solid world in this order, and the order is load-bearing:

1. macro height — the continental surface every other layer agreed on
2. hydrology, shoreline and road carves — beds, banks, sea floor, benched roadways
3. relief and overhangs, **multiplied by the corridor mask**
4. caves, never under a river bed or a sea

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
builds its own `NoiseSet` rather than sharing one. Anything keyed to a place
rather than to a layer uses `place_seed(layer, cell)`, so the answer does not
depend on which sector asked. Sectors are a pure function of
`(seed, sector coordinate, atlas hash)` and may be generated in any order on any
thread. `WorldConfig.content_hash()` fingerprints every value that changes
generated content, including the sector contract version.

### Floating origin

Continental coordinates run to hundreds of kilometres, which float32 cannot
carry without visible jitter. `WorldOrigin` keeps scene space near zero: world
positions are absolute and authoritative, scene positions are `world - offset`,
and the streamer rebases on a chunk boundary when the player drifts too far,
then refreshes every chunk node and the far terrain. Rebasing never changes a
generation coordinate or an identity.

## Streaming

`SectorManager` owns sector generation: it bakes on the queue, publishes
finished sectors atomically, prefetches the ring around the player's sector
before they reach an edge, and holds an LRU cache (`sector_cache_size`).

`Streamer`, once per frame:

1. rebase the origin if needed
2. pump the sector manager, and re-request the ring when the player's sector changes
3. recompute the desired chunk set and its LOD ring (`3, 6, 10, 16` chunks at
   `2, 4, 8, 16` m voxels)
4. ensure the owning sector and the feature page are ready, then queue the chunk
5. instantiate a budgeted number of finished chunks
6. drop chunks outside the ring plus hysteresis, and cancel queued chunks that
   left it

Step 6's cancellation matters more than it sounds. The ring is re-evaluated
every frame, so a player moving faster than the world builds can queue thousands
of chunks that were abandoned before a worker reached them; left in the queue
they starve the ground ahead, because the queue is sorted by how near the chunk
was when it was enqueued, not by where the player is now.

A chunk whose sector is not baked yet is not meshed from a guess — it is counted
in `stat_chunks_waiting_on_sector` and retried. Only step 5 allocates scene
nodes, so generation cost never lands on one frame. LOD rings meet at hairline
seams, hidden by short downward skirts that borrow the vertex's own normal and
colour.

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

- `tools/tests/world_tests.gd` — headless. Bakes one interesting sector and
  asserts the invariants above inside it: descending rivers, flat lakes at
  distinct levels, connected road networks, crossings on their roads, meshing at
  every LOD, the contract, props out of the water, caves, overhangs on steep
  ground, determinism.
- `tools/tests/seam_tests.gd` — headless, and the reason this design is
  believable. Bakes neighbouring sectors and asserts they meet: coordinate round
  trips, identical continental samples across the boundary, the same coastline
  from both sides, symmetric edge contracts, identical macro cells in the
  overlap, generation-order independence, local water staying out of the
  boundary band, matching trunk crossings, continuous chunk columns across the
  seam, and a river mouth you can actually spawn beside.
- `tools/tests/runtime_smoke.gd` — runs the real scene, walks the player across
  a sector boundary, and checks chunks stream, the origin rebases, props and
  water appear, and the generation backlog drains once the player stops.
- `tools/tests/screenshots.gd` — opens a window and writes `docs/shots`. This is
  how the landscape is judged. `--only=`, `--no-water`, `--no-skirts`,
  `--debug-view=`, `--plain-light` and `--mark-sky` exist because a suspicious
  screenshot is otherwise impossible to diagnose: unlit ground and ground that
  was never drawn look identical.

Run them with:

```
godot --headless --path <project> --script res://tools/tests/world_tests.gd
godot --headless --path <project> --script res://tools/tests/seam_tests.gd
godot --headless --path <project> res://tools/tests/runtime_smoke.tscn
godot --path <project> --resolution 1600x900 res://tools/tests/screenshots.tscn
```
