class_name ChunkJob
extends GenQueue.Job
## Everything one chunk needs, computed off the main thread.
##
## Inputs are the owning sector plus its page; outputs are plain arrays. The job
## never creates a Node, Mesh or Shape - see [ChunkNode] for that half.
##
## The continental sampler and the noise set are built here rather than passed
## in: both own FastNoiseLite state, which is not safe to read from two threads
## at once, and building them is cheap next to meshing a chunk.

var config: WorldConfig
var context: WorldContext
var sector: WorldSector
var region: RegionData
var prop_specs: Array[PropPlacer.PropSpec] = []

var chunk: Vector2i
var lod: int = 0
var want_collision: bool = false
var want_props: bool = false

var mesh_data: MeshExtract.MeshData
var water_data: WaterSurface.WaterData
var props: Dictionary = {}
var bridges: Array[BridgeSite] = []
var max_contract_error: float = 0.0
var build_ms: int = 0


func run() -> void:
	var started: int = Time.get_ticks_msec()
	var noise: NoiseSet = NoiseSet.create(config)
	var continental: ContinentalTerrain = context.sampler()
	var chunk_origin: Vector2 = WorldCoords.chunk_origin(config, chunk)

	var field: DensityField.Field = DensityField.build(
		config, sector, continental, noise, chunk, lod
	)
	max_contract_error = field.max_contract_error

	mesh_data = MeshExtract.build(
		field, chunk_origin, want_collision, config.skirts_enabled
	)
	water_data = WaterSurface.build(field, chunk_origin)

	if want_props and config.props_enabled:
		props = PropPlacer.place(
			config, prop_specs, field, region, sector.claims, chunk_origin
		)

	var bounds: Rect2 = Rect2(chunk_origin, Vector2.ONE * config.chunk_size)
	for site in region.bridges:
		var centre: Vector3 = site.center()
		if bounds.has_point(Vector2(centre.x, centre.z)):
			bridges.append(site)

	build_ms = Time.get_ticks_msec() - started
