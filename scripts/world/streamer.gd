class_name Streamer
extends Node3D
## Keeps the world around the player built, in the background.
##
## Order of operations per frame:
##   1. rebase the floating origin if the player has wandered too far
##   2. work out which chunks should exist and at what LOD
##   3. make sure their region is ready, then queue the chunk itself
##   4. instantiate a small number of finished chunks
##   5. drop chunks that fell outside the ring
##
## Only step 4 touches the SceneTree, and it is budgeted, so generation cost
## never lands on a single frame.

signal first_chunk_ready(chunk: Vector2i)

var config: WorldConfig
var map: WorldMap

var _queue: GenQueue
var _chunks: Dictionary = {}
var _pending_chunks: Dictionary = {}
var _regions: Dictionary = {}
var _pending_regions: Dictionary = {}
var _ready_results: Array[ChunkJob] = []
var _prop_specs: Array[PropPlacer.PropSpec] = []

var _terrain_material: Material
var _water_material: Material

## Debug switch: hides every water surface so the terrain below can be judged.
var water_visible: bool = true:
	set(value):
		water_visible = value
		for key in _chunks:
			var node: ChunkNode = _chunks[key]
			node.set_water_visible(value)

var _far_terrain: FarTerrain

var _player: Node3D
var _last_center: Vector2i = Vector2i(2147483647, 2147483647)
var _announced_first: bool = false

## Debug counters, read by the HUD.
var stat_chunks_live: int = 0
var stat_last_build_ms: int = 0
var stat_worst_contract_error: float = 0.0
## Which chunk produced that error. A contract breach is only actionable if you
## know where to go and look at it.
var stat_worst_contract_chunk: Vector2i = Vector2i(-1, -1)
var stat_triangles: int = 0


func setup(
	world_config: WorldConfig,
	world_map: WorldMap,
	player: Node3D,
	specs: Array[PropPlacer.PropSpec],
	terrain_material: Material,
	water_material: Material
) -> void:
	config = world_config
	map = world_map
	_player = player
	_prop_specs = specs
	_terrain_material = terrain_material
	_water_material = water_material
	_queue = GenQueue.new()

	_far_terrain = FarTerrain.create(config, map, terrain_material)
	add_child(_far_terrain)
	_far_terrain.refresh_transform()


func _process(_delta: float) -> void:
	if map == null:
		return
	_maybe_rebase()
	var center: Vector2i = _player_chunk()
	if center != _last_center:
		_last_center = center
		_refresh_desired(center)
	_queue.pump()
	_collect()
	_instantiate_budgeted()


# --- floating origin ----------------------------------------------------------

func _maybe_rebase() -> void:
	# Absolute world coordinates run to tens of kilometres, which float32 cannot
	# carry without visible jitter. Scene space is kept near zero instead.
	var scene_pos: Vector3 = _player.global_position
	if Vector2(scene_pos.x, scene_pos.z).length() < config.origin_rebase_distance:
		return
	var world_pos: Vector3 = WorldOrigin.to_world(scene_pos)
	var snap: float = config.chunk_size
	var new_offset: Vector3 = Vector3(
		floorf(world_pos.x / snap) * snap, 0.0, floorf(world_pos.z / snap) * snap
	)
	WorldOrigin.rebase_to(new_offset)
	for key in _chunks:
		var node: ChunkNode = _chunks[key]
		node.refresh_transform()
	if _far_terrain != null:
		_far_terrain.refresh_transform()


# --- ring management ------------------------------------------------------------

func _player_chunk() -> Vector2i:
	var world_pos: Vector3 = WorldOrigin.to_world(_player.global_position)
	return WorldCoords.chunk_of(config, world_pos.x, world_pos.z)


func _refresh_desired(center: Vector2i) -> void:
	var max_radius: int = config.lod_radius[config.lod_radius.size() - 1]
	var drop_radius: int = max_radius + config.unload_hysteresis

	for dropped in _queue.clear_waiting():
		var stale: ChunkJob = dropped
		_pending_chunks.erase(WorldCoords.chunk_key(stale.chunk))

	for dz in range(-max_radius, max_radius + 1):
		for dx in range(-max_radius, max_radius + 1):
			var chunk: Vector2i = center + Vector2i(dx, dz)
			if not _chunk_in_world(chunk):
				continue
			var ring: int = maxi(absi(dx), absi(dz))
			var lod: int = _lod_for_ring(ring)
			if lod < 0:
				continue

			var key: int = WorldCoords.chunk_key(chunk)
			if _chunks.has(key):
				var existing: ChunkNode = _chunks[key]
				if existing.lod == lod:
					continue
				# Detail changed: rebuild at the new LOD, keep showing the old
				# mesh until the replacement is ready so nothing blinks out.
			_queue_chunk(chunk, lod, float(ring))

	_unload_outside(center, drop_radius)
	_queue.sort_waiting()


