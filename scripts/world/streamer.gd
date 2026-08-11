class_name Streamer
extends Node3D
## Keeps the world around the player built, in the background.

const _HitchLog: GDScript = preload("res://scripts/core/hitch_log.gd")
##
## Order of operations per frame:
##   1. rebase the floating origin if the player has wandered too far
##   2. publish any sector that finished baking, and prefetch the neighbours
##   3. work out which chunks should exist and at what LOD
##   4. make sure the owning sector and page are ready, then queue the chunk
##   5. instantiate a small number of finished chunks
##   6. drop chunks that fell outside the ring
##
## Only step 5 touches the SceneTree, and it is budgeted (with a per-frame
## collision-install cap). Sector/page/chunk generation runs on workers.
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
var _pending_regions: Dictionary = {}
## Chunks that could not be queued yet (sector/page not ready). Retried when a
## sector/page publishes, not every frame.
var _blocked_chunks: Dictionary = {}
var _blocked_retry_cursor: int = 0
var _chunks_since_retarget: int = 0
var _ready_results: Array[ChunkJob] = []
## ChunkNodes waiting to install deferred concave collision (one soup per frame).
var _collision_deferred: Array[ChunkNode] = []
var _prop_specs: Array[PropPlacer.PropSpec] = []
var _clutter_specs: Array[GroundClutter.Spec] = []
## Soft cap for one blocked-chunk retry slice (microseconds).
const BLOCKED_RETRY_BUDGET_USEC: int = 1500

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
## Set by [method shutdown]; stops pumping and skips new cache writes.
var _shutting_down: bool = false
## In-flight [BakeCache.save_chunk] worker tasks; joined in [method shutdown].
var _chunk_save_tasks: Array[int] = []

## Debug counters, read by the HUD.
var stat_chunks_live: int = 0
var stat_last_build_ms: int = 0
var stat_last_density_ms: int = 0
var stat_last_columns_ms: int = 0
var stat_last_volume_ms: int = 0
var stat_last_mesh_ms: int = 0
var stat_last_water_ms: int = 0
var stat_last_dress_ms: int = 0
var stat_last_props_ms: int = 0
var stat_last_clutter_ms: int = 0
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

## Last Streamer._process cost (ms) and phase breakdown for the HUD / hitch log.
var stat_frame_ms: float = 0.0
var stat_install_ms: float = 0.0
var stat_installed_this_frame: int = 0
var stat_last_frame_parts: Dictionary = {}


func setup(
	world_context: WorldContext,
	sector_manager: SectorManager,
	player: Node3D,
	specs: Array[PropPlacer.PropSpec],
	terrain_material: Material,
	water_material: Material,
	clutter_specs: Array[GroundClutter.Spec] = []
) -> void:
	context = world_context
	config = world_context.config
	sectors = sector_manager
	_player = player
	_prop_specs = specs
	_clutter_specs = clutter_specs
	_terrain_material = terrain_material
	_water_material = water_material
	# Prefer most of the machine for chunks; sector bakes stay on a smaller pool.
	_queue = GenQueue.new(maxi(OS.get_processor_count() - 1, 3))

	_far_terrain = FarTerrain.create(terrain_material)
	add_child(_far_terrain)


