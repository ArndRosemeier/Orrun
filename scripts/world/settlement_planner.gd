class_name SettlementPlanner
extends RefCounted
## Settlement planner for all tiers.
##
## Building placement is owned by [HamletLabPlanner] (2D marketplace lab).
## This type resolves a dry plaza, runs the lab, bridges to [HouseSite]s, and
## drapes market-ring lanes. Farms/crofts are deferred until the lab grows them.

const _LabBridge := preload("res://scripts/world/hamlet_lab_bridge.gd")
const _LabPlanner := preload("res://scripts/debug/hamlet_lab_planner.gd")
const PLACE_ATTEMPTS: int = 120
## Legacy street-row alley; lab wall-share uses 0 inflate (flush faces).
const ALLEY_BUILDING: float = 0.85
## Post-lab OBB check: lab stamps exact footprints (wall-share is flush).
const LAB_BUILDING_MARGIN: float = 0.0
const ALLEY_PROP: float = 0.55
const ALLEY_CROP: float = 0.3
const LANE_HALF_WIDTH: float = 2.0
const LANE_BUILDING_MARGIN: float = 0.6
## Distance from street centreline to house centre (must clear facing OBB depth).
const STREET_SETBACK: float = 8.5
## Side-by-side packing uses a fraction of catalog footprint so rows read dense.
const PACK_WIDTH_SCALE: float = 0.72
## Depth toward street kept short so opposite rows do not collide through the road.
const BUILDING_DEPTH_SCALE: float = 0.55

static var DWELLING_MIN: PackedInt32Array = PackedInt32Array([6, 20, 100, 500])
static var DWELLING_MAX: PackedInt32Array = PackedInt32Array([15, 80, 400, 2000])
static var PROP_BUDGET: PackedInt32Array = PackedInt32Array([4, 8, 14, 22])
static var FARM_BUILDING_MIN: PackedInt32Array = PackedInt32Array([1, 1, 2, 3])
static var FARM_BUILDING_MAX: PackedInt32Array = PackedInt32Array([1, 2, 3, 4])
static var CROFT_CROP_BUDGET: PackedInt32Array = PackedInt32Array([10, 18, 28, 40])
static var FIELD_CROP_BUDGET: PackedInt32Array = PackedInt32Array([24, 48, 80, 120])
static var CROFT_HALF_L: PackedFloat32Array = PackedFloat32Array([6.0, 8.0, 10.0, 12.0])
static var CROFT_HALF_W: PackedFloat32Array = PackedFloat32Array([2.8, 3.2, 3.6, 4.0])
## Half-length of the primary street from the commons (metres).
static var STREET_HALF_LEN: PackedFloat32Array = PackedFloat32Array([38.0, 55.0, 78.0, 100.0])

static var CIVIC_BY_TIER: Array = [
	[&"Well"],
	[&"Well", &"MarketStand_1"],
	[&"Well", &"Inn", &"Blacksmith", &"Sawmill", &"Stable", &"Gazebo"],
	[&"Well", &"Inn", &"Blacksmith", &"Mill", &"Sawmill", &"Stable", &"Bell_Tower", &"Gazebo"],
]


class Area extends RefCounted:
	var centre: Vector2 = Vector2.ZERO
	var tier: int = VillageTier.Tier.HAMLET
	var settlement_id: int = 0
	var claim_radius: float = 90.0
	## Optional lab dwelling overrides (−1 = use HamletLabConfig tier defaults).
	var lab_dwelling_min: int = -1
	var lab_dwelling_max: int = -1


class Plan extends RefCounted:
	var plaza: Vector2 = Vector2.ZERO
	var tier: int = VillageTier.Tier.HAMLET
	var built_envelope: float = 32.0
	var street_along: Vector2 = Vector2.RIGHT
	var street_across: Vector2 = Vector2.UP
	var street_half_len: float = 38.0
	var sites: Array[HouseSite] = []
	var holdings: Array[SettlementHolding] = []
	var lanes: Array[PackedVector2Array] = []
	var occupancy: SettlementOccupancy = SettlementOccupancy.new()


