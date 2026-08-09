class_name SettlementLayout
extends RefCounted
## Alpha settlements: a small village green of Asset Lab houses around each
## atlas SETTLEMENT node. Reserves a clearing so props thin out, packs a
## centrepiece (rarely the large hall) plus a ring of homes facing the plaza.

const COMMON_HOUSES: Array[StringName] = [
	&"house_hut_thatch",
	&"house_cabin_timber",
	&"house_cottage_stone",
]
const HALL_ID: StringName = &"house_hall_large"
## Chance the village centrepiece is the large hall.
const HALL_CHANCE: float = 0.14

const FOOTPRINTS: Dictionary = {
	&"house_hut_thatch": 5.5,
	&"house_cabin_timber": 8.0,
	&"house_cottage_stone": 9.5,
	&"house_hall_large": 16.0,
}

const HOUSE_HEIGHTS: Dictionary = {
	&"house_hut_thatch": 4.5,
	&"house_cabin_timber": 6.0,
	&"house_cottage_stone": 6.4,
	&"house_hall_large": 9.2,
}

const CLAIM_RADIUS: float = 110.0
## Open plaza in the middle of the ring.
const PLAZA_RADIUS: float = 14.0
const RING_MIN: float = 22.0
const RING_MAX: float = 48.0
## Keep the whole footprint this far past the channel / lake edge.
const WATER_CLEARANCE: float = 10.0
## Macro height spread across the footprint before density terracing.
const MAX_MACRO_RELIEF: float = 0.65
const PLACE_ATTEMPTS: int = 64


static func is_house(catalog_id: StringName) -> bool:
	return FOOTPRINTS.has(catalog_id)


static func footprint_of(catalog_id: StringName) -> float:
	return float(FOOTPRINTS.get(catalog_id, 6.0))


static func height_of(catalog_id: StringName) -> float:
	return float(HOUSE_HEIGHTS.get(catalog_id, 4.5))


## Plaza stand point near the settlement closest to `hint_xz` (continental metres).
static func spawn_plaza_near(atlas: ContinentAtlas, hint_xz: Vector2) -> Vector2:
	var best: Vector2 = hint_xz
	var best_d: float = INF
	var found: bool = false
	for node_variant in atlas.nodes:
		var node: AtlasGraphNode = node_variant
		if node.kind != AtlasFeatures.NodeKind.SETTLEMENT:
			continue
		var centre: Vector2 = atlas.continental_centre(node.ax, node.az)
		var d: float = centre.distance_squared_to(hint_xz)
		if d < best_d:
			best_d = d
			best = centre
			found = true
	if not found:
		return hint_xz
	# Stand on the green, slightly off-centre so the player sees the ring.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = int(hash("spawn_plaza:%.0f:%.0f" % [best.x, best.y])) & 0x7fffffff
	var angle: float = rng.randf() * TAU
	return best + Vector2(cos(angle), sin(angle)) * 10.0


static func build(
	context: WorldContext,
	terrain: MacroTerrain,
	hydro: Hydrology,
	claims: ClaimMask,
	core: Rect2
) -> Array[HouseSite]:
	var out: Array[HouseSite] = []
	var atlas: ContinentAtlas = context.atlas
	for node_variant in atlas.nodes:
		var node: AtlasGraphNode = node_variant
		if node.kind != AtlasFeatures.NodeKind.SETTLEMENT:
			continue
		var centre: Vector2 = atlas.continental_centre(node.ax, node.az)
		if not core.has_point(centre):
			continue
		var ground_z: float = terrain.height_at(centre.x, centre.y)
		claims.add(&"settlement", centre, CLAIM_RADIUS, ground_z)
		out.append_array(_pack_village(node.id, centre, terrain, hydro))
	return out


static func _pack_village(
	settlement_id: int, centre: Vector2, terrain: MacroTerrain, hydro: Hydrology
) -> Array[HouseSite]:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = int(hash("settlement_houses:%d" % settlement_id)) & 0x7fffffff

	var sites: Array[HouseSite] = []
	var placed: Array[Vector2] = []

	# Centrepiece on the plaza edge — hall when the rare roll hits, else a cottage.
	var primary_id: StringName = (
		HALL_ID if rng.randf() < HALL_CHANCE else &"house_cottage_stone"
	)
	var primary: HouseSite = _try_place(
		rng, centre, primary_id, PLAZA_RADIUS + 2.0, PLAZA_RADIUS + 8.0,
		placed, terrain, hydro, true
	)
	if primary != null:
		sites.append(primary)

	var homes: int = rng.randi_range(3, 6)
	for _i in homes:
		var catalog_id: StringName = COMMON_HOUSES[rng.randi() % COMMON_HOUSES.size()]
		# Prefer timber/hut for the ring; cottage already used as fallback primary.
		if catalog_id == &"house_cottage_stone" and rng.randf() < 0.45:
			catalog_id = &"house_cabin_timber"
		var home: HouseSite = _try_place(
			rng, centre, catalog_id, RING_MIN, RING_MAX, placed, terrain, hydro, false
		)
		if home != null:
			sites.append(home)

	return sites