func _process(_delta: float) -> void:
	if sectors == null or _shutting_down:
		return
	_HitchLog.ensure_open()
	var frame_t0: int = Time.get_ticks_usec()
	var parts: Dictionary = {}

	var t0: int = Time.get_ticks_usec()
	_maybe_rebase()
	parts["rebase"] = (Time.get_ticks_usec() - t0) * 0.001

	var sectors_before: int = sectors.stat_generated
	t0 = Time.get_ticks_usec()
	sectors.pump()
	parts["sectors_pump"] = (Time.get_ticks_usec() - t0) * 0.001
	var sector_publishes: int = sectors.stat_generated - sectors_before

	var world_pos: Vector3 = WorldOrigin.to_world(_player.global_position)
	var sector: Vector2i = WorldCoords.sector_of(world_pos.x, world_pos.z)
	var sector_changed: bool = sector != _last_sector
	if sector_changed:
		_last_sector = sector
		sectors.request_around(sector)
		# A sector change invalidates nothing that is already built, but it does
		# mean pages from an evicted sector must not be handed to new chunks.
		t0 = Time.get_ticks_usec()
		_forget_stale_regions()
		parts["forget_regions"] = (Time.get_ticks_usec() - t0) * 0.001

	var center: Vector2i = WorldCoords.chunk_of(config, world_pos.x, world_pos.z)
	var center_changed: bool = center != _last_center
	if center_changed:
		_last_center = center

	t0 = Time.get_ticks_usec()
	_maybe_refresh_far(Vector2(world_pos.x, world_pos.z))
	parts["far_queue"] = (Time.get_ticks_usec() - t0) * 0.001

	t0 = Time.get_ticks_usec()
	_queue.pump()
	parts["queue_pump"] = (Time.get_ticks_usec() - t0) * 0.001

	t0 = Time.get_ticks_usec()
	var collect_stats: Dictionary = _collect()
	parts["collect"] = (Time.get_ticks_usec() - t0) * 0.001
	parts["far_apply"] = float(collect_stats.get("far_apply_ms", 0.0))
	parts["region_collect"] = float(collect_stats.get("region_ms", 0.0))
	var region_publishes: int = int(collect_stats.get("regions_ready", 0))

	# Refresh after collect so a page that finished this frame can enqueue chunks.
	t0 = Time.get_ticks_usec()
	_refresh_desired(center, center_changed, sector_publishes, region_publishes)
	parts["refresh_desired"] = (Time.get_ticks_usec() - t0) * 0.001

	t0 = Time.get_ticks_usec()
	var install_stats: Dictionary = _instantiate_budgeted()
	parts["instantiate"] = (Time.get_ticks_usec() - t0) * 0.001
	parts["install_terrain"] = float(install_stats.get("terrain_ms", 0.0))
	parts["install_water"] = float(install_stats.get("water_ms", 0.0))
	parts["install_bridges"] = float(install_stats.get("bridges_ms", 0.0))
	parts["install_props"] = float(install_stats.get("props_ms", 0.0))

	t0 = Time.get_ticks_usec()
	parts["deferred_collision"] = _install_one_deferred_collision()
	parts["instantiate"] = float(parts["instantiate"]) + float(parts["deferred_collision"])

	stat_frame_ms = (Time.get_ticks_usec() - frame_t0) * 0.001
	stat_install_ms = float(parts["instantiate"])
	stat_installed_this_frame = int(install_stats.get("count", 0))
	stat_last_frame_parts = parts

	var note: String = "live=%d ready=%d queue=%d wait_sector=%d installed=%d center_chg=%s sector_chg=%s sec_pub=%d reg_pub=%d blocked=%d" % [
		stat_chunks_live,
		_ready_results.size(),
		queue_depth(),
		stat_chunks_waiting_on_sector,
		stat_installed_this_frame,
		str(center_changed),
		str(sector_changed),
		sector_publishes,
		region_publishes,
		_blocked_chunks.size(),
	]
	if int(install_stats.get("collision_faces", 0)) > 0:
		note += " coll_faces=%d" % int(install_stats["collision_faces"])
	_HitchLog.record("streamer", stat_frame_ms, parts, note)


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

