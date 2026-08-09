extends Node
## Boots the real main scene headless and walks the player across the world.
##
##   godot --headless --path <project> res://tools/tests/runtime_smoke.tscn
##
## Runs as a scene rather than a --script main loop so the project's autoloads
## (the floating origin) exist exactly as they do in the game.
##
## Proves the parts a data test cannot: chunks stream in around a moving player,
## the spawn lands on real collision, water and props are instantiated, the
## floating origin rebases without losing the world, and - the point of the
## sector rework - that walking out of one 8 km sector and into the next just
## keeps working, with no boundary to fall off and no backlog that never clears.

## Measured in seconds, not frames: the atlas and the spawn sector take tens of
## seconds to build and a headless main loop spins far faster than a real one.
const WARMUP_SECONDS: float = 240.0
## Travel is timed too, and by the frame's real delta, for the same reason. A
## fixed step per frame makes the player supersonic on a headless loop, which
## tests nothing except that generation cannot outrun light.
const WALK_SPEED: float = 60.0
const MAX_WALK_SECONDS: float = 300.0
## How far past the boundary the walk continues, so the far side is genuinely
## streamed rather than merely touched.
const OVERSHOOT_METRES: float = 600.0
## After the player stops, generation gets this long to catch up. A backlog that
## never drains is a streaming failure; one that drains is just a fast player.
const SETTLE_SECONDS: float = 180.0

enum Phase { WARMUP, WALK, SETTLE }

var main: Node3D
var streamer: Streamer
var player: PlayerController
var frames: int = 0
var spawned_frame: int = -1
var rebases: int = 0
var failures: int = 0
var started_msec: int = 0

var phase: Phase = Phase.WARMUP
var _start_world: Vector3 = Vector3.ZERO
var _walk_dir: Vector3 = Vector3.RIGHT
var _walk_target: float = 0.0
var _walk_seconds: float = 0.0
var _settle_seconds: float = 0.0
var _sectors_seen: Dictionary = {}
var _worst_queue: int = 0
var _worst_waiting: int = 0


func _ready() -> void:
	print("=== Orrun runtime smoke ===")
	started_msec = Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	streamer = main.get_node("Streamer")
	player = main.get_node("Player")
	WorldOrigin.rebased.connect(func(_delta: Vector3) -> void: rebases += 1)


func _process(delta: float) -> void:
	frames += 1
	match phase:
		Phase.WARMUP:
			_warmup()
		Phase.WALK:
			_walk(delta)
		Phase.SETTLE:
			_settle(delta)


func _warmup() -> void:
	if player.frozen:
		if Time.get_ticks_msec() - started_msec > int(WARMUP_SECONDS * 1000.0):
			_fail("player never spawned (%d chunks live, %d sectors baked)" % [
				streamer.stat_chunks_live,
				streamer.sectors.live_count() if streamer.sectors != null else -1
			])
			_finish()
		return

	spawned_frame = frames
	_start_world = player.world_position()
	_aim_at_nearest_boundary()
	phase = Phase.WALK
	print("spawned after %d frames at continental %s (sector %s)" % [
		frames, _start_world,
		WorldCoords.sector_of(_start_world.x, _start_world.z)
	])
	print("walking %s for %.0f m at %.0f m/s" % [
		_walk_dir, _walk_target, WALK_SPEED
	])


## Heads for whichever sector boundary is closest, plus an overshoot. Flying a
## fixed bearing would mean up to 8 km of travel before the interesting part,
## and the interesting part is the crossing.
func _aim_at_nearest_boundary() -> void:
	var rect: Rect2 = WorldCoords.sector_rect(
		WorldCoords.sector_of(_start_world.x, _start_world.z)
	)
	var options: Array = [
		[Vector3.LEFT, _start_world.x - rect.position.x],
		[Vector3.RIGHT, rect.end.x - _start_world.x],
		[Vector3.FORWARD, _start_world.z - rect.position.y],
		[Vector3.BACK, rect.end.y - _start_world.z],
	]
	var best: Array = options[0]
	for option in options:
		if option[1] < best[1]:
			best = option
	_walk_dir = best[0]
	_walk_target = best[1] + OVERSHOOT_METRES


func _walk(delta: float) -> void:
	player.flying = true
	player.global_position += _walk_dir * WALK_SPEED * delta
	_walk_seconds += delta

	var world_pos: Vector3 = player.world_position()
	_observe(world_pos)

	var travelled: float = (world_pos - _start_world).length()
	if travelled >= _walk_target or _walk_seconds >= MAX_WALK_SECONDS:
		print("stopped after %.0f m in %.0f s, letting generation catch up" % [
			travelled, _walk_seconds
		])
		phase = Phase.SETTLE


## Standing still, the queue has to empty. Whether it emptied is the difference
## between a player who outran the world for a moment and a world that never
## finishes building.
func _settle(delta: float) -> void:
	_settle_seconds += delta
	_observe(player.world_position())
	if streamer.queue_depth() > 0 and _settle_seconds < SETTLE_SECONDS:
		return
	if streamer.queue_depth() > 0:
		_fail("generation never caught up (%d jobs still queued after %.0f s)" % [
			streamer.queue_depth(), _settle_seconds
		])
	_report()
	_finish()