static func plan(
	area: Area,
	terrain: MacroTerrain,
	hydro: Hydrology,
	paths: PathNetwork
) -> Plan:
	assert(VillageCatalog.has_id(&"House_1"), "VillageCatalog.load_catalog must run first")
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = int(hash("settlement_planner:%d" % area.settlement_id)) & 0x7fffffff

	var out: Plan = Plan.new()
	out.tier = area.tier
	var plaza_area: VillageDecorator.Area = VillageDecorator.Area.new()
	plaza_area.centre = area.centre
	plaza_area.tier = area.tier
	plaza_area.settlement_id = area.settlement_id
	plaza_area.claim_radius = area.claim_radius
	out.plaza = VillageDecorator.resolve_plaza(plaza_area, terrain, hydro, rng)
	out.street_half_len = STREET_HALF_LEN[area.tier]
	out.occupancy = SettlementOccupancy.new()
	for road in paths.roads:
		if road.is_trunk:
			out.occupancy.add_road_edge(road, 0.25)

	var lab_cfg: HamletLabConfig = _LabBridge.config_for(area.tier, area.settlement_id)
	if area.lab_dwelling_min >= 0:
		lab_cfg.dwelling_min = area.lab_dwelling_min
	if area.lab_dwelling_max >= 0:
		lab_cfg.dwelling_max = area.lab_dwelling_max
	# Keep the pack inside the wilderness claim.
	lab_cfg.max_settle_radius = minf(
		lab_cfg.max_settle_radius, maxf(area.claim_radius - 12.0, lab_cfg.market_radius + 24.0)
	)
	var lab: HamletLabPlanner.Plan2D = _LabPlanner.plan(lab_cfg)
	out.sites = _LabBridge.to_house_sites(lab, out.plaza)
	out.lanes = _LabBridge.market_lanes(lab, out.plaza)
	out.built_envelope = maxf(lab.built_envelope, VillageTier.built_radius(area.tier))
	out.street_along = Vector2.RIGHT
	out.street_across = Vector2.UP

	for site in out.sites:
		if VillageCatalog.has_id(site.catalog_id):
			var role: StringName = VillageCatalog.spec_for(site.catalog_id).role
			if role == &"dwelling" or role == &"civic":
				_LabBridge.add_oriented_site(out.occupancy, site, LAB_BUILDING_MARGIN)

	if _building_obb_overlap(out):
		push_error(
			"SettlementPlanner: building OBB overlap left in settlement %d after lab plan"
			% area.settlement_id
		)
	return out


static func _building_obb_overlap(plan: Plan) -> bool:
	var occ: SettlementOccupancy = SettlementOccupancy.new()
	for site in plan.sites:
		if not VillageCatalog.has_id(site.catalog_id):
			continue
		var role: StringName = VillageCatalog.spec_for(site.catalog_id).role
		if role != &"dwelling" and role != &"civic":
			continue
		if not _LabBridge.fits_oriented_site(occ, site, LAB_BUILDING_MARGIN):
			return true
		_LabBridge.add_oriented_site(occ, site, LAB_BUILDING_MARGIN)
	return false


