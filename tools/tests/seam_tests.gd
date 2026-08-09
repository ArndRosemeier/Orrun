extends SceneTree
## Headless verification that adjacent sectors meet exactly.
##
##   godot --headless --path <project> --script res://tools/tests/seam_tests.gd
##
## Everything here is about one question: can two 8 km sectors be baked
## independently, in any order, on any thread, and still produce one continuous
## world? The suite walks the same red-green order the design does - coordinates,
## then terrain, then shorelines, then edge contracts, then whole sectors, then
## chunks, and finally the river mouth the game opens on.
##
## Two kinds of comparison are used deliberately:
##   - exact equality for identities, contract records, and anything produced by
##     the same continental function at the same coordinate;
##   - a small named tolerance for values that pass through interpolation or
##     meshing, never a blanket epsilon that would hide a real step.

## Terrain sampled at the same continental metre must be bit-identical. There is
## no interpolation between the two calls, so there is nothing to round.
const EXACT: float = 0.0
## Density-field columns of two chunks meeting on a boundary are meshed on the
## same voxel lattice, so they may only differ by float32 rounding.
const COLUMN_TOLERANCE: float = 0.01
## Small atlas: big enough for real rivers and coast, small enough that the
## whole suite runs in seconds.
const ATLAS_SIZE: int = 64

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	print("=== Orrun sector seam tests ===")
	var config: WorldConfig = WorldConfig.new()
	config.atlas_size = ATLAS_SIZE

	_test_coordinates(config)

	var t0: int = Time.get_ticks_msec()
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	print("continent: %d km, %s, %d trunk segments, %d road segments, %d mouths" % [
		config.atlas_size, context.build_timings,
		context.corridors.river_segment_count(),
		context.corridors.road_segment_count(),
		context.corridors.mouths.size()
	])

	var pair: Array[Vector2i] = _pick_boundary(context)
	print("test boundary: sector %s | %s" % [pair[0], pair[1]])

	_test_terrain_is_pure(context, pair)
	_test_shoreline_seam(context)
	_test_contract_symmetry(context, pair)

	var t1: int = Time.get_ticks_msec()
	var west: WorldSector = WorldSector.generate(context, pair[0])
	var east: WorldSector = WorldSector.generate(context, pair[1])
	print("sector bakes: %s, %s (%d ms for two)" % [
		west.bake_timings, east.bake_timings, Time.get_ticks_msec() - t1
	])

	_test_sector_overlap(west, east)
	_test_generation_order(context, pair, west)
	_test_water_ownership(west, east)
	_test_trunks_cross(west, east)
	_test_chunk_seam(context, west, east)
	_test_river_mouth(context)

	print("---")
	print("%d ms total | %d checks | %d failures" % [
		Time.get_ticks_msec() - t0, checks, failures
	])
	quit(1 if failures > 0 else 0)