func _refresh_desired(
	center: Vector2i,
	center_changed: bool,
	sector_publishes: int,
	region_publishes: int
) -> void:
	var max_radius: int = config.lod_radius[config.lod_radius.size() - 1]
	var drop_radius: int = max_radius + config.unload_hysteresis
	var waiting: int = 0

	# Underfoot must not wait on the far-ring blocked-retry cursor. Always try
	# the walk ring first so region/chunk jobs for the player land in the queue.
	_ensure_near_chunks(center, mini(2, config.lod_radius[0]))

	if center_changed:
		# Near rings first so region requests and chunk jobs enter the queue in
		# the order workers should run them (sort is a backup, not the only gate).
		for ring in range(0, max_radius + 1):
			var lod: int = _lod_for_ring(ring)
			if lod < 0:
				continue
			for chunk in _chunks_on_ring(center, ring):
				var key: int = WorldCoords.chunk_key(chunk)
				if _chunks.has(key):
					var existing: ChunkNode = _chunks[key]
					if _chunk_is_current(existing, lod, ring):
						_blocked_chunks.erase(key)
						continue
					# LOD change or missing clutter dress: rebuild, keep showing
					# the old mesh until the replacement is ready.
				if not _queue_chunk(chunk, lod, float(ring)):
					waiting += 1
		_prune_blocked(center, drop_radius)
		_unload_outside(center, drop_radius)
		# Cancel + retarget are O(waiting). At sprint speeds the waiting queue
		# can be hundreds of jobs; do both every few chunk crossings only.
		_chunks_since_retarget += 1
		if _chunks_since_retarget >= 3:
			_chunks_since_retarget = 0
			_cancel_outside(center, drop_radius)
			var focus_region: Vector2i = WorldCoords.region_of_chunk(config, center)
			_queue.retarget_waiting(
				func(job: GenQueue.Job) -> void:
					if job is ChunkJob:
						var c: Vector2i = (job as ChunkJob).chunk
						job.priority = float(maxi(absi(c.x - center.x), absi(c.y - center.y)))
					elif job is ChunkCacheLoadJob:
						var lc: Vector2i = (job as ChunkCacheLoadJob).chunk
						job.priority = float(maxi(absi(lc.x - center.x), absi(lc.y - center.y)))
					elif job is RegionJob:
						var r: Vector2i = (job as RegionJob).region
						job.priority = (
							float(maxi(absi(r.x - focus_region.x), absi(r.y - focus_region.y)))
							- 0.5
						)
					elif job is FarTerrainJob:
						job.priority = 10000.0
			)
	elif sector_publishes > 0 or region_publishes > 0:
		waiting = _retry_blocked(center)
	elif not _blocked_chunks.is_empty():
		# Keep draining nearest blocked work even between publishes — pages often
		# unlock more chunks than one budgeted slice clears.
		waiting = _retry_blocked(center)
	else:
		waiting = 0

	stat_chunks_waiting_on_sector = waiting


## Queue the Chebyshev disc around the player without the far-ring scan cost.
func _ensure_near_chunks(center: Vector2i, near_ring: int) -> void:
	for ring in range(0, near_ring + 1):
		var lod: int = _lod_for_ring(ring)
		if lod < 0:
			continue
		for chunk in _chunks_on_ring(center, ring):
			var key: int = WorldCoords.chunk_key(chunk)
			if _chunks.has(key) and _chunk_is_current(_chunks[key] as ChunkNode, lod, ring):
				_blocked_chunks.erase(key)
				continue
			_queue_chunk(chunk, lod, float(ring))


## True when the live chunk already matches the desired LOD and dress level.
## Clutter is gated by [member WorldConfig.clutter_max_ring] at first mesh time;
## without this upgrade, grass only appears under the original spawn ring.
func _chunk_is_current(node: ChunkNode, lod: int, ring: int) -> bool:
	if node.lod != lod:
		return false
	if (
		lod == 0
		and config.props_enabled
		and ring <= config.clutter_max_ring
		and not node.has_clutter
	):
		return false
	return true


func _chunks_on_ring(center: Vector2i, ring: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if ring == 0:
		out.append(center)
		return out
	# Perimeter of the Chebyshev square at this ring.
	for dx in range(-ring, ring + 1):
		out.append(center + Vector2i(dx, -ring))
		out.append(center + Vector2i(dx, ring))
	for dz in range(-ring + 1, ring):
		out.append(center + Vector2i(-ring, dz))
		out.append(center + Vector2i(ring, dz))
	return out


func _retry_blocked(center: Vector2i) -> int:
	if _blocked_chunks.is_empty():
		return 0
	# Nearest first — a round-robin cursor was starving underfoot behind hundreds
	# of far blocked entries after each region publish.
	var entries: Array[Dictionary] = []
	for key_variant in _blocked_chunks.keys():
		var key: int = int(key_variant)
		var entry: Dictionary = _blocked_chunks[key]
		var chunk: Vector2i = entry["chunk"]
		var ring: int = maxi(absi(chunk.x - center.x), absi(chunk.y - center.y))
		entries.append({
			"key": key,
			"chunk": chunk,
			"lod": int(entry["lod"]),
			"ring": ring,
		})
	entries.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return int(a["ring"]) < int(b["ring"])
	)
	var started: int = Time.get_ticks_usec()
	var examined: int = 0
	while examined < entries.size() and Time.get_ticks_usec() - started < BLOCKED_RETRY_BUDGET_USEC:
		var e: Dictionary = entries[examined]
		_queue_chunk(e["chunk"], int(e["lod"]), float(e["ring"]))
		examined += 1
	_blocked_retry_cursor = 0
	return _blocked_chunks.size()


