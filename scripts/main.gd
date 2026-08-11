class_name MainWorld
extends Node3D
## Boots the world: generate the continent atlas, build the shared continental
## context, bake the sector the player will open in, then stream chunks.
##
## Boot lands at the last saved player position ([constant SESSION_PATH]), or at
## the largest atlas settlement plaza on a fresh profile. Closing the window
## writes the current continental position so the next launch resumes there.
##
## Generation runs on a worker so the window stays responsive, and the player is
## held frozen until there is real collision under the spawn point.

const CATALOG_PATH: String = "res://assets/catalog/props.json"
const SESSION_PATH: String = "user://player_session.cfg"
const TERRAIN_SHADER: String = "res://shaders/terrain.gdshader"
const WATER_SHADER: String = "res://shaders/water.gdshader"

@onready var streamer: Streamer = $Streamer
@onready var fauna_sim: FaunaSim = $FaunaSim
@onready var player: PlayerController = $Player
@onready var debug_hud: Control = $UI/DebugHud
@onready var hydro_map: Control = $UI/HydroMap
@onready var world_map: Control = $UI/WorldMap
@onready var terrain_tune: Control = $UI/TerrainTune
@onready var splash: Control = $UI/Splash
@onready var loading_label: Label = $UI/Splash/Loading

var config: WorldConfig
var context: WorldContext
var sectors: SectorManager
var spawn_sector: WorldSector

var _bake_task: int = -1
## 0 = idle, 1 = atlas worker, 2 = spawn-sector worker.
var _bake_phase: int = 0
var _baked_atlas: ContinentAtlas = null
var _spawn_world: Vector3 = Vector3.ZERO
var _spawn_yaw: float = 0.0
var _spawn_pending: bool = false
var _terrain_material: ShaderMaterial
var _water_material: ShaderMaterial
var _boot_error: String = ""
## Last known continental pose while the player is in the tree. Used so session
## save during teardown cannot call [method Node3D.global_position] off-tree.
var _session_world: Vector3 = Vector3.ZERO
var _session_yaw: float = 0.0
var _session_valid: bool = false
## WM_CLOSE_REQUEST and PREDELETE both tear down; only run once.
var _shutdown_done: bool = false


func _ready() -> void:
	config = WorldConfig.new()
	WorldOrigin.register_root(player)

	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = load(TERRAIN_SHADER)
	_terrain_material.set_shader_parameter("debug_view", 0)
	_water_material = ShaderMaterial.new()
	_water_material.shader = load(WATER_SHADER)

	assert(
		ClassDB.class_exists("OrrunGen"),
		"OrrunGen native extension is required — run native/orrun_gen/build.bat"
	)
	var native: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
	print("OrrunGen: %s" % [native.call("version")])

	_show_splash("Charting %d km of continent..." % config.atlas_size)
	# Atlas generation stays on a worker. Typed class_name factories such as
	# WorldContext.create must run on the main thread — worker calls can fail
	# with "Invalid type in function 'create'" (sibling RefCounted misread).
	# AgentLog records that class of failure in logs/godot_runtime.log.
	_bake_phase = 1
	_bake_task = WorkerThreadPool.add_task(_bake_atlas)


func _bake_atlas() -> void:
	var t0: int = Time.get_ticks_msec()
	var atlas: ContinentAtlas = BakeCache.try_load_atlas(config)
	if atlas != null:
		atlas.generate_ms = Time.get_ticks_msec() - t0
		print("BakeCache: atlas hit (%d ms, hash=%d)" % [atlas.generate_ms, atlas.content_hash])
	else:
		atlas = ContinentAtlas.generate(config.seed, config.atlas_size)
		BakeCache.save_atlas(config, atlas)
		print("BakeCache: atlas miss, generated in %d ms" % atlas.generate_ms)
	var errors: PackedStringArray = atlas.validate()
	if not errors.is_empty():
		# The atlas is the authority for everything below it. A broken one must
		# stop the boot, not quietly produce a world with impossible rivers.
		_boot_error = "Atlas failed validation: %s" % [errors]
		return
	_baked_atlas = atlas


