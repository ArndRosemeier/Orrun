class_name FarTerrainJob
extends GenQueue.Job
## Rebuilds the moving horizon patch on a worker thread.
##
## Sampling 24 km of continental terrain is far too much work for a frame, and
## it only has to happen when the player crosses into a new sector, so it goes
## through the same queue as everything else.

var context: WorldContext
var centre: Vector2
var result: FarTerrain.Patch
var mesh_epoch: int = 0


func run() -> void:
	result = FarTerrain.build_patch(context, context.sampler(), centre)
