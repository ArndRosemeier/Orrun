# Continent Atlas — design contract (v1)

Status: **Phases 1–3 implemented** (generator + 2D viewer + tests, and the 3D
world now generated from the atlas as immutable 8 km sectors). Amend
deliberately; do not “simplify away” continuity and come back later — that is
how seams become permanent.

Companion to [`ARCHITECTURE.md`](ARCHITECTURE.md). Run the viewer with
`start_atlas.bat` (optional `-- --seed=42 --size=256`; production size is 1000).
Tests: `godot --headless --path <project> --script res://tools/tests/atlas_tests.gd`.

---

## 1. Why this exists

Orrun used to be a single finite window: about 12 km on a side, fully baked,
with `FarTerrain` drawing that same window at low resolution. That was enough to
walk in and judge rivers and roads. It was not enough for:

- a sense that the wilderness belongs to a larger landmass
- travel, maps, and “what’s over that ridge” beyond the baked window
- far LODs that show coastlines, climate belts, and mountain chains decided
  before the player arrived
- **rivers and roads that still exist** when you cross a kilometre boundary
- later content (settlements, cultures, trade) that needs continental structure

The atlas is that larger landmass. The finite window is gone: the 3D world is
now generated as immutable **8 km sectors** refining the atlas, built on demand
around the player and cached — detail where the player is, summary everywhere
else, and no boundary anywhere. See
[`ARCHITECTURE.md`](ARCHITECTURE.md) for the sector pipeline.

---

## 2. Goals (non-negotiable for v1)

1. **Continental structure at 1 km resolution.** Always resident, cheap to sample.
2. **Deterministic.** `f(world_seed, …)` only. Same seed → identical atlas.
3. **One authority chain.** Atlas constrains the sector bake; a sector does
   not invent a second planet.
4. **Ocean is landcover, not humidity=255.** Open sea is biome `OCEAN`.
5. **Continuity of major rivers and roads across cell borders.** Edge ports +
   in-cell wiring from day one — not a retrofit after climate looks pretty.
6. **Every major river terminates** in atlas `OCEAN` or atlas `LAKE`. No dangling
   trunks in the middle of a plain.
7. **Far LOD and sector bake read the same atlas** for climate and corridors.

Non-goals (still true):

- replacing the 32 m hydrology / road bake for local detail
- high-fidelity climate or plate simulation
- packing rivers into the 32-bit climate word
- multiplayer sync (regenerate from seed)
- required disk cache of the atlas

---

## 3. Core idea

```
World seed
    │
    ▼
ContinentAtlas
    ├─ climate grid          1000×1000 × 32-bit cells
    ├─ lake basins           coarse sinks (cell sets + spill cell)
    ├─ river graph           edge ports + in-cell links → ocean/lake
    └─ road graph            edge ports + in-cell links → nodes
    │
    ▼
ContinentalTerrain   pure surface: atlas fields + corridors + detail noise
    │
    ▼
Sector bake (8 km)   MacroTerrain → EdgeContracts → Hydrology → Paths
    │
    ▼
Chunk stream         density, mesh, water, props
```

| Level | Cell size | Decides | Does not decide |
|-------|-----------|---------|-----------------|
| Atlas | 1 km | land/ocean, climate, coarse elev/relief, **major** river/road topology, coarse lakes | meanders, fords, bridges, brooks, cave mouths |
| Sector | 8 km | which 8 km of the lower layers is baked and cached as one immutable unit | anything continental; it refines, it does not decide |
| Macro | 32 m | drainage detail, local brooks, local roads/bridges, local lakes | continental landmask, trunk rivers and roads |
| Chunk | 2–16 m | walkable mesh, overhangs, caves, props | which continent you are on |

---

## 4. Climate cell format

### 4.1 Extent

- **1000 × 1000** cells, **1 km** each → **1000 km × 1000 km** (design target;
  `WorldConfig.atlas_size` defaults to 256 so booting the game does not spend a
  minute in atlas generation)
- Dense climate store ≈ **4 MB** at 32 bits/cell
- Playable extent: **all of it**. A generation sector is **8 × 8** atlas cells.