func _check(name: String, condition: bool, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS  %s %s" % [name, detail])
	else:
		failures += 1
		printerr("  FAIL  %s %s" % [name, detail])


# --- 1. Coordinates and ownership --------------------------------------------------

func _test_coordinates(config: WorldConfig) -> void:
	print("- coordinates and sector ownership")

	# Negative coordinates are the classic place a world like this breaks: an
	# integer division that truncates towards zero puts two different sectors on
	# either side of the origin into the same bucket.
	var round_trips: int = 0
	var probes: Array[Vector2] = [
		Vector2(0.0, 0.0), Vector2(0.5, -0.5), Vector2(-1.0, -1.0),
		Vector2(7999.9, 8000.1), Vector2(-8000.1, 123456.7),
		Vector2(412345.25, -98765.5),
	]
	for point in probes:
		var sector: Vector2i = WorldCoords.sector_of(point.x, point.y)
		var rect: Rect2 = WorldCoords.sector_rect(sector)
		if (
			point.x >= rect.position.x and point.x < rect.position.x + rect.size.x
			and point.y >= rect.position.y and point.y < rect.position.y + rect.size.y
		):
			round_trips += 1
	_check("sector rect contains its own points", round_trips == probes.size(),
		"(%d of %d)" % [round_trips, probes.size()])

	var keys: Dictionary = {}
	var collisions: int = 0
	for sz in range(-3, 4):
		for sx in range(-3, 4):
			var key: int = WorldCoords.sector_key(Vector2i(sx, sz))
			if keys.has(key):
				collisions += 1
			keys[key] = true
	_check("sector keys are unique", collisions == 0, "(%d collisions)" % collisions)

	# 8000 / 64 = 125 exactly. If that ever stops being an integer, chunks start
	# straddling two sectors and there is no owner to ask for their terrain.
	_check("a sector is a whole number of chunks", config.chunks_per_sector() == 125,
		"(%d chunks)" % config.chunks_per_sector())
	_check("a sector is a whole number of macro cells",
		config.macro_cells_per_sector() == 250,
		"(%d cells)" % config.macro_cells_per_sector())

	var mismatched: int = 0
	var per: int = config.chunks_per_sector()
	for probe_sector in [Vector2i(0, 0), Vector2i(3, 7), Vector2i(-2, -1)]:
		var base: Vector2i = probe_sector * per
		for corner in [
			Vector2i(0, 0), Vector2i(per - 1, 0),
			Vector2i(0, per - 1), Vector2i(per - 1, per - 1)
		]:
			var chunk: Vector2i = base + corner
			if WorldCoords.sector_of_chunk(config, chunk) != probe_sector:
				mismatched += 1
	_check("every chunk has exactly one owning sector", mismatched == 0,
		"(%d chunks owned by the wrong sector)" % mismatched)

	var origin_mismatch: int = 0
	for probe_sector in [Vector2i(0, 0), Vector2i(5, 2), Vector2i(-1, 4)]:
		var cell: Vector2i = WorldCoords.sector_macro_origin(config, probe_sector)
		var centre: Vector2 = WorldCoords.macro_cell_center(config, cell)
		if WorldCoords.sector_of(centre.x, centre.y) != probe_sector:
			origin_mismatch += 1
	_check("sector macro origin lands inside its sector", origin_mismatch == 0,
		"(%d off)" % origin_mismatch)


# --- 2. The continental surface is a pure function -----------------------------------

## A boundary worth testing: two neighbouring sectors that are mostly land and
## have a trunk river running through them.
func _pick_boundary(context: WorldContext) -> Array[Vector2i]:
	var best: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 1)]
	var best_score: int = -1
	var per_sector: int = int(WorldCoords.SECTOR_SIZE / WorldCoords.ATLAS_CELL_SIZE)
	var sectors: int = context.config.atlas_size / per_sector
	for sz in range(1, sectors - 1):
		for sx in range(1, sectors - 2):
			var here: Vector2i = Vector2i(sx, sz)
			var there: Vector2i = Vector2i(sx + 1, sz)
			var score: int = _sector_land_score(context, here) + _sector_land_score(
				context, there
			)
			if score > best_score:
				best_score = score
				best = [here, there]
	return best


## Land cells plus a heavy bonus for river cells, so the chosen pair actually
## exercises a trunk crossing rather than two squares of empty steppe.
func _sector_land_score(context: WorldContext, sector: Vector2i) -> int:
	var rect: Rect2 = WorldCoords.sector_rect(sector)
	var score: int = 0
	var origin: Vector2i = WorldCoords.atlas_cell_of(rect.position.x, rect.position.y)
	for dz in 8:
		for dx in 8:
			var cell: Vector2i = origin + Vector2i(dx, dz)
			if not context.atlas.in_bounds(cell.x, cell.y):
				continue
			if context.atlas.is_ocean(cell.x, cell.y):
				continue
			score += 1
			if not context.atlas.links_in_cell(
				cell.x, cell.y, AtlasFeatures.Kind.RIVER
			).is_empty():
				score += 6
	return score


