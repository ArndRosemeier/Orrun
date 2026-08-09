class_name Hydrology
extends RefCounted
## Layer 2: where water actually is, solved for one sector.
##
## The sector only solves what it is allowed to own. Anything that crosses its
## boundary belongs to the atlas and is reconstructed from it, identically, by
## every sector that touches it:
##
##   trunk rivers   pure [AtlasCorridors] polylines in XZ, draped onto the
##                  continental surface for water height, atlas feature class -
##                  never sector-local accumulation, because 8 km of catchment
##                  cannot tell you how big a river is
##   ocean, atlas   the global signed shoreline in [ContinentalTerrain]
##   lakes
##   local brooks   solved here, and required to stay inside the sector core
##   local lakes    solved here, and rejected unless the whole basin is visible
##                  to both neighbours, so both accept or both reject it
##
## The interior solver is still a bucket-queue priority flood, which gives in
## one pass: a depression-filled drainage surface that never rises downstream,
## flow directions, a downstream-first processing order, and lakes for free.
##
## What changed from the finite-world version: the whole-rim sink is gone,
## replaced by typed boundary conditions (atlas water, trunk corridors, and the
## edge contract's ports), and the terrain is never rewritten. Breaching used to
## carve outlets into the macro grid; the atlas trunk valleys in
## [ContinentalTerrain] do that job now, as a pure function, so no sector can
## disagree with its neighbour about where the ground is.

static var NEIGHBOR_DX: PackedInt32Array = PackedInt32Array([1, 1, 0, -1, -1, -1, 0, 1])
static var NEIGHBOR_DZ: PackedInt32Array = PackedInt32Array([0, 1, 1, 1, 0, -1, -1, -1])
const LEVEL_STEP: float = 0.25
const LAKE_EPSILON: float = 0.05
const MAX_LAKE_DISTANCE: float = 512.0
## Metres a local lake may span before it stops being a lake and becomes a
## basin the drainage never left. Well under the sector halo, so both
## neighbours see the whole basin and reach the same verdict about it.
const LOCAL_LAKE_MAX_SPAN: float = 1200.0
## Extra metres beyond the atlas valley radius still claimed as trunk corridor.
##
## The continental surface carves a valley out to [method AtlasCorridors.river_valley_radius].
## Local brooks that form anywhere inside that carve show up as thin dashed
## water in a wide dry trench - the "river goes underground" look. The trunk
## stamp therefore covers the whole valley, not just the channel half-width.
const TRUNK_VALLEY_PAD: float = 16.0
## Local reaches are capped below the trunk order so a brook can never claim to
## be wider than the river it joins.
const LOCAL_MAX_ORDER: int = 3
## How far apart draped trunk stations are, in metres.
##
## Atlas corridor vertices are hundreds of metres apart. A straight water chord
## between them cuts through every bump in the refined valley floor: the
## monotonic drape holds the water down, the ground rises over the sheet, and
## the river disappears under its own banks. Resampling at a spacing the
## density field can resolve keeps the chord on the land.
const TRUNK_STATION_SPACING: float = 8.0
## Stations along a port stub, on each side of the boundary.
const STUB_STATIONS: int = 6

var config: WorldConfig
var terrain: MacroTerrain
var continental: ContinentalTerrain
var corridors: AtlasCorridors

## Local cell bounds of the sector core, inclusive. Everything outside is halo:
## read to get the interior right, never published.
var core_min: Vector2i = Vector2i.ZERO
var core_max: Vector2i = Vector2i.ZERO
## The core minus the keep-out band. Locally solved water lives here and nowhere
## else, so it can never shape ground a neighbouring sector also meshes.
var local_min: Vector2i = Vector2i.ZERO
var local_max: Vector2i = Vector2i.ZERO

## Depression-filled drainage surface (m). filled >= elevation everywhere.
var filled: PackedFloat32Array
## Downstream neighbour index, -1 for cells that drain into a boundary sink.
var receiver: PackedInt32Array
## Pop order of the priority flood: downstream before upstream.
var flow_order: PackedInt32Array
## Upslope contributing area, in weighted cells.
var accumulation: PackedFloat32Array
## Local lake id per cell, -1 when dry or when the water is the atlas's.
var lake_id: PackedInt32Array
## True where local flow is concentrated enough to be a visible channel.
var is_channel: PackedInt32Array
## 1 inside an atlas trunk corridor.
var trunk: PackedByteArray
## 1 where the atlas says the ground is under ocean or an atlas lake.
var atlas_water: PackedByteArray
## Distance in metres to the nearest local lake cell, capped.
var lake_distance: PackedFloat32Array
## Surface height of whichever lake that nearest cell belongs to, -INF when no
## lake is in range.
var lake_surface_near: PackedFloat32Array
var _surface_reach: PackedFloat32Array

var lakes: Array[LakeData] = []
var rivers: Array[RiverPolyline] = []
var river_index: SpatialIndex2D

## Ports the sector must accept flow from, and drain flow into.
var inflow_ports: Array[SectorEdgeContract.Port] = []
var outflow_ports: Array[SectorEdgeContract.Port] = []


static func solve(
	cfg: WorldConfig,
	macro: MacroTerrain,
	cont: ContinentalTerrain,
	corr: AtlasCorridors,
	core_from: Vector2i,
	core_to: Vector2i,
	inflow: Array[SectorEdgeContract.Port],
	outflow: Array[SectorEdgeContract.Port],
	noise: NoiseSet
) -> Hydrology:
	var hydro: Hydrology = Hydrology.new()
	hydro.config = cfg
	hydro.terrain = macro
	hydro.continental = cont
	hydro.corridors = corr
	hydro.core_min = core_from
	hydro.core_max = core_to
	hydro.inflow_ports = inflow
	hydro.outflow_ports = outflow
	hydro.river_index = SpatialIndex2D.new(160.0)

	var keepout: int = cfg.keepout_cells()
	hydro.local_min = core_from + Vector2i(keepout, keepout)
	hydro.local_max = core_to - Vector2i(keepout, keepout)

	hydro._classify_cells()
	hydro._priority_flood()
	hydro._accumulate()
	hydro._find_lakes()
	hydro._mark_channels()
	hydro._build_trunk_rivers()
	hydro._build_port_stubs()
	hydro._build_local_rivers(noise)
	hydro._index_rivers()
	hydro._build_lake_distance()
	return hydro