Continental metres: cell `(ax, az)` covers
`[ax, ax+1) × [az, az+1)` kilometres. Sector `(sx, sz)` covers exactly 8 cells
on each axis, so sector and atlas grids never straddle each other.

### 4.2 Bit layout (32 bits)

| Field | Bits | Range | Meaning |
|-------|------|-------|---------|
| `elevation` | 8 | 0–255 | Coarse height (§4.3) |
| `humidity` | 8 | 0–255 | Climate moisture (not ocean flag) |
| `biome` | 6 | 0–63 | Landcover id (§4.4) |
| `relief` | 6 | 0–63 | Ruggedness |
| `population` | 4 | 0–15 | Coarse occupancy; 0 default in wilderness (§6.4 step 7) |

Fauna is **derived** later from biome + humidity + relief + population. Not stored.

### 4.3 Elevation codes (fixed mapping)

One function, used by atlas preview, FarTerrain, and MacroTerrain bias:

| Code | Meaning |
|------|---------|
| 0–32 | Ocean depth / shelf (only with `OCEAN`) |
| 33–40 | Coastal lowland |
| 41–120 | Plains / lowlands |
| 121–180 | Hills / highlands |
| 181–220 | Mountains |
| 221–255 | High peaks |

Metres are **not** linear across the whole 0–255 range. Sea (0–32) and
coast (33–40) stay linear so shores keep fine resolution. Land codes 41–255
use an **exponential decode** (`AtlasPack.elevation_to_metres`): low codes stay
in walkable plains/hills, high codes reach Alps-scale peaks (~4 km at 255).
Tests lock the endpoints and round-trips. Schema version bumps when this curve
changes.

**Orogens:** after the climate landmask, the generator stamps 1–2 crescent
mountain belts (length/width scaled to atlas size) with a high core, foothill
apron, and sparse passes so rivers can cross. Noise alone does not produce
Alps-like ranges.

### 4.4 Biome ids (v1 set)

| Id | Name | Notes |
|----|------|-------|
| 0 | `OCEAN` | Open water; continental drainage sink |
| 1 | `COAST` | Land cell with an `OCEAN` 4-neighbour (can also be painted) |
| 2 | `PLAINS` | |
| 3 | `FOREST` | |
| 4 | `WETLAND` | |
| 5 | `ARID` | |
| 6 | `ALPINE` | |
| 7 | `TUNDRA` | |
| 8 | `LAKE` | Atlas-scale standing water (§5) |
| 9+ | reserved | |

`LAKE` is a biome on the climate grid **and** a sink in the river graph. The
atlas says “there is a lake basin here”, owns its surface height, and rivers may
end in it; the 3D world refines the shoreline through the same global signed
shoreline function on both sides of every sector boundary.

---

## 5. Atlas lakes (required in v1)

Skipping atlas lakes forces every major river to the sea. That erases inland
basins and fights the existing local hydrology model (lakes at their own spill
height). Do it now.

**Atlas lake (coarse):**

- Contiguous set of `LAKE` cells (or land cells marked flooded at atlas scale)
- One **spill cell** (outlet) toward lower land or along a river link
- One **surface class** (elevation code of the spill) — flat across the basin
  at atlas resolution

Rules:

- Rivers may terminate in a lake or continue through a lake via the spill into
  an outflow river (same idea as local hydrology, coarser).
- Local bake: where a sector overlaps an atlas lake, the continental surface
  already carries the basin and its water plane; sector hydrology treats those
  cells as a sink and may not dry the basin, flood past it, or move the outlet
  to another atlas cell.

Minimum presence: a non-trivial seed should produce **some** inland lakes, not
only ocean mouths. Tests assert that.

---

## 6. Continuity: edge ports + wiring (required in v1)

This is the part that bites if deferred. Climate-only atlases teach a lie:
pretty continents whose rivers die at every kilometre line.

### 6.1 Rejected approaches

| Approach | Why not |
|----------|---------|
| Count of outs per side | Ambiguous joins; no class; no position |
| Each cell invents its own border | Neighbours disagree |
| Pack rivers into the 32-bit climate word | Starves climate bits; cannot hold topology |
| Atlas stores every brook | Wrong resolution; that is sector Hydrology |
| “Add continuity after far LOD looks good” | Seams become content people walk through |

