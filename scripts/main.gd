class_name MainWorld
extends Node3D
## Boots the world: bake the lower layers, then stream chunks around the player.
##
## The bake runs on a worker so the window stays responsive, and the player is
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
var map: WorldMap

var _bake_task: int = -1
var _spawn_world: Vector3 = Vector3.ZERO
var _spawn_pending: bool = false
var _terrain_material: ShaderMaterial
var _water_material: ShaderMaterial


func _ready() -> void:
	config = WorldConfig.new()
	WorldOrigin.register_root(player)

	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = load(TERRAIN_SHADER)
	_terrain_material.set_shader_parameter("debug_view", 0)
	_water_material = ShaderMaterial.new()
	_water_material.shader = load(WATER_SHADER)

	loading_label.text = "Shaping %0.1f km of land..." % (config.world_size() / 1000.0)
	_bake_task = WorkerThreadPool.add_task(_bake)


func _bake() -> void:
	map = WorldMap.generate(config)


func _process(_delta: float) -> void:
	if _bake_task >= 0:
		if not WorkerThreadPool.is_task_completed(_bake_task):
			return
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
		_on_world_baked()
		return
	if _spawn_pending:
		_try_spawn()


func _on_world_baked() -> void:
	print("Orrun world baked: %s" % [map.bake_timings])
	print("  %d river reaches, %d lakes, %d roads, %d crossings" % [
		map.hydro.rivers.size(), map.hydro.lakes.size(),
		map.paths.roads.size(), map.paths.bridges.size()
	])

	var specs: Array[PropPlacer.PropSpec] = PropPlacer.load_specs(CATALOG_PATH)
	PropLibrary.load_catalog(specs, CATALOG_PATH)

	var candidates: PackedVector3Array = WorldQuery.spawn_candidates(map)
	assert(candidates.size() > 0, "World produced no spawn candidates")
	_spawn_world = candidates[0]

	# Start the origin under the spawn so scene coordinates begin near zero even
	# though the spawn itself can be kilometres into the map.
	WorldOrigin.rebase_to(Vector3(_spawn_world.x, 0.0, _spawn_world.z))
	player.global_position = WorldOrigin.to_scene(
		_spawn_world + Vector3(0.0, 60.0, 0.0)
	)

	streamer.setup(config, map, player, specs, _terrain_material, _water_material)
	hydro_map.build(map, player)
	debug_hud.bind(streamer, map, player)
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