static func _try_place(
	rng: RandomNumberGenerator,
	centre: Vector2,
	catalog_id: StringName,
	radius_min: float,
	radius_max: float,
	placed: Array[Vector2],
	terrain: MacroTerrain,
	hydro: Hydrology,
	prefer_cardinal: bool
) -> HouseSite:
	var footprint: float = footprint_of(catalog_id)
	for attempt in PLACE_ATTEMPTS:
		var angle: float
		if prefer_cardinal and attempt < 4:
			angle = float(attempt) * TAU * 0.25 + rng.randf_range(-0.2, 0.2)
		else:
			angle = rng.randf() * TAU
		var radius: float = rng.randf_range(radius_min, radius_max)
		radius += footprint * 0.2
		var pos: Vector2 = centre + Vector2(cos(angle), sin(angle)) * radius
		if pos.distance_to(centre) < PLAZA_RADIUS + footprint * 0.35:
			continue
		var ok: bool = true
		for other in placed:
			if pos.distance_to(other) < footprint + 5.0:
				ok = false
				break
		if not ok:
			continue
		var to_centre: Vector2 = Vector2(centre.x - pos.x, centre.y - pos.y)
		var yaw: float = atan2(to_centre.x, -to_centre.y)
		if not _footprint_buildable(pos, footprint, yaw, terrain, hydro):
			continue
		placed.append(pos)
		var site: HouseSite = HouseSite.new()
		site.catalog_id = catalog_id
		site.world_x = pos.x
		site.world_z = pos.y
		site.footprint = footprint
		site.yaw = yaw
		return site
	return null


## Centre + oriented corners must be dry, clear of channels, and not too tilted.
static func _footprint_buildable(
	pos: Vector2,
	footprint: float,
	yaw: float,
	terrain: MacroTerrain,
	hydro: Hydrology
) -> bool:
	var half: float = footprint * 0.5
	var basis: Basis = Basis(Vector3.UP, yaw)
	var samples: Array[Vector2] = [pos]
	for ox in [-half, half]:
		for oz in [-half, half]:
			var offset: Vector3 = basis * Vector3(ox, 0.0, oz)
			samples.append(Vector2(pos.x + offset.x, pos.y + offset.z))

	var min_h: float = INF
	var max_h: float = -INF
	var query_r: float = footprint * 0.5 + WATER_CLEARANCE + 24.0
	for sample in samples:
		if not _point_dry(sample.x, sample.y, footprint * 0.5, terrain, hydro, query_r):
			return false
		var h: float = terrain.height_at(sample.x, sample.y)
		min_h = minf(min_h, h)
		max_h = maxf(max_h, h)
	if max_h - min_h > MAX_MACRO_RELIEF:
		return false
	var slope: float = (max_h - min_h) / maxf(footprint, 0.001)
	return slope <= 0.18


static func _point_dry(
	world_x: float,
	world_z: float,
	half_foot: float,
	terrain: MacroTerrain,
	hydro: Hydrology,
	query_r: float
) -> bool:
	var cell: Vector2i = terrain.local_cell_of(world_x, world_z)
	if terrain.contains_local(cell.x, cell.y):
		var index: int = cell.y * terrain.cells + cell.x
		if hydro.atlas_water[index] != 0:
			return false
		if hydro.lake_id[index] != -1:
			return false
		if hydro.is_channel[index] != 0:
			return false
	if hydro.lake_at(world_x, world_z) != -1:
		return false
	var lake_d: float = hydro.lake_distance_at(world_x, world_z)
	if lake_d < half_foot + WATER_CLEARANCE:
		return false
	var height: float = terrain.height_at(world_x, world_z)
	if hydro.drainage_at(world_x, world_z) > height + 0.2:
		return false
	var reach: Dictionary = hydro.nearest_reach(world_x, world_z, query_r)
	if not reach.is_empty():
		var edge: float = float(reach["distance"]) - float(reach["half_width"])
		if edge < half_foot + WATER_CLEARANCE:
			return false
	return true