### 6.2 Edge ports (shared-edge ownership)

A boundary between two cells is generated **once**:

```
# Horizontal edge between (ax,az) and (ax+1,az): owned by the west cell
edge_key = hash(world_seed, "edge", ax, az, EAST)

# Vertical edge between (ax,az) and (ax,az+1): owned by the north cell
edge_key = hash(world_seed, "edge", ax, az, SOUTH)
```

Both cells read the same port list for that edge. There is no merge step.

**`AtlasPort`:**

| Field | Type | Meaning |
|-------|------|---------|
| `id` | int | Stable within the edge (0..N-1) |
| `t` | float | Cross position along edge in `[0,1]`, kept away from corners (e.g. clamp to `[0.15, 0.85]`) |
| `kind` | enum | `RIVER` or `ROAD` |
| `feature_class` | int | River: Strahler/width band 1..4. Road: primary/secondary/trail |
| `flow_sign` | int | Rivers only: `+1` / `-1` along the edge’s outward axis from the owner |
| `surface_z` | int | Quantized feature height at the crossing (metres or elevation code — one mapping). Rivers: water surface. Roads: grade height. **Required** so two cells that share an edge meet vertically, not only in XZ. |

**Caps (v1):** at most **2 river ports** and **2 road ports** per edge. Most edges
have none. Caps exist so wiring stays tractable and far LOD stays readable.

### 6.3 In-cell links

Each land cell stores a small set of **`AtlasLink`** records:

| Field | Meaning |
|-------|---------|
| `a` | Endpoint A (`EdgePortRef` or `TerminalRef`) |
| `b` | Endpoint B |
| `kind` | `RIVER` or `ROAD` |
| `feature_class` | Max/min rules: river links carry the downstream class after merges |

**Terminals (v1, all first-class):**

| Terminal | Used by | Meaning |
|----------|---------|---------|
| `OCEAN` | rivers, roads | Mouth / coastal gate (cell is `OCEAN` or `COAST`) |
| `LAKE` | rivers | End or pass-through via spill |
| `NODE` | roads | Typed landmark (§8.5) |

River link rules:

- Graph is directed downhill (atlas elevation + lake/ocean sinks).
- Every river node is on a path to `OCEAN` or `LAKE`.
- Confluences raise `feature_class` like Strahler (simplified bands).
- No river port may be left unmatched across an edge.

Road link rules:

- Graph is undirected.
- Endpoints are `NODE` terminals (and optionally `OCEAN` coastal gates).
- Primary roads form a connected backbone among a seed set of nodes; secondary
  and trails may branch.
- Primary roads do not dead-end in empty wilderness without a node.

### 6.4 Generation order (fixed)

1. **Landmask + ocean collar** (border sea frame + continent noise).
2. **Elevation + relief** on land (and shelf codes on ocean if useful).
3. **Humidity** (boost near ocean; simple rain-shadow optional).
4. **Atlas lakes** — depressions / seeds → `LAKE` cells + spill.
5. **Biome classify** (including `COAST`, `LAKE`, `OCEAN`).
6. **River graph** — major trunks only: flow accumulation on atlas elevation
   with ocean+lake sinks → create edge ports where channels cross cell borders →
   wire in-cell links → assign classes.
7. **Population** — sparse land occupancy (0–15) from humidity, river corridors
   and, strongest of all, river mouths into ocean/lake plus their immediate
   hinterland. High relief, alpine and arid land is suppressed. Ocean and lake
   cells are always 0, and most land stays 0; occupancy is peaks, not a field.
8. **Road nodes** — sparse seeds placed after population so towns own the
   spacing budget: `SETTLEMENT` on local population maxima (each populated
   landmass gets at least one), then coastal gates, lake shores, highland
   saddles and interior landmarks fill the wilderness lattice.
9. **Road graph** — least-cost paths between nodes on atlas costs (flat, low
   relief, prefer non-ocean, cheaper through occupied cells and along river
   shoulders while still penalising the channel itself) → ports + links →
   classes. The MST and spur weights are discounted by endpoint population, so
   the trunk grows town to town.

