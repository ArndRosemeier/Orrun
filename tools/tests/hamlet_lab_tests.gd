extends SceneTree


func _initialize() -> void:
	print("=== Hamlet lab catalog forms ===")
	VillageCatalog.load_catalog()
	var house1: VillageCatalog.Spec = VillageCatalog.spec_for(&"House_1")
	assert(house1.has_oriented_size(), "House_1 needs size_x/size_z")
	assert(VillageCatalog.spec_for(&"Bell_Tower").has_oriented_size())

	var cfg: HamletLabConfig = HamletLabConfig.new()
	cfg.apply_tier_defaults(0)
	cfg.seed = 1
	var plan: HamletLabPlanner.Plan2D = HamletLabPlanner.plan(cfg)
	print("hamlet dwellings=", plan.house_count, " civics=", plan.civic_count)
	assert(plan.house_count >= 3, "expected several dwellings")
	assert(plan.civic_count >= 1, "hamlet should place Well")
	assert(plan.market_sides == 6, "hamlet market should be hex")
	var saw_well := false
	for s in plan.shapes:
		if s.kind != HamletLabPlanner.Shape.Kind.HOUSE:
			continue
		assert(VillageCatalog.has_id(s.catalog_id), "unknown form %s" % String(s.catalog_id))
		var spec: VillageCatalog.Spec = VillageCatalog.spec_for(s.catalog_id)
		assert(is_equal_approx(s.half_size.x * 2.0, spec.size_x), "size_x mismatch")
		assert(is_equal_approx(s.half_size.y * 2.0, spec.size_z), "size_z mismatch")
		if s.catalog_id == &"Well":
			saw_well = true
		assert(spec.is_dwelling() or spec.is_civic(), "lab only places dwelling/civic")
	assert(saw_well, "Well missing")

	cfg.apply_tier_defaults(1)
	cfg.seed = 7
	cfg.dwelling_min = 20
	cfg.dwelling_max = 20
	plan = HamletLabPlanner.plan(cfg)
	print("village dwellings=", plan.house_count, " markets=", plan.markets.size())
	assert(plan.markets.size() == 1, "village has no secondary markets")
	assert(plan.house_count == 20, "village should fill dwellings")

	cfg.apply_tier_defaults(2)
	cfg.seed = 3
	cfg.dwelling_min = 30
	cfg.dwelling_max = 30
	plan = HamletLabPlanner.plan(cfg)
	print("town dwellings=", plan.house_count, " civics=", plan.civic_count, " markets=", plan.markets.size())
	assert(plan.markets.size() == 3, "town should have primary + 2 secondaries")
	assert(plan.house_count == 30, "town should place all dwellings")
	assert(plan.civic_count >= 4, "town should place several civics")

	cfg.apply_tier_defaults(3)
	cfg.seed = 5
	cfg.dwelling_min = 40
	cfg.dwelling_max = 40
	plan = HamletLabPlanner.plan(cfg)
	print("port dwellings=", plan.house_count, " civics=", plan.civic_count)
	var saw_tower := false
	for s in plan.shapes:
		if s.kind == HamletLabPlanner.Shape.Kind.HOUSE and s.catalog_id == &"Bell_Tower":
			saw_tower = true
	assert(saw_tower, "port should place Bell_Tower")
	assert(plan.house_count == 40, "port should place all dwellings")
	print("=== OK ===")
	quit(0)