func _test_terrain_is_pure(context: WorldContext, pair: Array[Vector2i]) -> void:
	print("- the continental surface is one function")

	# Two samplers, as if two worker threads were baking the two sectors.
	var a: ContinentalTerrain = context.sampler()
	var b: ContinentalTerrain = context.sampler()

	var line: float = float(pair[1].x) * WorldCoords.SECTOR_SIZE
	var start: float = float(pair[0].y) * WorldCoords.SECTOR_SIZE
	var height_diff: float = 0.0
	var shore_diff: float = 0.0
	var plane_diff: float = 0.0
	var samples: int = 0
	for i in 400:
		var z: float = start + float(i) * (WorldCoords.SECTOR_SIZE / 400.0)
		height_diff = maxf(
			height_diff, absf(a.height_at(line, z) - b.height_at(line, z))
		)
		shore_diff = maxf(
			shore_diff, absf(a.shore_signed(line, z) - b.shore_signed(line, z))
		)
		plane_diff = maxf(
			plane_diff, absf(a.water_plane_at(line, z) - b.water_plane_at(line, z))
		)
		samples += 1
	_check("two samplers agree exactly on height", height_diff <= EXACT,
		"(worst %.9f m over %d samples)" % [height_diff, samples])
	_check("two samplers agree exactly on the shoreline", shore_diff <= EXACT,
		"(worst %.9f)" % shore_diff)
	_check("two samplers agree exactly on the water plane", plane_diff <= EXACT,
		"(worst %.9f m)" % plane_diff)

	# The bulk window fill is an optimisation of the single-sample reader. If it
	# is not exactly the same function, every sector edge is a step.
	var config: WorldConfig = context.config
	var origin_cell: Vector2i = WorldCoords.sector_macro_origin(config, pair[0])
	var cells: int = 24
	var elevation: PackedFloat32Array = PackedFloat32Array()
	elevation.resize(cells * cells)
	var relief: PackedFloat32Array = PackedFloat32Array()
	relief.resize(cells * cells)
	var moisture: PackedFloat32Array = PackedFloat32Array()
	moisture.resize(cells * cells)
	var temperature: PackedFloat32Array = PackedFloat32Array()
	temperature.resize(cells * cells)
	a.fill_window(origin_cell, cells, elevation, relief, moisture, temperature)

	var bulk_diff: float = 0.0
	for cz in cells:
		for cx in cells:
			var centre: Vector2 = WorldCoords.macro_cell_center(
				config, origin_cell + Vector2i(cx, cz)
			)
			bulk_diff = maxf(bulk_diff, absf(
				elevation[cz * cells + cx] - b.height_at(centre.x, centre.y)
			))
	_check("bulk fill matches point sampling", bulk_diff <= EXACT,
		"(worst %.9f m over %d cells)" % [bulk_diff, cells * cells])


# --- 3. Shorelines ----------------------------------------------------------------------

func _test_shoreline_seam(context: WorldContext) -> void:
	print("- shorelines cross sector boundaries unbroken")

	var coastal: Vector2i = _find_coastal_boundary(context)
	if coastal == Vector2i(-1, -1):
		_check("atlas has a coast on a sector boundary", false, "(none found)")
		return

	var a: ContinentalTerrain = context.sampler()
	var b: ContinentalTerrain = context.sampler()
	var line: float = float(coastal.x + 1) * WorldCoords.SECTOR_SIZE
	var start: float = float(coastal.y) * WorldCoords.SECTOR_SIZE

	# Walk the boundary at half-metre spacing and find every land/water crossing
	# each side sees. If the two sides disagree about even one, there is a step
	# in the waterline exactly on the seam - the most visible artefact there is.
	var crossings_a: PackedFloat32Array = _shore_crossings(a, line, start)
	var crossings_b: PackedFloat32Array = _shore_crossings(b, line, start)
	_check("both sides find the same waterline crossings",
		crossings_a == crossings_b,
		"(%d vs %d crossings along the shared edge)" % [
			crossings_a.size(), crossings_b.size()
		])
	_check("the boundary really does cross a coast", crossings_a.size() > 0,
		"(%d crossings)" % crossings_a.size())

	# The beach profile has to match too, not just the waterline: same depth
	# below and same freeboard above, sampled across the seam.
	var worst_profile: float = 0.0
	for along in crossings_a:
		for offset in [-40.0, -12.0, -2.0, 2.0, 12.0, 40.0]:
			var here: Vector2 = Vector2(line + offset, along)
			worst_profile = maxf(worst_profile, absf(
				a.height_at(here.x, here.y) - b.height_at(here.x, here.y)
			))
	_check("beach profiles match across the seam", worst_profile <= EXACT,
		"(worst %.9f m)" % worst_profile)

	# Water height is per body, and the body is continental: an atlas lake that
	# two sectors share must sit at one surface, not two.
	var lake_gap: float = _worst_lake_surface_gap(context, a)
	_check("a shared lake has one surface", lake_gap <= 0.001,
		"(worst spread %.4f m across sector boundaries)" % lake_gap)


