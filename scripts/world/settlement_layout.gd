class_name SettlementLayout
extends RefCounted
## Settlements: atlas SETTLEMENT nodes get a tiered claim, then
## [SettlementPlanner] runs [HamletLabPlanner] and drapes market-ring lanes.

static func is_house(catalog_id: StringName) -> bool:
	if VillageCatalog.has_id(catalog_id) and VillageCatalog.needs_collision(catalog_id):
		return true
	if FarmCatalog.has_id(catalog_id) and FarmCatalog.needs_collision(catalog_id):
		return true
	return false


static func footprint_of(catalog_id: StringName) -> float:
	if VillageCatalog.has_id(catalog_id):
		return VillageCatalog.footprint_of(catalog_id)
	if FarmCatalog.has_id(catalog_id):
		return FarmCatalog.footprint_of(catalog_id)
	return 6.0


static func height_of(catalog_id: StringName) -> float:
	if VillageCatalog.has_id(catalog_id):
		return VillageCatalog.height_of(catalog_id)
	if FarmCatalog.has_id(catalog_id):
		return FarmCatalog.height_of(catalog_id)
	return 4.5


## Plaza stand point near the settlement closest to `hint_xz` (continental metres).
static func spawn_plaza_near(atlas: ContinentAtlas, hint_xz: Vector2) -> Vector2:
	var best_node: AtlasGraphNode = null
	var best_d: float = INF
	for node_variant in atlas.nodes:
		var node: AtlasGraphNode = node_variant
		if node.kind != AtlasFeatures.NodeKind.SETTLEMENT:
			continue
		var centre: Vector2 = atlas.continental_centre(node.ax, node.az)
		var d: float = centre.distance_squared_to(hint_xz)
		if d < best_d:
			best_d = d
			best_node = node
	if best_node == null:
		return hint_xz
	var centre: Vector2 = atlas.continental_centre(best_node.ax, best_node.az)
	var tier: int = VillageTier.from_atlas_node(atlas, best_node)
	var stand: float = VillageTier.plaza_radius(tier) * 0.65
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = int(hash("spawn_plaza:%.0f:%.0f" % [centre.x, centre.y])) & 0x7fffffff
	var angle: float = rng.randf() * TAU
	return centre + Vector2(cos(angle), sin(angle)) * stand


static func build(
	context: WorldContext,
	terrain: MacroTerrain,
	hydro: Hydrology,
	claims: ClaimMask,
	paths: PathNetwork,
	core: Rect2
) -> Array[HouseSite]:
	# Sector bake (including the spawn sector) can run before Main loads catalogs.
	if VillageCatalog.all_specs().is_empty():
		VillageCatalog.load_catalog()
	if FarmCatalog.all_specs().is_empty():
		FarmCatalog.load_catalog()
	var out: Array[HouseSite] = []
	var atlas: ContinentAtlas = context.atlas
	for node_variant in atlas.nodes:
		var node: AtlasGraphNode = node_variant
		if node.kind != AtlasFeatures.NodeKind.SETTLEMENT:
			continue
		var centre: Vector2 = atlas.continental_centre(node.ax, node.az)
		if not core.has_point(centre):
			continue
		var tier: int = VillageTier.from_atlas_node(atlas, node)
		var claim_r: float = VillageTier.claim_radius(tier)
		var area: SettlementPlanner.Area = SettlementPlanner.Area.new()
		area.centre = centre
		area.tier = tier
		area.settlement_id = node.id
		area.claim_radius = claim_r
		var planned: SettlementPlanner.Plan = SettlementPlanner.plan(
			area, terrain, hydro, paths
		)
		var ground_z: float = terrain.height_at(planned.plaza.x, planned.plaza.y)
		claims.add(
			&"settlement",
			planned.plaza,
			claim_r,
			ground_z,
			planned.built_envelope
		)
		paths.append_settlement_lanes(planned.lanes, SettlementPlanner.LANE_HALF_WIDTH)
		out.append_array(planned.sites)
	return out
