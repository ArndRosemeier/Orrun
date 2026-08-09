class_name SectorManager
extends RefCounted
## Owns which sectors exist, and makes sure the one under the player already
## does before a chunk is asked for.
##
## Sectors are generated asynchronously, published atomically when finished, and
## never regenerated: crossing a sector boundary means reading chunks out of the
## neighbouring immutable sector, not rebaking an overlapping window. That is
## the difference between this and a sliding world - a sliding window would move
## the lakes and roads you just walked past.
##
## Neighbours are prefetched before the player reaches an edge. If a sector is
## still missing when its chunks are wanted, the streamer holds rather than
## meshing something it will have to replace.

var context: WorldContext

var _queue: GenQueue
var _ready: Dictionary = {}
var _pending: Dictionary = {}
## Sector keys in least-recently-used order, oldest first.
var _lru: Array[int] = []

## Debug counters.
var stat_generated: int = 0
var stat_evicted: int = 0
var stat_last_bake_ms: int = 0
var last_bake_timings: Dictionary = {}
## Bumped by [method invalidate_around] so in-flight sector jobs from an older
## interpretation are never published.
var bake_epoch: int = 0


func _init(world_context: WorldContext) -> void:
	context = world_context
	# Sector bakes are long; leave workers free for chunk meshing or the ring
	# under the player stalls behind the horizon.
	_queue = GenQueue.new(maxi(OS.get_processor_count() / 2, 1))


## Publishes finished sectors. Call once per frame before asking for chunks.
func pump() -> void:
	_queue.pump()
	for job in _queue.collect():
		var sector_job: SectorJob = job
		var key: int = WorldCoords.sector_key(sector_job.sector)
		_pending.erase(key)
		if sector_job.bake_epoch != bake_epoch:
			continue
		_publish(key, sector_job.result)


## Adopts a sector that was baked outside the queue, e.g. the spawn sector.
func adopt(sector: WorldSector) -> void:
	_publish(WorldCoords.sector_key(sector.sector), sector)


func _publish(key: int, sector: WorldSector) -> void:
	_ready[key] = sector
	_touch(key)
	stat_generated += 1
	stat_last_bake_ms = int(sector.bake_timings.get("total_ms", 0))
	last_bake_timings = sector.bake_timings
	_evict()


## The sector, or null when it is not baked yet. Never blocks and never returns
## a half-built sector.
func get_sector(sector_coord: Vector2i) -> WorldSector:
	var key: int = WorldCoords.sector_key(sector_coord)
	if not _ready.has(key):
		return null
	_touch(key)
	return _ready[key]


func has_sector(sector_coord: Vector2i) -> bool:
	return _ready.has(WorldCoords.sector_key(sector_coord))


func sector_for_chunk(chunk: Vector2i) -> WorldSector:
	return get_sector(WorldCoords.sector_of_chunk(context.config, chunk))


func sector_at(world_x: float, world_z: float) -> WorldSector:
	return get_sector(WorldCoords.sector_of(world_x, world_z))


## Queues the sector and everything within the prefetch radius of it, nearest
## first, so the player never walks into an edge that has not started baking.
func request_around(centre: Vector2i) -> void:
	var radius: int = context.config.sector_prefetch_radius
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			request(centre + Vector2i(dx, dz), float(maxi(absi(dx), absi(dz))))


func request(sector_coord: Vector2i, priority: float = 0.0) -> void:
	if not context.sector_in_atlas(sector_coord):
		return
	var key: int = WorldCoords.sector_key(sector_coord)
	if _ready.has(key) or _pending.has(key):
		return
	var job: SectorJob = SectorJob.new()
	job.context = context
	job.sector = sector_coord
	job.priority = priority
	job.bake_epoch = bake_epoch
	_pending[key] = true
	_queue.enqueue(job)
	_queue.sort_waiting()


## Drops cached sectors and requeues around [param centre]. Used when
## interpretation knobs on the shared [WorldConfig] change: the atlas stays,
## but macro elevation / hydro must be rebuilt from the new params.
func invalidate_around(centre: Vector2i) -> void:
	bake_epoch += 1
	_ready.clear()
	_lru.clear()
	_queue.drop_waiting(func(_job: GenQueue.Job) -> bool: return true)
	_pending.clear()
	request_around(centre)


func pending_count() -> int:
	return _pending.size()


func live_count() -> int:
	return _ready.size()


func _touch(key: int) -> void:
	_lru.erase(key)
	_lru.append(key)


## Least-recently-used eviction. Dropping a sector is safe because it can be
## rebuilt bit-identically; nothing that has been published is ever mutated.
func _evict() -> void:
	while _lru.size() > context.config.sector_cache_size:
		var key: int = _lru.pop_front()
		_ready.erase(key)
		stat_evicted += 1


func shutdown() -> void:
	_queue.drain()