Sector bakes come after all of these in the larger pipeline, not as part of
atlas generation. The atlas is finished and frozen before the first sector is
asked for.

### 6.5 What each view draws

| View | Draws |
|------|--------|
| Atlas debug / parchment | Climate + port/link graph as straights, turns, junctions, mouths |
| FarTerrain / horizon | Biome/elevation tint; **ribbons for major river/road links** |
| Sector bake | Full local polylines; trunks reconstructed from the atlas corridors rather than routed locally |

Chunk mesher does not implement tile-turn logic. It keeps today’s mesh pipeline;
atlas corridors decide where major features run, and `SectorEdgeContract` decides
how everything crosses a sector boundary.

### 6.6 Storage

- Climate: dense `PackedInt32Array` (or four byte planes — implementation choice,
  same fields).
- Lakes: list of basin records + cell→basin id plane (compact).
- Rivers/roads: sparse `AtlasFeatureGraph` (edge→ports, cell→links, terminals).

Do not smuggle topology into climate bits.

---

## 7. Invariants (must have tests)

These are to the atlas what the drainage-surface contract is to chunks.

1. **Determinism.** Same `world_seed` → identical climate hash, lake set, river
   graph hash, road graph hash.
2. **Shared-edge agreement.** Ports on east of `(ax,az)` equal ports on west of
   `(ax+1,az)` (same for north/south).
3. **Port matching.** Every river/road port has exactly one partner across its
   edge (no half-features).
4. **River termination.** Every river path ends at `OCEAN` or `LAKE`.
5. **River monotonicity.** Along each directed river path, atlas elevation class
   is non-increasing except through a lake surface (flat).
6. **Lake outlets.** Every atlas lake has a spill toward lower land or a river
   outflow.
7. **Ocean frame.** Border band is predominantly `OCEAN` (collar).
8. **Land exists.** Interior is not 100% ocean; mountains and plains both appear
   for a fixed test seed.
9. **Road backbone per landmass.** Each contiguous land component has its own
    connected primary-road graph among its nodes. No requirement to bridge ocean
    in v1 (no ships yet).
10. **Sector anchor.** Every atlas river/road crossing a sector boundary appears
    as a port in the canonical `SectorEdgeContract` for that boundary, and both
    neighbours derive the same port: same continental position, tangent, grade,
    `surface_z`, width, depth and feature id. Asserted by
    `tools/tests/seam_tests.gd`, not by inspection.
11. **Ocean datum.** All `OCEAN` cells share one continental sea-surface height
    (§8.2). Inland `LAKE` surfaces do not use that number.
12. **Schema stamp.** Atlas carries `schema_version` + parameter hash; mismatches
    fail loud rather than silently mis-read bits.
13. **Population is sparse land occupancy.** `OCEAN` and `LAKE` cells are always
    0, the clear majority of land stays 0, river-linked land is denser than
    inland land, wetter land is denser than drier land, and river mouths average
    far higher than inland cells. Where mouths exist, at least one `SETTLEMENT`
    node exists and towns appear on the primary road network.

---

## 8. Contracts that must exist before code (not later)

Continuity ports fix horizontal seams. These fix the seams that usually appear
the week you add coasts, a second sector, or a quest that names “the same river.”

### 8.1 Two coordinate spaces

Name them and never mix them in APIs:

| Space | Unit | Range / notes |
|-------|------|----------------|
| **Continental** | metres on the planet | Absolute and authoritative. Atlas ports, sector identities, every generated polyline and every save-stable position live here. |
| **Scene** | metres after floating origin | What Godot nodes use. `WorldOrigin` maps continental↔scene and does nothing else; rebasing never changes a generation coordinate. |

There is no third “window” space any more. Sector-local *cell indices* exist
inside a bake (`MacroTerrain.origin_cell` plus a local cell), but they index a
window onto continental metres; they are not a coordinate system anything
outside that bake may see.

```
scene = continental - WorldOrigin.offset
```

At ~1 000 km, float32 still has centimetre-ish precision, but double-safe integer
cell indices (`ax, az`) stay the authority for atlas lookups. Do not hash from
noisy float positions.

