extends SceneTree
## Headless round-trip checks for BakeCache (atlas + spawn sector).
##
##   godot --headless --path <project> --script res://tools/tests/bake_cache_tests.gd


var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	print("=== Orrun bake cache tests ===")
	_test_atlas_roundtrip()
	_test_sector_roundtrip()
	_test_knob_invalidation()
	_test_chunk_roundtrip()
	_test_mesh_knob_invalidation()
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


func _make_config(seed: int, atlas_size: int) -> WorldConfig:
	var config: WorldConfig = WorldConfig.new()
	config.seed = seed
	config.atlas_size = atlas_size
	return config


func _delete_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_atlas_roundtrip() -> void:
	print("- atlas round-trip")
	var config: WorldConfig = _make_config(42424201, 64)
	var path: String = BakeCache.atlas_path(config)
	_delete_if_exists(path)

	var miss: ContinentAtlas = BakeCache.try_load_atlas(config)
	_check("cold miss", miss == null)

	var generated: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var errors: PackedStringArray = generated.validate()
	_check("generated validates", errors.is_empty(), str(errors))
	BakeCache.save_atlas(config, generated)
	_check("atlas file exists", FileAccess.file_exists(path))

	var loaded: ContinentAtlas = BakeCache.try_load_atlas(config)
	_check("cache hit", loaded != null)
	if loaded == null:
		return
	_check("content_hash", loaded.content_hash == generated.content_hash)
	_check("cells size", loaded.cells.size() == generated.cells.size())
	_check("cells equal", loaded.cells == generated.cells)
	_check("lakes", loaded.lakes.size() == generated.lakes.size())
	_check("nodes", loaded.nodes.size() == generated.nodes.size())
	_check("river_ports", loaded.river_ports.size() == generated.river_ports.size())
	_check("road_links", loaded.road_links.size() == generated.road_links.size())
	_check("mouth_distance", loaded.mouth_distance == generated.mouth_distance)
	var loaded_errors: PackedStringArray = loaded.validate()
	_check("loaded validates", loaded_errors.is_empty(), str(loaded_errors))


func _test_sector_roundtrip() -> void:
	print("- sector round-trip")
	var config: WorldConfig = _make_config(42424201, 64)
	var atlas: ContinentAtlas = BakeCache.try_load_atlas(config)
	if atlas == null:
		atlas = ContinentAtlas.generate(config.seed, config.atlas_size)
		BakeCache.save_atlas(config, atlas)
	var context: WorldContext = WorldContext.create(config, atlas)
	var sector_coord: Vector2i = Vector2i(2, 2)
	_check("sector in atlas", context.sector_in_atlas(sector_coord))

	var path: String = BakeCache.sector_path(context.content_key(), sector_coord)
	_delete_if_exists(path)

	var miss: WorldSector = BakeCache.try_load_sector(context, sector_coord)
	_check("sector cold miss", miss == null)

	var generated: WorldSector = WorldSector.generate(context, sector_coord)
	BakeCache.save_sector(context, generated)
	_check("sector file exists", FileAccess.file_exists(path))

	var loaded: WorldSector = BakeCache.try_load_sector(context, sector_coord)
	_check("sector cache hit", loaded != null)
	if loaded == null:
		return
	_check("sector coord", loaded.sector == generated.sector)
	_check("terrain cells", loaded.terrain.cells == generated.terrain.cells)
	_check("elevation", loaded.terrain.elevation == generated.terrain.elevation)
	_check("filled", loaded.hydro.filled == generated.hydro.filled)
	_check("rivers", loaded.hydro.rivers.size() == generated.hydro.rivers.size())
	_check("lakes", loaded.hydro.lakes.size() == generated.hydro.lakes.size())
	_check("roads", loaded.paths.roads.size() == generated.paths.roads.size())
	_check("bridges", loaded.paths.bridges.size() == generated.paths.bridges.size())
	_check("houses", loaded.houses.size() == generated.houses.size())
	_check("claims", loaded.claims.claims.size() == generated.claims.claims.size())
	if not generated.hydro.rivers.is_empty() and not loaded.hydro.rivers.is_empty():
		_check(
			"first river points",
			loaded.hydro.rivers[0].points == generated.hydro.rivers[0].points
		)
	if not generated.paths.roads.is_empty() and not loaded.paths.roads.is_empty():
		var g_road: RoadEdge = generated.paths.roads[0]
		var l_road: RoadEdge = loaded.paths.roads[0]
		_check("first road points", l_road.points == g_road.points)
		_check("first road crossings", l_road.crossings.size() == g_road.crossings.size())