func _prune_blocked(center: Vector2i, drop_radius: int) -> void:
	var doomed: Array[int] = []
	for key_variant in _blocked_chunks.keys():
		var key: int = key_variant
		var chunk: Vector2i = _blocked_chunks[key]["chunk"]
		var ring: int = maxi(absi(chunk.x - center.x), absi(chunk.y - center.y))
		if ring > drop_radius:
			doomed.append(key)
	for key in doomed:
		_blocked_chunks.erase(key)


func _lod_for_ring(ring: int) -> int:
	for lod in config.lod_radius.size():
		if ring <= config.lod_radius[lod]:
			return lod
	return -1


## Returns false when the chunk could not be queued yet because its sector is
## still baking. The caller counts those rather than meshing a guess. Waiting on
## a region page still returns true — work is already in flight.
func _queue_chunk(chunk: Vector2i, lod: int, priority: float) -> bool:
	var key: int = WorldCoords.chunk_key(chunk)
	if _pending_chunks.has(key):
		_blocked_chunks.erase(key)
		return true

	var sector_coord: Vector2i = WorldCoords.sector_of_chunk(config, chunk)
	if not context.sector_in_atlas(sector_coord):
		# Off the edge of the continent there is no authority for climate or
		# coast, so there is nothing to mesh.
		_blocked_chunks.erase(key)
		return true

	# Fast path: still waiting on the same sector/page — do not rebuild the
	# blocked entry or re-request the sector on every center step.
	if _blocked_chunks.has(key) and int(_blocked_chunks[key]["lod"]) == lod:
		var sector_fast: WorldSector = sectors.get_sector(sector_coord)
		if sector_fast == null:
			_blocked_chunks[key]["priority"] = priority
			return false
		var region_fast: RegionData = _region_or_request(sector_fast, WorldCoords.region_of_chunk(config, chunk), priority)
		if region_fast == null:
			_blocked_chunks[key]["priority"] = priority
			return true
		return _enqueue_chunk_job(key, chunk, lod, priority, sector_fast, region_fast)

	var sector: WorldSector = sectors.get_sector(sector_coord)
	if sector == null:
		sectors.request(sector_coord, priority)
		_blocked_chunks[key] = {"chunk": chunk, "lod": lod, "priority": priority}
		return false

	# Page first, always: a chunk may only read hydrology and roads that were
	# resolved for the whole page, never invent its own.
	var region_coord: Vector2i = WorldCoords.region_of_chunk(config, chunk)
	var region: RegionData = _region_or_request(sector, region_coord, priority)
	if region == null:
		_blocked_chunks[key] = {"chunk": chunk, "lod": lod, "priority": priority}
		return true

	return _enqueue_chunk_job(key, chunk, lod, priority, sector, region)


func _enqueue_chunk_job(
	key: int,
	chunk: Vector2i,
	lod: int,
	priority: float,
	sector: WorldSector,
	region: RegionData
) -> bool:
	_pending_chunks[key] = true
	_blocked_chunks.erase(key)

	# Warm underfoot ring: load from disk on a worker (not the main thread —
	# sync FileAccess of ~0.4 MB meshes was ~130 ms/chunk and felt like a remesh).
	if lod == 0 and BakeCache.is_warm_ring(priority) and BakeCache.has_chunk(context, chunk):
		var load_job: ChunkCacheLoadJob = ChunkCacheLoadJob.new()
		load_job.context = context
		load_job.sector = sector
		load_job.region = region
		load_job.chunk = chunk
		load_job.lod = lod
		load_job.priority = priority
		load_job.mesh_epoch = mesh_epoch
		_queue.enqueue(load_job)
		return true
	if lod == 0 and BakeCache.is_warm_ring(priority):
		print("BakeCache: chunk %s miss" % [chunk])

	_enqueue_mesh_job(chunk, lod, priority, sector, region)
	return true


func _enqueue_mesh_job(
	chunk: Vector2i,
	lod: int,
	priority: float,
	sector: WorldSector,
	region: RegionData
) -> void:
	var job: ChunkJob = ChunkJob.new()
	job.config = config
	job.context = context
	job.sector = sector
	job.region = region
	job.prop_specs = _prop_specs
	job.clutter_specs = _clutter_specs
	job.chunk = chunk
	job.lod = lod
	job.want_collision = lod == 0
	job.want_props = lod == 0 and int(priority) <= config.props_max_ring
	job.want_clutter = lod == 0 and int(priority) <= config.clutter_max_ring
	job.priority = priority
	job.mesh_epoch = mesh_epoch
	_queue.enqueue(job)


