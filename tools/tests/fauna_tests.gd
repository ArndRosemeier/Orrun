extends SceneTree
## Headless fauna habitat / determinism / behaviour checks.
##
##   godot --headless --path <project> --script res://tools/tests/fauna_tests.gd

const ATLAS_SIZE: int = 64

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	print("=== Orrun fauna tests ===")
	var config: WorldConfig = WorldConfig.new()
	config.atlas_size = ATLAS_SIZE

	var specs: Array[FaunaCatalog.FaunaSpec] = FaunaCatalog.load_catalog()
	_check("catalog has 12 species", specs.size() == 12, "got %d" % specs.size())
	var wild: Array[FaunaCatalog.FaunaSpec] = FaunaCatalog.wilderness_specs()
	_check("wilderness species active", wild.size() >= 4, "got %d" % wild.size())
	for id in [&"deer", &"stag", &"wolf", &"fox", &"horse", &"horse_white"]:
		_check("wilderness includes %s" % String(id), FaunaCatalog.spec_for(id).wilderness_spawn, "")
	for id in [&"cow", &"bull", &"donkey", &"alpaca", &"husky", &"shiba"]:
		_check("settlement-only %s" % String(id), not FaunaCatalog.spec_for(id).wilderness_spawn, "")

	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var sector: WorldSector = WorldSector.generate(context, _pick_inland_sector(context))
	var continental: ContinentalTerrain = context.sampler()
	var deer: FaunaCatalog.FaunaSpec = FaunaCatalog.spec_for(&"deer")
	var wolf: FaunaCatalog.FaunaSpec = FaunaCatalog.spec_for(&"wolf")

	_test_habitat_rejects_water(deer, sector, continental)
	_test_habitat_rejects_road(deer, sector, continental)
	_test_suitability_positive_somewhere(deer, sector, continental)
	_test_place_seed_determinism(config)
	_test_agent_cap_constant(config)
	_test_flee_reaction(deer, wolf)

	print("=== %d checks, %d failures ===" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _test_habitat_rejects_water(
	spec: FaunaCatalog.FaunaSpec, sector: WorldSector, continental: ContinentalTerrain
) -> void:
	var found_wet: bool = false
	var origin: Vector2 = WorldCoords.sector_origin(sector.sector)
	var step: float = sector.config.macro_cell_size
	for z in range(0, 40):
		for x in range(0, 40):
			var wx: float = origin.x + (float(x) + 0.5) * step
			var wz: float = origin.y + (float(z) + 0.5) * step
			if WorldQuery.is_water(sector, continental, wx, wz):
				found_wet = true
				_check(
					"may_stand rejects water",
					not HabitatQuery.may_stand(spec, sector, continental, wx, wz),
					"%.0f,%.0f" % [wx, wz]
				)
				_check(
					"suitability zero on water",
					HabitatQuery.suitability(spec, sector, continental, wx, wz) == 0.0,
					"%.0f,%.0f" % [wx, wz]
				)
				return
	_check("found a wet sample in sector", found_wet, "sector %s" % sector.sector)


func _test_habitat_rejects_road(
	spec: FaunaCatalog.FaunaSpec, sector: WorldSector, continental: ContinentalTerrain
) -> void:
	var origin: Vector2 = WorldCoords.sector_origin(sector.sector)
	var step: float = sector.config.macro_cell_size
	for z in range(0, 60):
		for x in range(0, 60):
			var wx: float = origin.x + (float(x) + 0.5) * step
			var wz: float = origin.y + (float(z) + 0.5) * step
			if WorldQuery.road_clearance(sector, wx, wz) < 0.5:
				_check(
					"may_stand rejects road",
					not HabitatQuery.may_stand(spec, sector, continental, wx, wz),
					"%.0f,%.0f" % [wx, wz]
				)
				return
	print("  (skip road reject — no road sample in test sector)")


func _test_suitability_positive_somewhere(
	spec: FaunaCatalog.FaunaSpec, sector: WorldSector, continental: ContinentalTerrain
) -> void:
	var origin: Vector2 = WorldCoords.sector_origin(sector.sector)
	var step: float = sector.config.macro_cell_size * 2.0
	var best: float = 0.0
	for z in range(0, 30):
		for x in range(0, 30):
			var wx: float = origin.x + (float(x) + 0.5) * step
			var wz: float = origin.y + (float(z) + 0.5) * step
			best = maxf(best, HabitatQuery.suitability(spec, sector, continental, wx, wz))
	_check("deer suitability > 0 somewhere", best > 0.0, "best=%.3f" % best)


func _test_place_seed_determinism(config: WorldConfig) -> void:
	var cell: Vector2i = Vector2i(12, -7)
	var a: int = config.place_seed("fauna", cell)
	var b: int = config.place_seed("fauna", cell)
	_check("place_seed fauna stable", a == b, "%d vs %d" % [a, b])
	var other: int = config.place_seed("fauna", Vector2i(13, -7))
	_check("place_seed differs by cell", a != other, "%d vs %d" % [a, other])


func _test_agent_cap_constant(config: WorldConfig) -> void:
	_check("fauna_max_agents positive", config.fauna_max_agents > 0, str(config.fauna_max_agents))
	_check("fauna_max_agents capped", config.fauna_max_agents <= 128, str(config.fauna_max_agents))


func _test_flee_reaction(deer: FaunaCatalog.FaunaSpec, wolf: FaunaCatalog.FaunaSpec) -> void:
	# Lightweight state-machine check without streaming the world: prey enters
	# FLEE when a predator peer is within flee_radius.
	var sim: FaunaSim = FaunaSim.new()
	var prey: FaunaAgent = FaunaAgent.new()
	var predator: FaunaAgent = FaunaAgent.new()
	prey.spec = deer
	predator.spec = wolf
	prey.world_pos = Vector3(100.0, 10.0, 100.0)
	predator.world_pos = Vector3(110.0, 10.0, 100.0)
	prey.state = FaunaAgent.State.GRAZE
	# Assign private sim ref used by the brain (no mesh / origin needed here).
	prey.set("_sim", sim)
	prey.set("_waypoint", Vector2(100.0, 100.0))
	var peers: Array[FaunaAgent] = [prey, predator]
	prey.call("_tick_prey", 0.05, peers)
	_check("prey flees nearby wolf", prey.state == FaunaAgent.State.FLEE, prey.state_name())


func _pick_inland_sector(context: WorldContext) -> Vector2i:
	# Prefer a sector with both land and some hydrology so wet/road samples exist.
	var span: int = context.config.atlas_size
	var mid: int = span / 2
	var sector: Vector2i = Vector2i(mid / 8, mid / 8)
	if context.sector_in_atlas(sector):
		return sector
	return Vector2i(2, 2)


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