func _shore_crossings(
	terrain: ContinentalTerrain, line: float, start: float
) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	var steps: int = int(WorldCoords.SECTOR_SIZE / 4.0)
	var previous: float = terrain.shore_signed(line, start)
	for i in range(1, steps + 1):
		var along: float = start + float(i) * 4.0
		var here: float = terrain.shore_signed(line, along)
		if (previous <= 0.0) != (here <= 0.0):
			out.append(along)
		previous = here
	return out


func _find_coastal_boundary(context: WorldContext) -> Vector2i:
	var per_sector: int = int(WorldCoords.SECTOR_SIZE / WorldCoords.ATLAS_CELL_SIZE)
	var sectors: int = context.config.atlas_size / per_sector
	for sz in range(0, sectors):
		for sx in range(0, sectors - 1):
			var ax: int = (sx + 1) * per_sector
			var wet: int = 0
			var dry: int = 0
			for i in per_sector:
				var az: int = sz * per_sector + i
				if not context.atlas.in_bounds(ax, az):
					continue
				if context.atlas.is_ocean(ax, az) or context.atlas.is_lake(ax, az):
					wet += 1
				else:
					dry += 1
			if wet >= 2 and dry >= 2:
				return Vector2i(sx, sz)
	return Vector2i(-1, -1)


## Widest disagreement in water-plane height sampled either side of any sector
## boundary that runs through an atlas lake.
func _worst_lake_surface_gap(
	context: WorldContext, terrain: ContinentalTerrain
) -> float:
	var worst: float = 0.0
	for lake_variant in context.atlas.lakes:
		var lake: AtlasLake = lake_variant
		for cell_index in lake.cells:
			var ax: int = cell_index % context.atlas.size
			var az: int = cell_index / context.atlas.size
			var centre: Vector2 = context.atlas.continental_centre(ax, az)
			var sector: Vector2i = WorldCoords.sector_of(centre.x, centre.y)
			var rect: Rect2 = WorldCoords.sector_rect(sector)
			# Only cells hugging a sector edge can expose a mismatch.
			if (
				centre.x - rect.position.x > WorldCoords.ATLAS_CELL_SIZE
				and rect.position.x + rect.size.x - centre.x > WorldCoords.ATLAS_CELL_SIZE
			):
				continue
			var here: float = terrain.water_plane_at(centre.x, centre.y)
			worst = maxf(worst, absf(here - float(lake.surface_z)))
	return worst


# --- 4. Edge contracts --------------------------------------------------------------------