### 8.2 Ocean datum vs inland water

`ARCHITECTURE.md` forbids a **global inland** water plane. That stands.

The atlas adds one narrow exception:

- **`OCEAN` biome** has a single continental **sea surface height** (metres),
  used wherever a sector touches ocean — shoreline and coastal sinks agree.
- **`LAKE` basins** keep per-basin spill heights, and an atlas lake's height is
  atlas-owned because it can span sectors. They never snap to sea level.
- **Local (sector-owned) lakes** still keep their own spill height, and are only
  accepted when the whole basin is inside one sector's local domain.

Without an ocean datum, every coastal sector invents its own shoreline height
and the coast steps at every boundary.

### 8.3 Coastline authority

- Atlas decides which cells are `OCEAN` / `COAST` / land / `LAKE`.
- The shoreline is **fractalized once**, by `ContinentalTerrain`, as a pure
  function of continental metres. No sector classifies its own shore, so both
  sides of a boundary find the same waterline, beach slope and bank profile.
- Refinement may **not** flood a pure inland plains cell into ocean, nor dry an
  `OCEAN` cell into walkable land, nor delete an atlas `LAKE` basin.

That one rule prevents “pretty local coasts” from rewriting the continent.

### 8.4 Hard ports, soft corridors

- **Hard:** boundary ports (XZ from `t`, Z from `surface_z`, class from port).
- **Soft:** through-cell links bias local path/river cost toward a deterministic
  corridor reconstructed from the link (e.g. least-cost on atlas elevation
  between the two ports). Local meanders may deviate inside a tolerance; they
  may not ignore the ports.

Far LOD ribbons may use the same reconstructed corridor so the horizon and the
walkable world are cousins, not strangers.

### 8.5 Node kinds (seed them now)

`NODE` terminals are typed from the start, even if most kinds do nothing in
gameplay yet:

| Kind | Role |
|------|------|
| `COASTAL_GATE` | Road meets sea; future docks |
| `LAKE_SHORE` | Road/river meet atlas lake |
| `PASS` | Mountain saddle; road bias |
| `LANDMARK` | Hash-seeded wilderness POI slot |
| `SETTLEMENT` | Seeded on population peaks (river mouths first); road hub |
| `CLAIM_RESERVED` | Future dungeon/mythic claim — roads/settlements must respect |

If every node is an untyped dot, the first settlement generator will pave a town
onto the dungeon mouth you meant to keep wild. Kinds are cheap; fights later are
not.

Each node has a **stable id** derived from seed + cell + kind slot (not from
array order after filtering).

### 8.6 Stable feature identities

Rivers, lakes, roads, and nodes need ids that survive regeneration:

- `lake_id`, `river_id`, `road_id`, `node_id` from hash(seed, type, anchor)
- Ports reference `river_id` / `road_id`
- Future names, quests, and maps key off these — not off “the third polyline
  in the sector bake”

Sector-local reaches are allowed extra ephemeral ids, but must record which
atlas `river_id` or `road_id` they refine. `RiverPolyline.feature_id` and
`RoadEdge.feature_id` carry that parent identity through the bake.

### 8.7 Landmass components

After landmask, label contiguous land components (`landmass_id` per land cell).

- Road graphs are built **per landmass** (invariant 9).
- Spawn picks a landmass explicitly, by way of a ranked river mouth.
- Avoids a “connected primary backbone” invariant that is impossible when the
  ocean collar creates islands.

### 8.8 Atlas immutability and threads

After `ContinentAtlas.generate`:

- Atlas is **immutable** for the rest of the run.
- All sector/chunk workers may read it with no locks, through the shared
  immutable `WorldContext`.
- No “fix up this lake” mutation — change seed or parameters and regenerate.

Matches the existing bake philosophy; say it so nobody caches a mutable atlas on
the streamer.

### 8.9 Biome → local climate mapping

Atlas biome is not a paintbrush on chunk vertices. Define a table now:

- atlas `FOREST` → bias local moisture/temperature/relief into the existing
  `BiomeTable` forest band
- atlas `ARID` → opposite bias
- etc.