func _complete_boot_from_atlas() -> void:
	_show_splash("Building continental terrain...")
	context = WorldContext.create(config, _baked_atlas)
	_baked_atlas = null
	_show_splash("Baking the spawn sector...")
	_bake_phase = 2
	_bake_task = WorkerThreadPool.add_task(_bake_spawn_sector)


func _bake_spawn_sector() -> void:
	var continental: ContinentalTerrain = context.sampler()
	var spawn: Dictionary = _resolve_spawn()
	var spawn_xz: Vector2 = spawn["xz"]
	_spawn_yaw = float(spawn["yaw"])
	var sector_coord: Vector2i = WorldCoords.sector_of(spawn_xz.x, spawn_xz.y)
	if not context.sector_in_atlas(sector_coord):
		_boot_error = "Spawn is outside the atlas (%.0f, %.0f)" % [spawn_xz.x, spawn_xz.y]
		return
	spawn_sector = _load_or_bake_sector(sector_coord)
	var saved_y: float = float(spawn["y"])
	# Fresh profile: snap onto the flattest dry plaza in the settlement claim
	# (atlas |∇h| is 1 km; this uses macro slope so the floodplain can win).
	if saved_y <= -INF:
		spawn_xz = _snap_fresh_spawn_plaza(spawn_xz)
		sector_coord = WorldCoords.sector_of(spawn_xz.x, spawn_xz.y)
		if sector_coord != spawn_sector.sector:
			if not context.sector_in_atlas(sector_coord):
				_boot_error = "Snapped spawn outside atlas (%.0f, %.0f)" % [spawn_xz.x, spawn_xz.y]
				return
			spawn_sector = _load_or_bake_sector(sector_coord)
	var ground: float = continental.height_at(spawn_xz.x, spawn_xz.y)
	# A prior crash/teardown can persist a Y deep under the mesh. Treat that as
	# "unknown" so the spawn ray starts from the continental surface instead.
	if saved_y > -INF and saved_y < ground - 25.0:
		push_warning(
			"Saved spawn Y %.1f m is %.1f m below continental ground; ignoring it" % [
				saved_y, ground - saved_y
			]
		)
		saved_y = -INF
	_spawn_world = Vector3(
		spawn_xz.x,
		saved_y if saved_y > -INF else ground,
		spawn_xz.y
	)


func _load_or_bake_sector(sector_coord: Vector2i) -> WorldSector:
	var t0: int = Time.get_ticks_msec()
	var cached: WorldSector = BakeCache.try_load_sector(context, sector_coord)
	if cached != null:
		var load_ms: int = Time.get_ticks_msec() - t0
		cached.bake_timings = {"cache_hit": 1, "total_ms": load_ms}
		print("BakeCache: sector %s hit (%d ms)" % [sector_coord, load_ms])
		return cached
	var baked: WorldSector = WorldSector.generate(context, sector_coord)
	BakeCache.save_sector(context, baked)
	print("BakeCache: sector %s miss, baked in %d ms" % [
		sector_coord, int(baked.bake_timings.get("total_ms", 0))
	])
	return baked