# --- Boundary conditions --------------------------------------------------------

## Marks the cells the sector does not get to decide about: atlas water, and
## the trunk corridors that carry flow across the boundary.
func _classify_cells() -> void:
	var n: int = terrain.cells
	var count: int = n * n
	trunk = PackedByteArray()
	trunk.resize(count)
	atlas_water = PackedByteArray()
	atlas_water.resize(count)

	for cz in n:
		for cx in n:
			var centre: Vector2 = terrain.cell_center(cx, cz)
			if continental.shore_signed(centre.x, centre.y) <= 0.0:
				atlas_water[cz * n + cx] = 1

	var rect: Rect2 = terrain.window_rect().grow(corridors.max_valley_radius)
	for base in corridors.rivers_in_rect(rect):
		var ax: float = corridors.rivers[base]
		var az: float = corridors.rivers[base + 2]
		var bx: float = corridors.rivers[base + 3]
		var bz: float = corridors.rivers[base + 5]
		var feature_class: int = int(corridors.rivers[base + 8])
		var half: float = (
			corridors.river_valley_radius(feature_class) + TRUNK_VALLEY_PAD
		)
		_stamp_trunk(ax, az, bx, bz, half)


func _stamp_trunk(ax: float, az: float, bx: float, bz: float, half: float) -> void:
	var cs: float = terrain.cell_size
	var min_x: float = minf(ax, bx) - half
	var max_x: float = maxf(ax, bx) + half
	var min_z: float = minf(az, bz) - half
	var max_z: float = maxf(az, bz) + half
	var c0: Vector2i = terrain.local_cell_of(min_x, min_z)
	var c1: Vector2i = terrain.local_cell_of(max_x, max_z)
	var n: int = terrain.cells
	for cz in range(maxi(c0.y, 0), mini(c1.y + 1, n)):
		for cx in range(maxi(c0.x, 0), mini(c1.x + 1, n)):
			var centre: Vector2 = terrain.cell_center(cx, cz)
			var t: float = ContinentalTerrain._segment_param(
				centre.x, centre.y, ax, az, bx, bz
			)
			var px: float = ax + (bx - ax) * t
			var pz: float = az + (bz - az) * t
			if Vector2(centre.x - px, centre.y - pz).length() <= half + cs * 0.5:
				trunk[cz * n + cx] = 1


func _is_sink(index: int) -> bool:
	return atlas_water[index] != 0 or trunk[index] != 0


# --- Priority flood ---------------------------------------------------------------

func _priority_flood() -> void:
	assert(
		ClassDB.class_exists("OrrunGen"),
		"OrrunGen is required for Hydrology.priority_flood"
	)
	var n: int = terrain.cells
	var count: int = n * n
	var elevation: PackedFloat32Array = terrain.elevation

	# Typed sinks (atlas water / trunk). Edge + outflow ports are seeded inside
	# OrrunGen.priority_flood.
	var sink_mask: PackedByteArray = PackedByteArray()
	sink_mask.resize(count)
	for i in count:
		sink_mask[i] = 1 if _is_sink(i) else 0
	var outflow_cells: PackedInt32Array = PackedInt32Array()
	for port in outflow_ports:
		var cell: Vector2i = terrain.local_cell_of(port.position.x, port.position.y)
		if terrain.contains_local(cell.x, cell.y):
			outflow_cells.append(cell.y * n + cell.x)

	var native: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
	var result: Variant = native.call(
		"priority_flood",
		elevation,
		sink_mask,
		outflow_cells,
		n,
		terrain.min_elevation,
		terrain.max_elevation,
		LEVEL_STEP
	)
	assert(
		typeof(result) == TYPE_DICTIONARY,
		"OrrunGen.priority_flood failed: %s" % [result]
	)
	var dict: Dictionary = result
	filled = dict["filled"]
	receiver = dict["receiver"]
	flow_order = dict["flow_order"]


# --- Flow accumulation --------------------------------------------------------------

func _accumulate() -> void:
	assert(
		ClassDB.class_exists("OrrunGen"),
		"OrrunGen is required for Hydrology.accumulate"
	)
	var n: int = terrain.cells
	var moisture: PackedFloat32Array = terrain.moisture
	var inflow_boosts: PackedFloat32Array = PackedFloat32Array()
	# A brook that enters through a contract port arrives with the catchment it
	# gathered next door. Starting it at zero would make the same stream a
	# trickle on one side of the boundary and a channel on the other.
	for port in inflow_ports:
		var cell: Vector2i = terrain.local_cell_of(port.position.x, port.position.y)
		if terrain.contains_local(cell.x, cell.y):
			inflow_boosts.append(float(cell.y * n + cell.x))
			inflow_boosts.append(config.river_accum_threshold * 0.5)

	var native: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
	var result: Variant = native.call(
		"accumulate", flow_order, receiver, moisture, inflow_boosts
	)
	assert(
		typeof(result) == TYPE_PACKED_FLOAT32_ARRAY,
		"OrrunGen.accumulate failed: %s" % [result]
	)
	accumulation = result


# --- Local lakes -----------------------------------------------------------------------

func _find_lakes() -> void:
	assert(
		ClassDB.class_exists("OrrunGen"),
		"OrrunGen is required for Hydrology.find_lakes"
	)
	var n: int = terrain.cells
	var count: int = n * n
	var elevation: PackedFloat32Array = terrain.elevation

	var sink_mask: PackedByteArray = PackedByteArray()
	sink_mask.resize(count)
	for i in count:
		sink_mask[i] = 1 if _is_sink(i) else 0

	var native: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
	var params: Dictionary = {
		"cells": n,
		"cell_size": terrain.cell_size,
		"origin_x": terrain.origin_cell.x,
		"origin_z": terrain.origin_cell.y,
		"local_min_x": local_min.x,
		"local_min_z": local_min.y,
		"local_max_x": local_max.x,
		"local_max_z": local_max.y,
		"lake_epsilon": LAKE_EPSILON,
		"local_lake_max_span": LOCAL_LAKE_MAX_SPAN,
		"lake_min_cells": config.lake_min_cells,
		"lake_max_cells": config.lake_max_cells,
		"lake_min_depth": config.lake_min_depth,
	}
	var result: Variant = native.call(
		"find_lakes",
		elevation,
		filled,
		sink_mask,
		receiver,
		accumulation,
		params
	)
	assert(
		typeof(result) == TYPE_DICTIONARY,
		"OrrunGen.find_lakes failed: %s" % [result]
	)
	_apply_native_lakes(result)