Without this, far LOD shows green forest and the walkable ground is grey rock
because local noise ignored the atlas. Both now read the same
`ContinentalTerrain` fields, so they cannot disagree.

### 8.10 Vocabulary

Never reuse “macro” for atlas cells. Existing code: **macro** = 32 m hydrology
grid. Atlas: **atlas cell** = 1 km. Docs, APIs, and debug HUD must say which.

### 8.11 Schema version + content hash

- `ATLAS_SCHEMA_VERSION` integer in code and in the generated atlas object
- Atlas parameters participate in `WorldConfig.content_hash()` (or a sibling
  `atlas_content_hash`) so any cached bake invalidates when collar width, port
  caps, or elevation mapping change

### 8.12 Sector policy (supersedes the sliding window)

The original plan here was a 12 km window that slid with hysteresis and rebaked
with overlap. That is now explicitly **rejected**: a moving window means the
same metre of ground is solved twice from two different catchments, so local
hydrology, lakes and roads change under the player as the window moves.

The policy instead:

- The world is partitioned into fixed **8 km sectors**, aligned to the atlas
  (8 cells) and to chunks (125 chunks). A sector's content depends on
  `(seed, sector coordinate, atlas hash)` and on nothing else.
- A sector bake reads a 1024 m halo past its core and publishes only the core.
- Everything crossing a boundary is either a pure continental function or a
  canonical `SectorEdgeContract` port both neighbours derive identically.
- Sector-local features keep `local_keepout_metres` clear of the boundary.
- Crossing an edge loads the next immutable sector. Nothing is ever rebaked
  because the player moved.

### 8.13 Atlas-scale river × road crossings

Where a road link and a river link cross in the same cell (or share a cell with
orthogonal ports), record an **`AtlasCrossing`** (cell, river_id, road_id,
class pair). Sector `PathNetwork` should prefer placing its bridge/ford near
that site. Cheap to store; painful to rediscover when every bridge sits a
kilometre off the atlas highway.

---

## 9. Relationship to the wilderness bake

### 9.1 Authority

When baking a sector:

1. `AtlasFields` interpolates atlas elevation / humidity / relief / water under
   the sector and its halo.
2. `ContinentalTerrain` refines that into a continuous surface: detail noise,
   the §8.9 biome bias, the fractal shoreline, and a carved valley along every
   atlas river corridor.
3. Atlas ocean, atlas lakes and atlas trunks are hydrology sinks and reserved
   water (§8.2–8.3); the sector solves only what is left.
4. Trunk rivers and roads are **reconstructed** from `AtlasCorridors`, not routed
   locally, and draped onto the continental surface; `AtlasCrossing` sites are
   preferred for bridges (§8.13).
5. Local systems still own meanders, brooks, fords, bridges and local lake
   shores — inside the local domain only. They may not erase or relocate atlas
   trunks, and they may not touch the boundary band.

### 9.2 Far LOD

- Horizon colours from climate.
- Ocean / lake colours from biome.
- Major corridors as ribbons from reconstructed link corridors.
- Streamed chunks always win where they overlap.

### 9.3 Sectors

- Sector grid is fixed and atlas-aligned; identity is the sector coordinate
  (§8.12). Nothing slides.
- `SectorManager` bakes ahead, publishes atomically and caches; the atlas stays
  immutable (§8.8).
- Continuity between sectors is what `SectorEdgeContract` and the pure
  continental surface are for; atlas ports + `surface_z` are what those
  contracts are built from.

---

## 10. API sketch

```gdscript
class_name ContinentAtlas
extends RefCounted

const SIZE: int = 1000
const CELL_METRES: float = 1000.0
const SCHEMA_VERSION: int = 1

var schema_version: int
var world_seed: int
var content_hash: int
var sea_surface_z: float
var cells: PackedInt32Array
var landmass_id: PackedInt32Array
var lakes: Array[AtlasLake]
var river_ports / road_ports: Dictionary  # edge_key -> Array[AtlasPort]
var river_links / road_links: Dictionary  # cell -> Array[AtlasLink]
var crossings: Array[AtlasCrossing]
var nodes: Array[AtlasGraphNode]

static func generate(world_seed: int, size: int = SIZE) -> ContinentAtlas

func cell_at(ax: int, az: int) -> int  # packed climate word
func is_ocean(ax: int, az: int) -> bool
func is_lake(ax: int, az: int) -> bool
func ports_on_edge(ax: int, az: int, dir: int, kind: int) -> Array
func links_in_cell(ax: int, az: int, kind: int) -> Array
func validate() -> PackedStringArray  # empty = all invariants hold
```

