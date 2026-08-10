class_name HabitatQuery
extends RefCounted
## Derives fauna suitability from sector climate + hard ground contracts.
##
## Fauna is not stored in the atlas. A point either may host a species (standable
## dry ground with positive suitability) or it must not — never a soft fallback.

const WATERLINE_MARGIN: float = 0.35


## Hard reject: water, roads, reserved claims (wild only), steep macro slope.
## Livestock must stand in the settlement farm annulus (outside built core).
static func may_stand(
	spec: FaunaCatalog.FaunaSpec,
	sector: WorldSector,
	continental: ContinentalTerrain,
	world_x: float,
	world_z: float
) -> bool:
	if WorldQuery.is_water(sector, continental, world_x, world_z):
		return false
	var water: float = WorldQuery.water_surface_at(sector, continental, world_x, world_z)
	var ground: float = continental.height_at(world_x, world_z)
	if water > -INF and ground < water + WATERLINE_MARGIN + spec.avoid_water * 0.15:
		# Near-shore thinning is soft via suitability; standing in/on the sheet is hard.
		if ground <= water + WATERLINE_MARGIN:
			return false
	var road: float = WorldQuery.road_clearance(sector, world_x, world_z)
	if road < spec.clearance_road:
		return false
	if spec.wilderness_spawn and sector.claims.is_reserved(world_x, world_z):
		return false
	if spec.role == &"livestock" and not _in_farm_annulus(sector, world_x, world_z):
		return false
	var normal: Vector3 = _macro_normal(continental, world_x, world_z)
	if normal.y < cos(deg_to_rad(spec.max_slope_deg)):
		return false
	return true


## Settlement claim ring between built envelope and claim edge (meadow / fields).
static func _in_farm_annulus(sector: WorldSector, world_x: float, world_z: float) -> bool:
	var claim: ClaimMask.Claim = sector.claims.claim_at(world_x, world_z)
	if claim == null or claim.kind != &"settlement":
		return false
	var dist: float = Vector2(world_x, world_z).distance_to(claim.center)
	var built_r: float = claim.built_radius
	if built_r <= 0.0:
		built_r = claim.radius * 0.36
		for tier in range(VillageTier.Tier.PORT + 1):
			if is_equal_approx(claim.radius, VillageTier.claim_radius(tier)):
				built_r = VillageTier.built_radius(tier)
				break
	return dist >= built_r + 2.0 and dist <= claim.radius * 0.92


## Soft 0–1 habitat score. Zero when [method may_stand] fails.
static func suitability(
	spec: FaunaCatalog.FaunaSpec,
	sector: WorldSector,
	continental: ContinentalTerrain,
	world_x: float,
	world_z: float
) -> float:
	if not may_stand(spec, sector, continental, world_x, world_z):
		return 0.0
	var biome: int = sector.biome_at(world_x, world_z)
	assert(biome >= 0 and biome < spec.biome_weight.size(), "Biome index out of range")
	var weight: float = spec.biome_weight[biome]
	if weight <= 0.0:
		return 0.0
	var moisture: float = continental.moisture_at(world_x, world_z)
	var relief: float = continental.relief_amp_at(world_x, world_z)
	var score: float = weight
	# Grazers prefer moderate moisture; predators tolerate drier ridges.
	if spec.is_prey():
		score *= clampf(0.45 + moisture * 0.7, 0.2, 1.15)
		score *= clampf(1.1 - relief * 0.35, 0.35, 1.15)
	elif spec.is_predator():
		score *= clampf(0.55 + (1.0 - moisture) * 0.35 + relief * 0.25, 0.25, 1.2)
	var road: float = WorldQuery.road_clearance(sector, world_x, world_z)
	if road < spec.clearance_road * 2.0:
		score *= 0.35
	var claim_depth: float = sector.claims.reservation_depth(world_x, world_z)
	if claim_depth > 0.0 and spec.wilderness_spawn:
		score *= 1.0 - claim_depth
	if spec.role == &"livestock":
		# Prefer mid-annulus pasture, not the claim rim.
		var claim: ClaimMask.Claim = sector.claims.claim_at(world_x, world_z)
		if claim != null and claim.radius > 0.0:
			var t: float = Vector2(world_x, world_z).distance_to(claim.center) / claim.radius
			score *= clampf(1.15 - absf(t - 0.55) * 1.6, 0.25, 1.15)
	return clampf(score * spec.density, 0.0, 1.0)


static func _macro_normal(continental: ContinentalTerrain, world_x: float, world_z: float) -> Vector3:
	var step: float = 4.0
	var h_l: float = continental.height_at(world_x - step, world_z)
	var h_r: float = continental.height_at(world_x + step, world_z)
	var h_d: float = continental.height_at(world_x, world_z - step)
	var h_u: float = continental.height_at(world_x, world_z + step)
	var n: Vector3 = Vector3(h_l - h_r, step * 2.0, h_d - h_u)
	if n.length_squared() < 1e-8:
		return Vector3.UP
	return n.normalized()