func _apply_native_lakes(result: Dictionary) -> void:
	lake_id = result["lake_id"]
	lakes.clear()
	var surfaces: PackedFloat32Array = result["surface"]
	var depths: PackedFloat32Array = result["max_depth"]
	var outlets: PackedInt32Array = result["outlet"]
	var bounds: PackedFloat32Array = result["bounds"]
	var offsets: PackedInt32Array = result["member_offsets"]
	var members: PackedInt32Array = result["members"]
	for i in surfaces.size():
		var lake: LakeData = LakeData.new()
		lake.id = i
		lake.surface_z = surfaces[i]
		lake.max_depth = depths[i]
		lake.outlet_cell = outlets[i]
		lake.bounds = Rect2(
			bounds[i * 4], bounds[i * 4 + 1], bounds[i * 4 + 2], bounds[i * 4 + 3]
		)
		var from_i: int = offsets[i]
		var to_i: int = offsets[i + 1]
		var cells: PackedInt32Array = PackedInt32Array()
		cells.resize(to_i - from_i)
		for j in cells.size():
			cells[j] = members[from_i + j]
		lake.cells = cells
		lakes.append(lake)


# --- Channels --------------------------------------------------------------------------

func _mark_channels() -> void:
	var count: int = filled.size()
	is_channel = PackedInt32Array()
	is_channel.resize(count)
	var base_threshold: float = config.river_accum_threshold
	var hills_amp: float = config.relief_amp_hills
	var mtn_amp: float = config.relief_amp_mountains
	for i in count:
		# Steep alpine faces spawn parallel “comb” brooks at the base threshold;
		# demand more catchment before a visible local channel is published.
		var threshold: float = base_threshold
		var elev: float = terrain.elevation[i]
		var amp: float = terrain.relief_amp[i]
		if elev > 700.0:
			threshold *= lerpf(1.0, 3.2, clampf((elev - 700.0) / 1600.0, 0.0, 1.0))
		if amp > hills_amp:
			threshold *= lerpf(
				1.0, 2.4,
				clampf((amp - hills_amp) / maxf(mtn_amp - hills_amp, 1.0), 0.0, 1.0)
			)
		var channel: bool = (
			accumulation[i] >= threshold
			and lake_id[i] == -1
			and receiver[i] >= 0
			and trunk[i] == 0
			and atlas_water[i] == 0
		)
		is_channel[i] = 1 if channel else 0


# --- Trunk rivers ---------------------------------------------------------------------

## Rebuilds the atlas trunks that touch this window, straight from the shared
## corridor geometry. No smoothing, no meander, no local re-routing: whatever
## this produces, the neighbour produces exactly the same polyline, which is the
## only way a river can cross a sector boundary without a kink.
func _build_trunk_rivers() -> void:
	var stride: int = AtlasCorridors.RIVER_STRIDE
	var rect: Rect2 = terrain.window_rect().grow(config.macro_cell_size * 4.0)
	var bases: PackedInt32Array = corridors.rivers_in_rect(rect)
	bases.sort()

	var run: PackedInt32Array = PackedInt32Array()
	for base in bases:
		var continues_run: bool = (
			not run.is_empty()
			and base == run[run.size() - 1] + stride
			and corridors.river_feature_ids[base / stride]
				== corridors.river_feature_ids[run[run.size() - 1] / stride]
		)
		if continues_run:
			run.append(base)
			continue
		_emit_trunk_reach(run)
		run = PackedInt32Array([base])
	_emit_trunk_reach(run)


func _emit_trunk_reach(run: PackedInt32Array) -> void:
	if run.size() < 1:
		return
	var stride: int = AtlasCorridors.RIVER_STRIDE
	var feature_class: int = int(corridors.rivers[run[0] + 8])
	var order: int = corridors.trunk_order(feature_class)

	var reach: RiverPolyline = RiverPolyline.new()
	reach.id = rivers.size()
	reach.order = order
	reach.is_trunk = true
	reach.is_shared = true
	reach.feature_id = corridors.river_feature_ids[run[0] / stride]
	reach.depth = config.river_depth_base + float(order - 1) * config.river_depth_per_order
	reach.valley = config.river_valley_base + float(order - 1) * config.river_valley_per_order

	# Corridor vertices only: XZ and atlas water, no drape yet. Both neighbours
	# see the same run of bases, so they build the same coarse polyline.
	var coarse_x: PackedFloat32Array = PackedFloat32Array()
	var coarse_z: PackedFloat32Array = PackedFloat32Array()
	var coarse_atlas: PackedFloat32Array = PackedFloat32Array()
	var coarse_half: PackedFloat32Array = PackedFloat32Array()
	for i in run.size():
		var base: int = run[i]
		if i == 0:
			coarse_x.append(corridors.rivers[base])
			coarse_atlas.append(corridors.rivers[base + 1])
			coarse_z.append(corridors.rivers[base + 2])
			coarse_half.append(corridors.rivers[base + 6])
		coarse_x.append(corridors.rivers[base + 3])
		coarse_atlas.append(corridors.rivers[base + 4])
		coarse_z.append(corridors.rivers[base + 5])
		coarse_half.append(corridors.rivers[base + 7])

	# Prefix lengths along the coarse centreline, so resampling is a pure
	# function of the shared corridor geometry.
	var prefix: PackedFloat32Array = PackedFloat32Array()
	prefix.append(0.0)
	for i in range(1, coarse_x.size()):
		prefix.append(
			prefix[i - 1]
			+ Vector2(coarse_x[i] - coarse_x[i - 1], coarse_z[i] - coarse_z[i - 1]).length()
		)
	var total: float = prefix[prefix.size() - 1]
	if total <= 0.001:
		return

	# XZ stays on the atlas centreline so the channel is shared. Water height is
	# draped onto the refined surface: the atlas elevation is a kilometre
	# average and will float a canal in the air wherever detail has dug the
	# valley deeper. Stations are dense enough that a straight chord between
	# them cannot climb through a bump and bury the sheet under the ground.
	var points: PackedVector3Array = PackedVector3Array()
	var widths: PackedFloat32Array = PackedFloat32Array()
	var sample_count: int = maxi(2, int(ceil(total / TRUNK_STATION_SPACING)) + 1)
	var seg: int = 0
	for s in sample_count:
		var dist: float = total if s == sample_count - 1 else float(s) * TRUNK_STATION_SPACING
		dist = minf(dist, total)
		while seg + 1 < prefix.size() and prefix[seg + 1] < dist:
			seg += 1
		var seg_len: float = prefix[seg + 1] - prefix[seg]
		var t: float = 0.0 if seg_len <= 0.001 else (dist - prefix[seg]) / seg_len
		points.append(
			_drape_water_station(
				lerpf(coarse_x[seg], coarse_x[seg + 1], t),
				lerpf(coarse_atlas[seg], coarse_atlas[seg + 1], t),
				lerpf(coarse_z[seg], coarse_z[seg + 1], t)
			)
		)
		widths.append(lerpf(coarse_half[seg], coarse_half[seg + 1], t))

	if points.size() < 2:
		return
	reach.points = points
	reach.half_width = widths
	_grade_ocean_mouth(reach)
	reach.compute_bounds()
	rivers.append(reach)