Debug view: `scenes/atlas_viewer.tscn` — biome/elev/humidity/relief/population
planes, river and road overlays, node markers (settlements drawn larger);
per-cell field labels when zoomed in.

---

## 11. Delivery phases

### Phase 1 — Atlas core ✅

- Full generate path §6.4 including lakes, typed nodes, rivers, roads, crossings
- Ocean datum, landmass ids, schema/hash, stable feature ids (§8)
- Debug views for all planes/graphs (`start_atlas.bat`)
- `validate()` + tests (`tools/tests/atlas_tests.gd`) for §7 invariants 1–9, 11–12
- No gameplay integration required yet

### Phase 2 — Far LOD consumes atlas

- Horizon from climate + lake/ocean
- Ribbons along reconstructed corridors

### Phase 3 — World generated from the atlas as sectors ✅

- Continental ↔ scene conversions only (§8.1)
- Continental surface: atlas bias via biome mapping (§8.9), fractal coastline,
  corridor valleys
- Hydro sinks, coastline authority, trunks reconstructed from corridors
- Crossing hints for bridges
- Immutable 8 km sectors with canonical edge contracts (§8.12); invariant 10
- Spawn beside a ranked river mouth
- Seam suite: `tools/tests/seam_tests.gd`

### Phase 4 — Content

- Population means something; `SETTLEMENT` / `CLAIM_RESERVED` go live
- Cultures, named regions, travel

Ship Phase 1 as one unit — climate **with** continuity and §8 contracts.

---

## 12. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Deferred continuity | Phase 1 graphs; CI on §7 |
| Height mismatch at borders | `surface_z` on ports; pure continental surface; `seam_tests.gd` |
| Local features straddling a sector edge | `local_keepout_metres` band (§8.12) |
| Coastal sea height disagree | Single ocean datum (§8.2) |
| Local coast rewrites continent | Coastline authority (§8.3) |
| Ambiguous edge joins | Edge-owned ports with `t` |
| All rivers forced to sea | Atlas lakes (§5) |
| Roads with no endpoints | Typed nodes (§8.5) |
| Towns on dungeon mouths later | `CLAIM_RESERVED` kind now |
| Float / origin bugs at 1000 km | Three named spaces (§8.1) |
| Atlas/local biome clash | Mapping table (§8.9) |
| Multi-island road invariant | Per-landmass graphs (§8.7) |
| Silent format drift | Schema version + hash (§8.11) |

---

## 13. Remaining open questions

1. **Temperature / latitude:** noise-derived now, or explicit field later?
2. **Spawn UX:** seed-fixed river mouth (today) vs player picks on a preview?
3. **Climate storage shape:** `PackedInt32Array` vs four byte planes?
4. **Primary road density:** ~30 vs ~100 nodes per large landmass (tuning).
5. **`surface_z` units:** **locked — quantized metres** (see `AtlasPack.elevation_to_metres`).

---

## 14. Locked decisions (summary)

- 1000×1000 km, 1 km cells; climate fields as in §4.2
- `OCEAN` / `COAST` / `LAKE`; atlas lakes with spills in v1
- Edge ports + links for rivers and roads; ports carry `surface_z`
- Sparse graphs; stable ids; typed nodes; atlas crossings
- Ocean datum for sea only; inland lakes per-basin
- Coastline authority; hard ports / soft corridors
- Continental / scene spaces; landmass ids
- Atlas immutable; schema version + content hash
- Biome → local mapping; immutable 8 km sectors with canonical edge contracts
  (the sliding window is rejected, §8.12)
- Phase 1 = climate + continuity + §8 contracts together
- World seed in every hash; fauna derived

Amend this list in writing when we change our minds — not silently in code.
