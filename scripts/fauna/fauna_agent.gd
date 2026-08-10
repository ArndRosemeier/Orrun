class_name FaunaAgent
extends Node3D
## One live animal. Walks dry ground with graze / flee / hunt brains.

enum State { GRAZE, FLEE, PATROL, CHASE, COOLDOWN, EAT }

## Quaternius walk cycles are brisk; play them slower so stride matches a stroll.
const ANIM_SPEED_IDLE: float = 0.65
const ANIM_SPEED_EAT: float = 0.55
const ANIM_SPEED_WALK: float = 0.48
const ANIM_SPEED_RUN: float = 0.62
## Radians/sec while browsing; flee may turn faster.
const TURN_RATE_GRAZE: float = 1.05
const TURN_RATE_FLEE: float = 2.8
const TURN_RATE_CHASE: float = 2.2
## Only step forward once roughly facing the goal (radians).
const MOVE_ALIGN_RAD: float = 0.7

var spec: FaunaCatalog.FaunaSpec
var agent_id: int = 0
var flock_id: int = 0
var home_cell: Vector2i = Vector2i.ZERO
var world_pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var state: State = State.GRAZE
var velocity_xz: Vector2 = Vector2.ZERO
var ground_normal: Vector3 = Vector3.UP

var _sim: FaunaSim
var _anim: AnimationPlayer
var _waypoint: Vector2 = Vector2.ZERO
var _desired_yaw: float = 0.0
var _state_time: float = 0.0
var _eat_left: float = 0.0
var _hold_left: float = 0.0
var _cooldown_left: float = 0.0
var _flee_retarget_left: float = 0.0
var _flee_duration: float = 6.0
var _walk_deadline: float = 20.0
var _walking: bool = false
var _current_clip: StringName = &""
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func setup(
	sim: FaunaSim,
	fauna_spec: FaunaCatalog.FaunaSpec,
	id: int,
	flock: int,
	cell: Vector2i,
	spawn_world: Vector3,
	facing: float,
	seed: int
) -> void:
	_sim = sim
	spec = fauna_spec
	agent_id = id
	flock_id = flock
	home_cell = cell
	world_pos = spawn_world
	yaw = facing
	_desired_yaw = facing
	_rng.seed = seed
	name = "%s_%d" % [String(spec.id), agent_id]
	_waypoint = Vector2(world_pos.x, world_pos.z)
	_mount_mesh()
	_sync_transform()
	if spec.is_predator():
		state = State.PATROL
		_begin_patrol_leg()
	else:
		state = State.GRAZE
		# Spawn already browsing — do not immediately start pacing.
		_begin_idle_hold(_rng.randf_range(6.0, 16.0))
	_play(spec.anim_idle, ANIM_SPEED_IDLE)


func is_prey() -> bool:
	return spec.is_prey()


func is_predator() -> bool:
	return spec.is_predator()


func species_id() -> StringName:
	return spec.id


func apply_surface(normal: Vector3) -> void:
	if normal.length_squared() < 1e-8:
		ground_normal = Vector3.UP
	else:
		ground_normal = normal.normalized()


func state_name() -> String:
	match state:
		State.GRAZE:
			return "graze"
		State.FLEE:
			return "flee"
		State.PATROL:
			return "patrol"
		State.CHASE:
			return "chase"
		State.COOLDOWN:
			return "cooldown"
		State.EAT:
			return "eat"
		_:
			assert(false, "Unknown fauna state")
			return "?"


func tick(delta: float, peers: Array[FaunaAgent]) -> void:
	_state_time += delta
	if spec.is_predator():
		_tick_predator(delta, peers)
	else:
		_tick_prey(delta, peers)
	_integrate(delta)
	_sync_transform()
	_update_anim()


