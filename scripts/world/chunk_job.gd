class_name ChunkJob
extends GenQueue.Job
## Everything one chunk needs, computed off the main thread.
##
## Inputs are the baked world plus its region; outputs are plain arrays. The job
## never creates a Node, Mesh or Shape - see [ChunkNode] for that half.

var config: WorldConfig
var map: WorldMap
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
	var chunk_origin: Vector2 = WorldCoords.chunk_origin(config, chunk)

	var field: DensityField.Field = DensityField.build(config, map, noise, chunk, lod)
	max_contract_error = field.max_contract_error

	mesh_data = MeshExtract.build(
		field, chunk_origin, want_collision, config.skirts_enabled
	)
	water_data = WaterSurface.build(field, chunk_origin)

	if want_props and config.props_enabled:
		props = PropPlacer.place(
			config, prop_specs, field, region, map.claims, chunk_origin
		)

	var bounds: Rect2 = Rect2(chunk_origin, Vector2.ONE * config.chunk_size)
	for site in region.bridges:
		var center: Vector3 = site.center()
		if bounds.has_point(Vector2(center.x, center.z)):
			bridges.append(site)

	build_ms = Time.get_ticks_msec() - started
