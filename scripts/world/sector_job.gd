class_name SectorJob
extends GenQueue.Job
## Bakes one sector on a worker thread.
##
## The job holds nothing but the shared read-only context and a sector
## coordinate, because that pair is the entire input: two jobs for the same
## coordinate produce the same sector, and jobs for different coordinates never
## touch each other's data.

var context: WorldContext
var sector: Vector2i
var result: WorldSector
## Matches [member SectorManager.bake_epoch] at enqueue time. Stale results
## from a tuning rebake are discarded on publish.
var bake_epoch: int = 0


func run() -> void:
	result = WorldSector.generate(context, sector)
