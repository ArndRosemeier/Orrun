class_name RegionJob
extends GenQueue.Job
## Builds a page's feature lists. Always finishes before any chunk inside it
## is queued, which is what stops two chunks disagreeing about a river.

var sector: WorldSector
var region: Vector2i
## Matches [member Streamer.mesh_epoch] at enqueue; stale pages are dropped.
var mesh_epoch: int = 0
var result: RegionData


func run() -> void:
	result = RegionData.build(sector, region)
