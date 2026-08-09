class_name WorldMap
extends RefCounted
## The baked, world-wide lower layers: macro terrain, hydrology, claims, roads.
##
## Everything here is solved once for the whole finite map before any chunk is
## meshed. That is what makes rivers and roads agree across chunk and region
## borders: chunks never invent hydrology, they only sample this.

var config: WorldConfig
var noise: NoiseSet
var terrain: MacroTerrain
var hydro: Hydrology
var claims: ClaimMask
var paths: PathNetwork

## Timings of the bake, in milliseconds, for the debug HUD.
var bake_timings: Dictionary = {}

## Segment strides for the flattened query results consumed by DensityField.
const RIVER_STRIDE: int = 10
const ROAD_STRIDE: int = 8


static func generate(cfg: WorldConfig) -> WorldMap:
	var map: WorldMap = WorldMap.new()
	map.config = cfg
	map.noise = NoiseSet.create(cfg)

	var t0: int = Time.get_ticks_msec()
	map.terrain = MacroTerrain.bake(cfg, map.noise)
	var t1: int = Time.get_ticks_msec()
	map.hydro = Hydrology.solve(cfg, map.terrain, map.noise)
	var t2: int = Time.get_ticks_msec()
	map.claims = ClaimMask.new()
	map.paths = PathNetwork.build(cfg, map.terrain, map.hydro, map.claims)
	var t3: int = Time.get_ticks_msec()

	map.bake_timings = {
		"macro_ms": t1 - t0,
		"hydrology_ms": t2 - t1,
		"paths_ms": t3 - t2,
		"total_ms": t3 - t0,
	}
	return map


# --- Queries used by chunk generation -----------------------------------------

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
		var center: Vector3 = site.center()
		if rect.has_point(Vector2(center.x, center.z)):
			out.append(site)
	return out


func lakes_in_rect(rect: Rect2) -> Array[LakeData]:
	var out: Array[LakeData] = []
	for lake in hydro.lakes:
		if lake.bounds.intersects(rect):
			out.append(lake)
	return out


## A dry, gently sloped world position next to a settlement, for spawning.
func find_spawn() -> Vector3:
	assert(paths.nodes.size() > 0, "No settlement nodes to spawn at")
	var node: Vector2 = paths.nodes[0]
	var height: float = terrain.height_at(node.x, node.y)
	return Vector3(node.x, height, node.y)


func biome_at(world_x: float, world_z: float) -> int:
	return BiomeTable.classify(
		terrain.moisture_at(world_x, world_z),
		terrain.temperature_at(world_x, world_z),
		terrain.height_at(world_x, world_z),
		terrain.relief_amp_at(world_x, world_z)
	)


func describe_at(world_x: float, world_z: float) -> Dictionary:
	var cell: Vector2i = WorldCoords.macro_cell_of(config, world_x, world_z)
	var index: int = cell.y * terrain.cells + cell.x
	return {
		"biome": BiomeTable.name_of(biome_at(world_x, world_z)),
		"macro_height": terrain.elevation[index],
		"drainage_height": hydro.filled[index],
		"accumulation": hydro.accumulation[index],
		"lake": hydro.lake_id[index],
		"channel": hydro.is_channel[index] != 0,
		"claim": String(claims.kind_at(world_x, world_z)),
	}
