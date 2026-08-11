class_name ChunkCacheLoadJob
extends GenQueue.Job
## Loads a warm-ring LOD0 chunk blob on a worker so the main thread is not
## blocked on FileAccess during [method Streamer._ensure_near_chunks].

var context: WorldContext
var sector: WorldSector
var region: RegionData
var chunk: Vector2i = Vector2i.ZERO
var lod: int = 0
var mesh_epoch: int = 0
## Filled by [method run]; null means the file was corrupt / mismatched.
var result: ChunkJob = null
var load_ms: int = 0


func run() -> void:
	var t0: int = Time.get_ticks_msec()
	result = BakeCache.try_load_chunk(context, sector, region, chunk, lod)
	load_ms = Time.get_ticks_msec() - t0