static func _choose_street_axis(
	area: Area,
	plan: Plan,
	paths: PathNetwork,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	var hitch: Vector2 = _nearest_trunk_point(paths, plan.plaza, area.claim_radius * 0.9)
	var along: Vector2
	if hitch != Vector2.ZERO:
		along = (hitch - plan.plaza).normalized()
	else:
		# Prefer the axis with the most standable street-row pads.
		var best_along: Vector2 = Vector2.RIGHT.rotated(rng.randf() * TAU)
		var best_score: float = -INF
		for i in 12:
			var candidate: Vector2 = Vector2.RIGHT.rotated(TAU * float(i) / 12.0 + rng.randf() * 0.1)
			var across: Vector2 = Vector2(-candidate.y, candidate.x)
			var score: float = 0.0
			for street_sign in [-1.0, 1.0]:
				for side in [-1.0, 1.0]:
					for k in 6:
						var t: float = 5.0 + float(k) * 5.5
						var p: Vector2 = (
							plan.plaza
							+ candidate * (t * street_sign)
							+ across * (STREET_SETBACK * side)
						)
						if _street_pad_ok(p, 8.0, terrain, hydro):
							score += 1.0
			if score > best_score:
				best_score = score
				best_along = candidate
		along = best_along
	if along.length_squared() < 1e-6:
		along = Vector2.RIGHT
	plan.street_along = along.normalized()
	plan.street_across = Vector2(-plan.street_along.y, plan.street_along.x)


static func _reserve_street_corridor(plan: Plan) -> void:
	var a: Vector2 = plan.plaza - plan.street_along * plan.street_half_len
	var b: Vector2 = plan.plaza + plan.street_along * plan.street_half_len
	plan.occupancy.add_polyline(
		PackedVector2Array([a, b]), LANE_HALF_WIDTH + LANE_BUILDING_MARGIN
	)


static func _place_seed_civic(
	area: Area,
	plan: Plan,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	if not VillageCatalog.has_id(&"Well"):
		return
	var required: bool = area.tier >= VillageTier.Tier.VILLAGE
	# Well on the commons — along-street pocket, clear of house setbacks.
	var footprint: float = VillageCatalog.footprint_of(&"Well")
	var site: HouseSite = null
	for attempt in 16:
		var along_off: float = rng.randf_range(-3.5, 3.5)
		var across_off: float = rng.randf_range(1.2, 2.6) * (1.0 if (attempt % 2) == 0 else -1.0)
		var pos: Vector2 = plan.plaza + plan.street_along * along_off + plan.street_across * across_off
		var yaw: float = _yaw_toward(pos, plan.plaza)
		var candidate: HouseSite = _make_site(&"Well", pos, yaw, footprint, 0.2)
		if not plan.occupancy.fits_site(candidate, ALLEY_BUILDING, BUILDING_DEPTH_SCALE, true):
			continue
		if not _street_pad_ok(pos, footprint, terrain, hydro):
			continue
		site = candidate
		break
	if site != null:
		plan.sites.append(site)
		plan.occupancy.add_site(site, ALLEY_BUILDING, BUILDING_DEPTH_SCALE)
	elif required:
		push_warning(
			"SettlementPlanner: Well missing at settlement %d (commons pad scarce)"
			% area.settlement_id
		)


static func _grow_street_rows(
	area: Area,
	plan: Plan,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	var dwellings: Array[StringName] = VillageCatalog.ids_with_role(&"dwelling", area.tier)
	assert(not dwellings.is_empty(), "No dwelling meshes in village catalog")
	dwellings.sort_custom(
		func(a: StringName, b: StringName) -> bool:
			return VillageCatalog.footprint_of(a) < VillageCatalog.footprint_of(b)
	)
	var want: int = rng.randi_range(DWELLING_MIN[area.tier], DWELLING_MAX[area.tier])
	var croft_l: float = CROFT_HALF_L[area.tier]
	var croft_w: float = CROFT_HALF_W[area.tier]

	## Next free street parameter per lane: +L +R -L -R
	var cursor: PackedFloat32Array = PackedFloat32Array([3.0, 3.0, 3.0, 3.0])
	var placed_n: int = 0
	var lane_i: int = 0
	var stalls: int = 0
	while placed_n < want and stalls < want * 8:
		var lane: int = lane_i % 4
		lane_i += 1
		var street_sign: float = 1.0 if lane < 2 else -1.0
		var sign: float = -1.0 if (lane % 2) == 0 else 1.0
		var catalog_id: StringName = dwellings[placed_n % dwellings.size()]
		if rng.randf() < 0.35:
			catalog_id = dwellings[rng.randi() % dwellings.size()]
		var footprint: float = VillageCatalog.footprint_of(catalog_id)
		var pack_w: float = maxf(footprint * PACK_WIDTH_SCALE, 6.0)
		var accepted: bool = false
		var final_site: HouseSite = null
		var final_pos: Vector2 = Vector2.ZERO
		var t_used: float = cursor[lane]
		var scan_t: float = cursor[lane]
		while scan_t + pack_w * 0.5 <= plan.street_half_len:
			var try_pos: Vector2 = (
				plan.plaza
				+ plan.street_along * (scan_t * street_sign)
				+ plan.street_across * (STREET_SETBACK * sign)
			)
			var try_yaw: float = _yaw_toward(try_pos, try_pos - plan.street_across * sign)
			var try_site: HouseSite = _make_site(catalog_id, try_pos, try_yaw, footprint, 0.2)
			scan_t += 1.5
			if not plan.occupancy.fits_site(try_site, ALLEY_BUILDING, BUILDING_DEPTH_SCALE, true):
				continue
			if not _street_pad_ok(try_pos, footprint, terrain, hydro):
				continue
			accepted = true
			final_site = try_site
			final_pos = try_pos
			t_used = scan_t - 1.5
			break
		if not accepted:
			cursor[lane] = plan.street_half_len + 1.0
			stalls += 1
			continue

		var holding: SettlementHolding = SettlementHolding.new()
		holding.house = final_site
		holding.frontage = final_pos - plan.street_across * sign * (footprint * 0.35)
		holding.croft_yaw = atan2(plan.street_across.x * sign, plan.street_across.y * sign)
		holding.croft_half_w = minf(croft_w, pack_w * 0.45)
		holding.croft_half_l = croft_l
		holding.croft_center = (
			final_pos + plan.street_across * sign * (footprint * 0.45 + croft_l * 0.9)
		)
		var len_try: float = croft_l
		while len_try >= 3.0:
			var cc: Vector2 = (
				final_pos + plan.street_across * sign * (footprint * 0.45 + len_try * 0.9)
			)
			if VillageDecorator._point_dry(cc.x, cc.y, holding.croft_half_w * 0.4, terrain, hydro, 40.0):
				holding.croft_center = cc
				holding.croft_half_l = len_try
				break
			len_try -= 1.5
		if len_try < 3.0:
			holding.croft_half_l = 3.0
			holding.croft_center = final_pos + plan.street_across * sign * (footprint * 0.7)

		plan.sites.append(final_site)
		plan.holdings.append(holding)
		plan.occupancy.add_site(final_site, ALLEY_BUILDING, BUILDING_DEPTH_SCALE)
		cursor[lane] = t_used + pack_w * 0.5 + ALLEY_BUILDING
		placed_n += 1
		stalls = 0

	var max_d: float = VillageTier.plaza_radius(area.tier)
	for holding in plan.holdings:
		max_d = maxf(
			max_d,
			Vector2(holding.house.world_x, holding.house.world_z).distance_to(plan.plaza)
		)
		max_d = maxf(max_d, holding.rear_midpoint().distance_to(plan.plaza))
	plan.built_envelope = maxf(max_d + 3.0, STREET_SETBACK + CROFT_HALF_L[area.tier] + 6.0)

	var want_min: int = DWELLING_MIN[area.tier]
	if plan.holdings.size() < maxi(want_min / 2, 3) and area.tier >= VillageTier.Tier.TOWN:
		push_warning(
			"SettlementPlanner: settlement %d tier %s placed %d/%d street holdings"
			% [
				area.settlement_id,
				VillageTier.name_of(area.tier),
				plan.holdings.size(),
				want_min,
			]
		)


## Street tofts only need a dry stand — full corner relief rejects too many real pads.
static func _street_pad_ok(
	pos: Vector2, footprint: float, terrain: MacroTerrain, hydro: Hydrology
) -> bool:
	if not VillageDecorator._point_dry(pos.x, pos.y, footprint * 0.25, terrain, hydro, 48.0):
		return false
	var step: float = footprint * 0.28
	var h0: float = terrain.height_at(pos.x, pos.y)
	for ox in [-step, step]:
		for oz in [-step, step]:
			if not VillageDecorator._point_dry(
				pos.x + ox, pos.y + oz, 0.0, terrain, hydro, 40.0
			):
				return false
			if absf(terrain.height_at(pos.x + ox, pos.y + oz) - h0) > 2.4:
				return false
	return true


static func _derive_lanes(area: Area, plan: Plan, paths: PathNetwork) -> void:
	plan.lanes.clear()
	# Primary street — the only road the eye should read as the hamlet spine.
	var street_a: Vector2 = plan.plaza - plan.street_along * plan.street_half_len
	var street_b: Vector2 = plan.plaza + plan.street_along * plan.street_half_len
	# Trim street to the outermost occupied frontage so it does not run into empty grass.
	var min_t: float = 0.0
	var max_t: float = 0.0
	for holding in plan.holdings:
		var t: float = (holding.frontage - plan.plaza).dot(plan.street_along)
		min_t = minf(min_t, t)
		max_t = maxf(max_t, t)
	if plan.holdings.is_empty():
		min_t = -12.0
		max_t = 12.0
	else:
		min_t -= 6.0
		max_t += 6.0
	street_a = plan.plaza + plan.street_along * min_t
	street_b = plan.plaza + plan.street_along * max_t
	plan.lanes.append(PackedVector2Array([street_a, street_b]))

	# Back lanes: one per side, chaining croft rears that share a side.
	for sign in [-1.0, 1.0]:
		var rears: Array[Vector2] = []
		for holding in plan.holdings:
			var side: float = (holding.house.world_x - plan.plaza.x) * plan.street_across.x
			side += (holding.house.world_z - plan.plaza.y) * plan.street_across.y
			if sign < 0.0 and side > 0.0:
				continue
			if sign > 0.0 and side < 0.0:
				continue
			rears.append(holding.rear_midpoint())
		if rears.size() < 2:
			continue
		rears.sort_custom(
			func(a: Vector2, b: Vector2) -> bool:
				return (a - plan.plaza).dot(plan.street_along) < (b - plan.plaza).dot(plan.street_along)
		)
		var poly: PackedVector2Array = PackedVector2Array()
		for p in rears:
			poly.append(p)
		plan.lanes.append(poly)

	var hitch: Vector2 = _nearest_trunk_point(paths, plan.plaza, area.claim_radius * 0.95)
	if hitch != Vector2.ZERO:
		# Hitch from the nearer street end, not a random plaza spur.
		var end_a: Vector2 = street_a
		var end_b: Vector2 = street_b
		var end: Vector2 = end_a if end_a.distance_to(hitch) < end_b.distance_to(hitch) else end_b
		plan.lanes.append(PackedVector2Array([end, hitch]))


static func _nearest_trunk_point(paths: PathNetwork, plaza: Vector2, max_r: float) -> Vector2:
	var best: Vector2 = Vector2.ZERO
	var best_d: float = max_r
	for road in paths.roads:
		if not road.is_trunk:
			continue
		for p in road.points:
			var q: Vector2 = Vector2(p.x, p.z)
			var d: float = q.distance_to(plaza)
			if d < best_d:
				best_d = d
				best = q
	return best


static func _place_remaining_civics(
	area: Area,
	plan: Plan,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	var menu: Array = CIVIC_BY_TIER[area.tier]
	for id_variant in menu:
		var catalog_id: StringName = id_variant
		if catalog_id == &"Well":
			continue
		if not VillageCatalog.has_id(catalog_id):
			continue
		if VillageCatalog.spec_for(catalog_id).min_tier > area.tier:
			continue
		# Prefer street-front slots near the commons (high traffic).
		var site: HouseSite = null
		for attempt in 24:
			var side_sign: float = -1.0 if (attempt % 2) == 0 else 1.0
			var t: float = rng.randf_range(4.0, minf(18.0 + float(area.tier) * 4.0, plan.street_half_len * 0.55))
			if attempt >= 12:
				t = -t
			var pos: Vector2 = (
				plan.plaza
				+ plan.street_along * t
				+ plan.street_across * (STREET_SETBACK * side_sign)
			)
			var yaw: float = _yaw_toward(pos, pos - plan.street_across * side_sign)
			var footprint: float = VillageCatalog.footprint_of(catalog_id)
			var candidate: HouseSite = _make_site(catalog_id, pos, yaw, footprint, 0.2)
			if not plan.occupancy.fits_site(candidate, ALLEY_BUILDING, BUILDING_DEPTH_SCALE, true):
				continue
			if not VillageDecorator._footprint_buildable(pos, footprint, yaw, terrain, hydro):
				continue
			site = candidate
			break
		if site == null:
			site = _try_place_near(
				plan,
				plan.plaza,
				catalog_id,
				STREET_SETBACK,
				plan.built_envelope * 0.7,
				terrain,
				hydro,
				rng,
				0.2,
				ALLEY_BUILDING,
				true
			)
		if site != null:
			plan.sites.append(site)
			plan.occupancy.add_site(site, ALLEY_BUILDING, BUILDING_DEPTH_SCALE)


static func _place_croft_gardens(
	area: Area,
	plan: Plan,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	var garden_crops: Array[StringName] = []
	for id in [&"Carrot_Crop", &"Lettuce_Crop", &"Beet_Crop", &"Tomato_Crop"]:
		if FarmCatalog.has_id(id) and FarmCatalog.spec_for(id).min_tier <= area.tier:
			garden_crops.append(id)
	if garden_crops.is_empty():
		return
	var budget: int = CROFT_CROP_BUDGET[area.tier]
	var placed_n: int = 0
	for holding in plan.holdings:
		if placed_n >= budget:
			break
		var per: int = maxi(budget / maxi(plan.holdings.size(), 1), 2)
		for _i in per:
			if placed_n >= budget:
				break
			var crop_id: StringName = garden_crops[rng.randi() % garden_crops.size()]
			var local: Vector2 = Vector2(
				rng.randf_range(-holding.croft_half_w * 0.65, holding.croft_half_w * 0.65),
				rng.randf_range(-holding.croft_half_l * 0.5, holding.croft_half_l * 0.5)
			)
			var basis_x: Vector2 = Vector2(cos(holding.croft_yaw), -sin(holding.croft_yaw))
			var basis_z: Vector2 = Vector2(sin(holding.croft_yaw), cos(holding.croft_yaw))
			var pos: Vector2 = holding.croft_center + basis_x * local.x + basis_z * local.y
			var site: HouseSite = _try_accept_farm(
				plan, pos, crop_id, terrain, hydro, 0.05, ALLEY_CROP, 0.65
			)
			if site != null:
				plan.sites.append(site)
				plan.occupancy.add_site(site, ALLEY_CROP, 0.65)
				placed_n += 1


static func _place_croft_fences(
	area: Area,
	plan: Plan,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	## One short fence on the rear of some crofts — property edge, not scatter.
	if not FarmCatalog.has_id(&"FarmFence"):
		return
	var fence_id: StringName = &"FarmFence"
	var max_fences: int = mini(plan.holdings.size(), 2 + area.tier * 2)
	var placed_n: int = 0
	for holding in plan.holdings:
		if placed_n >= max_fences:
			break
		if rng.randf() > 0.55:
			continue
		var pos: Vector2 = holding.rear_midpoint()
		var yaw: float = holding.croft_yaw + PI * 0.5
		var site: HouseSite = _make_site(fence_id, pos, yaw, 4.0, 0.05)
		if not plan.occupancy.fits_site(site, ALLEY_PROP, 0.4, true):
			continue
		if not VillageDecorator._point_dry(pos.x, pos.y, 1.0, terrain, hydro, 32.0):
			continue
		plan.sites.append(site)
		plan.occupancy.add_site(site, ALLEY_PROP, 0.4)
		placed_n += 1


static func _place_open_fields(
	area: Area,
	plan: Plan,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	var crops: Array[StringName] = FarmCatalog.ids_with_role(&"crop", area.tier)
	if crops.is_empty():
		return
	var budget: int = FIELD_CROP_BUDGET[area.tier]
	var ring0: float = plan.built_envelope + 4.0
	var ring1: float = area.claim_radius * 0.88
	var patches: int = clampi(2 + area.tier, 2, 6)
	var per: int = maxi(budget / patches, 6)
	for _p in patches:
		# Prefer field patches beyond croft ends (along across), not random ring.
		var sign: float = -1.0 if rng.randf() < 0.5 else 1.0
		var t: float = rng.randf_range(-plan.street_half_len * 0.7, plan.street_half_len * 0.7)
		var rad: float = rng.randf_range(ring0, minf(ring1, plan.built_envelope + 28.0))
		var patch: Vector2 = (
			plan.plaza
			+ plan.street_along * t
			+ plan.street_across * sign * rad
		)
		var crop_id: StringName = crops[rng.randi() % crops.size()]
		for _i in per:
			var jitter: Vector2 = (
				plan.street_along * rng.randf_range(-8.0, 8.0)
				+ plan.street_across * rng.randf_range(-4.0, 4.0)
			)
			var pos: Vector2 = patch + jitter
			if pos.distance_to(plan.plaza) < plan.built_envelope + 2.0:
				continue
			if pos.distance_to(plan.plaza) > area.claim_radius * 0.92:
				continue
			var site: HouseSite = _try_accept_farm(
				plan, pos, crop_id, terrain, hydro, 0.05, ALLEY_CROP, 0.65
			)
			if site != null:
				plan.sites.append(site)
				plan.occupancy.add_site(site, ALLEY_CROP, 0.65)


static func _place_farm_buildings(
	area: Area,
	plan: Plan,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	var menu: Array[StringName] = FarmCatalog.ids_with_role(&"farm_building", area.tier)
	if menu.is_empty():
		return
	var count: int = rng.randi_range(FARM_BUILDING_MIN[area.tier], FARM_BUILDING_MAX[area.tier])
	for _i in count:
		var catalog_id: StringName = menu[rng.randi() % menu.size()]
		var anchor: Vector2 = plan.plaza + plan.street_across * (plan.built_envelope + 8.0)
		if not plan.holdings.is_empty():
			var host: SettlementHolding = plan.holdings[rng.randi() % plan.holdings.size()]
			var side: float = (Vector2(host.house.world_x, host.house.world_z) - plan.plaza).dot(
				plan.street_across
			)
			var outward: float = 1.0 if side >= 0.0 else -1.0
			anchor = host.rear_midpoint() + plan.street_across * outward * 6.0
		var site: HouseSite = _try_place_near(
			plan,
			anchor,
			catalog_id,
			4.0,
			18.0,
			terrain,
			hydro,
			rng,
			0.2,
			ALLEY_BUILDING,
			false,
			true
		)
		if site == null:
			site = _try_place_near(
				plan,
				plan.plaza,
				catalog_id,
				plan.built_envelope + 4.0,
				minf(area.claim_radius * 0.5, plan.built_envelope + 36.0),
				terrain,
				hydro,
				rng,
				0.2,
				ALLEY_BUILDING,
				false,
				true
			)
		if site != null:
			plan.sites.append(site)
			plan.occupancy.add_site(site, ALLEY_BUILDING, BUILDING_DEPTH_SCALE)


static func _place_props(
	area: Area,
	plan: Plan,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator
) -> void:
	var props: Array[StringName] = VillageCatalog.ids_with_role(&"prop", area.tier)
	if props.is_empty():
		return
	# Strip fence-like village props from loose scatter; croft fences handle edges.
	var usable: Array[StringName] = []
	for id in props:
		var name: String = String(id)
		if name.begins_with("Fence") or name.begins_with("Path_"):
			continue
		usable.append(id)
	if usable.is_empty():
		return
	var budget: int = PROP_BUDGET[area.tier]
	for _i in budget:
		var catalog_id: StringName = usable[rng.randi() % usable.size()]
		# Only in the street/commons pocket — never the field annulus.
		var site: HouseSite = _try_place_near(
			plan,
			plan.plaza,
			catalog_id,
			2.0,
			STREET_SETBACK + 6.0,
			terrain,
			hydro,
			rng,
			0.05,
			ALLEY_PROP,
			false,
			false,
			0.75
		)
		if site != null:
			plan.sites.append(site)
			plan.occupancy.add_site(site, ALLEY_PROP, 0.75)


static func _try_place_near(
	plan: Plan,
	anchor: Vector2,
	catalog_id: StringName,
	radius_min: float,
	radius_max: float,
	terrain: MacroTerrain,
	hydro: Hydrology,
	rng: RandomNumberGenerator,
	seat_sink: float,
	alley: float,
	prefer_cardinal: bool,
	from_farm: bool = false,
	depth_scale: float = 0.85
) -> HouseSite:
	var footprint: float = (
		FarmCatalog.footprint_of(catalog_id) if from_farm else VillageCatalog.footprint_of(catalog_id)
	)
	if from_farm and (catalog_id == &"FarmFence" or catalog_id == &"FarmFence2"):
		footprint = 4.0
	if radius_max < radius_min:
		radius_max = radius_min
	for attempt in PLACE_ATTEMPTS:
		var angle: float
		if prefer_cardinal and attempt < 4:
			angle = float(attempt) * TAU * 0.25 + rng.randf_range(-0.15, 0.15)
		else:
			angle = rng.randf() * TAU
		var radius: float = rng.randf_range(radius_min, radius_max)
		var pos: Vector2 = anchor + Vector2(cos(angle), sin(angle)) * radius
		var yaw: float = _yaw_toward(pos, plan.plaza)
		# Face street when close to it.
		var lateral: float = absf((pos - plan.plaza).dot(plan.street_across))
		if lateral < STREET_SETBACK + 8.0:
			var side: float = (pos - plan.plaza).dot(plan.street_across)
			var sign: float = 1.0 if side >= 0.0 else -1.0
			yaw = _yaw_toward(pos, pos - plan.street_across * sign)
		var site: HouseSite = _make_site(catalog_id, pos, yaw, footprint, seat_sink)
		var use_depth: float = BUILDING_DEPTH_SCALE if (
			(not from_farm and not VillageCatalog.spec_for(catalog_id).is_prop())
			or (from_farm and FarmCatalog.spec_for(catalog_id).is_farm_building())
		) else depth_scale
		if not plan.occupancy.fits_site(site, alley, use_depth, true):
			continue
		if (
			(not from_farm and VillageCatalog.spec_for(catalog_id).is_civic())
			or (from_farm and FarmCatalog.spec_for(catalog_id).is_farm_building())
		):
			if _conflicts_croft(
				plan, pos, footprint * 0.5, footprint * 0.42 * use_depth, yaw, alley
			):
				continue
		if not VillageDecorator._footprint_buildable(pos, footprint, yaw, terrain, hydro):
			continue
		return site
	return null


static func _try_accept_farm(
	plan: Plan,
	pos: Vector2,
	catalog_id: StringName,
	terrain: MacroTerrain,
	hydro: Hydrology,
	seat_sink: float,
	alley: float,
	depth_scale: float
) -> HouseSite:
	var footprint: float = FarmCatalog.footprint_of(catalog_id)
	var yaw: float = _yaw_toward(pos, plan.plaza)
	var site: HouseSite = _make_site(catalog_id, pos, yaw, footprint, seat_sink)
	if not plan.occupancy.fits_site(site, alley, depth_scale, true):
		return null
	if FarmCatalog.spec_for(catalog_id).is_crop():
		if not VillageDecorator._point_dry(
			pos.x, pos.y, footprint * 0.2, terrain, hydro, 48.0
		):
			return null
	elif not VillageDecorator._footprint_buildable(pos, footprint, yaw, terrain, hydro):
		return null
	return site


static func _make_site(
	catalog_id: StringName,
	pos: Vector2,
	yaw: float,
	footprint: float,
	seat_sink: float
) -> HouseSite:
	var site: HouseSite = HouseSite.new()
	site.catalog_id = catalog_id
	site.world_x = pos.x
	site.world_z = pos.y
	site.yaw = yaw
	site.footprint = footprint
	site.seat_sink = seat_sink
	return site


static func _yaw_toward(from: Vector2, toward: Vector2) -> float:
	var to: Vector2 = toward - from
	return atan2(to.x, -to.y)


static func _conflicts_croft(
	plan: Plan,
	center: Vector2,
	half_x: float,
	half_z: float,
	yaw: float,
	margin: float
) -> bool:
	var probe: SettlementOccupancy.Body = SettlementOccupancy.Body.new()
	probe.center = center
	probe.half_x = half_x
	probe.half_z = half_z
	probe.yaw = yaw
	probe.margin = margin
	for holding in plan.holdings:
		var croft: SettlementOccupancy.Body = SettlementOccupancy.Body.new()
		croft.center = holding.croft_center
		croft.half_x = holding.croft_half_w
		croft.half_z = holding.croft_half_l
		croft.yaw = holding.croft_yaw
		croft.margin = ALLEY_CROP
		if SettlementOccupancy._obb_overlap(probe, croft):
			return true
	return false