## Returns a ready page, or null after ensuring a [RegionJob] is queued.
func _region_or_request(
	sector: WorldSector, region_coord: Vector2i, priority: float
) -> RegionData:
	var key: int = WorldCoords.region_key(region_coord)
	if _regions.has(key):
		return _regions[key]
	if _pending_regions.has(key):
		return null
	var job: RegionJob = RegionJob.new()
	job.sector = sector
	job.region = region_coord
	# Slightly ahead of the chunk that needed it.
	job.priority = priority - 0.5
	job.mesh_epoch = mesh_epoch
	_pending_regions[key] = true
	_queue.enqueue(job)
	return null


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
		_pending_regions.erase(key)


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
		_collision_deferred.erase(node)
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
			var chunk: Vector2i
			if job is ChunkJob:
				chunk = (job as ChunkJob).chunk
			elif job is ChunkCacheLoadJob:
				chunk = (job as ChunkCacheLoadJob).chunk
			else:
				return false
			var ring: int = maxi(absi(chunk.x - center.x), absi(chunk.y - center.y))
			return ring > drop_radius
	)
	for job in dropped:
		var chunk: Vector2i
		if job is ChunkJob:
			chunk = (job as ChunkJob).chunk
		else:
			chunk = (job as ChunkCacheLoadJob).chunk
		_pending_chunks.erase(WorldCoords.chunk_key(chunk))
	stat_chunks_cancelled += dropped.size()


# --- results ---------------------------------------------------------------------

func _collect() -> Dictionary:
	var far_apply_ms: float = 0.0
	var region_ms: float = 0.0
	var regions_ready: int = 0
	for job in _queue.collect():
		if job is FarTerrainJob:
			var far_job: FarTerrainJob = job
			_far_pending = false
			if far_job.mesh_epoch != mesh_epoch:
				continue
			var t0: int = Time.get_ticks_usec()
			_far_terrain.apply(far_job.result)
			far_apply_ms += (Time.get_ticks_usec() - t0) * 0.001
			continue
		if job is RegionJob:
			var region_job: RegionJob = job
			var region_key: int = WorldCoords.region_key(region_job.region)
			_pending_regions.erase(region_key)
			if region_job.mesh_epoch != mesh_epoch or region_job.result == null:
				continue
			var owner: Vector2i = WorldCoords.sector_of(
				region_job.result.rect.position.x + 1.0,
				region_job.result.rect.position.y + 1.0
			)
			if not sectors.has_sector(owner):
				continue
			var t1: int = Time.get_ticks_usec()
			_regions[region_key] = region_job.result
			region_ms += (Time.get_ticks_usec() - t1) * 0.001
			regions_ready += 1
			continue
		if job is ChunkCacheLoadJob:
			var load_job: ChunkCacheLoadJob = job
			var load_key: int = WorldCoords.chunk_key(load_job.chunk)
			if load_job.mesh_epoch != mesh_epoch:
				_pending_chunks.erase(load_key)
				continue
			if load_job.result != null:
				var cached: ChunkJob = load_job.result
				cached.prop_specs = _prop_specs
				cached.clutter_specs = _clutter_specs
				cached.priority = load_job.priority
				cached.mesh_epoch = mesh_epoch
				cached.from_cache = true
				cached.build_ms = load_job.load_ms
				_ready_results.append(cached)
				print("BakeCache: chunk %s hit (%d ms)" % [load_job.chunk, load_job.load_ms])
			else:
				push_warning(
					"BakeCache: chunk %s load failed; remeshing" % [load_job.chunk]
				)
				_enqueue_mesh_job(
					load_job.chunk, load_job.lod, load_job.priority,
					load_job.sector, load_job.region
				)
			continue
		var chunk_job: ChunkJob = job as ChunkJob
		if chunk_job.mesh_epoch != mesh_epoch:
			_pending_chunks.erase(WorldCoords.chunk_key(chunk_job.chunk))
			continue
		_ready_results.append(chunk_job)
	return {
		"far_apply_ms": far_apply_ms,
		"region_ms": region_ms,
		"regions_ready": regions_ready,
	}