## Pull stations near the ocean (or atlas water) down to the plane. The mouth
## may sit mid-reach on a coastal trunk, so the tip is the lowest shore_d
## station — not only an endpoint.
func _grade_ocean_mouth(reach: RiverPolyline) -> void:
	var blend: float = DensityField.ESTUARY_BLEND_METRES
	var points: PackedVector3Array = reach.points
	var n: int = points.size()
	if n < 2:
		return
	var tip_i: int = 0
	var tip_shore: float = INF
	for i in n:
		var sd: float = continental.shore_distance(points[i].x, points[i].z)
		if sd < tip_shore:
			tip_shore = sd
			tip_i = i
	if tip_shore > blend:
		return
	var plane: float = continental.water_plane_at(points[tip_i].x, points[tip_i].z)
	# Graph distance along the polyline from the mouth station (both directions).
	var dist: PackedFloat32Array = PackedFloat32Array()
	dist.resize(n)
	for i in n:
		dist[i] = INF
	dist[tip_i] = 0.0
	for i in range(tip_i + 1, n):
		dist[i] = dist[i - 1] + Vector2(
			points[i].x - points[i - 1].x, points[i].z - points[i - 1].z
		).length()
	for i in range(tip_i - 1, -1, -1):
		dist[i] = dist[i + 1] + Vector2(
			points[i].x - points[i + 1].x, points[i].z - points[i + 1].z
		).length()
	# Pull / non-climb membership: near the mouth along the reach, and actually
	# near the shore. Along-track alone buries highland shelves; shore-distance
	# alone would flatten every coastal river to sea level.
	var track_span: float = blend + 40.0
	for j in n:
		if dist[j] > track_span:
			continue
		var sd: float = continental.shore_distance(points[j].x, points[j].z)
		if sd > blend:
			continue
		# Falloff by shore distance so freeboard berms are shaved; a station
		# merely near the tip along-track with large shore_d is not pulled.
		var t: float = 1.0 - clampf(sd / blend, 0.0, 1.0)
		if points[j].y > plane:
			points[j].y = lerpf(points[j].y, plane, t)
	var order: Array[int] = []
	for j in n:
		if dist[j] > track_span:
			continue
		if continental.shore_distance(points[j].x, points[j].z) > blend:
			continue
		order.append(j)
	order.sort_custom(func(a: int, b: int) -> bool: return dist[a] > dist[b])
	var prev_y: float = INF
	for j in order:
		points[j].y = minf(points[j].y, prev_y)
		prev_y = points[j].y
	reach.points = points


## Water height for one station on a shared channel: the atlas (or drainage)
## height, but never above the land under the station itself. Pure in
## continental metres, so two sectors that share the station agree.
##
## Grade is left alone on purpose. Forcing the sheet not to rise across a bump
## buries it under the land; the density field then has to cut a slot canyon,
## and at ordinary LOD the ground mesh bridges that slot so the river vanishes.
## The atlas corridor and the continental valley already descend overall; the
## visible water just has to sit in the bed.
##
## The sample is the centreline and nothing else. Searching a disc for the
## lowest ground nearby is a catastrophe beside a coastal cliff: the lowest
## ground within a hundred metres is the sea bed, and the river falls off the
## cliff as a wall of water.
func _drape_water_station(world_x: float, ceiling: float, world_z: float) -> Vector3:
	var land_z: float = continental.height_at(world_x, world_z)
	var shore_d: float = continental.shore_distance(world_x, world_z)
	var plane: float = continental.water_plane_at(world_x, world_z)
	# Atlas-wet ocean/lake: the sheet is the atlas plane. Draping onto the
	# shelf bed would put the mouth tens of metres under the sea and invent a
	# waterfall on the last station.
	if shore_d <= 0.0:
		return Vector3(world_x, plane, world_z)
	# Atlas cells can encode elevations below the global sea. Dry land is
	# floored at sea level, so a submarine atlas ceiling would bury the sheet
	# and then force an upward grade into the ocean.
	ceiling = maxf(ceiling, continental.fields.sea_surface_z)
	var water_z: float = minf(land_z, ceiling)
	# Pull down only: freeboard berms can leave the drape above the sea plane.
	# Never raise a low station to meet the ocean.
	var blend: float = DensityField.ESTUARY_BLEND_METRES
	if shore_d < blend and water_z > plane:
		var t: float = 1.0 - clampf(shore_d / blend, 0.0, 1.0)
		water_z = lerpf(water_z, plane, t)
	return Vector3(world_x, water_z, world_z)


# --- Port stubs ---------------------------------------------------------------------------

