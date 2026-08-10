extends SceneTree
## Headless farm / settlement-fringe checks.
##
##   godot --headless --path <project> --script res://tools/tests/farm_tests.gd

const ATLAS_SIZE: int = 64

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	print("=== Orrun farm tests ===")
	VillageCatalog.load_catalog()
	FarmCatalog.load_catalog()
	_check("farm catalog non-empty", FarmCatalog.all_specs().size() >= 18, str(FarmCatalog.all_specs().size()))
	_check("Wheat_Crop present", FarmCatalog.has_id(&"Wheat_Crop"), "")
	_check("Barn is farm building", FarmCatalog.spec_for(&"Barn").is_farm_building(), "")
	_check("Wheat is crop", FarmCatalog.spec_for(&"Wheat_Crop").is_crop(), "")
	_check("mesh_scale positive", FarmCatalog.mesh_scale() > 0.0, str(FarmCatalog.mesh_scale()))

	FaunaCatalog.load_catalog()
	var livestock: Array[FaunaCatalog.FaunaSpec] = FaunaCatalog.livestock_specs()
	_check("livestock specs exist", livestock.size() >= 3, str(livestock.size()))
	for spec in livestock:
		_check(
			"%s wilderness_spawn false" % String(spec.id),
			not spec.wilderness_spawn,
			""
		)
		_check("%s density > 0" % String(spec.id), spec.density > 0.0, str(spec.density))

	var config: WorldConfig = WorldConfig.new()
	config.atlas_size = ATLAS_SIZE
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var settlement: AtlasGraphNode = null
	for node_variant in atlas.nodes:
		var node: AtlasGraphNode = node_variant
		if node.kind == AtlasFeatures.NodeKind.SETTLEMENT:
			settlement = node
			break
	_check("atlas has settlement", settlement != null, "")
	if settlement == null:
		_finish()
		return

	var centre: Vector2 = atlas.continental_centre(settlement.ax, settlement.az)
	var sector: WorldSector = WorldSector.generate(
		context, WorldCoords.sector_of(centre.x, centre.y)
	)
	var pack: Vector2 = _dry_stand(sector, centre)
	_check("dry stand", pack != Vector2.ZERO, "")

	var village_area: VillageDecorator.Area = VillageDecorator.Area.new()
	village_area.centre = pack
	village_area.tier = VillageTier.Tier.VILLAGE
	village_area.settlement_id = 910001
	village_area.claim_radius = VillageTier.claim_radius(VillageTier.Tier.VILLAGE)
	var plaza: Vector2 = VillageDecorator.resolve_plaza(
		village_area, sector.terrain, sector.hydro,
		RandomNumberGenerator.new()
	)
	village_area.centre = plaza

	var plan_area: SettlementPlanner.Area = SettlementPlanner.Area.new()
	plan_area.centre = plaza
	plan_area.tier = VillageTier.Tier.VILLAGE
	plan_area.settlement_id = 910001
	plan_area.claim_radius = village_area.claim_radius
	var empty_paths: PathNetwork = PathNetwork.new()
	empty_paths.terrain = sector.terrain
	empty_paths.hydro = sector.hydro
	empty_paths.config = config
	empty_paths.roads = []
	empty_paths.road_index = SpatialIndex2D.new(160.0)
	var planned: SettlementPlanner.Plan = SettlementPlanner.plan(
		plan_area, sector.terrain, sector.hydro, empty_paths
	)
	_check("village plan has holdings", planned.holdings.size() >= 8, str(planned.holdings.size()))
	_check("village plan has a primary street lane", planned.lanes.size() >= 1, str(planned.lanes.size()))
	if planned.lanes.size() >= 1:
		var street: PackedVector2Array = planned.lanes[0]
		_check("primary street has two endpoints", street.size() == 2, str(street.size()))
	_check("village plan OBB clear", not planned.occupancy.any_obb_overlap(), "")

	var crops := 0
	var buildings := 0
	var field_outside := 0
	var field_total := 0
	for site in planned.sites:
		if not FarmCatalog.has_id(site.catalog_id):
			continue
		var spec: FarmCatalog.Spec = FarmCatalog.spec_for(site.catalog_id)
		if spec.is_crop():
			crops += 1
		if spec.is_farm_building():
			buildings += 1
		# Croft gardens sit inside the envelope on purpose; score open-field + barns.
		var d: float = Vector2(site.world_x, site.world_z).distance_to(planned.plaza)
		if spec.is_farm_building() or (
			spec.is_crop() and d >= planned.built_envelope * 0.85
		):
			field_total += 1
			if d >= planned.built_envelope:
				field_outside += 1
	_check("village farm has crops", crops >= 6, str(crops))
	_check("village farm has a building", buildings >= 1, str(buildings))
	_check(
		"open-field / barns sit outside street rows",
		field_total == 0 or field_outside >= int(float(field_total) * 0.5),
		"%d/%d" % [field_outside, field_total]
	)

	var hamlet_area: SettlementPlanner.Area = SettlementPlanner.Area.new()
	hamlet_area.centre = plaza
	hamlet_area.tier = VillageTier.Tier.HAMLET
	hamlet_area.settlement_id = 910002
	hamlet_area.claim_radius = VillageTier.claim_radius(VillageTier.Tier.HAMLET)
	var hamlet_plan: SettlementPlanner.Plan = SettlementPlanner.plan(
		hamlet_area, sector.terrain, sector.hydro, empty_paths
	)
	var hamlet_big := 0
	for site in hamlet_plan.sites:
		if site.catalog_id == &"BigBarn" or site.catalog_id == &"TowerWindmill":
			hamlet_big += 1
	_check("hamlet excludes big/town farm buildings", hamlet_big == 0, str(hamlet_big))

	_finish()


func _dry_stand(sector: WorldSector, hint: Vector2) -> Vector2:
	if VillageDecorator._point_dry(
		hint.x, hint.y, 6.0, sector.terrain, sector.hydro, 64.0
	):
		return hint
	var origin: Vector2 = WorldCoords.sector_origin(sector.sector)
	var step: float = sector.config.macro_cell_size * 2.0
	for z in range(8, 40):
		for x in range(8, 40):
			var p: Vector2 = origin + Vector2((float(x) + 0.5) * step, (float(z) + 0.5) * step)
			if VillageDecorator._point_dry(
				p.x, p.y, 6.0, sector.terrain, sector.hydro, 64.0
			):
				return p
	return Vector2.ZERO


func _finish() -> void:
	print("=== %d checks, %d failures ===" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _check(label: String, ok: bool, detail: String) -> void:
	checks += 1
	if ok:
		print("  PASS  %s" % label)
	else:
		failures += 1
		if detail.is_empty():
			print("  FAIL  %s" % label)
		else:
			print("  FAIL  %s — %s" % [label, detail])