func _tick_prey(delta: float, peers: Array[FaunaAgent]) -> void:
	var threat: FaunaAgent = _nearest_predator(peers, spec.flee_radius)
	if threat != null:
		if state != State.FLEE:
			state = State.FLEE
			_state_time = 0.0
			_flee_duration = _rng.randf_range(5.0, 9.0)
			_flee_retarget_left = 0.0
			_walking = true
			_hold_left = 0.0
		_flee_retarget_left -= delta
		if _flee_retarget_left <= 0.0:
			_retarget_flee(threat)
			_flee_retarget_left = _rng.randf_range(1.2, 2.4)
		return

	if state == State.FLEE:
		# Settle only after a real burst — not the moment the threat leaves LOS.
		if _state_time > _flee_duration or (_state_time > 3.0 and _near_waypoint(3.0)):
			state = State.GRAZE
			_begin_idle_hold(_rng.randf_range(8.0, 18.0))
		return

	if state == State.EAT:
		_eat_left -= delta
		_walking = false
		velocity_xz = Vector2.ZERO
		if _eat_left <= 0.0:
			state = State.GRAZE
			# After a meal, linger before wandering again.
			_begin_idle_hold(_rng.randf_range(5.0, 14.0))
		return

	if state != State.GRAZE:
		state = State.GRAZE
		_begin_idle_hold(_rng.randf_range(4.0, 10.0))
		return

	if _walking:
		if _near_waypoint(2.2):
			_finish_walk_arrival()
		return

	_hold_left -= delta
	if _hold_left > 0.0:
		return
	_roll_graze_next_action()


func _finish_walk_arrival() -> void:
	_walking = false
	velocity_xz = Vector2.ZERO
	var roll: float = _rng.randf()
	if roll < 0.62:
		_begin_eat()
	elif roll < 0.92:
		_begin_idle_hold(_rng.randf_range(8.0, 22.0))
	else:
		_begin_walk_leg()


func _roll_graze_next_action() -> void:
	var roll: float = _rng.randf()
	if roll < 0.55:
		_begin_eat()
	elif roll < 0.82:
		_begin_idle_hold(_rng.randf_range(6.0, 16.0))
	else:
		_begin_walk_leg()


func _begin_idle_hold(seconds: float) -> void:
	_walking = false
	_hold_left = seconds
	velocity_xz = Vector2.ZERO
	# Small look fidget so idle herds do not freeze as statues.
	_desired_yaw = yaw + _rng.randf_range(-0.45, 0.45)


func _begin_eat() -> void:
	state = State.EAT
	_walking = false
	_eat_left = _rng.randf_range(12.0, 28.0)
	velocity_xz = Vector2.ZERO


func _begin_walk_leg() -> void:
	_walking = true
	_hold_left = 0.0
	# Short amble, not a cross-country dash between snacks.
	_waypoint = _sim.random_stand_near(
		spec, world_pos.x, world_pos.z, _rng.randf_range(5.0, 12.0), _rng
	)
	_face_waypoint()


func _retarget_flee(threat: FaunaAgent) -> void:
	var away: Vector2 = Vector2(world_pos.x - threat.world_pos.x, world_pos.z - threat.world_pos.z)
	if away.length_squared() < 0.01:
		away = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
	_waypoint = Vector2(world_pos.x, world_pos.z) + away.normalized() * _rng.randf_range(16.0, 28.0)
	_face_waypoint()