## The short length of channel either side of every drainage port.
##
## A local brook may not come within the keep-out band of a boundary, so on its
## own it could never cross one. The stub is what carries it over: a straight
## run of channel centred on the contract port, long enough to span the band on
## both sides, and derived from nothing but the port and the continental
## surface. Both neighbours build the whole stub, identically, so the ground and
## the water line under it are the same on both sides of the seam.
func _build_port_stubs() -> void:
	var length: float = config.local_keepout_metres
	var seen: Dictionary = {}
	for port in inflow_ports + outflow_ports:
		# Only local drainage. A trunk crossing already has its channel: the
		# atlas polyline itself, which both sectors rebuilt from the corridor.
		if port.kind != SectorEdgeContract.Kind.DRAIN or seen.has(port.id):
			continue
		seen[port.id] = true
		_emit_port_stub(port, length)


func _emit_port_stub(port: SectorEdgeContract.Port, length: float) -> void:
	var order: int = 1
	var reach: RiverPolyline = RiverPolyline.new()
	reach.id = rivers.size()
	reach.order = order
	reach.is_shared = true
	# The port's own id: stable across runs, and the same number in both
	# sectors, so the two halves of one crossing can be recognised as one thing.
	reach.feature_id = port.id
	reach.depth = port.depth
	reach.valley = port.valley

	# Stations run downstream, from the far side of the boundary to the far side
	# of this sector's keep-out band.
	var points: PackedVector3Array = PackedVector3Array()
	var widths: PackedFloat32Array = PackedFloat32Array()
	var previous: float = INF
	for i in range(-STUB_STATIONS, STUB_STATIONS + 1):
		var s: float = float(i) / float(STUB_STATIONS) * length
		var at: Vector2 = port.position + port.tangent * s
		# The port's own height at the boundary and the real ground elsewhere.
		# Stubs stay monotonic: both neighbours build the same short run, and
		# the seam tests require the contract crossing not to rise.
		var ground: float = continental.height_at(at.x, at.y)
		var water: float = minf(ground, port.surface_z + port.grade * s)
		if water > previous:
			water = previous
		previous = water
		points.append(Vector3(at.x, water, at.y))
		widths.append(maxf(port.half_width, config.river_width_base))

	reach.points = points
	reach.half_width = widths
	reach.compute_bounds()
	rivers.append(reach)


# --- Local rivers -----------------------------------------------------------------------

func _build_local_rivers(noise: NoiseSet) -> void:
	var n: int = terrain.cells
	var count: int = filled.size()

	var strahler: PackedInt32Array = PackedInt32Array()
	strahler.resize(count)
	var max_up: PackedInt32Array = PackedInt32Array()
	max_up.resize(count)
	var max_up_count: PackedInt32Array = PackedInt32Array()
	max_up_count.resize(count)

	# Upstream-first pass: Strahler order only needs each cell's tributaries.
	for i in range(count - 1, -1, -1):
		var cell: int = flow_order[i]
		var order: int = 0
		if is_channel[cell] != 0:
			order = 1
			if max_up[cell] > 0:
				order = max_up[cell] + 1 if max_up_count[cell] >= 2 else max_up[cell]
			order = mini(order, LOCAL_MAX_ORDER)
			strahler[cell] = order
		else:
			order = max_up[cell]
		if order <= 0:
			continue
		var down: int = receiver[cell]
		if down >= 0:
			if order > max_up[down]:
				max_up[down] = order
				max_up_count[down] = 1
			elif order == max_up[down]:
				max_up_count[down] += 1

	var consumed: PackedByteArray = PackedByteArray()
	consumed.resize(count)
	var cell_owner: PackedInt32Array = PackedInt32Array()
	cell_owner.resize(count)
	for i in count:
		cell_owner[i] = -1
	var end_cells: Dictionary = {}

	for i in range(count - 1, -1, -1):
		var start: int = flow_order[i]
		if is_channel[start] == 0 or consumed[start] != 0:
			continue
		if not _in_local_domain(start):
			continue

		var reach: RiverPolyline = RiverPolyline.new()
		reach.id = rivers.size()
		reach.order = strahler[start]
		reach.depth = config.river_depth_base + float(reach.order - 1) * config.river_depth_per_order
		reach.valley = config.river_valley_base + float(reach.order - 1) * config.river_valley_per_order

		var chain: PackedInt32Array = PackedInt32Array()
		var cell: int = start
		var joined_shared: bool = false
		while true:
			consumed[cell] = 1
			chain.append(cell)
			var down: int = receiver[cell]
			if down < 0:
				break
			if not _in_local_domain(down):
				# The brook has reached the keep-out band. If a contract port
				# stub is waiting there it will be snapped onto it; otherwise
				# the reach simply ends, because carrying it any further would
				# shape ground the neighbour meshes too.
				joined_shared = true
				break
			if trunk[down] != 0 or atlas_water[down] != 0:
				chain.append(down)
				joined_shared = true
				break
			if lake_id[down] != -1:
				chain.append(down)
				reach.ends_in_lake = lake_id[down]
				# Keep walking into the basin so the tip is under open water, not
				# stranded on the first shore cell (meander then leaves a dry berm).
				var tip: int = down
				for _step in 5:
					var nxt: int = receiver[tip]
					if nxt < 0 or lake_id[nxt] != reach.ends_in_lake:
						break
					tip = nxt
					chain.append(tip)
				break
			if is_channel[down] == 0:
				chain.append(down)
				break
			if strahler[down] != reach.order or consumed[down] != 0:
				chain.append(down)
				break
			cell = down

		if chain.size() < 2:
			continue

		_chain_to_polyline(reach, chain, n, noise)
		if joined_shared:
			_snap_to_shared(reach)
		if reach.ends_in_lake < 0:
			var tip_p: Vector3 = reach.points[reach.points.size() - 1]
			reach.ends_in_lake = _nearest_lake_id_near(tip_p.x, tip_p.z, 3)
		if reach.ends_in_lake >= 0:
			_extend_reach_into_lake(reach)
		for k in chain.size() - 1:
			cell_owner[chain[k]] = reach.id
		end_cells[reach.id] = chain[chain.size() - 1]
		reach.compute_bounds()
		rivers.append(reach)

	_link_downstream(cell_owner, end_cells)
	_cull_local_reaches_in_trunk_valleys()
	_join_confluences()