func _test_knob_invalidation() -> void:
	print("- knob invalidation")
	var config_a: WorldConfig = _make_config(42424201, 64)
	var config_b: WorldConfig = _make_config(42424201, 64)
	config_b.swell_height = config_a.swell_height + 1.0
	_check(
		"content_hash changes with knob",
		config_a.content_hash() != config_b.content_hash()
	)
	var atlas: ContinentAtlas = BakeCache.try_load_atlas(config_a)
	_check("atlas still keyed by config hash", atlas != null)
	var miss: ContinentAtlas = BakeCache.try_load_atlas(config_b)
	_check("changed knob is atlas miss", miss == null)


func _test_chunk_roundtrip() -> void:
	print("- LOD0 chunk round-trip")
	assert(
		ClassDB.class_exists("OrrunGen"),
		"OrrunGen required for chunk cache test"
	)
	var config: WorldConfig = _make_config(42424201, 64)
	var atlas: ContinentAtlas = BakeCache.try_load_atlas(config)
	if atlas == null:
		atlas = ContinentAtlas.generate(config.seed, config.atlas_size)
		BakeCache.save_atlas(config, atlas)
	var context: WorldContext = WorldContext.create(config, atlas)
	var sector_coord: Vector2i = Vector2i(2, 2)
	var sector: WorldSector = BakeCache.try_load_sector(context, sector_coord)
	if sector == null:
		sector = WorldSector.generate(context, sector_coord)
		BakeCache.save_sector(context, sector)

	var sector_centre: Vector2 = WorldCoords.sector_origin(sector_coord) + Vector2(4000.0, 4000.0)
	var chunk: Vector2i = WorldCoords.chunk_of(config, sector_centre.x, sector_centre.y)
	var region: RegionData = RegionData.build(
		sector, WorldCoords.region_of_chunk(config, chunk)
	)
	var path: String = BakeCache.chunk_path(BakeCache.chunk_key(context), chunk)
	_delete_if_exists(path)

	var miss: ChunkJob = BakeCache.try_load_chunk(context, sector, region, chunk, 0)
	_check("chunk cold miss", miss == null)

	var generated: ChunkJob = ChunkJob.new()
	generated.config = config
	generated.context = context
	generated.sector = sector
	generated.region = region
	generated.chunk = chunk
	generated.lod = 0
	generated.want_collision = true
	generated.want_props = false
	generated.want_clutter = false
	generated.run()
	_check("chunk meshed", generated.mesh_data != null and not generated.mesh_data.is_empty())
	_check("chunk has collision", generated.mesh_data.collision_faces.size() >= 9)

	BakeCache.save_chunk(context, generated)
	_check("chunk file exists", FileAccess.file_exists(path))

	var loaded: ChunkJob = BakeCache.try_load_chunk(context, sector, region, chunk, 0)
	_check("chunk cache hit", loaded != null)
	if loaded == null:
		return
	_check("chunk coord", loaded.chunk == generated.chunk)
	_check("vertices", loaded.mesh_data.vertices == generated.mesh_data.vertices)
	_check("indices", loaded.mesh_data.indices == generated.mesh_data.indices)
	_check(
		"collision_faces",
		loaded.mesh_data.collision_faces == generated.mesh_data.collision_faces
	)
	_check("water indices", loaded.water_data.indices == generated.water_data.indices)
	_check("bridges", loaded.bridges.size() == generated.bridges.size())
	_check(
		"bridge builds",
		loaded.bridge_builds.size() == generated.bridge_builds.size()
	)
	_check("warm ring helper", BakeCache.is_warm_ring(0.0) and BakeCache.is_warm_ring(1.0))
	_check("warm ring excludes 2", not BakeCache.is_warm_ring(2.0))


func _test_mesh_knob_invalidation() -> void:
	print("- mesh knob invalidation")
	var config_a: WorldConfig = _make_config(42424201, 64)
	var config_b: WorldConfig = _make_config(42424201, 64)
	config_b.cave_threshold = config_a.cave_threshold + 0.05
	_check(
		"mesh_content_hash changes with cave knob",
		config_a.mesh_content_hash() != config_b.mesh_content_hash()
	)
	var atlas: ContinentAtlas = BakeCache.try_load_atlas(config_a)
	_check("atlas available for mesh key test", atlas != null)
	if atlas == null:
		return
	var ctx_a: WorldContext = WorldContext.create(config_a, atlas)
	var ctx_b: WorldContext = WorldContext.create(config_b, atlas)
	_check(
		"chunk_key changes with mesh knob",
		BakeCache.chunk_key(ctx_a) != BakeCache.chunk_key(ctx_b)
	)
	# Same sector content_key (atlas+config content_hash unchanged for cave-only).
	_check(
		"sector content_key unchanged by cave knob",
		ctx_a.content_key() == ctx_b.content_key()
	)