func _instantiate_budgeted() -> Dictionary:
	var stats: Dictionary = {
		"count": 0,
		"terrain_ms": 0.0,
		"water_ms": 0.0,
		"bridges_ms": 0.0,
		"props_ms": 0.0,
		"collision_faces": 0,
	}
	var drop_radius: int = (
		config.lod_radius[config.lod_radius.size() - 1] + config.unload_hysteresis
	)
	# Drop results that fell outside the keep ring.
	var kept: Array[ChunkJob] = []
	var near_ready: int = 0
	for job in _ready_results:
		var ring: int = maxi(
			absi(job.chunk.x - _last_center.x), absi(job.chunk.y - _last_center.y)
		)
		if ring > drop_radius:
			_pending_chunks.erase(WorldCoords.chunk_key(job.chunk))
			continue
		kept.append(job)
		if ring <= 2:
			near_ready += 1
	_ready_results = kept

	var budget: int = config.instantiate_budget
	if near_ready > 0:
		budget = mini(
			config.instantiate_budget_burst,
			config.instantiate_budget + near_ready
		)

	# Always install nearest finished ground first. Far LODs finish sooner and
	# used to append at the front of the budget, so underfoot stayed empty while
	# the horizon filled in.
	while budget > 0 and not _ready_results.is_empty():
		var best_i: int = _nearest_ready_index()
		if best_i < 0:
			break
		var job: ChunkJob = _ready_results[best_i]
		_ready_results.remove_at(best_i)
		_pending_chunks.erase(WorldCoords.chunk_key(job.chunk))
		# LOD0 always installs walk collision with the mesh. Deferring left
		# visible ground the player could walk onto before the collider existed.
		var defer_collision: bool = false
		var apply_stats: Dictionary = _install(job, defer_collision)
		stats["count"] = int(stats["count"]) + 1
		stats["terrain_ms"] = float(stats["terrain_ms"]) + float(apply_stats.get("terrain_ms", 0.0))
		stats["water_ms"] = float(stats["water_ms"]) + float(apply_stats.get("water_ms", 0.0))
		stats["bridges_ms"] = float(stats["bridges_ms"]) + float(apply_stats.get("bridges_ms", 0.0))
		stats["props_ms"] = float(stats["props_ms"]) + float(apply_stats.get("props_ms", 0.0))
		stats["collision_faces"] = (
			int(stats["collision_faces"]) + int(apply_stats.get("collision_faces", 0))
		)
		budget -= 1
	return stats


func _nearest_ready_index() -> int:
	var best_i: int = -1
	var best_ring: int = 2147483647
	var best_lod: int = 2147483647
	for i in _ready_results.size():
		var job: ChunkJob = _ready_results[i]
		var ring: int = maxi(
			absi(job.chunk.x - _last_center.x), absi(job.chunk.y - _last_center.y)
		)
		# Prefer closer, then finer LOD (lower number) at the same ring.
		if ring < best_ring or (ring == best_ring and job.lod < best_lod):
			best_ring = ring
			best_lod = job.lod
			best_i = i
	return best_i


func _install_one_deferred_collision() -> float:
	# Prefer colliders nearest the player so spawn/fauna are not stuck behind
	# horizon soups.
	var best_i: int = -1
	var best_ring: int = 2147483647
	for i in _collision_deferred.size():
		var candidate: ChunkNode = _collision_deferred[i]
		if not is_instance_valid(candidate) or not candidate.has_deferred_collision():
			continue
		var ring: int = maxi(
			absi(candidate.chunk.x - _last_center.x),
			absi(candidate.chunk.y - _last_center.y)
		)
		if ring < best_ring:
			best_ring = ring
			best_i = i
	if best_i < 0:
		_collision_deferred.clear()
		return 0.0
	if best_i > 0:
		var near: ChunkNode = _collision_deferred[best_i]
		_collision_deferred.remove_at(best_i)
		_collision_deferred.insert(0, near)
	var node: ChunkNode = _collision_deferred[0]
	var ms: float = node.install_deferred_collision()
	if not node.has_deferred_collision():
		_collision_deferred.remove_at(0)
	return ms