func _test_contract_symmetry(context: WorldContext, pair: Array[Vector2i]) -> void:
	print("- both neighbours derive the same edge contract")

	var terrain: ContinentalTerrain = context.sampler()
	var from_west: Array = SectorEdgeContract.canonical(
		pair[0], SectorEdgeContract.Side.EAST
	)
	var from_east: Array = SectorEdgeContract.canonical(
		pair[1], SectorEdgeContract.Side.WEST
	)
	_check("the two sides name the same edge", from_west == from_east,
		"(%s vs %s)" % [from_west, from_east])

	var west_view: SectorEdgeContract = SectorEdgeContract.build(
		context.config, context.corridors, terrain, from_west[0], from_west[1]
	)
	var east_view: SectorEdgeContract = SectorEdgeContract.build(
		context.config, context.corridors, context.sampler(),
		from_east[0], from_east[1]
	)
	_check("contract records are identical",
		west_view.fingerprint() == east_view.fingerprint(),
		"(%d ports vs %d)" % [west_view.ports.size(), east_view.ports.size()])
	_check("the edge carries ports at all", west_view.ports.size() > 0,
		"(%d ports)" % west_view.ports.size())

	# Every port must be on the line, unit-tangent, and pointed at exactly one
	# of the two sectors. A port that flows into neither is a dangling channel.
	var line: float = west_view.line_constant()
	var off_line: int = 0
	var bad_tangent: int = 0
	var bad_target: int = 0
	var rising_rivers: int = 0
	for port in west_view.ports:
		if absf(port.position.x - line) > 0.001:
			off_line += 1
		if absf(port.tangent.length() - 1.0) > 0.0005:
			bad_tangent += 1
		if port.into_sector != pair[0] and port.into_sector != pair[1]:
			bad_target += 1
		if port.kind != SectorEdgeContract.Kind.ROAD and port.grade > 0.0001:
			rising_rivers += 1
	_check("ports sit exactly on the boundary", off_line == 0, "(%d off)" % off_line)
	_check("port tangents are unit length", bad_tangent == 0, "(%d bad)" % bad_tangent)
	_check("every port enters one of the two sectors", bad_target == 0,
		"(%d pointing elsewhere)" % bad_target)
	_check("water ports never flow uphill", rising_rivers == 0,
		"(%d rising)" % rising_rivers)

	# A port is an inflow for exactly one side and an outflow for the other.
	var unbalanced: int = 0
	var water_ports: int = 0
	for port in west_view.ports:
		if port.kind == SectorEdgeContract.Kind.ROAD:
			continue
		water_ports += 1
		var into_west: bool = west_view.inflow_for(pair[0]).has(port)
		var into_east: bool = west_view.inflow_for(pair[1]).has(port)
		if into_west == into_east:
			unbalanced += 1
	_check("each water port is one side's inflow and the other's outflow",
		unbalanced == 0, "(%d ambiguous of %d)" % [unbalanced, water_ports])


# --- 5. Whole sectors -----------------------------------------------------------------------

func _test_sector_overlap(west: WorldSector, east: WorldSector) -> void:
	print("- neighbouring sector bakes agree where they overlap")

	# Each bake covers its core plus a halo, so the two windows share a strip.
	# Same global macro cell, two independent bakes, must be the same number.
	var worst: float = 0.0
	var compared: int = 0
	var cells: int = west.terrain.cells
	for cz in range(0, cells, 3):
		for cx in range(0, cells, 3):
			var global: Vector2i = west.terrain.origin_cell + Vector2i(cx, cz)
			var local: Vector2i = global - east.terrain.origin_cell
			if not east.terrain.contains_local(local.x, local.y):
				continue
			compared += 1
			worst = maxf(worst, absf(
				west.terrain.elevation[cz * cells + cx]
				- east.terrain.elevation[local.y * east.terrain.cells + local.x]
			))
	_check("overlapping macro cells are identical", worst <= EXACT,
		"(worst %.9f m over %d shared cells)" % [worst, compared])
	_check("the bakes really do overlap", compared > 0, "(%d cells)" % compared)

	# And the surface each side hands to a chunk on the shared face.
	var line: float = float(east.sector.x) * WorldCoords.SECTOR_SIZE
	var start: float = float(west.sector.y) * WorldCoords.SECTOR_SIZE
	var surface_gap: float = 0.0
	for i in 250:
		var z: float = start + float(i) * 32.0
		surface_gap = maxf(surface_gap, absf(
			west.terrain.height_at(line, z) - east.terrain.height_at(line, z)
		))
	_check("the shared face has one ground height", surface_gap <= COLUMN_TOLERANCE,
		"(worst %.6f m)" % surface_gap)


