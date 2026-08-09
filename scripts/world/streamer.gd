class_name Streamer
extends Node3D
## Keeps the world around the player built, in the background.
##
## Order of operations per frame:
##   1. rebase the floating origin if the player has wandered too far
##   2. publish any sector that finished baking, and prefetch the neighbours
##   3. work out which chunks should exist and at what LOD
##   4. make sure the owning sector and page are ready, then queue the chunk
##   5. instantiate a small number of finished chunks
##   6. drop chunks that fell outside the ring
##
## Only step 5 touches the SceneTree, and it is budgeted, so generation cost
## never lands on a single frame.
##
## There is no world boundary. A chunk exists if the atlas has land authority
## where it is, and it is owned by exactly one sector - 8 km is exactly 125
## chunks, so ownership is a division, not a decision. Chunks are never rebuilt
## because a window moved; crossing a sector edge only means reading from the
## next immutable sector.

signal first_chunk_ready(chunk: Vector2i)

var config: WorldConfig
var context: WorldContext
var sectors: SectorManager

var _queue: GenQueue
var _chunks: Dictionary = {}
var _pending_chunks: Dictionary = {}
var _regions: Dictionary = {}
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
var _far_pending: bool = false

var _player: Node3D
var _last_center: Vector2i = Vector2i(2147483647, 2147483647)
var _last_sector: Vector2i = Vector2i(2147483647, 2147483647)
var _announced_first: bool = false

## Debug counters, read by the HUD.
var stat_chunks_live: int = 0
var stat_last_build_ms: int = 0
var stat_worst_contract_error: float = 0.0
## Which chunk produced that error. A contract breach is only actionable if you
## know where to go and look at it.
var stat_worst_contract_chunk: Vector2i = Vector2i(-1, -1)
var stat_triangles: int = 0
## Chunks the ring wanted but could not queue because their sector is still
## baking. Loud on purpose: a persistent backlog is a streaming failure, not a
## cosmetic one.
var stat_chunks_waiting_on_sector: int = 0
## Queued chunks abandoned because the ring moved off them before a worker
## picked them up.
var stat_chunks_cancelled: int = 0
## Bumped by [method rebake_interpretation] so chunk/far jobs from an older
## config never install.
var mesh_epoch: int = 0


func setup(
	world_context: WorldContext,
	sector_manager: SectorManager,
	player: Node3D,
	specs: Array[PropPlacer.PropSpec],
	terrain_material: Material,
	water_material: Material
) -> void:
	context = world_context
	config = world_context.config
	sectors = sector_manager
	_player = player
	_prop_specs = specs
	_terrain_material = terrain_material
	_water_material = water_material
	_queue = GenQueue.new()

	_far_terrain = FarTerrain.create(terrain_material)
	add_child(_far_terrain)


func _process(_delta: float) -> void:
	if sectors == null:
		return
	_maybe_rebase()
	sectors.pump()

	var world_pos: Vector3 = WorldOrigin.to_world(_player.global_position)
	var sector: Vector2i = WorldCoords.sector_of(world_pos.x, world_pos.z)
	if sector != _last_sector:
		_last_sector = sector
		sectors.request_around(sector)
		# A sector change invalidates nothing that is already built, but it does
		# mean pages from an evicted sector must not be handed to new chunks.
		_forget_stale_regions()

	var center: Vector2i = WorldCoords.chunk_of(config, world_pos.x, world_pos.z)
	if center != _last_center:
		_last_center = center
	# Re-run every frame rather than only on a chunk change: the ring may have
	# been unable to queue work last time because a sector was still baking.
	_refresh_desired(center)

	_maybe_refresh_far(Vector2(world_pos.x, world_pos.z))
	_queue.pump()
	_collect()
	_instantiate_budgeted()


# --- floating origin ----------------------------------------------------------

