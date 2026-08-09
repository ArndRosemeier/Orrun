class_name WorldConfig
extends Resource
## Single source of tuning for every world layer.
##
## Everything downstream is a pure function of (this config, coordinates).
## Two runs with the same config values must produce the same world.

## Master seed. All layer seeds are derived from it.
@export var seed: int = 20260809

# --- Macro grid (drainage scale) ---------------------------------------------

## Metres per macro cell. Drainage, lakes and roads are solved on this grid.
@export var macro_cell_size: float = 32.0
## Macro grid is macro_cells x macro_cells. World is finite (Daggerfall-like map).
@export var macro_cells: int = 384

## Continental shaping.
@export var elevation_sea_base: float = 8.0
@export var elevation_land_scale: float = 210.0
@export var mountain_height: float = 520.0
@export var continent_noise_scale: float = 3400.0
@export var mountain_noise_scale: float = 2600.0
@export var warp_strength: float = 420.0
## Gentle rise toward the middle of the map (m). Breaks up enclosed basins so
## depressions become lakes instead of one inland sea.
@export var drainage_dome: float = 130.0
## Rolling ground laid over the continental shape: amplitude in metres and
## wavelength in metres. This is the difference between plains that drain and
## plains that flood, and between a landscape and a tablecloth.
@export var swell_height: float = 26.0
@export var swell_scale: float = 620.0

## Relief amplitude (metres of 3D detail allowed on top of the macro surface).
@export var relief_amp_plains: float = 3.0
@export var relief_amp_hills: float = 14.0
@export var relief_amp_mountains: float = 46.0

# --- Hydrology ----------------------------------------------------------------

## Flow accumulation (in macro cells) needed before a cell counts as a channel.
@export var river_accum_threshold: float = 90.0
## How deep a notch (m) the hydrology may cut through a divide to drain a
## depression. Filling every hollow to its spill height is what turns a flat
## lowland into an inland sea; real drainage cuts its own way out first, and a
## lake only survives where the rim is too high to breach. Raise this and the
## map dries out, lower it and it floods.
@export var breach_limit: float = 30.0
## Above this many macro cells, a depression is not a lake that happens to be
## large, it is a basin the drainage never got out of, and it is breached at any
## depth. 900 cells is a little under a square kilometre: big enough that real
## lakes survive, small enough that nothing turns into an inland sea. The gorge
## this cuts through the enclosing ridge is the point, not a side effect.
@export var breach_area_cells: int = 900
## The cut allowed for those oversized basins. Still bounded, and bounded by
## what the river valley carve can absorb rather than by taste: cut a channel
## deeper than the valley can ramp down to and the drainage surface ends up
## metres below ground that the contract says must sit under it.
@export var breach_limit_large: float = 20.0
## Fall (m per m) of a breached channel, so an outlet is a stream bed and not a
## level ditch that the next flood pass refills.
@export var breach_slope: float = 0.006
## Minimum lake depth (m) before a filled depression is kept as a lake.
## A filled depression only becomes a lake if it is both deep and wide enough.
## Low thresholds turn every noise dip in a floodplain into a puddle, and the
## result reads as a grid of mismatched water planes rather than a landscape.
@export var lake_min_depth: float = 4.5
## Minimum lake size in macro cells.
@export var lake_min_cells: int = 14
## Channel half-width in metres for Strahler order 1, and growth per order.
@export var river_width_base: float = 1.6
@export var river_width_per_order: float = 2.3
## Bed depth below the water surface for order 1, and growth per order.
@export var river_depth_base: float = 1.4
@export var river_depth_per_order: float = 0.9
## Valley (bank ramp) radius beyond the channel edge. Wide ramps make a river
## a stripe painted on a field; the bank is what makes it a river.
@export var river_valley_base: float = 15.0
@export var river_valley_per_order: float = 11.0
## Lateral meander amplitude on low-slope ground.
@export var meander_amplitude: float = 34.0
@export var meander_scale: float = 260.0

# --- Paths ---------------------------------------------------------------------

@export var road_width_primary: float = 6.0
@export var road_width_secondary: float = 4.0
@export var road_width_trail: float = 2.4
## Rivers wider than this need a bridge; narrower ones can be forded.
@export var ford_max_width: float = 4.0
## Number of settlement-scale nodes the road network connects.
@export var settlement_count: int = 26

# --- Drainage-surface contract -------------------------------------------------