func _observe(world_pos: Vector3) -> void:
	_sectors_seen[WorldCoords.sector_key(
		WorldCoords.sector_of(world_pos.x, world_pos.z)
	)] = true
	_worst_queue = maxi(_worst_queue, streamer.queue_depth())
	_worst_waiting = maxi(_worst_waiting, streamer.stat_chunks_waiting_on_sector)


func _fail(message: String) -> void:
	failures += 1
	printerr("  FAIL  %s" % message)


func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  PASS  %s %s" % [name, detail])
	else:
		_fail("%s %s" % [name, detail])


func _report() -> void:
	var world_pos: Vector3 = player.world_position()
	var terrain_meshes: int = 0
	var water_meshes: int = 0
	var multimeshes: int = 0
	var colliders: int = 0
	var triangles: int = 0

	var chunks_by_lod: PackedInt32Array = PackedInt32Array()
	var meshed_by_lod: PackedInt32Array = PackedInt32Array()
	chunks_by_lod.resize(streamer.config.lod_count())
	meshed_by_lod.resize(streamer.config.lod_count())

	for child in streamer.get_children():
		# The streamer also parents the far-terrain backdrop, which is not a
		# chunk and has no LOD.
		if child is not ChunkNode:
			continue
		var chunk: ChunkNode = child
		chunks_by_lod[chunk.lod] += 1
		if chunk.triangle_count > 0:
			meshed_by_lod[chunk.lod] += 1
		for part in chunk.get_children():
			if part is MultiMeshInstance3D:
				multimeshes += 1
			elif part is MeshInstance3D:
				var instance: MeshInstance3D = part
				var mesh: ArrayMesh = instance.mesh
				triangles += mesh.get_faces().size() / 3
				if mesh.surface_get_material(0) != null and str(
					mesh.surface_get_material(0).get_shader().resource_path
				).ends_with("water.gdshader"):
					water_meshes += 1
				else:
					terrain_meshes += 1
			elif part is StaticBody3D:
				colliders += 1

	print("travelled %.0f m to continental %s over %d frames, through %d sectors" % [
		(world_pos - _start_world).length(), world_pos, frames, _sectors_seen.size()
	])
	for lod in chunks_by_lod.size():
		print("  LOD %d: %d chunks, %d with terrain" % [
			lod, chunks_by_lod[lod], meshed_by_lod[lod]
		])
	_check("chunks stayed loaded", streamer.stat_chunks_live > 20,
		"(%d live)" % streamer.stat_chunks_live)
	_check("terrain meshes exist", terrain_meshes > 20, "(%d)" % terrain_meshes)
	_check("collision only near the player", colliders > 0 and colliders < terrain_meshes,
		"(%d colliders for %d meshes)" % [colliders, terrain_meshes])
	_check("water surfaces built", water_meshes > 0, "(%d)" % water_meshes)
	_check("props instantiated", multimeshes > 0,
		"(%d multimeshes, %d prop meshes loaded)" % [multimeshes, PropLibrary.available_count()])
	_check("floating origin rebased", rebases > 0, "(%d rebases)" % rebases)
	# The old world had a rim to fall off. This one has sectors, and walking
	# into the next one has to be indistinguishable from staying in this one.
	_check("the walk crossed a sector boundary", _sectors_seen.size() >= 2,
		"(%d sectors visited)" % _sectors_seen.size())
	_check("the sector under the player is baked",
		streamer.sectors.sector_at(world_pos.x, world_pos.z) != null,
		"(%d sectors cached, %d baking)" % [
			streamer.sectors.live_count(), streamer.sectors.pending_count()
		])
	_check("the player is still inside the atlas",
		streamer.context.sector_in_atlas(
			WorldCoords.sector_of(world_pos.x, world_pos.z)
		))
	# The queue may run deep while the player is moving; what it may not do is
	# keep work for ground nobody is near. Abandoned chunks are cancelled, so
	# the backlog is bounded by the ring rather than by the distance travelled.
	_check("generation backlog drained", streamer.queue_depth() == 0,
		"(worst queue %d, %d cancelled, worst chunks held for a sector %d)" % [
			_worst_queue, streamer.stat_chunks_cancelled, _worst_waiting
		])
	_check("contract held while streaming",
		streamer.stat_worst_contract_error <= streamer.config.corridor_epsilon,
		"(worst %.3f m at chunk %s)" % [
			streamer.stat_worst_contract_error, streamer.stat_worst_contract_chunk
		])
	_check("no missing prop meshes", PropLibrary.missing_ids().is_empty(),
		"(%s)" % [PropLibrary.missing_ids()])

	print("---")
	print("%d triangles live | %d failures" % [triangles, failures])


func _finish() -> void:
	set_process(false)
	streamer.shutdown()
	get_tree().quit(1 if failures > 0 else 0)
