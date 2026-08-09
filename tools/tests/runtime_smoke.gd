extends Node
## Boots the real main scene headless and walks the player across the world.
##
##   godot --headless --path <project> res://tools/tests/runtime_smoke.tscn
##
## Runs as a scene rather than a --script main loop so the project's autoloads
## (the floating origin) exist exactly as they do in the game.
##
## Proves the parts a data test cannot: chunks stream in around a moving player,
## the spawn lands on real collision, water and props are instantiated, and the
## floating origin rebases without losing the world.

## Measured in seconds, not frames: the world bake alone takes tens of seconds
## and a headless main loop spins far faster than a real one.
const WARMUP_SECONDS: float = 180.0
const WALK_FRAMES: int = 2200
const WALK_SPEED: float = 22.0

var main: Node3D
var streamer: Streamer
var player: PlayerController
var frames: int = 0
var spawned_frame: int = -1
var rebases: int = 0
var failures: int = 0
var started_msec: int = 0


func _ready() -> void:
	print("=== Orrun runtime smoke ===")
	started_msec = Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	streamer = main.get_node("Streamer")
	player = main.get_node("Player")
	WorldOrigin.rebased.connect(func(_delta: Vector3) -> void: rebases += 1)


func _process(_delta: float) -> void:
	frames += 1

	if spawned_frame < 0:
		if not player.frozen:
			spawned_frame = frames
			print("spawned after %d frames at world %s" % [frames, player.world_position()])
		elif Time.get_ticks_msec() - started_msec > int(WARMUP_SECONDS * 1000.0):
			_fail("player never spawned (%d chunks live, world baked: %s)" % [
				streamer.stat_chunks_live, streamer.map != null
			])
			_finish()
		return

	# Fly east so the ring has to load and unload continuously.
	player.flying = true
	player.global_position += Vector3(WALK_SPEED / 60.0, 0.0, 0.0)

	if frames >= spawned_frame + WALK_FRAMES:
		_report()
		_finish()


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

	print("travelled to world %s over %d frames" % [world_pos, frames])
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
	_check("player still on the map",
		WorldCoords.in_bounds(streamer.config, world_pos.x, world_pos.z))
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