func _test_generation_order(
	context: WorldContext, pair: Array[Vector2i], reference: WorldSector
) -> void:
	print("- a sector does not depend on when it was baked")

	# Baked second the first time, first this time, from a fresh context so no
	# lazily cached state can carry over.
	var fresh: WorldContext = WorldContext.create(context.config, context.atlas)
	var again: WorldSector = WorldSector.generate(fresh, pair[0])

	_check("macro terrain identical",
		hash(again.terrain.elevation) == hash(reference.terrain.elevation))
	_check("drainage identical",
		hash(again.hydro.filled) == hash(reference.hydro.filled))
	_check("same rivers", again.hydro.rivers.size() == reference.hydro.rivers.size(),
		"(%d vs %d)" % [again.hydro.rivers.size(), reference.hydro.rivers.size()])
	_check("same lakes", again.hydro.lakes.size() == reference.hydro.lakes.size(),
		"(%d vs %d)" % [again.hydro.lakes.size(), reference.hydro.lakes.size()])
	_check("same roads", again.paths.roads.size() == reference.paths.roads.size(),
		"(%d vs %d)" % [again.paths.roads.size(), reference.paths.roads.size()])

	var contracts_match: bool = true
	for side in again.edges:
		var mine: SectorEdgeContract = again.edges[side]
		var theirs: SectorEdgeContract = reference.edges[side]
		if mine.fingerprint() != theirs.fingerprint():
			contracts_match = false
	_check("edge contracts identical", contracts_match)


func _test_water_ownership(west: WorldSector, east: WorldSector) -> void:
	print("- water bodies have exactly one owner")

	# A local lake that reaches the core boundary would be solved twice, once by
	# each neighbour, at two different surfaces. Those are rejected at the bake,
	# and this is the check that they really are.
	var escaping: int = 0
	var largest: int = 0
	for sector in [west, east]:
		var rect: Rect2 = sector.core_rect()
		for lake in sector.hydro.lakes:
			largest = maxi(largest, lake.cells.size())
			if not rect.encloses(lake.bounds):
				escaping += 1
	_check("no local lake crosses its sector core", escaping == 0,
		"(%d escaping, largest local lake %d cells)" % [escaping, largest])

	# Locally solved reaches must keep out of the boundary band entirely: their
	# carve reshapes the ground around them, and the neighbour never heard of
	# them. Only shared water - atlas trunks and port stubs - may go near it.
	var stray: int = 0
	var shared_reaches: int = 0
	var keepout: float = west.config.local_keepout_metres
	for sector in [west, east]:
		var allowed: Rect2 = sector.core_rect().grow(-keepout)
		for reach in sector.hydro.rivers:
			if reach.is_shared:
				shared_reaches += 1
				continue
			for point in reach.points:
				if not allowed.has_point(Vector2(point.x, point.z)):
					stray += 1
					break
	_check("local water keeps out of the boundary band", stray == 0,
		"(%d reaches inside the band, %d shared reaches which may)" % [
			stray, shared_reaches
		])

	# The stub of a boundary port is built by both neighbours, from the port
	# alone. If the two copies were not the same polyline, a brook crossing the
	# seam would arrive at two different water heights.
	var west_stubs: Dictionary = _stubs_by_feature(west)
	var east_stubs: Dictionary = _stubs_by_feature(east)
	var matched: int = 0
	var mismatched: int = 0
	for key in west_stubs:
		if not east_stubs.has(key):
			continue
		if west_stubs[key] == east_stubs[key]:
			matched += 1
		else:
			mismatched += 1
	_check("port stubs are identical on both sides", mismatched == 0,
		"(%d matching, %d differing)" % [matched, mismatched])


func _test_trunks_cross(west: WorldSector, east: WorldSector) -> void:
	print("- atlas trunks are the same river on both sides")

	var line: float = float(east.sector.x) * WorldCoords.SECTOR_SIZE
	var west_hits: Dictionary = _trunk_crossings(west, line)
	var east_hits: Dictionary = _trunk_crossings(east, line)

	var shared: int = 0
	var worst_position: float = 0.0
	var worst_surface: float = 0.0
	for feature_id in west_hits:
		if not east_hits.has(feature_id):
			continue
		shared += 1
		var a: Vector3 = west_hits[feature_id]
		var b: Vector3 = east_hits[feature_id]
		worst_position = maxf(worst_position, absf(a.z - b.z))
		worst_surface = maxf(worst_surface, absf(a.y - b.y))

	if west_hits.is_empty() and east_hits.is_empty():
		print("    (no trunk crosses this boundary; skipping)")
		return
	_check("every trunk crossing is seen by both sectors",
		shared == west_hits.size() and shared == east_hits.size(),
		"(%d shared, %d west, %d east)" % [shared, west_hits.size(), east_hits.size()])
	_check("trunk crossings meet at the same point",
		worst_position <= COLUMN_TOLERANCE, "(worst %.4f m along the edge)" % worst_position)
	_check("trunk crossings meet at the same water height",
		worst_surface <= COLUMN_TOLERANCE, "(worst %.4f m)" % worst_surface)


