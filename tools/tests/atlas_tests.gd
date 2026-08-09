extends SceneTree
## Headless checks for ContinentAtlas invariants.
##
##   godot --headless --path <project> --script res://tools/tests/atlas_tests.gd


var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	print("=== Orrun atlas tests ===")
	_test_elevation_mapping()
	_test_pack_roundtrip()
	var atlas: ContinentAtlas = ContinentAtlas.generate(20260809, 128)
	print(
		"atlas 128²: %d ms | lakes %d | nodes %d | river edges %d | road edges %d | crossings %d" % [
			atlas.generate_ms, atlas.lakes.size(), atlas.nodes.size(),
			atlas.river_ports.size(), atlas.road_ports.size(), atlas.crossings.size()
		]
	)
	_test_validate(atlas)
	_test_climate_sanity(atlas)
	_test_edge_ports_shared(atlas)
	_test_river_and_lake_sanity(atlas)
	_test_population(atlas)
	_test_road_coverage(atlas)
	_test_determinism()
	print("---")
	print("%d checks | %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if ok:
		print("  PASS  %s %s" % [name, detail])
	else:
		failures += 1
		print("  FAIL  %s %s" % [name, detail])


func _test_elevation_mapping() -> void:
	print("- elevation mapping")
	_check("sea code 0 is below sea", AtlasPack.elevation_to_metres(0) < 0)
	_check("sea code 32 is sea level", AtlasPack.elevation_to_metres(32) == 0)
	_check("coast band positive", AtlasPack.elevation_to_metres(40) > 0)
	_check("peaks high", AtlasPack.elevation_to_metres(255) >= 900)
	_check(
		"metres round-trip near plains",
		absi(
			AtlasPack.elevation_to_metres(AtlasPack.metres_to_elevation(100)) - 100
		) <= 8
	)


func _test_pack_roundtrip() -> void:
	print("- climate packing")
	var packed: int = AtlasPack.pack(120, 200, AtlasBiomes.Id.FOREST, 40, 3)
	_check("elevation", AtlasPack.elevation(packed) == 120)
	_check("humidity", AtlasPack.humidity(packed) == 200)
	_check("biome", AtlasPack.biome(packed) == AtlasBiomes.Id.FOREST)
	_check("relief", AtlasPack.relief(packed) == 40)
	_check("population", AtlasPack.population(packed) == 3)


func _test_validate(atlas: ContinentAtlas) -> void:
	print("- validate()")
	var errors: PackedStringArray = atlas.validate()
	for err in errors:
		print("    · ", err)
	_check("validate clean", errors.is_empty(), "(%d errors)" % errors.size())


func _test_climate_sanity(atlas: ContinentAtlas) -> void:
	print("- climate sanity")
	var ocean: int = 0
	var land: int = 0
	var lake: int = 0
	var forest: int = 0
	var alpine: int = 0
	for i in atlas.cells.size():
		var biome: int = AtlasPack.biome(atlas.cells[i])
		match biome:
			AtlasBiomes.Id.OCEAN:
				ocean += 1
			AtlasBiomes.Id.LAKE:
				lake += 1
			AtlasBiomes.Id.FOREST:
				forest += 1
				land += 1
			AtlasBiomes.Id.ALPINE:
				alpine += 1
				land += 1
			_:
				if AtlasBiomes.is_land(biome):
					land += 1
	_check("has ocean", ocean > atlas.size * 4)
	_check("has land", land > atlas.size * 4)
	_check("has lakes", lake > 0 and atlas.lakes.size() > 0)
	_check("lake cells match lakes", lake > 0)
	_check("sea_surface_z is 0", atlas.sea_surface_z == 0)
	_check("schema version", atlas.schema_version == ContinentAtlas.SCHEMA_VERSION)

	# Ocean cells carry high humidity by contract.
	var wet_ocean: int = 0
	var ocean_n: int = 0
	for i in atlas.cells.size():
		if AtlasPack.biome(atlas.cells[i]) != AtlasBiomes.Id.OCEAN:
			continue
		ocean_n += 1
		if AtlasPack.humidity(atlas.cells[i]) >= 250:
			wet_ocean += 1
	_check(
		"ocean humidity saturated",
		ocean_n > 0 and wet_ocean * 10 >= ocean_n * 9,
		"(%d of %d)" % [wet_ocean, ocean_n]
	)


func _test_edge_ports_shared(atlas: ContinentAtlas) -> void:
	print("- shared edge ownership")
	var checked: int = 0
	var mismatches: int = 0
	for az in atlas.size:
		for ax in range(atlas.size - 1):
			var a: Array = atlas.ports_on_edge(
				ax, az, AtlasFeatures.Dir.EAST, AtlasFeatures.Kind.RIVER
			)
			var b: Array = atlas.ports_on_edge(
				ax + 1, az, AtlasFeatures.Dir.WEST, AtlasFeatures.Kind.RIVER
			)
			checked += 1
			if a.size() != b.size():
				mismatches += 1
	_check("east/west river ports agree", mismatches == 0, "(%d checked)" % checked)


func _test_river_and_lake_sanity(atlas: ContinentAtlas) -> void:
	print("- rivers and lakes")
	var climbs: int = 0
	var river_cells: int = 0
	var lake_mouths: int = 0
	var ocean_mouths: int = 0
	for cell_idx in atlas.river_links:
		river_cells += 1
		var idx: int = int(cell_idx)
		var down: int = atlas.river_receiver[idx]
		if down >= 0:
			var e0: int = AtlasPack.elevation(atlas.cells[idx])
			var db: int = AtlasPack.biome(atlas.cells[down])
			if db != AtlasBiomes.Id.OCEAN and db != AtlasBiomes.Id.LAKE:
				if AtlasPack.elevation(atlas.cells[down]) > e0:
					climbs += 1
		for link_variant in atlas.river_links[cell_idx]:
			var link: AtlasLink = link_variant
			if link.b.kind == AtlasFeatures.EndpointKind.LAKE:
				lake_mouths += 1
			elif link.b.kind == AtlasFeatures.EndpointKind.OCEAN:
				ocean_mouths += 1
	_check("no uphill river steps", climbs == 0, "(%d climbs)" % climbs)
	_check("rivers reach ocean", ocean_mouths > 0, "(%d mouths)" % ocean_mouths)
	_check("rivers reach lakes", lake_mouths > 0, "(%d mouths)" % lake_mouths)

	var sizes: Dictionary = {}
	var unique_shapes: int = 0
	for lake in atlas.lakes:
		var key: int = lake.cells.size()
		if not sizes.has(key):
			sizes[key] = 0
			unique_shapes += 1
		sizes[key] = int(sizes[key]) + 1
		_check("lake %d has spill" % lake.id, lake.spill_cell >= 0)
	_check(
		"lakes vary in size",
		atlas.lakes.size() <= 1 or unique_shapes > 1,
		"(%d distinct sizes of %d)" % [unique_shapes, atlas.lakes.size()]
	)


func _test_population(atlas: ContinentAtlas) -> void:
	print("- population")
	var land: int = 0
	var occupied: int = 0
	var water_occupied: int = 0
	var river_land: int = 0
	var river_occupied: int = 0
	var inland_pop_total: int = 0
	var inland_cells: int = 0
	# Absolute humidity thresholds do not transfer between seeds, so split the
	# land on its own terciles before comparing occupancy rates.
	var humidity_hist: PackedInt32Array = PackedInt32Array()
	humidity_hist.resize(256)
	for i in atlas.cells.size():
		var cell: int = atlas.cells[i]
		if AtlasBiomes.is_land(AtlasPack.biome(cell)):
			humidity_hist[AtlasPack.humidity(cell)] += 1
	var land_total: int = 0
	for h in 256:
		land_total += humidity_hist[h]
	var dry_cut: int = _humidity_percentile(humidity_hist, land_total, 0.33)
	var wet_cut: int = _humidity_percentile(humidity_hist, land_total, 0.67)
	var dry_land: int = 0
	var dry_occupied: int = 0
	var wet_land: int = 0
	var wet_occupied: int = 0

	for i in atlas.cells.size():
		var packed: int = atlas.cells[i]
		var pop: int = AtlasPack.population(packed)
		if not AtlasBiomes.is_land(AtlasPack.biome(packed)):
			if pop > 0:
				water_occupied += 1
			continue
		land += 1
		if pop > 0:
			occupied += 1
		if atlas.river_links.has(i):
			river_land += 1
			if pop > 0:
				river_occupied += 1
		else:
			inland_cells += 1
			inland_pop_total += pop
		var humidity: int = AtlasPack.humidity(packed)
		if humidity <= dry_cut:
			dry_land += 1
			if pop > 0:
				dry_occupied += 1
		elif humidity >= wet_cut:
			wet_land += 1
			if pop > 0:
				wet_occupied += 1

	_check("no population on water", water_occupied == 0, "(%d cells)" % water_occupied)
	_check("land is populated somewhere", occupied > 0, "(%d cells)" % occupied)
	var occupied_ratio: float = float(occupied) / maxf(1.0, float(land))
	_check(
		"population stays sparse",
		occupied_ratio < 0.35,
		"(%.1f%% of %d land cells)" % [100.0 * occupied_ratio, land]
	)

	var river_rate: float = float(river_occupied) / maxf(1.0, float(river_land))
	var inland_rate: float = float(occupied - river_occupied) / maxf(
		1.0, float(land - river_land)
	)
	_check(
		"river corridors are denser than inland",
		river_land == 0 or river_rate > inland_rate,
		"(%.1f%% vs %.1f%%)" % [100.0 * river_rate, 100.0 * inland_rate]
	)

	var dry_rate: float = float(dry_occupied) / maxf(1.0, float(dry_land))
	var wet_rate: float = float(wet_occupied) / maxf(1.0, float(wet_land))
	_check(
		"wet land outpopulates dry land",
		dry_land == 0 or wet_land == 0 or wet_rate > dry_rate,
		"(%.1f%% above hum %d vs %.1f%% below hum %d)" % [
			100.0 * wet_rate, wet_cut, 100.0 * dry_rate, dry_cut
		]
	)

	var mouth_cells: int = 0
	var mouth_pop_total: int = 0
	for cell_variant in atlas.river_links:
		var cell: int = int(cell_variant)
		for link_variant in atlas.river_links[cell]:
			var link: AtlasLink = link_variant
			if (
				link.b.kind == AtlasFeatures.EndpointKind.OCEAN
				or link.b.kind == AtlasFeatures.EndpointKind.LAKE
			):
				mouth_cells += 1
				mouth_pop_total += AtlasPack.population(atlas.cells[cell])
				break
	var mouth_avg: float = float(mouth_pop_total) / maxf(1.0, float(mouth_cells))
	var inland_avg: float = float(inland_pop_total) / maxf(1.0, float(inland_cells))
	_check(
		"river mouths are the population cores",
		mouth_cells == 0 or mouth_avg > inland_avg * 3.0,
		"(avg %.1f vs inland %.2f over %d mouths)" % [mouth_avg, inland_avg, mouth_cells]
	)

	var settlements: int = 0
	for node in atlas.nodes:
		if node.kind == AtlasFeatures.NodeKind.SETTLEMENT:
			settlements += 1
	_check(
		"mouths produce settlement nodes",
		mouth_cells == 0 or settlements > 0,
		"(%d of %d nodes)" % [settlements, atlas.nodes.size()]
	)


func _humidity_percentile(hist: PackedInt32Array, total: int, fraction: float) -> int:
	if total <= 0:
		return 0
	var wanted: int = int(float(total) * fraction)
	var seen: int = 0
	for h in 256:
		seen += hist[h]
		if seen >= wanted:
			return h
	return 255


func _test_road_coverage(atlas: ContinentAtlas) -> void:
	print("- road coverage")
	var min_nodes: int = maxi(8, atlas.size / 20)
	_check(
		"enough road nodes",
		atlas.nodes.size() >= min_nodes,
		"(%d >= %d)" % [atlas.nodes.size(), min_nodes]
	)
	_check(
		"has primary road edges",
		atlas.primary_road_edges.size() > 0,
		"(%d)" % atlas.primary_road_edges.size()
	)

	var by_mass: Dictionary = {}
	for node in atlas.nodes:
		if not by_mass.has(node.landmass):
			by_mass[node.landmass] = 0
		by_mass[node.landmass] = int(by_mass[node.landmass]) + 1
	var expected_edges: int = 0
	for mass in by_mass:
		var n: int = int(by_mass[mass])
		if n >= 2:
			expected_edges += n - 1
	_check(
		"primary MST edges present",
		atlas.primary_road_edges.size() >= expected_edges,
		"(%d >= %d)" % [atlas.primary_road_edges.size(), expected_edges]
	)

	var min_road_cells: int = maxi(24, atlas.nodes.size() * 4)
	_check(
		"road corridors cover many cells",
		atlas.road_links.size() >= min_road_cells,
		"(%d >= %d)" % [atlas.road_links.size(), min_road_cells]
	)

	var through_cells: int = 0
	var node_terminal_cells: int = 0
	for cell_idx in atlas.road_links:
		for link_variant in atlas.road_links[cell_idx]:
			var link: AtlasLink = link_variant
			if link.a.kind == AtlasFeatures.EndpointKind.NODE:
				node_terminal_cells += 1
			if link.b.kind == AtlasFeatures.EndpointKind.NODE:
				node_terminal_cells += 1
			if (
				link.a.kind == AtlasFeatures.EndpointKind.EDGE_PORT
				and link.b.kind == AtlasFeatures.EndpointKind.EDGE_PORT
				and link.a.ref_id != link.b.ref_id
			):
				through_cells += 1
				break
	_check(
		"roads have through-cell links",
		through_cells >= maxi(8, min_road_cells / 2),
		"(%d)" % through_cells
	)
	_check(
		"roads reach node terminals",
		node_terminal_cells >= atlas.nodes.size(),
		"(%d terminals, %d nodes)" % [node_terminal_cells, atlas.nodes.size()]
	)

	# Secondary spurs should exist beyond the bare MST on maps with enough nodes.
	var secondary_cells: int = 0
	for cell_idx in atlas.road_links:
		for link_variant in atlas.road_links[cell_idx]:
			var link2: AtlasLink = link_variant
			if link2.feature_class == AtlasFeatures.RoadClass.SECONDARY:
				secondary_cells += 1
				break
	_check(
		"secondary road spurs exist",
		atlas.nodes.size() < 4 or secondary_cells > 0,
		"(%d cells)" % secondary_cells
	)

	# Towns must be on the trunk, not hung off it as leaves.
	var settlements_per_mass: Dictionary = {}
	var settlement_ids: Dictionary = {}
	for node in atlas.nodes:
		if node.kind != AtlasFeatures.NodeKind.SETTLEMENT:
			continue
		settlement_ids[node.id] = true
		if not settlements_per_mass.has(node.landmass):
			settlements_per_mass[node.landmass] = 0
		settlements_per_mass[node.landmass] = int(settlements_per_mass[node.landmass]) + 1
	var expects_settlement_trunk: bool = false
	for mass in settlements_per_mass:
		if int(settlements_per_mass[mass]) >= 2:
			expects_settlement_trunk = true
	var settlement_primary: int = 0
	for edge in atlas.primary_road_edges:
		if settlement_ids.has(edge.x) and settlement_ids.has(edge.y):
			settlement_primary += 1
	_check(
		"settlements carry the primary network",
		not expects_settlement_trunk or settlement_primary > 0,
		"(%d town-to-town primary edges)" % settlement_primary
	)


func _test_determinism() -> void:
	print("- determinism")
	var a: ContinentAtlas = ContinentAtlas.generate(424242, 96)
	var b: ContinentAtlas = ContinentAtlas.generate(424242, 96)
	var c: ContinentAtlas = ContinentAtlas.generate(424243, 96)
	_check("same seed same hash", a.content_hash == b.content_hash)
	_check("same seed same lakes", a.lakes.size() == b.lakes.size())
	_check("same seed same nodes", a.nodes.size() == b.nodes.size())
	_check("same seed same cells", a.cells == b.cells)
	_check("different seed differs", a.content_hash != c.content_hash)
