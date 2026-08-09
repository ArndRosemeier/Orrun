class_name WorldQuery
extends RefCounted
## Questions gameplay asks about the world.
##
## Defined now, before there is any gameplay, because spawning, and later NPCs
## and quests, must not each invent their own idea of "is this ground walkable".

const RAY_HEIGHT: float = 400.0
## How far inland from a river mouth the spawn slice looks for dry ground, and
## how far apart the samples are.
const MOUTH_SEARCH_RADIUS: float = 420.0
const MOUTH_SEARCH_STEP: float = 40.0
## Metres of clearance above the water a spawn site needs, so the player does
## not appear on a tidal flat.
const SPAWN_FREEBOARD: float = 3.0


static func macro_surface_at(sector: WorldSector, world_x: float, world_z: float) -> float:
	return sector.terrain.height_at(world_x, world_z)


## Water surface height at a point, or -INF when the ground there is dry.
## There is no global water level, so this is always a per-feature answer: the
## sea and the atlas lakes come from the continental shoreline function, local
## lakes and brooks from the sector that owns them.
static func water_surface_at(
	sector: WorldSector, continental: ContinentalTerrain, world_x: float, world_z: float
) -> float:
	if continental.shore_signed(world_x, world_z) <= 0.0:
		return continental.water_plane_at(world_x, world_z)
	var lake: int = sector.hydro.lake_at(world_x, world_z)
	if lake >= 0:
		return sector.hydro.lakes[lake].surface_z
	var reach: Dictionary = sector.hydro.nearest_reach(world_x, world_z, 64.0)
	if reach.is_empty():
		return -INF
	if float(reach["distance"]) <= float(reach["half_width"]):
		return float(reach["water_z"])
	return -INF


static func is_water(
	sector: WorldSector, continental: ContinentalTerrain, world_x: float, world_z: float
) -> bool:
	return water_surface_at(sector, continental, world_x, world_z) > -INF


static func is_ford(sector: WorldSector, world_x: float, world_z: float) -> bool:
	for site in sector.paths.bridges:
		if not site.is_ford:
			continue
		var centre: Vector3 = site.center()
		if Vector2(centre.x - world_x, centre.z - world_z).length() < site.span_length():
			return true
	return false


## Metres from the nearest road edge; large when nowhere near a road.
static func road_clearance(sector: WorldSector, world_x: float, world_z: float) -> float:
	var rect: Rect2 = Rect2(world_x - 48.0, world_z - 48.0, 96.0, 96.0)
	var best: float = 1000.0
	for encoded in sector.paths.road_index.query_rect(rect):
		var road: RoadEdge = sector.paths.roads[encoded >> 16]
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


## The river mouths the world could open on, best first.
##
## Ranked by how big the river is and how far the mouth is from the edge of the
## atlas, both of which are pure atlas facts - so the same seed always offers
## the same mouths in the same order, whatever else changes about the 3D world.
static func ranked_river_mouths(context: WorldContext) -> Array[Dictionary]:
	var span: float = context.config.continent_metres()
	var scored: Array[Dictionary] = []
	for mouth in context.corridors.mouths:
		var position: Vector2 = mouth["position"]
		# The player has to be able to walk away from the spawn in any
		# direction, so every sector touching the mouth's own must be bakeable.
		if not _neighbourhood_in_atlas(context, WorldCoords.sector_of(position.x, position.y)):
			continue
		var edge_distance: float = minf(
			minf(position.x, position.y), minf(span - position.x, span - position.y)
		)
		var entry: Dictionary = mouth.duplicate()
		entry["score"] = float(int(mouth["feature_class"])) * 1000.0 + edge_distance * 0.001
		scored.append(entry)
	scored.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"])
	)
	return scored


static func _neighbourhood_in_atlas(context: WorldContext, sector: Vector2i) -> bool:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if not context.sector_in_atlas(sector + Vector2i(dx, dz)):
				return false
	return true


## Dry, gently sloped ground just inland of a river mouth, or INF when this
## mouth has none. Deterministic: the search is a fixed spiral over fixed
## offsets, so the same mouth always yields the same landing.
static func spawn_beside_mouth(
	sector: WorldSector, continental: ContinentalTerrain, mouth: Vector2
) -> Vector3:
	var best: Vector3 = Vector3.INF
	var best_score: float = -INF
	var steps: int = int(MOUTH_SEARCH_RADIUS / MOUTH_SEARCH_STEP)
	for iz in range(-steps, steps + 1):
		for ix in range(-steps, steps + 1):
			var x: float = mouth.x + float(ix) * MOUTH_SEARCH_STEP
			var z: float = mouth.y + float(iz) * MOUTH_SEARCH_STEP
			if not sector.contains_point(x, z):
				continue
			var water: float = water_surface_at(sector, continental, x, z)
			if water > -INF:
				continue
			var ground: float = sector.terrain.height_at(x, z)
			var plane: float = continental.water_plane_at(x, z)
			if ground < plane + SPAWN_FREEBOARD:
				continue
			# Near the mouth, low, and flat. Height above the sea is a cost, not
			# a prize: the point of this slice is to stand at the river's end.
			var distance: float = Vector2(x - mouth.x, z - mouth.y).length()
			var score: float = -distance - (ground - plane) * 6.0
			if score > best_score:
				best_score = score
				best = Vector3(x, ground, z)
	return best


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
