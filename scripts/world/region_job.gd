class_name RegionJob
extends GenQueue.Job
## Builds a region's feature lists. Always finishes before any chunk inside it
## is queued, which is what stops two chunks disagreeing about a river.

var map: WorldMap
var region: Vector2i
var result: RegionData


func run() -> void:
	result = RegionData.build(map, region)