func _chunk_in_world(chunk: Vector2i) -> bool:
	var limit: int = config.chunks_per_axis()
	return chunk.x >= 0 and chunk.y >= 0 and chunk.x < limit and chunk.y < limit


func _lod_for_ring(ring: int) -> int:
	for lod in config.lod_radius.size():
		if ring <= config.lod_radius[lod]:
			return lod
	return -1


func _queue_chunk(chunk: Vector2i, lod: int, priority: float) -> void:
	var key: int = WorldCoords.chunk_key(chunk)
	if _pending_chunks.has(key):
		return

	# Region first, always: a chunk may only read hydrology and roads that were
	# resolved for the whole region, never invent its own.
	var region_coord: Vector2i = WorldCoords.region_of_chunk(config, chunk)
	var region: RegionData = _ensure_region(region_coord, priority)
	if region == null:
		return

	var job: ChunkJob = ChunkJob.new()
	job.config = config
	job.map = map
	job.region = region
	job.prop_specs = _prop_specs
	job.chunk = chunk
	job.lod = lod
	job.want_collision = lod == 0
	job.want_props = lod == 0
	job.priority = priority
	_pending_chunks[key] = true
	_queue.enqueue(job)


func _ensure_region(region_coord: Vector2i, priority: float) -> RegionData:
	var key: int = WorldCoords.chunk_key(region_coord)
	if _regions.has(key):
		return _regions[key]
	if _pending_regions.has(key):
		return null
	# Regions are cheap and must exist before their chunks, so they are built
	# inline rather than racing the chunk queue.
	var data: RegionData = RegionData.build(map, region_coord)
	_regions[key] = data
	return data


func _unload_outside(center: Vector2i, drop_radius: int) -> void:
	var doomed: Array[int] = []
	for key in _chunks:
		var node: ChunkNode = _chunks[key]
		var ring: int = maxi(
			absi(node.chunk.x - center.x), absi(node.chunk.y - center.y)
		)
		if ring > drop_radius:
			doomed.append(key)
	for key in doomed:
		var node: ChunkNode = _chunks[key]
		_chunks.erase(key)
		node.queue_free()
	stat_chunks_live = _chunks.size()


# --- results ---------------------------------------------------------------------

func _collect() -> void:
	for job in _queue.collect():
		var chunk_job: ChunkJob = job
		_ready_results.append(chunk_job)


func _instantiate_budgeted() -> void:
	var budget: int = config.instantiate_budget
	while budget > 0 and not _ready_results.is_empty():
		var job: ChunkJob = _ready_results.pop_front()
		_pending_chunks.erase(WorldCoords.chunk_key(job.chunk))
		_install(job)
		budget -= 1


func _install(job: ChunkJob) -> void:
	var key: int = WorldCoords.chunk_key(job.chunk)
	if _chunks.has(key):
		var old: ChunkNode = _chunks[key]
		_chunks.erase(key)
		old.queue_free()

	var node: ChunkNode = ChunkNode.new()
	add_child(node)
	node.apply(job, _terrain_material, _water_material)
	node.set_water_visible(water_visible)
	_chunks[key] = node

	stat_chunks_live = _chunks.size()
	stat_last_build_ms = job.build_ms
	if job.max_contract_error > stat_worst_contract_error:
		stat_worst_contract_error = job.max_contract_error
		stat_worst_contract_chunk = job.chunk
	stat_triangles += node.triangle_count

	if not _announced_first:
		_announced_first = true
		first_chunk_ready.emit(job.chunk)


# --- queries -----------------------------------------------------------------------

func is_chunk_ready(chunk: Vector2i) -> bool:
	return _chunks.has(WorldCoords.chunk_key(chunk))


func queue_depth() -> int:
	return _queue.waiting_count() + _queue.running_count() + _ready_results.size()


func region_count() -> int:
	return _regions.size()


func shutdown() -> void:
	if _queue != null:
		_queue.drain()