## Drops local reaches that run through an atlas trunk valley.
##
## The cell stamp should already prevent channels there, but meander, Chaikin,
## and the one trunk cell appended at a confluence can still leave polyline
## geometry in the valley floor. Anything that is not clearly a join tip onto
## the channel itself becomes dashed water in a dry trench.
func _cull_local_reaches_in_trunk_valleys() -> void:
	var kept: Array[RiverPolyline] = []
	var remap: Dictionary = {}
	for reach in rivers:
		if reach.is_shared or not _reach_intrudes_trunk_valley(reach):
			remap[reach.id] = kept.size()
			kept.append(reach)
	rivers = kept
	for i in rivers.size():
		rivers[i].id = i
		var down: int = rivers[i].downstream_id
		if down >= 0 and remap.has(down):
			rivers[i].downstream_id = int(remap[down])
		else:
			rivers[i].downstream_id = -1


func _reach_intrudes_trunk_valley(reach: RiverPolyline) -> bool:
	var inside_valley: int = 0
	var parallel: int = 0
	for p in reach.points:
		var best_d: float = INF
		var best_half: float = 0.0
		var best_valley: float = 0.0
		var rect: Rect2 = Rect2(p.x - 500.0, p.z - 500.0, 1000.0, 1000.0)
		for base in corridors.rivers_in_rect(rect):
			var ax: float = corridors.rivers[base]
			var az: float = corridors.rivers[base + 2]
			var bx: float = corridors.rivers[base + 3]
			var bz: float = corridors.rivers[base + 5]
			var abx: float = bx - ax
			var abz: float = bz - az
			var len_sq: float = abx * abx + abz * abz
			var t: float = 0.0
			if len_sq > 0.000001:
				t = clampf(((p.x - ax) * abx + (p.z - az) * abz) / len_sq, 0.0, 1.0)
			var d: float = Vector2(p.x - (ax + abx * t), p.z - (az + abz * t)).length()
			if d < best_d:
				best_d = d
				var feature_class: int = int(corridors.rivers[base + 8])
				best_half = corridors.river_half_width(feature_class)
				best_valley = corridors.river_valley_radius(feature_class)
		if best_d >= best_valley:
			continue
		inside_valley += 1
		# Join tips sit near the channel; parallel runs sit out in the floor.
		if best_d > best_half + TRUNK_VALLEY_PAD:
			parallel += 1
	if parallel >= 2:
		return true
	# A reach that is mostly inside the valley even if every sample is somehow
	# near the channel is still wrong: that water belongs to the trunk.
	return inside_valley >= maxi(reach.points.size() / 2, 3)


## True for the part of the core this sector may put its own water in: the core
## minus the keep-out band along every boundary.
func _in_local_domain(index: int) -> bool:
	var n: int = terrain.cells
	var cx: int = index % n
	var cz: int = index / n
	return (
		cx >= local_min.x and cz >= local_min.y
		and cx <= local_max.x and cz <= local_max.y
	)


func _chain_to_polyline(
	reach: RiverPolyline, chain: PackedInt32Array, n: int, noise: NoiseSet
) -> void:
	var raw: PackedVector3Array = PackedVector3Array()
	var widths: PackedFloat32Array = PackedFloat32Array()

	for idx in chain.size():
		var cell: int = chain[idx]
		var centre: Vector2 = terrain.cell_center(cell % n, cell / n)
		var order: float = float(maxi(reach.order, 1))
		var half_w: float = config.river_width_base + (order - 1.0) * config.river_width_per_order
		raw.append(Vector3(centre.x, filled[cell], centre.y))
		widths.append(half_w)

	_apply_meander(raw, noise)
	var smooth: PackedVector3Array = _chaikin(raw, 2)
	var smooth_widths: PackedFloat32Array = _resample_widths(widths, smooth.size())
	# Meander and Chaikin walk the polyline off the cell centres whose filled
	# height it inherited. On the refined surface that is often a shoulder a
	# few metres above the real bed, which is the same floating-canal look the
	# trunk drape exists to kill. Pin every station back under the land. Do not
	# re-apply a monotonic clamp afterwards: holding the sheet down across a
	# bump buries it, and the river disappears under its own banks.
	_drape_polyline(smooth)
	_widen_steep_cascade(smooth, smooth_widths, reach.valley)

	reach.points = smooth
	reach.half_width = smooth_widths


## Steep lake-to-lake (or hillside) drops keep order-1 half-width, so density
## paints a thread in a dry gorge. Widen the wet ribbon on steep runs.
func _widen_steep_cascade(
	points: PackedVector3Array, widths: PackedFloat32Array, valley: float
) -> void:
	if points.size() < 3 or widths.size() != points.size():
		return
	var length: float = 0.0
	for i in range(1, points.size()):
		length += Vector2(
			points[i].x - points[i - 1].x, points[i].z - points[i - 1].z
		).length()
	if length < config.macro_cell_size:
		return
	var drop: float = points[0].y - points[points.size() - 1].y
	if drop < 6.0 or drop / length < 0.04:
		return
	var target: float = minf(maxf(valley * 0.35, config.river_width_base * 1.8), 10.0)
	for i in widths.size():
		widths[i] = maxf(widths[i], target)


## Local lake id within [param max_cells] of a world point, or -1.
func _nearest_lake_id_near(world_x: float, world_z: float, max_cells: int) -> int:
	if lakes.is_empty():
		return -1
	var cell: Vector2i = terrain.local_cell_of(world_x, world_z)
	var n: int = terrain.cells
	var best_id: int = -1
	var best_d: int = max_cells + 1
	for dz in range(-max_cells, max_cells + 1):
		for dx in range(-max_cells, max_cells + 1):
			var x: int = cell.x + dx
			var z: int = cell.y + dz
			if not terrain.contains_local(x, z):
				continue
			var id: int = lake_id[z * n + x]
			if id < 0:
				continue
			var d: int = maxi(absi(dx), absi(dz))
			if d < best_d:
				best_d = d
				best_id = id
	return best_id