## Relief is fully suppressed within this distance of a channel/road edge (m)...
@export var corridor_inner: float = 6.0
## ...and fully restored beyond this distance (m).
@export var corridor_outer: float = 70.0
## Hard tolerance used by the contract test: surface must stay this close (m)
## to the drainage height directly over a channel.
@export var corridor_epsilon: float = 1.25

# --- Chunks / meshing ----------------------------------------------------------

@export var chunk_size: float = 64.0
## Voxel edge length per LOD.
@export var lod_voxel_size: PackedFloat32Array = PackedFloat32Array([2.0, 4.0, 8.0, 16.0])
## Chunk-radius (in chunks) each LOD extends to. Must be ascending. The outer
## ring is what gives the horizon something to be; fog has to reach further than
## this or the world visibly stops.
@export var lod_radius: PackedInt32Array = PackedInt32Array([3, 6, 10, 16])
## Extra chunk radius kept loaded before unloading (hysteresis).
@export var unload_hysteresis: int = 2
## Vertical fringe hiding the hairline between rings of different detail.
@export var skirts_enabled: bool = true

## Vertical clamps for the whole world.
@export var world_floor: float = -140.0
@export var world_ceiling: float = 900.0
## Extra metres meshed above/below the sampled column extremes.
@export var vertical_margin: float = 14.0

## 3D overhang noise: amplitude fraction of relief amplitude, and feature size.
@export var overhang_amount: float = 0.5
@export var overhang_scale: float = 105.0
## Overhang/cliff detail is only evaluated within this band of the 2D surface.
@export var surface_band: float = 26.0

# --- Caves ----------------------------------------------------------------------

@export var cave_enabled: bool = true
## Caves start this far below the surface and stop this far below it.
@export var cave_top_depth: float = 6.0
@export var cave_bottom_depth: float = 72.0
@export var cave_scale: float = 130.0
## Tunnel selectivity: higher keeps fewer, more tube-like caves.
@export var cave_threshold: float = 0.86
## Caves are suppressed under water bodies by this margin (m).
@export var cave_water_clearance: float = 18.0
## Highest LOD index that still carves caves.
@export var cave_max_lod: int = 1

# --- Streaming -------------------------------------------------------------------

## Chunk results instantiated per frame on the main thread.
@export var instantiate_budget: int = 2
## Player distance from the scene origin (m) that triggers an origin rebase.
@export var origin_rebase_distance: float = 512.0

# --- Dressing ---------------------------------------------------------------------

@export var props_enabled: bool = true
## Prop candidate spacing in metres (jittered grid).
@export var prop_spacing: float = 7.0
@export var prop_max_slope_deg: float = 34.0

# --- Derived ----------------------------------------------------------------------

func world_size() -> float:
	return float(macro_cells) * macro_cell_size


func chunks_per_axis() -> int:
	return int(world_size() / chunk_size)


func lod_count() -> int:
	return lod_voxel_size.size()


func voxel_size_for_lod(lod: int) -> float:
	return lod_voxel_size[clampi(lod, 0, lod_voxel_size.size() - 1)]


## Stable fingerprint of every value that changes generated content.
## Used to invalidate the baked world map cache.
func content_hash() -> int:
	var parts: PackedFloat64Array = PackedFloat64Array([
		float(seed), macro_cell_size, float(macro_cells),
		elevation_sea_base, elevation_land_scale, mountain_height,
		continent_noise_scale, mountain_noise_scale, warp_strength, drainage_dome,
		swell_height, swell_scale,
		relief_amp_plains, relief_amp_hills, relief_amp_mountains,
		river_accum_threshold, breach_limit, breach_slope,
		float(breach_area_cells), breach_limit_large,
		lake_min_depth, float(lake_min_cells),
		river_width_base, river_width_per_order,
		river_depth_base, river_depth_per_order,
		river_valley_base, river_valley_per_order,
		meander_amplitude, meander_scale,
		road_width_primary, road_width_secondary, road_width_trail,
		ford_max_width, float(settlement_count),
	])
	var h: int = 1469598103934665603
	for value in parts:
		h = (h ^ hash(value)) * 1099511628211
		h = h & 0x7FFFFFFFFFFFFFFF
	return h


## Deterministic per-layer seed. Layer names are stable strings.
func layer_seed(layer: String) -> int:
	return int(hash(layer) ^ (seed * 2654435761)) & 0x7FFFFFFF