## Resolve the settlement plaza with macro |∇h| ranking (same as bake).
func _snap_fresh_spawn_plaza(hint_xz: Vector2) -> Vector2:
	var best_node: AtlasGraphNode = null
	var best_d: float = INF
	for node_variant in context.atlas.nodes:
		var node: AtlasGraphNode = node_variant
		if node.kind != AtlasFeatures.NodeKind.SETTLEMENT:
			continue
		var centre: Vector2 = context.atlas.continental_centre(node.ax, node.az)
		var d: float = centre.distance_squared_to(hint_xz)
		if d < best_d:
			best_d = d
			best_node = node
	assert(best_node != null, "fresh spawn: no SETTLEMENT near hint")
	var centre: Vector2 = context.atlas.continental_centre(best_node.ax, best_node.az)
	var tier: int = VillageTier.from_atlas_node(context.atlas, best_node)
	var area: VillageDecorator.Area = VillageDecorator.Area.new()
	area.centre = centre
	area.tier = tier
	area.settlement_id = best_node.id
	area.claim_radius = VillageTier.claim_radius(tier)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = int(hash("spawn_plaza_snap:%d" % best_node.id)) & 0x7fffffff
	var plaza: Vector2 = VillageDecorator.resolve_plaza(
		area, spawn_sector.terrain, spawn_sector.hydro, rng
	)
	print(
		"spawn plaza snap -> %.0f, %.0f (from atlas %.0f, %.0f, %s)" % [
			plaza.x, plaza.y, centre.x, centre.y, VillageTier.name_of(tier)
		]
	)
	return plaza


func _process(_delta: float) -> void:
	if _bake_task >= 0:
		if not WorkerThreadPool.is_task_completed(_bake_task):
			return
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
		if not _boot_error.is_empty():
			_show_splash(_boot_error)
			push_error(_boot_error)
			_bake_phase = 0
			return
		if _bake_phase == 1:
			_complete_boot_from_atlas()
			return
		if _bake_phase == 2:
			_bake_phase = 0
			_on_world_ready()
			return
		_bake_phase = 0
		return
	if _spawn_pending:
		_try_spawn()
	_cache_session_pose()


func _cache_session_pose() -> void:
	if player == null or player.frozen or not player.is_inside_tree():
		return
	_session_world = player.world_position()
	_session_yaw = player.rotation.y
	_session_valid = true


func _on_world_ready() -> void:
	print("Orrun continent: %s" % [context.build_timings])
	print("  atlas %d km, %d river mouths, %d trunk river segments, %d road segments" % [
		config.atlas_size, context.corridors.mouths.size(),
		context.corridors.river_segment_count(), context.corridors.road_segment_count()
	])
	print("  spawn sector %s: %s" % [spawn_sector.sector, spawn_sector.bake_timings])
	print("  %d river reaches, %d local lakes, %d roads, %d crossings, %d houses" % [
		spawn_sector.hydro.rivers.size(), spawn_sector.hydro.lakes.size(),
		spawn_sector.paths.roads.size(), spawn_sector.paths.bridges.size(),
		spawn_sector.houses.size()
	])
	print("  spawn at %.0f, %.0f (claim: %s)" % [
		_spawn_world.x, _spawn_world.z,
		spawn_sector.claims.kind_at(_spawn_world.x, _spawn_world.z)
	])

	var specs: Array[PropPlacer.PropSpec] = PropPlacer.load_specs(CATALOG_PATH)
	PropLibrary.load_catalog(specs, CATALOG_PATH)
	var clutter_specs: Array[GroundClutter.Spec] = GroundClutter.load_specs()
	PropLibrary.load_sources(GroundClutter.mesh_sources())
	VillageCatalog.load_catalog()
	PropLibrary.load_sources(VillageCatalog.mesh_sources(), VillageCatalog.mesh_scale())
	FarmCatalog.load_catalog()
	PropLibrary.load_sources(FarmCatalog.mesh_sources(), FarmCatalog.mesh_scale())
	BridgeLibrary.load_catalog()

	sectors = SectorManager.new(context)
	sectors.adopt(spawn_sector)
	sectors.request_around(spawn_sector.sector)

	# Start the origin under the spawn so scene coordinates begin near zero even
	# though the spawn itself is hundreds of kilometres into the continent.
	WorldOrigin.rebase_to(Vector3(_spawn_world.x, 0.0, _spawn_world.z))
	player.global_position = WorldOrigin.to_scene(
		_spawn_world + Vector3(0.0, 60.0, 0.0)
	)

	streamer.setup(
		context, sectors, player, specs, _terrain_material, _water_material,
		clutter_specs
	)
	player.bind_streamer(streamer, config)
	fauna_sim.setup(context, sectors, streamer, player)
	hydro_map.build(sectors, player)
	world_map.setup_for_game(context.atlas, player)
	world_map.teleport_requested.connect(_teleport_to_map)
	debug_hud.bind(streamer, sectors, player, fauna_sim)
	debug_hud.visible = false
	terrain_tune.bind(streamer, config)

	_spawn_pending = true
	_show_splash("Building the ground underfoot...")