## Port stubs by the port id they were built from.
func _stubs_by_feature(sector: WorldSector) -> Dictionary:
	var out: Dictionary = {}
	for reach in sector.hydro.rivers:
		if reach.is_shared and not reach.is_trunk:
			out[reach.feature_id] = reach.points
	return out


## Where each trunk feature meets the boundary line, keyed by atlas feature id.
func _trunk_crossings(sector: WorldSector, line: float) -> Dictionary:
	var out: Dictionary = {}
	for reach in sector.hydro.rivers:
		if not reach.is_trunk:
			continue
		for i in range(reach.points.size() - 1):
			var a: Vector3 = reach.points[i]
			var b: Vector3 = reach.points[i + 1]
			if (a.x - line) * (b.x - line) > 0.0 or absf(b.x - a.x) < 0.000001:
				continue
			var t: float = (line - a.x) / (b.x - a.x)
			out[reach.feature_id] = a.lerp(b, t)
	return out


# --- 6. Chunks across the seam ----------------------------------------------------------------

func _test_chunk_seam(
	context: WorldContext, west: WorldSector, east: WorldSector
) -> void:
	print("- chunks either side of the boundary mesh one surface")

	var config: WorldConfig = context.config
	var per: int = config.chunks_per_sector()
	var terrain: ContinentalTerrain = context.sampler()
	var noise: NoiseSet = NoiseSet.create(config)

	var row: int = west.sector.y * per + per / 2
	var last_west: Vector2i = Vector2i(west.sector.x * per + per - 1, row)
	var first_east: Vector2i = Vector2i(east.sector.x * per, row)
	_check("the two probe chunks belong to different sectors",
		WorldCoords.sector_of_chunk(config, last_west) == west.sector
		and WorldCoords.sector_of_chunk(config, first_east) == east.sector)

	var left: DensityField.Field = DensityField.build(
		config, west, terrain, noise, last_west, 0
	)
	var right: DensityField.Field = DensityField.build(
		config, east, terrain, noise, first_east, 0
	)

	var left_mesh: MeshExtract.MeshData = MeshExtract.build(
		left, WorldCoords.chunk_origin(config, last_west), false
	)
	var right_mesh: MeshExtract.MeshData = MeshExtract.build(
		right, WorldCoords.chunk_origin(config, first_east), false
	)
	_check("both chunks mesh", left_mesh.surface_triangles > 0 and right_mesh.surface_triangles > 0,
		"(%d and %d surface triangles)" % [
			left_mesh.surface_triangles, right_mesh.surface_triangles
		])

	# Both fields sample one voxel beyond their own chunk, so their columns
	# overlap. Same continental x/z, two owners, one ground height.
	var worst: float = 0.0
	var compared: int = 0
	for iz in left.dims.z:
		for ix in left.dims.x:
			var here: Vector3 = left.sample_world_position(ix, 0, iz)
			var mirror: Vector2i = _column_at(right, here.x, here.z)
			if mirror.x < 0:
				continue
			compared += 1
			worst = maxf(worst, absf(
				left.surface_z[iz * left.dims.x + ix]
				- right.surface_z[mirror.y * right.dims.x + mirror.x]
			))
	_check("shared columns have one surface height", worst <= COLUMN_TOLERANCE,
		"(worst %.5f m over %d shared columns)" % [worst, compared])
	_check("the probe chunks really do share columns", compared > 0,
		"(%d columns)" % compared)


## Column of a field at a continental position, or (-1, -1) when it has none.
func _column_at(field: DensityField.Field, world_x: float, world_z: float) -> Vector2i:
	var ix: int = int(round((world_x - field.origin.x) / field.voxel))
	var iz: int = int(round((world_z - field.origin.z) / field.voxel))
	if ix < 0 or iz < 0 or ix >= field.dims.x or iz >= field.dims.z:
		return Vector2i(-1, -1)
	var here: Vector3 = field.sample_world_position(ix, 0, iz)
	if absf(here.x - world_x) > 0.01 or absf(here.z - world_z) > 0.01:
		return Vector2i(-1, -1)
	return Vector2i(ix, iz)


