class_name WorldQuery
extends RefCounted
## Questions gameplay asks about the world.
##
## Defined now, before there is any gameplay, because spawning, and later NPCs
## and quests, must not each invent their own idea of "is this ground walkable".

const RAY_HEIGHT: float = 400.0


static func macro_surface_at(map: WorldMap, world_x: float, world_z: float) -> float:
	return map.terrain.height_at(world_x, world_z)


## Water surface height at a point, or -INF when the ground there is dry.
## There is no global water level, so this is always a per-feature answer.
static func water_surface_at(map: WorldMap, world_x: float, world_z: float) -> float:
	var lake: int = map.hydro.lake_at(world_x, world_z)
	if lake >= 0:
		return map.hydro.lakes[lake].surface_z
	var reach: Dictionary = map.hydro.nearest_reach(world_x, world_z, 64.0)
	if reach.is_empty():
		return -INF
	if float(reach["distance"]) <= float(reach["half_width"]):
		return float(reach["water_z"])
	return -INF


static func is_water(map: WorldMap, world_x: float, world_z: float) -> bool:
	return water_surface_at(map, world_x, world_z) > -INF


static func is_ford(map: WorldMap, world_x: float, world_z: float) -> bool:
	for site in map.paths.bridges:
		if not site.is_ford:
			continue
		var center: Vector3 = site.center()
		if Vector2(center.x - world_x, center.z - world_z).length() < site.span_length():
			return true
	return false


## Metres from the nearest road edge; large when nowhere near a road.
static func road_clearance(map: WorldMap, world_x: float, world_z: float) -> float:
	var rect: Rect2 = Rect2(world_x - 48.0, world_z - 48.0, 96.0, 96.0)
	var best: float = 1000.0
	for encoded in map.paths.road_index.query_rect(rect):
		var road: RoadEdge = map.paths.roads[encoded >> 16]
		var i: int = encoded & 0xFFFF
		var a: Vector3 = road.points[i]
		var b: Vector3 = road.points[i + 1]
		var ab: Vector2 = Vector2(b.x - a.x, b.z - a.z)
		var len_sq: float = ab.length_squared()
		var t: float = 0.0
		if len_sq > 0.000001:
			t = clampf(Vector2(world_x - a.x, world_z - a.z).dot(ab) / len_sq, 0.0, 1.0)
		var point: Vector2 = Vector2(a.x, a.z) + ab * t
		best = minf(best, point.distance_to(Vector2(world_x, world_z)) - road.half_width)
	return best


## Settlement sites, best first: dry, gently sloped and connected by road.
static func spawn_candidates(map: WorldMap) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	for node in map.paths.nodes:
		if is_water(map, node.x, node.y):
			continue
		out.append(Vector3(node.x, macro_surface_at(map, node.x, node.y), node.y))
	return out


## Exact ground height from the built collision mesh. Returns false when the
## chunk under the point has not streamed in yet - the caller must wait rather
## than guess, or the player drops through the world.
static func trace_ground(
	space: PhysicsDirectSpaceState3D, scene_x: float, scene_z: float, from_y: float
) -> Dictionary:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		Vector3(scene_x, from_y + RAY_HEIGHT, scene_z),
		Vector3(scene_x, from_y - RAY_HEIGHT, scene_z)
	)
	return space.intersect_ray(query)