func _install(job: ChunkJob, defer_collision: bool) -> Dictionary:
	var key: int = WorldCoords.chunk_key(job.chunk)
	if _chunks.has(key):
		var old: ChunkNode = _chunks[key]
		_chunks.erase(key)
		_collision_deferred.erase(old)
		old.queue_free()

	var node: ChunkNode = ChunkNode.new()
	add_child(node)
	var apply_stats: Dictionary = node.apply(
		job, _terrain_material, _water_material, defer_collision
	)
	node.set_water_visible(water_visible)
	_chunks[key] = node
	if bool(apply_stats.get("deferred_collision", false)):
		_collision_deferred.append(node)

	stat_chunks_live = _chunks.size()
	stat_last_build_ms = job.build_ms
	stat_last_density_ms = job.density_ms
	stat_last_columns_ms = job.columns_ms
	stat_last_volume_ms = job.volume_ms
	stat_last_mesh_ms = job.mesh_ms
	stat_last_water_ms = job.water_ms
	stat_last_dress_ms = job.dress_ms
	stat_last_props_ms = job.props_ms
	stat_last_clutter_ms = job.clutter_ms
	if job.max_contract_error > stat_worst_contract_error:
		stat_worst_contract_error = job.max_contract_error
		stat_worst_contract_chunk = job.chunk
	stat_triangles += node.triangle_count

	if not _announced_first:
		_announced_first = true
		first_chunk_ready.emit(job.chunk)
	_maybe_save_warm_chunk(job)
	return apply_stats


## Persist freshly meshed LOD0 underfoot chunks. Runs on a worker, but the task
## id is tracked so [method shutdown] can join before the tree is torn down —
## orphaned WorkerThreadPool tasks were crashing on window close.
func _maybe_save_warm_chunk(job: ChunkJob) -> void:
	if _shutting_down or job.lod != 0 or job.from_cache:
		return
	var ring: int = maxi(
		absi(job.chunk.x - _last_center.x), absi(job.chunk.y - _last_center.y)
	)
	if ring > BakeCache.WARM_CHUNK_RING:
		return
	var ctx: WorldContext = context
	var job_ref: ChunkJob = job
	var task_id: int = WorkerThreadPool.add_task(
		func() -> void:
			BakeCache.save_chunk(ctx, job_ref)
	)
	_chunk_save_tasks.append(task_id)


# --- queries -----------------------------------------------------------------------

## True when the chunk is safe to stand on: live LOD0 with walk collision.
## Higher LODs are visuals only and must not count as ready ground.
func is_chunk_ready(chunk: Vector2i) -> bool:
	var key: int = WorldCoords.chunk_key(chunk)
	if not _chunks.has(key):
		return false
	var node: ChunkNode = _chunks[key]
	return node.lod == 0 and node.walk_collision_ready


## True when every in-atlas chunk in the Chebyshev ring around [center] is
## walk-ready. Off-atlas neighbours are ignored (nothing to mesh there).
func is_neighborhood_ready(center: Vector2i, ring: int = 1) -> bool:
	assert(ring >= 0, "is_neighborhood_ready ring must be >= 0")
	for dz in range(-ring, ring + 1):
		for dx in range(-ring, ring + 1):
			var chunk: Vector2i = Vector2i(center.x + dx, center.y + dz)
			var sector_coord: Vector2i = WorldCoords.sector_of_chunk(config, chunk)
			if context != null and not context.sector_in_atlas(sector_coord):
				continue
			if not is_chunk_ready(chunk):
				return false
	return true


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
	_blocked_chunks.clear()
	_ready_results.clear()
	_collision_deferred.clear()
	_regions.clear()
	_pending_regions.clear()
	_queue.drop_waiting(
		func(job: GenQueue.Job) -> bool:
			return (
				job is ChunkJob or job is ChunkCacheLoadJob
				or job is FarTerrainJob or job is RegionJob
			)
	)
	_far_pending = false
	if _far_terrain != null:
		_far_terrain.clear()
	_last_sector = Vector2i(2147483647, 2147483647)
	_last_center = Vector2i(2147483647, 2147483647)
	stat_chunks_live = 0
	stat_chunks_waiting_on_sector = 0


func shutdown() -> void:
	if _shutting_down:
		_join_chunk_saves()
		return
	_shutting_down = true
	# Do not start more generation while we wait for in-flight workers.
	_blocked_chunks.clear()
	_ready_results.clear()
	if _queue != null:
		_queue.drop_waiting(func(_job: GenQueue.Job) -> bool: return true)
		_queue.drain()
	_join_chunk_saves()


func _join_chunk_saves() -> void:
	for task_id in _chunk_save_tasks:
		if task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(task_id)
	_chunk_save_tasks.clear()
