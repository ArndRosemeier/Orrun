class_name ChunkJob
extends GenQueue.Job
## Everything one chunk needs, computed off the main thread.
##
## Inputs are the owning sector plus its page; outputs are plain arrays (and
## shared kit Mesh refs for bridges). The job never creates a Node or Shape —
## see [ChunkNode] for that half.
##
## The continental sampler and the noise set are built here rather than passed
## in: both own FastNoiseLite state, which is not safe to read from two threads
## at once, and building them is cheap next to meshing a chunk.

var config: WorldConfig
var context: WorldContext
var sector: WorldSector
var region: RegionData
var prop_specs: Array[PropPlacer.PropSpec] = []
var clutter_specs: Array[GroundClutter.Spec] = []

var chunk: Vector2i
var lod: int = 0
var want_collision: bool = false
var want_props: bool = false
var want_clutter: bool = false
## Matches [member Streamer.mesh_epoch] at enqueue; stale remeshes are dropped.
var mesh_epoch: int = 0
## True when mesh/props came from [BakeCache] instead of [method run].
var from_cache: bool = false

var mesh_data: MeshExtract.MeshData
var water_data: WaterSurface.WaterData
var props: Dictionary = {}
var bridges: Array[BridgeSite] = []
## Prebuilt bridge visuals/collision from [BridgeBuilder] (worker thread).
var bridge_builds: Array[BridgeBuilder.BuildResult] = []
var max_contract_error: float = 0.0
var build_ms: int = 0
## Phase breakdown for the HUD (density / mesh / water / dress).
var density_ms: int = 0
var columns_ms: int = 0
var volume_ms: int = 0
var mesh_ms: int = 0
var water_ms: int = 0
var dress_ms: int = 0
var props_ms: int = 0
var clutter_ms: int = 0


func run() -> void:
	var started: int = Time.get_ticks_msec()
	var noise: NoiseSet = NoiseSet.create(config)
	var continental: ContinentalTerrain = context.sampler()
	var chunk_origin: Vector2 = WorldCoords.chunk_origin(config, chunk)

	var t0: int = Time.get_ticks_msec()
	var field: DensityField.Field = DensityField.build(
		config, sector, continental, noise, chunk, lod
	)
	density_ms = Time.get_ticks_msec() - t0
	columns_ms = field.columns_ms
	volume_ms = field.volume_ms
	max_contract_error = field.max_contract_error

	var bounds: Rect2 = Rect2(chunk_origin, Vector2.ONE * config.chunk_size)
	bridges.clear()
	bridge_builds.clear()
	for site in region.bridges:
		var centre: Vector3 = site.center()
		if bounds.has_point(Vector2(centre.x, centre.z)):
			bridges.append(site)

	if lod == 0 and not bridges.is_empty():
		DensityField.assert_bridge_flush(field, bridges)

	t0 = Time.get_ticks_msec()
	mesh_data = MeshExtract.build(
		field, chunk_origin, want_collision, config.skirts_enabled
	)
	mesh_ms = Time.get_ticks_msec() - t0

	t0 = Time.get_ticks_msec()
	water_data = WaterSurface.build(field, chunk_origin)
	water_ms = Time.get_ticks_msec() - t0

	var t_dress: int = Time.get_ticks_msec()
	if want_props and config.props_enabled:
		var t_props: int = Time.get_ticks_msec()
		props = PropPlacer.place(
			config, prop_specs, field, region, sector.claims, chunk_origin
		)
		var house_props: Dictionary = HousePlacer.place(
			region.houses, field, chunk_origin, config.chunk_size
		)
		for house_id in house_props:
			var existing: Array = props.get(house_id, [])
			existing.append_array(house_props[house_id])
			props[house_id] = existing
		props_ms = Time.get_ticks_msec() - t_props

	if want_clutter and config.props_enabled:
		var t_clutter: int = Time.get_ticks_msec()
		var clutter: Dictionary = GroundClutter.place(
			config, clutter_specs, field, region, sector.claims, chunk_origin
		)
		for clutter_id in clutter:
			var bag: Array = props.get(clutter_id, [])
			bag.append_array(clutter[clutter_id])
			props[clutter_id] = bag
		clutter_ms = Time.get_ticks_msec() - t_clutter

	for site in bridges:
		bridge_builds.append(BridgeBuilder.build(site, chunk_origin, want_collision))
	dress_ms = Time.get_ticks_msec() - t_dress

	build_ms = Time.get_ticks_msec() - started