func _tick_predator(delta: float, peers: Array[FaunaAgent]) -> void:
	if _cooldown_left > 0.0:
		state = State.COOLDOWN
		_cooldown_left -= delta
		_walking = false
		return

	var prey: FaunaAgent = _nearest_prey(peers, spec.hunt_range)
	if prey != null:
		var dist: float = _xz_distance(prey)
		if dist <= spec.catch_radius:
			_sim.catch_prey(prey)
			_cooldown_left = _rng.randf_range(6.0, 12.0)
			state = State.COOLDOWN
			_walking = false
			return
		state = State.CHASE
		_walking = true
		_waypoint = Vector2(prey.world_pos.x, prey.world_pos.z)
		_face_waypoint()
		return

	if state == State.CHASE:
		state = State.PATROL
		_begin_idle_hold(_rng.randf_range(3.0, 8.0))
		_walking = false
		return

	if state != State.PATROL and state != State.GRAZE:
		state = State.PATROL

	if _walking:
		if _near_waypoint(2.5) or _state_time > _walk_deadline:
			_walking = false
			_begin_idle_hold(_rng.randf_range(5.0, 14.0))
			_state_time = 0.0
		return

	_hold_left -= delta
	if _hold_left <= 0.0:
		if _rng.randf() < 0.4:
			_begin_idle_hold(_rng.randf_range(4.0, 12.0))
		else:
			_begin_patrol_leg()


func _begin_patrol_leg() -> void:
	state = State.PATROL
	_walking = true
	_hold_left = 0.0
	_state_time = 0.0
	_walk_deadline = _rng.randf_range(14.0, 28.0)
	_waypoint = _sim.random_stand_near(
		spec, world_pos.x, world_pos.z, _rng.randf_range(10.0, 22.0), _rng
	)
	_face_waypoint()


func _face_waypoint() -> void:
	var to: Vector2 = _waypoint - Vector2(world_pos.x, world_pos.z)
	if to.length_squared() < 0.01:
		return
	var dir: Vector2 = to.normalized()
	# Quaternius animals face +Z.
	_desired_yaw = atan2(dir.x, dir.y)


func _integrate(delta: float) -> void:
	if state == State.EAT or (not _walking and state != State.FLEE and state != State.CHASE):
		velocity_xz = Vector2.ZERO
		_turn_toward(_desired_yaw, TURN_RATE_GRAZE * delta)
		_snap_to_surface(world_pos.x, world_pos.z)
		return

	_face_waypoint()
	var turn_rate: float = TURN_RATE_GRAZE
	if state == State.FLEE:
		turn_rate = TURN_RATE_FLEE
	elif state == State.CHASE:
		turn_rate = TURN_RATE_CHASE
	_turn_toward(_desired_yaw, turn_rate * delta)

	var align: float = absf(angle_difference(yaw, _desired_yaw))
	if align > MOVE_ALIGN_RAD:
		velocity_xz = Vector2.ZERO
		_snap_to_surface(world_pos.x, world_pos.z)
		return

	var speed: float = spec.walk_speed
	if state == State.FLEE or state == State.CHASE:
		speed = spec.run_speed
	# Ease in while still finishing the turn.
	speed *= clampf(1.0 - align / MOVE_ALIGN_RAD, 0.35, 1.0)

	var forward: Vector2 = Vector2(sin(yaw), cos(yaw))
	velocity_xz = forward * speed
	var next: Vector2 = Vector2(world_pos.x, world_pos.z) + velocity_xz * delta
	if not _sim.can_stand(spec, next.x, next.y):
		_walking = false
		if spec.is_predator():
			_begin_idle_hold(_rng.randf_range(3.0, 8.0))
		else:
			_begin_idle_hold(_rng.randf_range(4.0, 10.0))
		velocity_xz = Vector2.ZERO
		_snap_to_surface(world_pos.x, world_pos.z)
		return
	world_pos.x = next.x
	world_pos.z = next.y
	_snap_to_surface(next.x, next.y)


## Stick feet to the streamed mesh; keep last pose if the ray misses for a frame.
func _snap_to_surface(world_x: float, world_z: float) -> void:
	var surface: Dictionary = _sim.sample_surface(world_x, world_z)
	if surface.is_empty():
		return
	world_pos.y = float(surface["y"])
	apply_surface(surface["normal"])


func _turn_toward(target_yaw: float, max_step: float) -> void:
	yaw = rotate_toward(yaw, target_yaw, max_step)


func _near_waypoint(eps: float) -> bool:
	return Vector2(world_pos.x, world_pos.z).distance_to(_waypoint) <= eps