# --- 7. The river mouth the game opens on -------------------------------------------------------

func _test_river_mouth(context: WorldContext) -> void:
	print("- the river-mouth spawn slice")

	var mouths: Array[Dictionary] = WorldQuery.ranked_river_mouths(context)
	_check("the atlas offers river mouths", not mouths.is_empty(),
		"(%d inside the safe margin)" % mouths.size())
	if mouths.is_empty():
		return

	# Deterministic ranking: the same context must offer the same first mouth.
	var again: Array[Dictionary] = WorldQuery.ranked_river_mouths(context)
	_check("the ranking is stable",
		mouths[0]["position"] == again[0]["position"]
		and mouths[0]["feature_class"] == again[0]["feature_class"],
		"(first mouth %s)" % [mouths[0]["position"]])

	var terrain: ContinentalTerrain = context.sampler()
	var chosen: Dictionary = {}
	var spawn: Vector3 = Vector3.INF
	var sector: WorldSector = null
	for mouth in mouths:
		var position: Vector2 = mouth["position"]
		sector = WorldSector.generate(
			context, WorldCoords.sector_of(position.x, position.y)
		)
		spawn = WorldQuery.spawn_beside_mouth(sector, terrain, position)
		if spawn != Vector3.INF:
			chosen = mouth
			break
	_check("a mouth has dry ground beside it", spawn != Vector3.INF,
		"(mouth %s in sector %s)" % [
			chosen.get("position", Vector2.ZERO), sector.sector if sector != null else Vector2i.ZERO
		])
	if spawn == Vector3.INF:
		return

	var sea: float = float(context.atlas.sea_surface_z)
	_check("the spawn stands above the sea", spawn.y > sea,
		"(ground %.1f m, sea %.1f m)" % [spawn.y, sea])
	_check("the spawn is dry",
		not WorldQuery.is_water(sector, terrain, spawn.x, spawn.z))
	_check("the spawn is near its mouth",
		Vector2(spawn.x, spawn.z).distance_to(chosen["position"])
		<= WorldQuery.MOUTH_SEARCH_RADIUS * 1.5,
		"(%.0f m away)" % Vector2(spawn.x, spawn.z).distance_to(chosen["position"]))

	# The mouth is where the atlas river meets the ocean. The 3D water there must
	# be the sea, not a lake the local flood invented, and the channel must
	# actually arrive: a river that stops 200 m short reads as a dry ditch.
	var mouth_pos: Vector2 = chosen["position"]
	var reach: Dictionary = sector.hydro.nearest_reach(mouth_pos.x, mouth_pos.y, 400.0)
	_check("a river reaches the mouth", not reach.is_empty(),
		"(nearest channel %.0f m away)" % (
			float(reach["distance"]) if not reach.is_empty() else -1.0
		))
	if not reach.is_empty():
		_check("the river arrives at sea level",
			float(reach["water_z"]) <= sea + 4.0,
			"(channel water %.2f m, sea %.2f m)" % [float(reach["water_z"]), sea])

	# Walking out of the mouth must not fall off the world: the neighbouring
	# sectors have to be bakeable and their shared faces continuous.
	var neighbour: Vector2i = sector.sector + Vector2i(1, 0)
	if context.sector_in_atlas(neighbour):
		var next: WorldSector = WorldSector.generate(context, neighbour)
		var line: float = float(neighbour.x) * WorldCoords.SECTOR_SIZE
		var gap: float = 0.0
		for i in 100:
			var z: float = (
				float(sector.sector.y) * WorldCoords.SECTOR_SIZE + float(i) * 80.0
			)
			gap = maxf(gap, absf(
				sector.terrain.height_at(line, z) - next.terrain.height_at(line, z)
			))
		_check("the sector the player walks into meets this one",
			gap <= COLUMN_TOLERANCE, "(worst %.5f m)" % gap)
