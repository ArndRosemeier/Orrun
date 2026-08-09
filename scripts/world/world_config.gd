class_name WorldConfig
extends Resource
## Single source of tuning for every world layer.
##
## Everything downstream is a pure function of (this config, the atlas,
## coordinates). Two runs with the same config values and the same atlas must
## produce the same world, sector by sector, in any order.

## Master seed. All layer seeds are derived from it, and so is the atlas.
@export var seed: int = 20260809

# --- Scale facts ---------------------------------------------------------------
#
# These are not tuning knobs. They are the alignment contract between the atlas,
# the generation sectors, the feature pages and the meshed chunks, and changing
# one without the others breaks sector ownership.

## Metres per macro cell. Drainage, local roads and lakes are solved on this
## grid. 8000 / 32 = 250 cells per sector, exactly.
@export var macro_cell_size: float = 32.0
## Metres per meshed chunk. 8000 / 64 = 125 chunks per sector, exactly.
@export var chunk_size: float = 64.0
## Read-only apron baked around each sector core so interior solvers see past
## the boundary. Nothing inside the halo is ever published.
@export var sector_halo_metres: float = 1024.0
## Metres inside the sector core where nothing sector-local may exist.
##
## This is the rule that makes chunks either side of a boundary mesh the same
## ground. A local brook, lake or track shapes the terrain around it out to
## roughly its valley plus [member corridor_outer]; if one could sit on the
## boundary, the neighbour - which has never heard of it - would mesh the same
## metre differently, and the seam would be a visible step. Only atlas features
## and edge-contract ports, which both sides derive identically, may come
## closer.
@export var local_keepout_metres: float = 160.0

## Side length of the continent atlas, in 1 km cells. The design target is
## 1000 km; the runtime default is smaller so booting the game does not spend a
## minute in atlas generation. Both are the same generator.
@export var atlas_size: int = 256

## Bumped whenever the meaning of a sector edge contract changes. Part of the
## content hash, so stale derived caches fail loudly instead of seaming.
@export var sector_contract_version: int = 1

# --- Continental terrain refinement --------------------------------------------
#
# The atlas owns elevation at the kilometre scale. These values only describe
# what the 3D world is allowed to add between atlas cells.

## Rolling ground laid over the atlas surface: amplitude in metres and
## wavelength in metres. This is the difference between plains that drain and
## plains that flood, and between a landscape and a tablecloth.
@export var swell_height: float = 22.0
@export var swell_scale: float = 620.0
## Ridge detail, scaled by how mountainous the atlas says the cell is.
@export var mountain_detail: float = 90.0
@export var mountain_noise_scale: float = 1400.0
## Domain warp applied before the detail noise, so refinement does not line up
## with the atlas lattice and betray the 1 km grid.
@export var warp_strength: float = 260.0
@export var warp_scale: float = 900.0

## Metres of freedom the shoreline detail has inside a coastal atlas cell. The
## atlas still decides which cells are coast; this only decides how ragged the
## waterline inside them is.
@export var coast_detail: float = 9.0
## Minimum depth (m) below the sea surface that authoritative ocean cells keep,
## and minimum height (m) above it that authoritative inland cells keep.
@export var ocean_floor_margin: float = 2.5
@export var inland_freeboard: float = 1.0

## Valley the continental surface cuts along an atlas river corridor. The trench
## is what makes the trunk network actually drain: without it, detail noise dams
## the valley floor and the local flood turns the lowland into a lake.
@export var trunk_valley_radius: float = 130.0
@export var trunk_valley_per_class: float = 95.0
@export var trunk_bank_rise: float = 2.2

## Relief amplitude (metres of 3D detail allowed on top of the macro surface).
@export var relief_amp_plains: float = 3.0
@export var relief_amp_hills: float = 14.0
@export var relief_amp_mountains: float = 46.0

# --- Hydrology ------------------------------------------------------------------

