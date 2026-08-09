class_name WorldSector
extends RefCounted
## One 8 km square of baked lower layers: macro terrain, hydrology, claims,
## local roads, and the atlas features that pass through.
##
## A sector is immutable once generated and is a pure function of
## (context, sector coordinate). It is generated independently of its
## neighbours, in any order, on any thread, and still meets them exactly,
## because everything that crosses its boundary is either a pure continental
## function or a [SectorEdgeContract] port both sides derive the same way.
##
## 8000 m is exactly 8 atlas cells, 250 macro cells and 125 chunks, so every
## chunk in the world has one unambiguous owning sector. Chunks are never
## generated twice and never have to choose between two versions of a river.
##
## The bake covers the core plus a halo of [member WorldConfig.sector_halo_metres]
## on every side. The halo exists so the interior solvers can see past the
## boundary; nothing in it is ever published.

## Segment strides for the flattened query results consumed by DensityField.
## [ax, water_z, az, bx, water_z, bz, half_a, half_b, depth, valley]
const RIVER_STRIDE: int = 10
## [ax, surface_z, az, bx, surface_z, bz, half_width, tier]
const ROAD_STRIDE: int = 8

var context: WorldContext
var config: WorldConfig
var sector: Vector2i = Vector2i.ZERO

var terrain: MacroTerrain
var hydro: Hydrology
var claims: ClaimMask
var paths: PathNetwork
var houses: Array[HouseSite] = []

## Canonical contracts for the four boundaries, keyed by [SectorEdgeContract.Side].
var edges: Dictionary = {}

## Local cell bounds of the core inside the baked window, inclusive.
var core_min: Vector2i = Vector2i.ZERO
var core_max: Vector2i = Vector2i.ZERO

var bake_timings: Dictionary = {}


static func generate(world_context: WorldContext, sector_coord: Vector2i) -> WorldSector:
	var built: WorldSector = WorldSector.new()
	built.context = world_context
	built.config = world_context.config
	built.sector = sector_coord

	var cfg: WorldConfig = world_context.config
	var halo: int = cfg.halo_cells()
	var cells: int = cfg.sector_bake_cells()
	var per: int = cfg.macro_cells_per_sector()
	built.core_min = Vector2i(halo, halo)
	built.core_max = Vector2i(halo + per - 1, halo + per - 1)

	var continental: ContinentalTerrain = world_context.sampler()
	var noise: NoiseSet = NoiseSet.create(cfg)
	var origin_cell: Vector2i = (
		WorldCoords.sector_macro_origin(cfg, sector_coord) - Vector2i(halo, halo)
	)

	var t0: int = Time.get_ticks_msec()
	built.terrain = MacroTerrain.bake_window(cfg, origin_cell, cells, continental)
	var t1: int = Time.get_ticks_msec()
	built._build_edge_contracts(continental)
	var t2: int = Time.get_ticks_msec()

	var inflow: Array[SectorEdgeContract.Port] = []
	var outflow: Array[SectorEdgeContract.Port] = []
	for side in built.edges:
		var contract: SectorEdgeContract = built.edges[side]
		inflow.append_array(contract.inflow_for(sector_coord))
		outflow.append_array(contract.outflow_for(sector_coord))

	built.hydro = Hydrology.solve(
		cfg, built.terrain, continental, world_context.corridors,
		built.core_min, built.core_max, inflow, outflow, noise
	)
	var t3: int = Time.get_ticks_msec()

	built.claims = ClaimMask.new()
	built.paths = PathNetwork.build(
		cfg, built.terrain, built.hydro, built.claims,
		world_context.corridors, built.core_min, built.core_max
	)
	var t4: int = Time.get_ticks_msec()
	built.houses = SettlementLayout.build(
		world_context, built.terrain, built.hydro, built.claims, built.core_rect()
	)
	var t5: int = Time.get_ticks_msec()

	built.bake_timings = {
		"macro_ms": t1 - t0,
		"contracts_ms": t2 - t1,
		"hydrology_ms": t3 - t2,
		"paths_ms": t4 - t3,
		"settlements_ms": t5 - t4,
		"total_ms": t5 - t0,
	}
	return built