func _nearest_predator(peers: Array[FaunaAgent], radius: float) -> FaunaAgent:
	var best: FaunaAgent = null
	var best_d: float = radius
	for peer in peers:
		if peer == self or not peer.is_predator():
			continue
		var d: float = _xz_distance(peer)
		if d < best_d:
			best_d = d
			best = peer
	return best


func _nearest_prey(peers: Array[FaunaAgent], radius: float) -> FaunaAgent:
	var best: FaunaAgent = null
	var best_d: float = radius
	for peer in peers:
		if peer == self or not peer.is_prey():
			continue
		var d: float = _xz_distance(peer)
		if d < best_d:
			best_d = d
			best = peer
	return best


func _xz_distance(other: FaunaAgent) -> float:
	return Vector2(world_pos.x, world_pos.z).distance_to(
		Vector2(other.world_pos.x, other.world_pos.z)
	)


func _mount_mesh() -> void:
	var packed: PackedScene = FaunaCatalog.scene_for(spec.id)
	var visual: Node3D = packed.instantiate() as Node3D
	assert(visual != null, "Fauna scene root is not Node3D for %s" % String(spec.id))
	visual.scale = Vector3.ONE * spec.scale
	add_child(visual)
	_anim = _find_animation_player(visual)
	assert(_anim != null, "Fauna scene has no AnimationPlayer: %s" % String(spec.id))
	_configure_looping_clips()


func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found: AnimationPlayer = _find_animation_player(child)
		if found != null:
			return found
	return null


## Quaternius clips import as one-shot (loop_mode none). Locomotion must loop
## or the body keeps translating on a frozen end-pose — classic foot-slide.
func _configure_looping_clips() -> void:
	var loop_names: Array[StringName] = [
		spec.anim_idle, spec.anim_walk, spec.anim_run, spec.anim_eat, &"Idle_2"
	]
	for clip_name in loop_names:
		if not _anim.has_animation(clip_name):
			continue
		var anim: Animation = _anim.get_animation(clip_name)
		anim.loop_mode = Animation.LOOP_LINEAR


func _play(clip: StringName, speed: float) -> void:
	if _anim == null:
		return
	if clip == _current_clip and _anim.is_playing():
		_anim.speed_scale = speed
		return
	assert(_anim.has_animation(clip), "Missing anim '%s' on %s" % [String(clip), String(spec.id)])
	_anim.speed_scale = speed
	_anim.play(clip)
	_current_clip = clip


func _update_anim() -> void:
	match state:
		State.EAT:
			_play(spec.anim_eat, ANIM_SPEED_EAT)
		State.FLEE, State.CHASE:
			_play(spec.anim_run, ANIM_SPEED_RUN)
		State.COOLDOWN:
			_play(spec.anim_idle, ANIM_SPEED_IDLE)
		_:
			if velocity_xz.length_squared() > 0.04:
				_play(spec.anim_walk, ANIM_SPEED_WALK)
			else:
				_play(spec.anim_idle, ANIM_SPEED_IDLE)


func _sync_transform() -> void:
	assert(_sim != null, "FaunaAgent sync without sim")
	# Basis: +Y along ground normal, +Z along facing projected onto the slope
	# (Quaternius forward). Upright yaw-only posing buries downhill flanks.
	var up: Vector3 = ground_normal
	if up.y < 0.2:
		up = Vector3.UP
	var ahead: Vector3 = Vector3(sin(yaw), 0.0, cos(yaw))
	var forward: Vector3 = ahead - up * ahead.dot(up)
	if forward.length_squared() < 1e-6:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var right: Vector3 = up.cross(forward)
	if right.length_squared() < 1e-6:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	forward = right.cross(up).normalized()
	up = forward.cross(right).normalized()
	global_transform = Transform3D(Basis(right, up, forward), _sim.world_to_scene(world_pos))