## Flow accumulation (in macro cells) needed before a cell counts as a channel.
@export var river_accum_threshold: float = 90.0
## Minimum lake depth (m) before a filled depression is kept as a local lake.
@export var lake_min_depth: float = 4.5
## Minimum local lake size in macro cells.
@export var lake_min_cells: int = 14
## Above this many cells a filled depression is not a lake, it is a basin the
## drainage never left. The atlas surface is depression free at its own scale,
## so anything this large came from detail noise and is rejected rather than
## flooded. Both neighbours reject it identically, so no seam appears.
@export var lake_max_cells: int = 2600
## Channel half-width in metres for Strahler order 1, and growth per order.
@export var river_width_base: float = 1.6
@export var river_width_per_order: float = 2.3
## Bed depth below the water surface for order 1, and growth per order.
@export var river_depth_base: float = 1.4
@export var river_depth_per_order: float = 0.9
## Valley (bank ramp) radius beyond the channel edge.
@export var river_valley_base: float = 15.0
@export var river_valley_per_order: float = 11.0
## Lateral meander amplitude on low-slope ground.
@export var meander_amplitude: float = 34.0
@export var meander_scale: float = 260.0

## Strahler order the atlas trunk of a given feature class is published with.
## Trunks are not measured from sector-local accumulation: a sector only sees
## its own 8 km of catchment, so its idea of how big the river is would change
## at every boundary.
@export var trunk_order_base: int = 4

# --- Paths -------------------------------------------------------------------------

@export var road_width_primary: float = 6.0
@export var road_width_secondary: float = 4.0
@export var road_width_trail: float = 2.4
## Rivers wider than this need a bridge; narrower ones can be forded.
@export var ford_max_width: float = 4.0
## Local (sector-contained) landmarks the local trail network connects. Atlas
## roads are not counted here: they are continental and cross sectors.
@export var local_node_count: int = 5

# --- Drainage-surface contract ---------------------------------------------------

## Relief is fully suppressed within this distance of a channel/road edge (m)...
@export var corridor_inner: float = 6.0
## ...and fully restored beyond this distance (m).
@export var corridor_outer: float = 70.0
## Hard tolerance used by the contract test: surface must stay this close (m)
## to the drainage height directly over a channel.
@export var corridor_epsilon: float = 1.25

# --- Chunks / meshing --------------------------------------------------------------

## Voxel edge length per LOD.
@export var lod_voxel_size: PackedFloat32Array = PackedFloat32Array([2.0, 4.0, 8.0, 16.0])
## Chunk-radius (in chunks) each LOD extends to. Must be ascending.
@export var lod_radius: PackedInt32Array = PackedInt32Array([3, 6, 10, 16])
## Extra chunk radius kept loaded before unloading (hysteresis).
@export var unload_hysteresis: int = 2
## Vertical fringe hiding the hairline between rings of different detail.
@export var skirts_enabled: bool = true

## Vertical clamps for the whole world.
@export var world_floor: float = -260.0
@export var world_ceiling: float = 1400.0
## Extra metres meshed above/below the sampled column extremes.
@export var vertical_margin: float = 14.0

## 3D overhang noise: amplitude fraction of relief amplitude, and feature size.
@export var overhang_amount: float = 0.5
@export var overhang_scale: float = 105.0
## Overhang/cliff detail is only evaluated within this band of the 2D surface.
@export var surface_band: float = 26.0

# --- Caves --------------------------------------------------------------------------

@export var cave_enabled: bool = true
## Caves start this far below the surface and stop this far below it.
@export var cave_top_depth: float = 6.0
@export var cave_bottom_depth: float = 72.0
@export var cave_scale: float = 130.0
## Tunnel selectivity: lower keeps fewer, more tube-like caves. A cave exists
## where two independent noise fields are both near zero, and that condition is
## far more common than it looks - most of this range is swiss cheese rather
## than caves.
@export var cave_threshold: float = 0.42
## Caves are suppressed under water bodies by this margin (m).
@export var cave_water_clearance: float = 18.0
## Highest LOD index that still carves caves.
@export var cave_max_lod: int = 1

# --- Streaming -----------------------------------------------------------------------