func _maybe_rebase() -> void:
	# Continental coordinates run to hundreds of kilometres, which float32
	# cannot carry without visible jitter. Scene space is kept near zero
	# instead, and rebasing never changes a generation coordinate.
	var scene_pos: Vector3 = _player.global_position
	if Vector2(scene_pos.x, scene_pos.z).length() < config.origin_rebase_distance:
		return
	var world_pos: Vector3 = WorldOrigin.to_world(scene_pos)
	var snap: float = config.chunk_size
	var new_offset: Vector3 = Vector3(
		floorf(world_pos.x / snap) * snap, 0.0, floorf(world_pos.z / snap) * snap
	)
	WorldOrigin.rebase_to(new_offset)
	refresh_origin_transforms()


## Re-place every chunk (and the far backdrop) after an external origin rebase,
## e.g. a map teleport that jumped farther than the usual walk-driven snap.
func refresh_origin_transforms() -> void:
	for key in _chunks:
		var node: ChunkNode = _chunks[key]
		node.refresh_transform()
	if _far_terrain != null:
		_far_terrain.refresh_transform()


# --- horizon --------------------------------------------------------------------

func _maybe_refresh_far(at: Vector2) -> void:
	if _far_pending or not _far_terrain.needs_recentre(at):
		return
	var job: FarTerrainJob = FarTerrainJob.new()
	job.context = context
	job.centre = at
	job.mesh_epoch = mesh_epoch
	# Behind every chunk: the backdrop can wait, the ground cannot.
	job.priority = 10000.0
	_far_pending = true
	_queue.enqueue(job)


# --- ring management ------------------------------------------------------------

func _refresh_desired(center: Vector2i) -> void:
	var max_radius: int = config.lod_radius[config.lod_radius.size() - 1]
	var drop_radius: int = max_radius + config.unload_hysteresis
	var waiting: int = 0

	for dz in range(-max_radius, max_radius + 1):
		for dx in range(-max_radius, max_radius + 1):
			var chunk: Vector2i = center + Vector2i(dx, dz)
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
			if not _queue_chunk(chunk, lod, float(ring)):
				waiting += 1

	stat_chunks_waiting_on_sector = waiting
	_unload_outside(center, drop_radius)
	_cancel_outside(center, drop_radius)
	_queue.sort_waiting()


func _lod_for_ring(ring: int) -> int:
	for lod in config.lod_radius.size():
		if ring <= config.lod_radius[lod]:
			return lod
	return -1


## Returns false when the chunk could not be queued yet because its sector is
## still baking. The caller counts those rather than meshing a guess.
func _queue_chunk(chunk: Vector2i, lod: int, priority: float) -> bool:
	var key: int = WorldCoords.chunk_key(chunk)
	if _pending_chunks.has(key):
		return true

	var sector_coord: Vector2i = WorldCoords.sector_of_chunk(config, chunk)
	if not context.sector_in_atlas(sector_coord):
		# Off the edge of the continent there is no authority for climate or
		# coast, so there is nothing to mesh.
		return true
	var sector: WorldSector = sectors.get_sector(sector_coord)
	if sector == null:
		sectors.request(sector_coord, priority)
		return false

	# Page first, always: a chunk may only read hydrology and roads that were
	# resolved for the whole page, never invent its own.
	var region_coord: Vector2i = WorldCoords.region_of_chunk(config, chunk)
	var region: RegionData = _ensure_region(sector, region_coord)

	var job: ChunkJob = ChunkJob.new()
	job.config = config
	job.context = context
	job.sector = sector
	job.region = region
	job.prop_specs = _prop_specs
	job.chunk = chunk
	job.lod = lod
	job.want_collision = lod == 0
	job.want_props = lod == 0
	job.priority = priority
	job.mesh_epoch = mesh_epoch
	_pending_chunks[key] = true
	_queue.enqueue(job)
	return true


func _ensure_region(sector: WorldSector, region_coord: Vector2i) -> RegionData:
	var key: int = WorldCoords.region_key(region_coord)
	if _regions.has(key):
		return _regions[key]
	# Pages are cheap and must exist before their chunks, so they are built
	# inline rather than racing the chunk queue.
	var data: RegionData = RegionData.build(sector, region_coord)
	_regions[key] = data
	return data