## Continues a lake-bound reach under the spill so density carves a continuous
## mouth instead of a rounded stub ending on dry berm before the sheet.
func _extend_reach_into_lake(reach: RiverPolyline) -> void:
	if reach.ends_in_lake < 0 or reach.ends_in_lake >= lakes.size():
		return
	if reach.points.size() < 2:
		return
	var lake: LakeData = lakes[reach.ends_in_lake]
	var tip: Vector3 = reach.points[reach.points.size() - 1]
	var prev: Vector3 = reach.points[reach.points.size() - 2]
	var dir: Vector2 = Vector2(tip.x - prev.x, tip.z - prev.z)
	var centre: Vector2 = lake.bounds.get_center()
	var to_centre: Vector2 = centre - Vector2(tip.x, tip.z)
	if dir.length_squared() < 1.0:
		dir = to_centre
	elif to_centre.length_squared() > 1.0 and dir.dot(to_centre) < 0.0:
		# Meander aimed back at the bank — prefer the basin.
		dir = to_centre
	if dir.length_squared() < 1.0:
		return
	dir = dir.normalized()

	var half: float = reach.half_width[reach.half_width.size() - 1]
	var step: float = config.macro_cell_size * 0.85
	var max_ext: float = config.macro_cell_size * 4.0
	var cursor: Vector2 = Vector2(tip.x, tip.z)
	var travelled: float = 0.0
	var inside_steps: int = 0
	var n: int = terrain.cells
	while travelled < max_ext:
		cursor += dir * step
		travelled += step
		var cell: Vector2i = terrain.local_cell_of(cursor.x, cursor.y)
		if not terrain.contains_local(cell.x, cell.y):
			break
		var idx: int = cell.y * n + cell.x
		var water_z: float = minf(tip.y, lake.surface_z)
		if lake_id[idx] == lake.id:
			inside_steps += 1
			water_z = lake.surface_z
		elif inside_steps > 0:
			break
		reach.points.append(Vector3(cursor.x, water_z, cursor.y))
		reach.half_width.append(half)
		if inside_steps >= 3:
			break

	# Water must not rise toward the lake mouth.
	for i in range(1, reach.points.size()):
		var p: Vector3 = reach.points[i]
		if p.y > reach.points[i - 1].y:
			p.y = reach.points[i - 1].y
			reach.points[i] = p
	reach.compute_bounds()


## Pulls the last station of a brook onto the shared water it joins - an atlas
## trunk, or the stub of a boundary port - at that water's own height.
##
## A confluence that misses by a few metres shows up as two water surfaces that
## never meet. The snap only happens when there really is shared water within
## reach; a brook that ran out of local domain with nothing to join simply ends
## where it is.
func _snap_to_shared(reach: RiverPolyline) -> void:
	var last: int = reach.points.size() - 1
	if last < 1:
		return
	var tip: Vector3 = reach.points[last]
	var best: Vector3 = tip
	var best_d: float = config.local_keepout_metres * config.local_keepout_metres
	var found: bool = false
	for other in rivers:
		if not other.is_shared:
			continue
		for p in other.points:
			# Only stations the brook is allowed to reach: snapping onto the
			# part of a stub that lies inside the keep-out band would drag the
			# brook's own carve in with it.
			var cell: Vector2i = terrain.local_cell_of(p.x, p.z)
			if not terrain.contains_local(cell.x, cell.y):
				continue
			if not _in_local_domain(cell.y * terrain.cells + cell.x):
				continue
			var d: float = Vector2(p.x - tip.x, p.z - tip.z).length_squared()
			if d < best_d:
				best_d = d
				best = p
				found = true
	if not found:
		return
	reach.points[last] = Vector3(
		best.x, minf(best.y, reach.points[last - 1].y), best.z
	)


## Lateral wander only. Station heights are never touched, so the monotonic
## drainage profile survives meandering.
func _apply_meander(points: PackedVector3Array, noise: NoiseSet) -> void:
	var n_points: int = points.size()
	if n_points < 3:
		return
	for i in range(1, n_points - 1):
		var prev: Vector3 = points[i - 1]
		var next: Vector3 = points[i + 1]
		var dir: Vector2 = Vector2(next.x - prev.x, next.z - prev.z)
		if dir.length_squared() < 0.0001:
			continue
		dir = dir.normalized()
		var perp: Vector2 = Vector2(-dir.y, dir.x)

		var drop: float = absf(prev.y - next.y)
		var run: float = Vector2(next.x - prev.x, next.z - prev.z).length()
		var slope: float = drop / maxf(run, 0.001)
		# Meanders belong on flat ground; steep reaches stay in their valley.
		var flatness: float = 1.0 - smoothstep(0.01, 0.09, slope)

		var wander: float = noise.meander.get_noise_2d(points[i].x, points[i].z)
		var offset: float = wander * config.meander_amplitude * flatness
		points[i] = Vector3(
			points[i].x + perp.x * offset,
			points[i].y,
			points[i].z + perp.y * offset
		)


## Pulls every station under the continental surface.
func _drape_polyline(points: PackedVector3Array) -> void:
	for i in points.size():
		var p: Vector3 = points[i]
		var water: float = minf(p.y, continental.height_at(p.x, p.z))
		points[i] = Vector3(p.x, water, p.z)


static func _chaikin(points: PackedVector3Array, iterations: int) -> PackedVector3Array:
	var current: PackedVector3Array = points
	for _i in iterations:
		if current.size() < 3:
			return current
		var next: PackedVector3Array = PackedVector3Array()
		next.append(current[0])
		for k in range(current.size() - 1):
			var a: Vector3 = current[k]
			var b: Vector3 = current[k + 1]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		next.append(current[current.size() - 1])
		current = next
	return current


static func _resample_widths(widths: PackedFloat32Array, target: int) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(target)
	var last: int = widths.size() - 1
	if last <= 0:
		for i in target:
			out[i] = widths[0] if widths.size() > 0 else 1.0
		return out
	for i in target:
		var t: float = float(i) / float(maxi(target - 1, 1)) * float(last)
		var i0: int = clampi(int(t), 0, last)
		var i1: int = mini(i0 + 1, last)
		out[i] = lerpf(widths[i0], widths[i1], t - float(i0))
	return out