func _try_spawn() -> void:
	var chunk: Vector2i = WorldCoords.chunk_of(config, _spawn_world.x, _spawn_world.z)
	# Wait for the underfoot chunk plus neighbours so the first step cannot
	# walk onto mesh-only / missing ground.
	if not streamer.is_neighborhood_ready(chunk, 1):
		return

	var scene_xz: Vector2 = WorldOrigin.to_scene_xz(_spawn_world.x, _spawn_world.z)
	# Ray from the higher of saved Y and continental ground so a bad session Y
	# cannot aim the cast entirely under the mesh.
	var hint_y: float = maxf(
		_spawn_world.y, context.sampler().height_at(_spawn_world.x, _spawn_world.z)
	)
	var hit: Dictionary = WorldQuery.trace_ground(
		get_world_3d().direct_space_state, scene_xz.x, scene_xz.y, hint_y
	)
	if hit.is_empty():
		return

	var landing: Vector3 = hit["position"]
	player.spawn_at_world(WorldOrigin.to_world(landing) + Vector3(0.0, 1.2, 0.0))
	player.rotation.y = _spawn_yaw
	_spawn_pending = false
	_hide_splash()
	_cache_session_pose()


func _show_splash(status: String) -> void:
	splash.visible = true
	loading_label.visible = true
	loading_label.text = status
	# Cover the game until the player can move (boot and map travel).
	if debug_hud != null:
		debug_hud.visible = false
	if world_map != null:
		world_map.visible = false
	if terrain_tune != null:
		terrain_tune.visible = false
	if hydro_map != null:
		hydro_map.visible = false


func _hide_splash() -> void:
	splash.visible = false
	debug_hud.visible = true
	hydro_map.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_hud"):
		debug_hud.visible = not debug_hud.visible
	elif event.is_action_pressed("debug_map"):
		_toggle_world_map()
	elif event.is_action_pressed("debug_terrain_tune"):
		_toggle_terrain_tune()
	elif event.is_action_pressed("debug_epsilon"):
		set_terrain_debug_view(
			(int(_terrain_material.get_shader_parameter("debug_view")) + 1) % 4
		)


func _toggle_world_map() -> void:
	world_map.visible = not world_map.visible
	hydro_map.visible = not world_map.visible
	if world_map.visible:
		terrain_tune.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# Size is final next frame; centre on the player then.
		call_deferred("_focus_world_map_on_player")
	else:
		_refresh_mouse_mode()


func _toggle_terrain_tune() -> void:
	terrain_tune.visible = not terrain_tune.visible
	if terrain_tune.visible:
		world_map.visible = false
		hydro_map.visible = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_refresh_mouse_mode()


func _refresh_mouse_mode() -> void:
	if world_map.visible or terrain_tune.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _focus_world_map_on_player() -> void:
	if not world_map.visible:
		return
	var world_pos: Vector3 = WorldOrigin.to_world(player.global_position)
	world_map.focus_world_xz(Vector2(world_pos.x, world_pos.z))
	world_map.grab_focus()


