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
	assert(false, "SettlementLayout.footprint_of: unknown id %s" % String(catalog_id))
	return 0.0


## Oriented local XZ metres for collision (door along ±Z). Village dwellings/civics
## use measured size_*; farm buildings use square footprint until measured.
static func collision_xz_of(catalog_id: StringName) -> Vector2:
	if VillageCatalog.has_id(catalog_id):
		var spec: VillageCatalog.Spec = VillageCatalog.spec_for(catalog_id)
		assert(
			spec.has_oriented_size(),
			"SettlementLayout.collision_xz_of: %s missing size_x/size_z" % String(catalog_id)
		)
		return Vector2(spec.size_x, spec.size_z)
	if FarmCatalog.has_id(catalog_id):
		var fp: float = FarmCatalog.footprint_of(catalog_id)
		return Vector2(fp, fp)
	assert(false, "SettlementLayout.collision_xz_of: unknown id %s" % String(catalog_id))
	return Vector2.ZERO


static func height_of(catalog_id: StringName) -> float:
	if VillageCatalog.has_id(catalog_id):
		return VillageCatalog.height_of(catalog_id)
	if FarmCatalog.has_id(catalog_id):
		return FarmCatalog.height_of(catalog_id)
	assert(false, "SettlementLayout.height_of: unknown id %s" % String(catalog_id))
	return 0.0


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
	assert(best_node != null, "SettlementLayout.spawn_plaza_near: no SETTLEMENT nodes")
	return _plaza_stand(atlas, best_node)


## Plaza stand at the largest settlement: PORT > TOWN > VILLAGE > HAMLET, then pop.
static func spawn_plaza_largest(atlas: ContinentAtlas) -> Vector2:
	var best_node: AtlasGraphNode = null
	var best_tier: int = -1
	var best_pop: int = -1
	for node_variant in atlas.nodes:
		var node: AtlasGraphNode = node_variant
		if node.kind != AtlasFeatures.NodeKind.SETTLEMENT:
			continue
		var tier: int = VillageTier.from_atlas_node(atlas, node)
		var pop: int = AtlasPack.population(atlas.cell_at(node.ax, node.az))
		if tier > best_tier or (tier == best_tier and pop > best_pop):
			best_tier = tier
			best_pop = pop
			best_node = node
		elif tier == best_tier and pop == best_pop and best_node != null:
			# Stable tie-break: lower atlas cell index wins.
			if node.cell < best_node.cell:
				best_node = node
	assert(best_node != null, "SettlementLayout.spawn_plaza_largest: no SETTLEMENT nodes")
	return _plaza_stand(atlas, best_node)


static func _plaza_stand(atlas: ContinentAtlas, node: AtlasGraphNode) -> Vector2:
	var centre: Vector2 = atlas.continental_centre(node.ax, node.az)
	var tier: int = VillageTier.from_atlas_node(atlas, node)
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