func _link_downstream(cell_owner: PackedInt32Array, end_cells: Dictionary) -> void:
	for reach in rivers:
		if reach.is_trunk or not end_cells.has(reach.id):
			continue
		var owner: int = cell_owner[int(end_cells[reach.id])]
		if owner >= 0 and owner != reach.id:
			reach.downstream_id = owner


## Pull each tributary's last station onto the trunk it joins. Without this the
## meander offset would leave a visible gap at every confluence, and the two
## water surfaces would not meet.
func _join_confluences() -> void:
	for reach in rivers:
		if reach.downstream_id < 0:
			continue
		var downstream: RiverPolyline = rivers[reach.downstream_id]
		var last_index: int = reach.points.size() - 1
		var tip: Vector3 = reach.points[last_index]

		var best: Vector3 = downstream.points[0]
		var best_d: float = INF
		for p in downstream.points:
			var d: float = Vector2(p.x - tip.x, p.z - tip.z).length_squared()
			if d < best_d:
				best_d = d
				best = p

		var previous_y: float = reach.points[last_index - 1].y
		reach.points[last_index] = Vector3(best.x, minf(best.y, previous_y), best.z)


func _index_rivers() -> void:
	for reach in rivers:
		for i in range(reach.points.size() - 1):
			var a: Vector3 = reach.points[i]
			var b: Vector3 = reach.points[i + 1]
			river_index.insert_segment(a.x, a.z, b.x, b.z, reach.id * 65536 + i)


# --- Local lake proximity ------------------------------------------------------------

func _build_lake_distance() -> void:
	var n: int = terrain.cells
	var count: int = n * n
	lake_distance = PackedFloat32Array()
	lake_distance.resize(count)
	lake_surface_near = PackedFloat32Array()
	lake_surface_near.resize(count)
	# The surface is carried on its own uncapped distance so it stays finite over
	# the whole grid. A field with holes in it cannot be sampled smoothly, and a
	# lake level read per cell puts a 32 m staircase around every shore.
	_surface_reach = PackedFloat32Array()
	_surface_reach.resize(count)
	for i in count:
		var id: int = lake_id[i]
		lake_distance[i] = 0.0 if id != -1 else MAX_LAKE_DISTANCE
		_surface_reach[i] = 0.0 if id != -1 else INF
		lake_surface_near[i] = lakes[id].surface_z if id != -1 else -INF

	var straight: float = config.macro_cell_size
	var diagonal: float = straight * 1.41421356

	for cz in n:
		for cx in n:
			var i: int = cz * n + cx
			if cx > 0:
				_relax_lake(i, i - 1, straight)
			if cz > 0:
				_relax_lake(i, i - n, straight)
			if cx > 0 and cz > 0:
				_relax_lake(i, i - n - 1, diagonal)
			if cx < n - 1 and cz > 0:
				_relax_lake(i, i - n + 1, diagonal)

	for cz in range(n - 1, -1, -1):
		for cx in range(n - 1, -1, -1):
			var i: int = cz * n + cx
			if cx < n - 1:
				_relax_lake(i, i + 1, straight)
			if cz < n - 1:
				_relax_lake(i, i + n, straight)
			if cx < n - 1 and cz < n - 1:
				_relax_lake(i, i + n + 1, diagonal)
			if cx > 0 and cz < n - 1:
				_relax_lake(i, i + n - 1, diagonal)


func _relax_lake(target: int, source: int, step: float) -> void:
	var reach: float = _surface_reach[source] + step
	if reach < _surface_reach[target]:
		_surface_reach[target] = reach
		lake_surface_near[target] = lake_surface_near[source]
	var candidate: float = lake_distance[source] + step
	if candidate < lake_distance[target]:
		lake_distance[target] = candidate


# --- Queries ---------------------------------------------------------------------------

## Local lake at a point, or -1. Atlas water is not a lake: ask
## [ContinentalTerrain] about the sea and the atlas lakes instead.
func lake_at(world_x: float, world_z: float) -> int:
	var cell: Vector2i = terrain.local_cell_of(world_x, world_z)
	if not terrain.contains_local(cell.x, cell.y):
		return -1
	return lake_id[cell.y * terrain.cells + cell.x]


## Nearest river station to a point, or an empty dictionary when none is close.
## Keys: distance, point, half_width, water_z, order, reach.
func nearest_reach(world_x: float, world_z: float, radius: float) -> Dictionary:
	var rect: Rect2 = Rect2(world_x - radius, world_z - radius, radius * 2.0, radius * 2.0)
	var best: Dictionary = {}
	var best_d: float = radius
	for encoded in river_index.query_rect(rect):
		var reach: RiverPolyline = rivers[encoded >> 16]
		var i: int = encoded & 0xFFFF
		var a: Vector3 = reach.points[i]
		var b: Vector3 = reach.points[i + 1]
		var ab: Vector2 = Vector2(b.x - a.x, b.z - a.z)
		var len_sq: float = ab.length_squared()
		var t: float = 0.0
		if len_sq > 0.000001:
			t = clampf(Vector2(world_x - a.x, world_z - a.z).dot(ab) / len_sq, 0.0, 1.0)
		var point: Vector2 = Vector2(a.x, a.z) + ab * t
		var d: float = point.distance_to(Vector2(world_x, world_z))
		if d >= best_d:
			continue
		best_d = d
		best = {
			"distance": d,
			"point": point,
			"half_width": lerpf(reach.half_width[i], reach.half_width[i + 1], t),
			"water_z": lerpf(a.y, b.y, t),
			"order": reach.order,
			"reach": reach.id,
		}
	return best


## The depression-filled drainage height, sampled as smoothly as the terrain it
## is compared against. Above the land surface means standing water; the two
## meet exactly at the waterline.
func drainage_at(world_x: float, world_z: float) -> float:
	return terrain.sample_field(filled, world_x, world_z)


func lake_distance_at(world_x: float, world_z: float) -> float:
	return maxf(terrain.sample_field(lake_distance, world_x, world_z), 0.0)


## Surface of the local lake nearest this point, or -INF when there is none.
func lake_surface_near_at(world_x: float, world_z: float) -> float:
	if lakes.is_empty():
		return -INF
	return terrain.sample_field(lake_surface_near, world_x, world_z)