## Drop the player on a world-map click. Reuses the spawn wait so they land on
## real collision once the streamer has caught up.
func _teleport_to_map(world_xz: Vector2) -> void:
	if context == null or streamer == null:
		return
	var span: float = context.config.continent_metres()
	if (
		world_xz.x < 0.0 or world_xz.y < 0.0
		or world_xz.x >= span or world_xz.y >= span
	):
		print("teleport rejected: outside atlas (%.0f, %.0f)" % [world_xz.x, world_xz.y])
		return
	var ground: float = context.sampler().height_at(world_xz.x, world_xz.y)
	_spawn_world = Vector3(world_xz.x, ground, world_xz.y)
	WorldOrigin.rebase_to(Vector3(world_xz.x, 0.0, world_xz.y))
	streamer.refresh_origin_transforms()
	player.frozen = true
	player.velocity = Vector3.ZERO
	player.global_position = WorldOrigin.to_scene(
		_spawn_world + Vector3(0.0, 60.0, 0.0)
	)
	sectors.request_around(WorldCoords.sector_of(world_xz.x, world_xz.y))
	_spawn_pending = true
	_show_splash("Travelling...")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	print(
		"teleport map -> %.0f, %.0f (sector %s)" % [
			world_xz.x, world_xz.y, WorldCoords.sector_of(world_xz.x, world_xz.y)
		]
	)


func set_terrain_debug_view(view: int) -> void:
	_terrain_material.set_shader_parameter("debug_view", view)


func _notification(what: int) -> void:
	# Save on window close while the player is still in the tree. PREDELETE runs
	# during teardown when global_position is already illegal — that used to
	# write a corrupt session and the next boot could spawn under the world.
	# Always drain worker pools before quit: GenQueue / chunk-cache tasks still
	# running into tree teardown crash the process (see BakeCache chunk saves).
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shutdown_workers_and_session()
		get_tree().quit()
	elif what == NOTIFICATION_PREDELETE:
		_shutdown_workers_and_session()


func _shutdown_workers_and_session() -> void:
	if _shutdown_done:
		return
	_shutdown_done = true
	_save_session()
	if streamer != null:
		streamer.shutdown()
	if sectors != null:
		sectors.shutdown()


## Keys: xz (Vector2), y (float, -INF if unknown), yaw (float).
func _resolve_spawn() -> Dictionary:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(SESSION_PATH) == OK and cfg.has_section_key("player", "world_x"):
		var xz: Vector2 = Vector2(
			float(cfg.get_value("player", "world_x")),
			float(cfg.get_value("player", "world_z"))
		)
		var span: float = context.config.continent_metres()
		if xz.x >= 0.0 and xz.y >= 0.0 and xz.x < span and xz.y < span:
			return {
				"xz": xz,
				"y": float(cfg.get_value("player", "world_y", -INF)),
				"yaw": float(cfg.get_value("player", "yaw", 0.0)),
			}
		push_warning("Saved spawn outside atlas; using largest settlement")
	var plaza: Vector2 = SettlementLayout.spawn_plaza_largest(context.atlas)
	print(
		"fresh spawn -> largest settlement plaza %.0f, %.0f (sector %s)" % [
			plaza.x, plaza.y, WorldCoords.sector_of(plaza.x, plaza.y)
		]
	)
	return {"xz": plaza, "y": -INF, "yaw": 0.0}


func _save_session() -> void:
	if context == null:
		return
	var world: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	if (
		player != null
		and is_instance_valid(player)
		and player.is_inside_tree()
		and not player.frozen
	):
		world = player.world_position()
		yaw = player.rotation.y
	elif _session_valid:
		world = _session_world
		yaw = _session_yaw
	else:
		return
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("player", "world_x", world.x)
	cfg.set_value("player", "world_y", world.y)
	cfg.set_value("player", "world_z", world.z)
	cfg.set_value("player", "yaw", yaw)
	var err: Error = cfg.save(SESSION_PATH)
	if err != OK:
		push_error("Failed to save player session to %s (error %d)" % [SESSION_PATH, err])
	else:
		print("saved session -> %.0f, %.0f (yaw %.2f)" % [world.x, world.z, yaw])