## Chunk results instantiated per frame on the main thread.
@export var instantiate_budget: int = 2
## Player distance from the scene origin (m) that triggers an origin rebase.
@export var origin_rebase_distance: float = 512.0
## Sectors kept in the LRU cache. 9 is the 3x3 the player can reach without a
## new bake; the rest is slack for walking a diagonal.
@export var sector_cache_size: int = 16
## Chebyshev radius, in sectors, prefetched around the player's sector.
@export var sector_prefetch_radius: int = 1

# --- Dressing -------------------------------------------------------------------------

@export var props_enabled: bool = true
## Prop candidate spacing in metres (jittered grid).
@export var prop_spacing: float = 7.0
@export var prop_max_slope_deg: float = 34.0

# --- Derived ---------------------------------------------------------------------------

## Macro cells across one sector core. Exact by construction.
func macro_cells_per_sector() -> int:
	return int(round(WorldCoords.SECTOR_SIZE / macro_cell_size))


## Macro cells of read-only halo on each side of the core.
func halo_cells() -> int:
	return int(ceil(sector_halo_metres / macro_cell_size))


## Side length of the array a sector bake actually allocates.
func sector_bake_cells() -> int:
	return macro_cells_per_sector() + halo_cells() * 2


## Macro cells of keep-out inside each core edge. Rounded up, so the band is
## never narrower than the influence it has to cover.
func keepout_cells() -> int:
	return int(ceil(local_keepout_metres / macro_cell_size))


func chunks_per_sector() -> int:
	return int(round(WorldCoords.SECTOR_SIZE / chunk_size))


func regions_per_sector() -> int:
	return int(round(WorldCoords.SECTOR_SIZE / WorldCoords.REGION_SIZE))


## Continental extent of the atlas in metres, on each axis from the origin.
func continent_metres() -> float:
	return float(atlas_size) * WorldCoords.ATLAS_CELL_SIZE


func lod_count() -> int:
	return lod_voxel_size.size()


func voxel_size_for_lod(lod: int) -> float:
	return lod_voxel_size[clampi(lod, 0, lod_voxel_size.size() - 1)]


## Stable fingerprint of every value that changes generated content. Combined
## with the atlas content hash it keys any derived on-disk cache.
func content_hash() -> int:
	var parts: PackedFloat64Array = PackedFloat64Array([
		float(seed), macro_cell_size, chunk_size, sector_halo_metres,
		local_keepout_metres,
		float(atlas_size), float(sector_contract_version),
		swell_height, swell_scale, mountain_detail, mountain_noise_scale,
		warp_strength, warp_scale,
		coast_detail, ocean_floor_margin, inland_freeboard,
		trunk_valley_radius, trunk_valley_per_class, trunk_bank_rise,
		relief_amp_plains, relief_amp_hills, relief_amp_mountains,
		river_accum_threshold, lake_min_depth,
		float(lake_min_cells), float(lake_max_cells),
		river_width_base, river_width_per_order,
		river_depth_base, river_depth_per_order,
		river_valley_base, river_valley_per_order,
		meander_amplitude, meander_scale, float(trunk_order_base),
		road_width_primary, road_width_secondary, road_width_trail,
		ford_max_width, float(local_node_count),
	])
	var h: int = 1469598103934665603
	for value in parts:
		h = (h ^ hash(value)) * 1099511628211
		h = h & 0x7FFFFFFFFFFFFFFF
	return h


## Deterministic per-layer seed. Layer names are stable strings.
func layer_seed(layer: String) -> int:
	return int(hash(layer) ^ (seed * 2654435761)) & 0x7FFFFFFF


## Deterministic seed for anything keyed to a place rather than to a layer, so
## a sector-local decision is reproducible without depending on which sector
## asked or in what order.
func place_seed(layer: String, cell: Vector2i) -> int:
	var mixed: int = (cell.x * 73856093) ^ (cell.y * 19349663)
	return int(hash(layer) ^ (seed * 2654435761) ^ mixed) & 0x7FFFFFFF
