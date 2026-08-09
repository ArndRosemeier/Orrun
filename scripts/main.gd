class_name MainWorld
extends Node3D
## Boots the world: generate the continent atlas, build the shared continental
## context, bake the sector the player will open in, then stream chunks.
##
## The first acceptance scene is a river mouth. It is chosen from the atlas
## alone - biggest river class, comfortably inside the continent - so the same
## seed always opens on the same estuary, and the slice exercises the two
## hardest seams at once: a trunk river crossing sector boundaries, and an
## ocean shoreline shared by four sectors.
##
## Generation runs on a worker so the window stays responsive, and the player is
## held frozen until there is real collision under the spawn point.

const CATALOG_PATH: String = "res://assets/catalog/props.json"
const TERRAIN_SHADER: String = "res://shaders/terrain.gdshader"
const WATER_SHADER: String = "res://shaders/water.gdshader"

@onready var streamer: Streamer = $Streamer
@onready var player: PlayerController = $Player
@onready var debug_hud: Control = $UI/DebugHud
@onready var hydro_map: Control = $UI/HydroMap
@onready var world_map: Control = $UI/WorldMap
@onready var loading_label: Label = $UI/Loading

var config: WorldConfig
var context: WorldContext
var sectors: SectorManager
var spawn_sector: WorldSector

var _bake_task: int = -1
## 0 = idle, 1 = atlas worker, 2 = spawn-sector worker.
var _bake_phase: int = 0
var _baked_atlas: ContinentAtlas = null
var _spawn_world: Vector3 = Vector3.ZERO
var _spawn_pending: bool = false
var _terrain_material: ShaderMaterial
var _water_material: ShaderMaterial
var _boot_error: String = ""


func _ready() -> void:
	config = WorldConfig.new()
	WorldOrigin.register_root(player)

	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = load(TERRAIN_SHADER)
	_terrain_material.set_shader_parameter("debug_view", 0)
	_water_material = ShaderMaterial.new()
	_water_material.shader = load(WATER_SHADER)

	if ClassDB.class_exists("OrrunGen"):
		var native: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
		print("OrrunGen: %s" % [native.call("version")])
	else:
		push_warning("OrrunGen missing — sector flood uses GDScript fallback")

	loading_label.text = "Charting %d km of continent..." % config.atlas_size
	# Atlas generation stays on a worker. Typed class_name factories such as
	# WorldContext.create must run on the main thread — worker calls can fail
	# with "Invalid type in function 'create'" (sibling RefCounted misread).
	# AgentLog records that class of failure in logs/godot_runtime.log.
	_bake_phase = 1
	_bake_task = WorkerThreadPool.add_task(_bake_atlas)


func _bake_atlas() -> void:
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var errors: PackedStringArray = atlas.validate()
	if not errors.is_empty():
		# The atlas is the authority for everything below it. A broken one must
		# stop the boot, not quietly produce a world with impossible rivers.
		_boot_error = "Atlas failed validation: %s" % [errors]
		return
	_baked_atlas = atlas


func _complete_boot_from_atlas() -> void:
	loading_label.text = "Building continental terrain..."
	context = WorldContext.create(config, _baked_atlas)
	_baked_atlas = null
	loading_label.text = "Baking the river mouth..."
	_bake_phase = 2
	_bake_task = WorkerThreadPool.add_task(_bake_spawn_sector)


func _bake_spawn_sector() -> void:
	var mouths: Array[Dictionary] = WorldQuery.ranked_river_mouths(context)
	if mouths.is_empty():
		_boot_error = "Atlas produced no river mouths to open on"
		return

	var continental: ContinentalTerrain = context.sampler()
	for mouth in mouths:
		var position: Vector2 = mouth["position"]
		var sector_coord: Vector2i = WorldCoords.sector_of(position.x, position.y)
		var candidate: WorldSector = WorldSector.generate(context, sector_coord)
		var landing: Vector3 = WorldQuery.spawn_beside_mouth(
			candidate, continental, position
		)
		if landing == Vector3.INF:
			continue
		spawn_sector = candidate
		_spawn_world = landing
		return
	_boot_error = "No river mouth had dry ground beside it"


func _process(_delta: float) -> void:
	if _bake_task >= 0:
		if not WorkerThreadPool.is_task_completed(_bake_task):
			return
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
		if not _boot_error.is_empty():
			loading_label.text = _boot_error
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


func _on_world_ready() -> void:
	print("Orrun continent: %s" % [context.build_timings])
	print("  atlas %d km, %d river mouths, %d trunk river segments, %d road segments" % [
		config.atlas_size, context.corridors.mouths.size(),
		context.corridors.river_segment_count(), context.corridors.road_segment_count()
	])
	print("  spawn sector %s: %s" % [spawn_sector.sector, spawn_sector.bake_timings])
	print("  %d river reaches, %d local lakes, %d roads, %d crossings" % [
		spawn_sector.hydro.rivers.size(), spawn_sector.hydro.lakes.size(),
		spawn_sector.paths.roads.size(), spawn_sector.paths.bridges.size()
	])

	var specs: Array[PropPlacer.PropSpec] = PropPlacer.load_specs(CATALOG_PATH)
	PropLibrary.load_catalog(specs, CATALOG_PATH)

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
		context, sectors, player, specs, _terrain_material, _water_material
	)
	hydro_map.build(sectors, player)
	world_map.setup_for_game(context.atlas, player)
	world_map.teleport_requested.connect(_teleport_to_map)
	debug_hud.bind(streamer, sectors, player)
	debug_hud.visible = true

	_spawn_pending = true
	loading_label.text = "Building the ground underfoot..."


func _try_spawn() -> void:
	var chunk: Vector2i = WorldCoords.chunk_of(config, _spawn_world.x, _spawn_world.z)
	if not streamer.is_chunk_ready(chunk):
		return

	var scene_xz: Vector2 = WorldOrigin.to_scene_xz(_spawn_world.x, _spawn_world.z)
	var hit: Dictionary = WorldQuery.trace_ground(
		get_world_3d().direct_space_state, scene_xz.x, scene_xz.y, _spawn_world.y
	)
	if hit.is_empty():
		return

	var landing: Vector3 = hit["position"]
	player.spawn_at_world(WorldOrigin.to_world(landing) + Vector3(0.0, 1.2, 0.0))
	_spawn_pending = false
	loading_label.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_hud"):
		debug_hud.visible = not debug_hud.visible
	elif event.is_action_pressed("debug_map"):
		_toggle_world_map()
	elif event.is_action_pressed("debug_epsilon"):
		set_terrain_debug_view(
			(int(_terrain_material.get_shader_parameter("debug_view")) + 1) % 4
		)


func _toggle_world_map() -> void:
	world_map.visible = not world_map.visible
	hydro_map.visible = not world_map.visible
	if world_map.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# Size is final next frame; centre on the player then.
		call_deferred("_focus_world_map_on_player")
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
	loading_label.visible = true
	loading_label.text = "Travelling..."
	world_map.visible = false
	hydro_map.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	print(
		"teleport map -> %.0f, %.0f (sector %s)" % [
			world_xz.x, world_xz.y, WorldCoords.sector_of(world_xz.x, world_xz.y)
		]
	)


func set_terrain_debug_view(view: int) -> void:
	_terrain_material.set_shader_parameter("debug_view", view)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if streamer != null:
			streamer.shutdown()
		if sectors != null:
			sectors.shutdown()
