class_name PlayerController
extends CharacterBody3D
## First-person walker. Positioned in scene space; reports world space.
##
## The player stays frozen until the streamer has real ground underneath,
## so nobody ever falls through a chunk that has not been built yet.

@export var walk_speed: float = 5.2
@export var sprint_speed: float = 10.5
@export var fly_speed: float = 34.0
@export var jump_velocity: float = 7.4
@export var mouse_sensitivity: float = 0.0022
@export var air_control: float = 0.35
## Ground steeper than this becomes a wall. Default Godot is 45° — too timid
## for Orrun banks, terraces, and bridge approaches.
@export var max_walk_angle_deg: float = 78.0

@onready var camera: Camera3D = $Camera3D

var frozen: bool = true
var flying: bool = false

var _pitch: float = 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 22.0)
var _streamer: Streamer = null
var _config: WorldConfig = null
## Probe this far ahead (metres) so a sprint cannot cross into unfinished ground.
const _WALK_PROBE_METRES: float = 2.5


func _ready() -> void:
	floor_max_angle = deg_to_rad(max_walk_angle_deg)
	floor_snap_length = 0.45
	floor_constant_speed = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func bind_streamer(streamer: Streamer, config: WorldConfig) -> void:
	assert(streamer != null, "PlayerController.bind_streamer requires a Streamer")
	assert(config != null, "PlayerController.bind_streamer requires a WorldConfig")
	_streamer = streamer
	_config = config


func world_position() -> Vector3:
	assert(
		is_inside_tree(),
		"PlayerController.world_position requires the player to be inside the scene tree"
	)
	return WorldOrigin.to_world(global_position)


## Drop the player onto a known-good world position and hand back control.
func spawn_at_world(world_pos: Vector3) -> void:
	global_position = WorldOrigin.to_scene(world_pos)
	velocity = Vector3.ZERO
	frozen = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion: InputEventMouseMotion = event
		rotate_y(-motion.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.5, 1.5)
		camera.rotation.x = _pitch
		return

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event.is_action_pressed("toggle_fly"):
		flying = not flying
		velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	if frozen:
		return

	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish: Vector3 = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var speed: float = sprint_speed if Input.is_action_pressed("sprint") else walk_speed

	if flying:
		var lift: float = 0.0
		if Input.is_action_pressed("fly_up"):
			lift += 1.0
		if Input.is_action_pressed("fly_down"):
			lift -= 1.0
		var fly_dir: Vector3 = (camera.global_transform.basis * Vector3(input_dir.x, 0.0, input_dir.y))
		velocity = (fly_dir + Vector3.UP * lift) * fly_speed
		move_and_slide()
		return

	# Never walk (or fall) where LOD0 walk collision is missing.
	if not _walk_ground_ready(world_position()):
		velocity = Vector3.ZERO
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	var control: float = 1.0 if is_on_floor() else air_control
	var target: Vector3 = wish * speed
	# Project wish onto the floor so steep grades stay walkable instead of
	# fighting the normal as a wall.
	if is_on_floor() and wish.length_squared() > 0.0001:
		var along: Vector3 = wish.slide(get_floor_normal())
		if along.length_squared() > 0.0001:
			target = along.normalized() * speed
	velocity.x = lerpf(velocity.x, target.x, control)
	velocity.z = lerpf(velocity.z, target.z, control)
	if is_on_floor() and wish.length_squared() > 0.0001:
		velocity.y = lerpf(velocity.y, target.y, control)

	if wish.length_squared() > 0.0001:
		var probe_world: Vector3 = world_position() + wish * _WALK_PROBE_METRES
		if not _walk_ground_ready(probe_world):
			velocity.x = 0.0
			velocity.z = 0.0
			if is_on_floor():
				velocity.y = 0.0

	move_and_slide()


func _walk_ground_ready(world_pos: Vector3) -> bool:
	assert(_streamer != null and _config != null, "PlayerController missing streamer bind")
	var chunk: Vector2i = WorldCoords.chunk_of(_config, world_pos.x, world_pos.z)
	return _streamer.is_chunk_ready(chunk)