## Pages belong to a sector. When a sector is evicted its pages must go too, or
## a later chunk would be handed features from a sector nobody holds any more.
func _forget_stale_regions() -> void:
	var doomed: Array[int] = []
	for key in _regions:
		var page: RegionData = _regions[key]
		var owner: Vector2i = WorldCoords.sector_of(
			page.rect.position.x + 1.0, page.rect.position.y + 1.0
		)
		if not sectors.has_sector(owner):
			doomed.append(key)
	for key in doomed:
		_regions.erase(key)


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


## Forgets queued chunks the player has already left behind.
##
## The ring is re-evaluated every frame, so a player moving faster than the
## world builds can queue thousands of chunks that were abandoned before a
## worker ever reached them. Left in place they starve the ground ahead: the
## queue is worked nearest-first, but "nearest" was decided when the job was
## enqueued, not now.
func _cancel_outside(center: Vector2i, drop_radius: int) -> void:
	var dropped: Array[GenQueue.Job] = _queue.drop_waiting(
		func(job: GenQueue.Job) -> bool:
			if job is not ChunkJob:
				return false
			var chunk: Vector2i = (job as ChunkJob).chunk
			var ring: int = maxi(absi(chunk.x - center.x), absi(chunk.y - center.y))
			return ring > drop_radius
	)
	for job in dropped:
		_pending_chunks.erase(WorldCoords.chunk_key((job as ChunkJob).chunk))
	stat_chunks_cancelled += dropped.size()


# --- results ---------------------------------------------------------------------

func _collect() -> void:
	for job in _queue.collect():
		if job is FarTerrainJob:
			var far_job: FarTerrainJob = job
			_far_pending = false
			if far_job.mesh_epoch != mesh_epoch:
				continue
			_far_terrain.apply(far_job.result)
			continue
		var chunk_job: ChunkJob = job as ChunkJob
		if chunk_job.mesh_epoch != mesh_epoch:
			_pending_chunks.erase(WorldCoords.chunk_key(chunk_job.chunk))
			continue
		_ready_results.append(chunk_job)


func _instantiate_budgeted() -> void:
	var budget: int = config.instantiate_budget
	var drop_radius: int = (
		config.lod_radius[config.lod_radius.size() - 1] + config.unload_hysteresis
	)
	while budget > 0 and not _ready_results.is_empty():
		var job: ChunkJob = _ready_results.pop_front()
		_pending_chunks.erase(WorldCoords.chunk_key(job.chunk))
		var ring: int = maxi(
			absi(job.chunk.x - _last_center.x), absi(job.chunk.y - _last_center.y)
		)
		# Finished, but the player has moved on. Building the nodes only to drop
		# them next frame spends the frame budget that the ground ahead needs.
		if ring > drop_radius:
			continue
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


## Drops live meshes and requeues sector bakes so interpretation knobs on the
## shared [WorldConfig] take effect around the player. Atlas is untouched.
func rebake_interpretation() -> void:
	if sectors == null or _player == null:
		return
	mesh_epoch += 1
	var world_pos: Vector3 = WorldOrigin.to_world(_player.global_position)
	var sector: Vector2i = WorldCoords.sector_of(world_pos.x, world_pos.z)
	sectors.invalidate_around(sector)

	for key in _chunks.keys():
		var node: ChunkNode = _chunks[key]
		node.queue_free()
	_chunks.clear()
	_pending_chunks.clear()
	_ready_results.clear()
	_regions.clear()
	_queue.drop_waiting(
		func(job: GenQueue.Job) -> bool:
			return job is ChunkJob or job is FarTerrainJob
	)
	_far_pending = false
	if _far_terrain != null:
		_far_terrain.clear()
	_last_sector = Vector2i(2147483647, 2147483647)
	_last_center = Vector2i(2147483647, 2147483647)
	stat_chunks_live = 0
	stat_chunks_waiting_on_sector = 0


func shutdown() -> void:
	if _queue != null:
		_queue.drain()