func _build_edge_contracts(continental: ContinentalTerrain) -> void:
	for side in [
		SectorEdgeContract.Side.EAST, SectorEdgeContract.Side.SOUTH,
		SectorEdgeContract.Side.WEST, SectorEdgeContract.Side.NORTH
	]:
		var canonical: Array = SectorEdgeContract.canonical(sector, side)
		edges[side] = SectorEdgeContract.build(
			config, context.corridors, continental, canonical[0], canonical[1]
		)


# --- Ownership -----------------------------------------------------------------

func core_rect() -> Rect2:
	return WorldCoords.sector_rect(sector)


func owns_chunk(chunk: Vector2i) -> bool:
	return WorldCoords.sector_of_chunk(config, chunk) == sector


func contains_point(world_x: float, world_z: float) -> bool:
	return WorldCoords.sector_of(world_x, world_z) == sector


# --- Queries used by chunk generation ---------------------------------------------

## River segments overlapping a rect, flattened for tight inner loops:
## [ax, a_water_z, az, bx, b_water_z, bz, a_half_width, b_half_width, depth, valley]
func collect_river_segments(rect: Rect2) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	for encoded in hydro.river_index.query_rect(rect):
		var reach: RiverPolyline = hydro.rivers[encoded >> 16]
		var i: int = encoded & 0xFFFF
		var a: Vector3 = reach.points[i]
		var b: Vector3 = reach.points[i + 1]
		out.append_array(PackedFloat32Array([
			a.x, a.y, a.z,
			b.x, b.y, b.z,
			reach.half_width[i], reach.half_width[i + 1],
			reach.depth, reach.valley,
		]))
	return out


## Road segments overlapping a rect:
## [ax, a_surface_z, az, bx, b_surface_z, bz, half_width, tier]
func collect_road_segments(rect: Rect2) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	for encoded in paths.road_index.query_rect(rect):
		var road: RoadEdge = paths.roads[encoded >> 16]
		var i: int = encoded & 0xFFFF
		var a: Vector3 = road.points[i]
		var b: Vector3 = road.points[i + 1]
		out.append_array(PackedFloat32Array([
			a.x, a.y, a.z,
			b.x, b.y, b.z,
			road.half_width, float(road.tier),
		]))
	return out


func bridges_in_rect(rect: Rect2) -> Array[BridgeSite]:
	var out: Array[BridgeSite] = []
	for site in paths.bridges:
		if site.is_ford:
			continue
		var centre: Vector3 = site.center()
		if rect.has_point(Vector2(centre.x, centre.z)):
			out.append(site)
	return out


func houses_in_rect(rect: Rect2) -> Array[HouseSite]:
	var out: Array[HouseSite] = []
	for site in houses:
		if rect.has_point(Vector2(site.world_x, site.world_z)):
			out.append(site)
	return out


func lakes_in_rect(rect: Rect2) -> Array[LakeData]:
	var out: Array[LakeData] = []
	for lake in hydro.lakes:
		if lake.bounds.intersects(rect):
			out.append(lake)
	return out


func biome_at(world_x: float, world_z: float) -> int:
	return BiomeTable.classify(
		terrain.moisture_at(world_x, world_z),
		terrain.temperature_at(world_x, world_z),
		terrain.height_at(world_x, world_z),
		terrain.relief_amp_at(world_x, world_z)
	)


func describe_at(world_x: float, world_z: float) -> Dictionary:
	var cell: Vector2i = terrain.local_cell_of(world_x, world_z)
	if not terrain.contains_local(cell.x, cell.y):
		return {"biome": "outside sector"}
	var index: int = cell.y * terrain.cells + cell.x
	return {
		"biome": BiomeTable.name_of(biome_at(world_x, world_z)),
		"sector": sector,
		"macro_height": terrain.elevation[index],
		"drainage_height": hydro.filled[index],
		"accumulation": hydro.accumulation[index],
		"lake": hydro.lake_id[index],
		"channel": hydro.is_channel[index] != 0,
		"trunk": hydro.trunk[index] != 0,
		"atlas_water": hydro.atlas_water[index] != 0,
		"claim": String(claims.kind_at(world_x, world_z)),
	}
