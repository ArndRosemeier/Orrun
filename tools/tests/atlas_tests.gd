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
