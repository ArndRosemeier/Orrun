class_name VillageDecorator
extends RefCounted
## Shared dry-pad helpers and plaza resolve for [SettlementPlanner].
##
## Building placement lives in [HamletLabPlanner] (via SettlementPlanner).
## This type keeps the pad geometry API and a thin decorate() shim for tests.

## Bank clearance beyond a sample point (metres).
const WATER_CLEARANCE: float = 4.0
const RELIEF_PER_METRE: float = 0.14
const MIN_PAD_RELIEF: float = 1.25
const MAX_PAD_SLOPE: float = 0.32
## Macro |∇h| taps for plaza ranking (metres).
const PLAZA_SLOPE_EPS: float = 28.0
## Reference rise/run for plaza flatness fitness (~2.3°).
const PLAZA_SLOPE_REF: float = 0.04


class Area extends RefCounted:
	var centre: Vector2 = Vector2.ZERO
	var tier: int = VillageTier.Tier.HAMLET
	var settlement_id: int = 0
	var claim_radius: float = 90.0
	var lab_dwelling_min: int = -1
	var lab_dwelling_max: int = -1


## Test / debug shim: plan without appending lanes (empty PathNetwork trunks only).
static func decorate(
	area: Area, terrain: MacroTerrain, hydro: Hydrology
) -> Array[HouseSite]:
	var plan_area: SettlementPlanner.Area = SettlementPlanner.Area.new()
	plan_area.centre = area.centre
	plan_area.tier = area.tier
	plan_area.settlement_id = area.settlement_id
	plan_area.claim_radius = area.claim_radius
	plan_area.lab_dwelling_min = area.lab_dwelling_min
	plan_area.lab_dwelling_max = area.lab_dwelling_max
	var empty_paths: PathNetwork = PathNetwork.new()
	empty_paths.terrain = terrain
	empty_paths.hydro = hydro
	empty_paths.config = WorldConfig.new()
	empty_paths.roads = []
	empty_paths.road_index = SpatialIndex2D.new(160.0)
	var planned: SettlementPlanner.Plan = SettlementPlanner.plan(
		plan_area, terrain, hydro, empty_paths
	)
	var village_only: Array[HouseSite] = []
	for site in planned.sites:
		if VillageCatalog.has_id(site.catalog_id):
			village_only.append(site)
	return village_only


## Pick the flattest dry plaza stand inside the claim (macro |∇h| primary).
static func resolve_plaza(
	area: Area, terrain: MacroTerrain, hydro: Hydrology, rng: RandomNumberGenerator
) -> Vector2:
	return _best_flat_plaza(
		area.centre, area.claim_radius * 0.9, terrain, hydro, rng
	)


## Search the claim for argmax flatness among dry pads. Near-pin is a tie-break.
static func _best_flat_plaza(
	centre: Vector2,
	search_r: float,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> Vector2:
	var best: Vector2 = centre
	var best_score: float = -INF
	var radius: float = maxf(search_r, 48.0)
	# Score the atlas pin if dry so hamlets can stay put when already best.
	if _point_dry(centre.x, centre.y, 5.0, terrain, hydro, 96.0):
		best_score = _plaza_score(centre, centre, radius, terrain, hydro)
		best = centre
	for _i in 96:
		var ang: float = rng.randf() * TAU
		var dist: float = rng.randf_range(radius * 0.08, radius)
		var p: Vector2 = centre + Vector2(cos(ang), sin(ang)) * dist
		if not _point_dry(p.x, p.y, 5.0, terrain, hydro, 96.0):
			continue
		var score: float = _plaza_score(p, centre, radius, terrain, hydro)
		if score > best_score:
			best_score = score
			best = p
	var step: float = 20.0
	var n: int = int(ceil(radius / step))
	for gz in range(-n, n + 1):
		for gx in range(-n, n + 1):
			var p: Vector2 = centre + Vector2(float(gx), float(gz)) * step
			if p.distance_to(centre) > radius:
				continue
			if not _point_dry(p.x, p.y, 5.0, terrain, hydro, 96.0):
				continue
			var score: float = _plaza_score(p, centre, radius, terrain, hydro)
			if score > best_score:
				best_score = score
				best = p
	assert(best_score > -INF, "VillageDecorator: no dry plaza in claim")
	return best


static func _macro_slope(p: Vector2, terrain: MacroTerrain) -> float:
	var eps: float = PLAZA_SLOPE_EPS
	var h: float = terrain.height_at(p.x, p.y)
	var hx: float = terrain.height_at(p.x + eps, p.y)
	var hz: float = terrain.height_at(p.x, p.y + eps)
	var gx: float = (hx - h) / eps
	var gz: float = (hz - h) / eps
	return sqrt(gx * gx + gz * gz)


static func _plaza_flatness(p: Vector2, terrain: MacroTerrain) -> float:
	var s: float = _macro_slope(p, terrain)
	var t: float = s / PLAZA_SLOPE_REF
	return 1.0 / (1.0 + t * t)


static func _plaza_score(
	p: Vector2,
	centre: Vector2,
	search_r: float,
	terrain: MacroTerrain,
	hydro: Hydrology
) -> float:
	var flat: float = _plaza_flatness(p, terrain)
	var reach: Dictionary = hydro.nearest_reach(p.x, p.y, 120.0)
	var wet_gap: float = 40.0
	if not reach.is_empty():
		wet_gap = maxf(float(reach["distance"]) - float(reach["half_width"]), 0.0)
	var lake_gap: float = hydro.lake_distance_at(p.x, p.y)
	var near: float = 1.0 - clampf(p.distance_to(centre) / maxf(search_r, 1.0), 0.0, 1.0)
	# Flatness dominates; dryness margins next; near-pin is only a small tie-break.
	return flat * 100.0 + wet_gap * 0.25 + minf(lake_gap, 80.0) * 0.12 + near * 8.0


static func _footprint_buildable(
	pos: Vector2,
	footprint: float,
	yaw: float,
	terrain: MacroTerrain,
	hydro: Hydrology
) -> bool:
	var half: float = footprint * 0.5
	var basis: Basis = Basis(Vector3.UP, yaw)
	var samples: Array[Dictionary] = [{"p": pos, "half": half}]
	for ox in [-half, half]:
		for oz in [-half, half]:
			var offset: Vector3 = basis * Vector3(ox, 0.0, oz)
			samples.append({
				"p": Vector2(pos.x + offset.x, pos.y + offset.z),
				"half": 0.0,
			})

	var min_h: float = INF
	var max_h: float = -INF
	var query_r: float = half + WATER_CLEARANCE + 24.0
	for sample_variant in samples:
		var sample: Dictionary = sample_variant
		var p: Vector2 = sample["p"]
		var sample_half: float = float(sample["half"])
		if not _point_dry(p.x, p.y, sample_half, terrain, hydro, query_r):
			return false
		var h: float = terrain.height_at(p.x, p.y)
		min_h = minf(min_h, h)
		max_h = maxf(max_h, h)
	var relief: float = max_h - min_h
	var relief_limit: float = maxf(MIN_PAD_RELIEF, footprint * RELIEF_PER_METRE)
	if relief > relief_limit:
		return false
	var slope: float = relief / maxf(footprint, 0.001)
	return slope <= MAX_PAD_SLOPE


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
