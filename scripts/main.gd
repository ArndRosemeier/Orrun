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
@onready var loading_label: Label = $UI/Loading

var config: WorldConfig
var context: WorldContext
var sectors: SectorManager
var spawn_sector: WorldSector

var _bake_task: int = -1
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

	loading_label.text = "Charting %d km of continent..." % config.atlas_size
	_bake_task = WorkerThreadPool.add_task(_bake)


func _bake() -> void:
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var errors: PackedStringArray = atlas.validate()
	if not errors.is_empty():
		# The atlas is the authority for everything below it. A broken one must
		# stop the boot, not quietly produce a world with impossible rivers.
		_boot_error = "Atlas failed validation: %s" % [errors]
		return
	context = WorldContext.create(config, atlas)

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
			return
		_on_world_ready()
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
		hydro_map.visible = not hydro_map.visible
	elif event.is_action_pressed("debug_epsilon"):
		set_terrain_debug_view(
			(int(_terrain_material.get_shader_parameter("debug_view")) + 1) % 4
		)


func set_terrain_debug_view(view: int) -> void:
	_terrain_material.set_shader_parameter("debug_view", view)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if streamer != null:
			streamer.shutdown()
		if sectors != null:
			sectors.shutdown()
