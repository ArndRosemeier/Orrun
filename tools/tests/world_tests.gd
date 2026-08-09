extends SceneTree
## Headless verification of the world generator, one sector at a time.
##
##   godot --headless --path <project> --script res://tools/tests/world_tests.gd
##
## Checks the invariants the design depends on inside a single 8 km sector:
## water never flows uphill, lakes sit at their own spill heights, the ground
## stays glued to the drainage surface, chunks mesh, and the same seed rebuilds
## the same sector. Whether two sectors *meet* is the other suite's job
## ([code]seam_tests.gd[/code]); this one is about whether one of them is any
## good on its own.

## Small enough to bake in seconds, big enough for real rivers and coast.
const ATLAS_SIZE: int = 64
## Chunks sampled across the sector when a measurement needs to be honest
## rather than anecdotal.
const SWEEP_STEP: int = 18
## Shared water may sit on the land, never above it. A few centimetres covers
## float32 noise on the continental sample; a metre of float is a canal in the sky.
const WATER_FLOAT_TOLERANCE: float = 0.05
## Metres a shared river may drop between consecutive stations. Stations are
## close together after resampling, so this still allows a steep reach; what it
## forbids is the hundred-metre curtain of water from draping onto the sea bed.
const MAX_STATION_DROP: float = 40.0
## Default-seed estuary where an atlas trunk used to float ~9 m above the
## refined valley floor, with a local brook in the trench underneath.
const FLOATING_TRUNK_REGRESSION_XZ: Vector2 = Vector2(179590.0, 86723.0)
## Default-seed column beside a trunk where a nearby lower lake used to paint
## a 7 m deep stepped hole into the river (land at ~36 m, lake sheet at ~29 m).
const LAKE_HOLE_REGRESSION_XZ: Vector2 = Vector2(178258.0, 84542.0)
## Default-seed trunk where FarTerrain's coarse grid used to chord across the
## channel as a green land strip between two wet sheets.
const FAR_BRIDGE_REGRESSION_XZ: Vector2 = Vector2(179009.0, 84375.0)

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	var config: WorldConfig = WorldConfig.new()
	config.atlas_size = ATLAS_SIZE
	print("=== Orrun world tests ===")
	print("sector: %d x %d macro cells (%.0f m core, %.0f m halo)" % [
		config.macro_cells_per_sector(), config.macro_cells_per_sector(),
		WorldCoords.SECTOR_SIZE, config.sector_halo_metres
	])

	var t0: int = Time.get_ticks_msec()
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var sector: WorldSector = WorldSector.generate(context, _pick_sector(context))
	var bake_ms: int = Time.get_ticks_msec() - t0
	print("sector %s bake: %s" % [sector.sector, sector.bake_timings])

	_report_sector(sector)
	_test_no_uphill_water(sector)
	_test_shared_water_does_not_float(context, sector)
	_test_no_local_rivers_in_atlas_valleys(context, sector)
	_test_lakes(sector)
	_test_rivers_reach_outlets(sector)
	_test_roads_and_crossings(context, sector)
	_test_chunks(context, sector)
	_test_highland_relief(context)
	_test_determinism(config, atlas, sector)
	_test_floating_trunk_regression()
	_test_lake_does_not_punch_holes_in_rivers()
	_test_far_terrain_does_not_bridge_rivers()

	print("---")
	print("bake %d ms | %d checks | %d failures" % [bake_ms, checks, failures])
	quit(1 if failures > 0 else 0)


func _check(name: String, condition: bool, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS  %s %s" % [name, detail])
	else:
		failures += 1
		printerr("  FAIL  %s %s" % [name, detail])


## The most interesting sector well inside the atlas: mostly land, with rivers.
func _pick_sector(context: WorldContext) -> Vector2i:
	var per: int = int(WorldCoords.SECTOR_SIZE / WorldCoords.ATLAS_CELL_SIZE)
	var sectors: int = context.config.atlas_size / per
	var best: Vector2i = Vector2i(1, 1)
	var best_score: int = -1
	for sz in range(1, sectors - 1):
		for sx in range(1, sectors - 1):
			var score: int = 0
			for dz in per:
				for dx in per:
					var cell: Vector2i = Vector2i(sx * per + dx, sz * per + dz)
					if context.atlas.is_ocean(cell.x, cell.y):
						continue
					score += 1
					if not context.atlas.links_in_cell(
						cell.x, cell.y, AtlasFeatures.Kind.RIVER
					).is_empty():
						score += 5
			if score > best_score:
				best_score = score
				best = Vector2i(sx, sz)
	return best


func _report_sector(sector: WorldSector) -> void:
	var hydro: Hydrology = sector.hydro
	var max_order: int = 0
	var total_points: int = 0
	var trunks: int = 0
	var stubs: int = 0
	for reach in hydro.rivers:
		max_order = maxi(max_order, reach.order)
		total_points += reach.points.size()
		if reach.is_trunk:
			trunks += 1
		elif reach.is_shared:
			stubs += 1
	print("sector: %d river reaches (%d atlas trunks, %d port stubs, %d stations, max Strahler %d)" % [
		hydro.rivers.size(), trunks, stubs, total_points, max_order
	])
	print("        %d local lakes, %d roads, %d crossings" % [
		hydro.lakes.size(), sector.paths.roads.size(), sector.paths.bridges.size()
	])
	print("elevation range: %.1f .. %.1f m" % [
		sector.terrain.min_elevation, sector.terrain.max_elevation
	])

	var flooded: int = 0
	var largest: int = 0
	for lake in hydro.lakes:
		flooded += lake.cells.size()
		largest = maxi(largest, lake.cells.size())
	var cell_area: float = sector.config.macro_cell_size * sector.config.macro_cell_size
	print("local lake cover: %.2f%% of the bake, largest %.2f km2" % [
		100.0 * float(flooded) / float(sector.terrain.cells * sector.terrain.cells),
		float(largest) * cell_area / 1.0e6
	])


func _test_no_uphill_water(sector: WorldSector) -> void:
	print("- water never flows uphill")
	# Visible river polylines are draped onto the continental surface and are
	# allowed to follow a bump in the bed; forcing them flat through the bump
	# was what buried the sheet under the ground. The authority for downhill
	# flow is the drainage surface on the macro grid.
	var bad_cells: int = 0
	var hydro: Hydrology = sector.hydro
	for i in hydro.filled.size():
		var down: int = hydro.receiver[i]
		if down >= 0 and hydro.filled[down] > hydro.filled[i] + 0.0001:
			bad_cells += 1
	_check("drainage surface descends", bad_cells == 0, "(%d bad cells)" % bad_cells)


## Atlas trunks and port stubs are reconstructed in XZ from shared geometry, but
## their water height must be draped onto the continental surface. The atlas
## elevation code is a kilometre average; when the refined valley sits below it,
## using the atlas height raw lays a sheet of water in the air and every local
## brook that found the real bed looks like a second river in a canyon.
func _test_shared_water_does_not_float(
	context: WorldContext, sector: WorldSector
) -> void:
	print("- shared rivers do not float above the ground")
	var report: Dictionary = _shared_water_float_report(context, sector)
	_check("shared water stays on the ground", report["offenders"] == 0,
		"(%d floating stations, worst +%.3f m over %d stations)" % [
			report["offenders"], report["worst"], report["stations"]
		])
	# Chords between stations may skim a bump or dip; the density field sits the
	# visible sheet on the continental bed under the channel, so a buried chord
	# is not the vanishing-river bug anymore. What still is: draping a station
	# onto ground that is not under the river, which shows up as a plunge.
	_check("shared water does not plunge", report["worst_drop"] <= MAX_STATION_DROP,
		"(worst drop %.1f m between stations %.0f m apart)" % [
			report["worst_drop"], report["worst_drop_run"]
		])


## Every shared reach measured against the land under it, on dry land only.
## Under the sea or an atlas lake the bed is supposed to lie below the water, so
## those samples are not this failure mode. Stations are held to
## [constant WATER_FLOAT_TOLERANCE]; the worst station-to-station drop comes
## back too, because draping onto ground that is not under the river shows up
## as a plunge.
func _shared_water_float_report(
	context: WorldContext, sector: WorldSector
) -> Dictionary:
	var continental: ContinentalTerrain = context.sampler()
	var worst: float = 0.0
	var offenders: int = 0
	var stations: int = 0
	var worst_drop: float = 0.0
	var worst_drop_run: float = 0.0
	for reach in sector.hydro.rivers:
		if not reach.is_shared:
			continue
		for i in reach.points.size():
			stations += 1
			var p: Vector3 = reach.points[i]
			var float_m: float = _land_water_float(continental, p)
			if float_m > WATER_FLOAT_TOLERANCE:
				offenders += 1
				worst = maxf(worst, float_m)
			if i + 1 >= reach.points.size():
				continue
			var q: Vector3 = reach.points[i + 1]
			var drop: float = p.y - q.y
			if drop > worst_drop:
				worst_drop = drop
				worst_drop_run = Vector2(q.x - p.x, q.z - p.z).length()
	return {
		"offenders": offenders, "worst": worst, "stations": stations,
		"worst_drop": worst_drop, "worst_drop_run": worst_drop_run,
	}


## Metres of float above the land surface, or -INF off dry land / when the
## water sits in its bed. The canal-in-the-sky bug is a land-only failure.
func _land_water_float(continental: ContinentalTerrain, station: Vector3) -> float:
	if continental.shore_signed(station.x, station.z) <= 0.0:
		return -INF
	return station.y - continental.height_at(station.x, station.z)


## Exact site of the floating-trunk bug on the default seed. Uses the production
## atlas size, because the 64 km test atlas does not contain this estuary.
func _test_floating_trunk_regression() -> void:
	print("- regression: estuary trunk stays in its bed")
	var config: WorldConfig = WorldConfig.new()
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var at: Vector2 = FLOATING_TRUNK_REGRESSION_XZ
	var sector: WorldSector = WorldSector.generate(
		context, WorldCoords.sector_of(at.x, at.y)
	)
	print("  sector %s at the known estuary" % sector.sector)

	var report: Dictionary = _shared_water_float_report(context, sector)
	_check("shared water stays on the ground at the estuary",
		report["offenders"] == 0,
		"(%d floating stations, worst +%.3f m)" % [report["offenders"], report["worst"]])
	_check("shared water does not plunge at the estuary",
		report["worst_drop"] <= MAX_STATION_DROP,
		"(worst drop %.1f m)" % report["worst_drop"])

	var continental: ContinentalTerrain = context.sampler()
	var nearest_d: float = INF
	var trunk_water: float = 0.0
	var trunk_ground: float = 0.0
	for reach in sector.hydro.rivers:
		if not reach.is_trunk:
			continue
		for p in reach.points:
			var d: float = Vector2(p.x - at.x, p.z - at.y).length()
			if d < nearest_d:
				nearest_d = d
				trunk_water = p.y
				trunk_ground = continental.height_at(p.x, p.z)

	_check("the known estuary still has a trunk nearby", nearest_d < 80.0,
		"(nearest station %.1f m away)" % nearest_d)
	_check("that trunk sits in the valley, not above it",
		trunk_water <= trunk_ground + WATER_FLOAT_TOLERANCE,
		"(water %.2f m, ground %.2f m, float %+.2f m)" % [
			trunk_water, trunk_ground, trunk_water - trunk_ground
		])


## A local lake's spill used to paint wet columns on land well above that spill,
## carving a stepped hole next to a higher trunk. The sheet must not sit in a
## pit under dry continental ground.
func _test_lake_does_not_punch_holes_in_rivers() -> void:
	print("- regression: nearby lakes do not punch holes beside trunks")
	var config: WorldConfig = WorldConfig.new()
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var continental: ContinentalTerrain = context.sampler()
	var at: Vector2 = LAKE_HOLE_REGRESSION_XZ
	var sector: WorldSector = WorldSector.generate(
		context, WorldCoords.sector_of(at.x, at.y)
	)
	var noise: NoiseSet = NoiseSet.create(config)
	var chunk: Vector2i = WorldCoords.chunk_of(config, at.x, at.y)
	var field: DensityField.Field = DensityField.build(
		config, sector, continental, noise, chunk, 0
	)
	var ix: int = clampi(
		int(round((at.x - field.origin.x) / field.voxel)), 0, field.dims.x - 1
	)
	var iz: int = clampi(
		int(round((at.y - field.origin.z) / field.voxel)), 0, field.dims.z - 1
	)
	var col: int = field.column_index(ix, iz)
	var water: float = field.water_top[col]
	var ground: float = continental.height_at(at.x, at.y)
	var pit: float = ground - water if water > -INF else 0.0
	_check(
		"column beside the trunk is not a deep lake pit",
		water == -INF or pit <= _max_sheet_pit(),
		"(water %s, continental %.2f m, pit %.2f m, allow %.2f m)" % [
			"dry" if water == -INF else "%.2f m" % water,
			ground, pit, _max_sheet_pit()
		]
	)
	var deep_pits: int = 0
	var worst_pit: float = 0.0
	for cz in field.dims.z:
		for cx in field.dims.x:
			var c: int = field.column_index(cx, cz)
			var top: float = field.water_top[c]
			if top == -INF:
				continue
			var world: Vector3 = field.sample_world_position(cx, 0, cz)
			var p: float = continental.height_at(world.x, world.z) - top
			if p > _max_sheet_pit():
				deep_pits += 1
				worst_pit = maxf(worst_pit, p)
	_check(
		"no wet column is a deep pit under continental land",
		deep_pits == 0,
		"(%d pits, worst %.2f m below continental)" % [deep_pits, worst_pit]
	)


## How far below the continental surface a water sheet may sit. Rivers use a
## freeboard plus a small chord-lift budget; anything deeper is a lake (or
## similar) carved into land that was never under that water.
func _max_sheet_pit() -> float:
	return (
		DensityField.MAX_CHORD_BURY
		+ DensityField.WATER_FREEBOARD
		+ 0.5
	)


## FarTerrain used to put an opaque plate through near river trenches (or chord
## across them on its coarse grid), winning the depth test over the bed. Under
## the streamed ring it must sit at world_floor; outside, below channel water.
func _test_far_terrain_does_not_bridge_rivers() -> void:
	print("- regression: FarTerrain does not bridge atlas trunks")
	var config: WorldConfig = WorldConfig.new()
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var continental: ContinentalTerrain = context.sampler()
	var at: Vector2 = FAR_BRIDGE_REGRESSION_XZ
	var sector: WorldSector = WorldSector.generate(
		context, WorldCoords.sector_of(at.x, at.y)
	)
	var noise: NoiseSet = NoiseSet.create(config)
	var near: Dictionary = sector.hydro.nearest_reach(at.x, at.y, 120.0)
	_check("far-bridge regression has a trunk", not near.is_empty() and bool(
		sector.hydro.rivers[int(near["reach"])].is_trunk
	), "")
	if near.is_empty():
		return
	var reach: RiverPolyline = sector.hydro.rivers[int(near["reach"])]
	var step: float = FarTerrain.SPAN / float(FarTerrain.QUADS)
	var hole: float = FarTerrain.near_hole_half_extent(config)
	var above_bed: int = 0
	var not_holed: int = 0
	var worst_over: float = 0.0
	var sample_at: Vector2 = Vector2.ZERO
	var checked: int = 0
	for i in reach.points.size():
		var p: Vector3 = reach.points[i]
		if Vector2(p.x - at.x, p.z - at.y).length() > 350.0:
			continue
		var stations: Array[Vector2] = [
			Vector2(p.x, p.z),
			Vector2(p.x + step * 0.5, p.z + step * 0.5),
		]
		for station in stations:
			var nr: Dictionary = sector.hydro.nearest_reach(station.x, station.y, 64.0)
			if nr.is_empty() or float(nr["distance"]) > float(nr["half_width"]):
				continue
			var chunk: Vector2i = WorldCoords.chunk_of(config, station.x, station.y)
			var field: DensityField.Field = DensityField.build(
				config, sector, continental, noise, chunk, 0
			)
			var ix: int = clampi(
				int(round((station.x - field.origin.x) / field.voxel)),
				0, field.dims.x - 1
			)
			var iz: int = clampi(
				int(round((station.y - field.origin.z) / field.voxel)),
				0, field.dims.z - 1
			)
			var col: int = field.column_index(ix, iz)
			var water: float = field.water_top[col]
			var bed: float = field.surface_z[col]
			if water <= -INF:
				continue
			checked += 1
			var far_y: float = FarTerrain.surface_y_at(
				context, continental, station.x, station.y, step, at, hole
			)
			var in_ring: bool = (
				maxf(absf(station.x - at.x), absf(station.y - at.y)) <= hole
			)
			if in_ring and far_y > config.world_floor + 0.5:
				not_holed += 1
				sample_at = station
			# Looking down, FarTerrain wins the pixel if it sits above the bed.
			if far_y > bed - 0.25:
				above_bed += 1
				worst_over = maxf(worst_over, far_y - bed)
				sample_at = station
	_check(
		"FarTerrain hole covers the streamed ring at the regression",
		not_holed == 0 and checked > 0,
		"(%d stations, %d not at world_floor, hole %.0f m)" % [
			checked, not_holed, hole
		]
	)
	_check(
		"FarTerrain sits below the chunk bed in the channel",
		above_bed == 0 and checked > 0,
		"(%d stations, %d above bed, worst %+0.2f m at %.0f,%.0f)" % [
			checked, above_bed, worst_over, sample_at.x, sample_at.y
		]
	)


## Atlas corridors carve valleys hundreds of metres wide. Local brooks that
## form in that floor show up as thin dashed water in a dry trench - the look
## that kept being reported as "underground river". Join tips near the channel
## are allowed; parallel runs further out are not.
func _test_no_local_rivers_in_atlas_valleys(
	context: WorldContext, sector: WorldSector
) -> void:
	print("- local rivers stay out of atlas trunk valleys")
	var offenders: int = 0
	var worst_d: float = INF
	var sample: Vector2 = Vector2.ZERO
	for reach in sector.hydro.rivers:
		if reach.is_shared:
			continue
		var parallel: int = 0
		var parallel_d: float = INF
		var parallel_at: Vector2 = Vector2.ZERO
		for p in reach.points:
			var best_d: float = INF
			var best_half: float = 0.0
			var best_valley: float = 0.0
			var rect: Rect2 = Rect2(p.x - 500.0, p.z - 500.0, 1000.0, 1000.0)
			for base in context.corridors.rivers_in_rect(rect):
				var ax: float = context.corridors.rivers[base]
				var az: float = context.corridors.rivers[base + 2]
				var bx: float = context.corridors.rivers[base + 3]
				var bz: float = context.corridors.rivers[base + 5]
				var abx: float = bx - ax
				var abz: float = bz - az
				var len_sq: float = abx * abx + abz * abz
				var t: float = 0.0
				if len_sq > 0.000001:
					t = clampf(
						((p.x - ax) * abx + (p.z - az) * abz) / len_sq, 0.0, 1.0
					)
				var d: float = Vector2(
					p.x - (ax + abx * t), p.z - (az + abz * t)
				).length()
				if d < best_d:
					best_d = d
					var feature_class: int = int(context.corridors.rivers[base + 8])
					best_half = context.corridors.river_half_width(feature_class)
					best_valley = context.corridors.river_valley_radius(feature_class)
			if best_d < best_valley and best_d > best_half + 16.0:
				parallel += 1
				if best_d < parallel_d:
					parallel_d = best_d
					parallel_at = Vector2(p.x, p.z)
		if parallel >= 2:
			offenders += 1
			if parallel_d < worst_d:
				worst_d = parallel_d
				sample = parallel_at
	_check(
		"no local reach runs parallel in an atlas valley",
		offenders == 0,
		"(%d reaches, nearest intrusion %.0f m from corridor at %.0f,%.0f)" % [
			offenders, worst_d if worst_d < INF else -1.0, sample.x, sample.y
		]
	)


func _test_lakes(sector: WorldSector) -> void:
	print("- lakes sit at their own spill elevation")
	var hydro: Hydrology = sector.hydro
	if hydro.lakes.is_empty():
		_check("sector has lakes", false, "(none generated)")
		return

	var heights: PackedFloat32Array = PackedFloat32Array()
	var flat: int = 0
	var no_outlet: int = 0
	var above_terrain: int = 0
	for lake in hydro.lakes:
		heights.append(lake.surface_z)
		if lake.outlet_cell < 0:
			no_outlet += 1
		for cell in lake.cells:
			if sector.terrain.elevation[cell] > lake.surface_z:
				above_terrain += 1
			if absf(hydro.filled[cell] - lake.surface_z) > 0.05:
				flat += 1

	var lowest: float = heights[0]
	var highest: float = heights[0]
	for h in heights:
		lowest = minf(lowest, h)
		highest = maxf(highest, h)

	_check("lake surfaces are flat", flat == 0, "(%d off-level cells)" % flat)
	_check("lake beds are below the surface", above_terrain == 0,
		"(%d cells above water)" % above_terrain)
	_check("lakes have outlets", no_outlet == 0, "(%d without)" % no_outlet)
	_check("lakes are NOT on one global water level", highest - lowest > 5.0,
		"(%d lakes spanning %.1f m, %.1f .. %.1f)" % [
			hydro.lakes.size(), highest - lowest, lowest, highest
		])


func _test_rivers_reach_outlets(sector: WorldSector) -> void:
	print("- river network is connected")
	var hydro: Hydrology = sector.hydro
	_check("rivers exist", hydro.rivers.size() > 20, "(%d reaches)" % hydro.rivers.size())

	# Every locally solved reach has to resolve into something: another reach, a
	# lake, an atlas trunk, or a port stub that carries it over the boundary.
	# A reach that just stops in a field is water that appears from nowhere.
	var linked: int = 0
	var into_lake: int = 0
	var into_shared: int = 0
	var dangling: int = 0
	for reach in hydro.rivers:
		if reach.is_shared:
			continue
		if reach.downstream_id >= 0:
			linked += 1
		elif reach.ends_in_lake >= 0:
			into_lake += 1
		else:
			var last: Vector3 = reach.points[reach.points.size() - 1]
			if _touches_shared_water(hydro, last):
				into_shared += 1
			else:
				dangling += 1
	var local: int = linked + into_lake + into_shared + dangling
	_check("every reach has an outlet", dangling * 12 < maxi(local, 1),
		"(%d linked, %d into lakes, %d into shared water, %d dangling of %d local)" % [
			linked, into_lake, into_shared, dangling, local
		])

	var lakes_with_outflow: int = 0
	for lake in hydro.lakes:
		var cx: int = lake.outlet_cell % sector.terrain.cells
		var cz: int = lake.outlet_cell / sector.terrain.cells
		var pos: Vector2 = sector.terrain.cell_center(cx, cz)
		if not hydro.nearest_reach(
			pos.x, pos.y, sector.config.macro_cell_size * 3.0
		).is_empty():
			lakes_with_outflow += 1
	_check("lake spills feed rivers", lakes_with_outflow * 2 >= hydro.lakes.size(),
		"(%d of %d lakes)" % [lakes_with_outflow, hydro.lakes.size()])

	var widening: int = 0
	for reach in hydro.rivers:
		if reach.downstream_id >= 0:
			var down: RiverPolyline = hydro.rivers[reach.downstream_id]
			if down.order >= reach.order:
				widening += 1
	_check("tributaries never shrink their trunk", widening == linked,
		"(%d of %d)" % [widening, linked])


## True when a point sits on an atlas trunk, a port stub, or atlas water.
func _touches_shared_water(hydro: Hydrology, at: Vector3) -> bool:
	var cell: Vector2i = hydro.terrain.local_cell_of(at.x, at.z)
	if hydro.terrain.contains_local(cell.x, cell.y):
		var index: int = cell.y * hydro.terrain.cells + cell.x
		if hydro.trunk[index] != 0 or hydro.atlas_water[index] != 0:
			return true
	for reach in hydro.rivers:
		if not reach.is_shared:
			continue
		for p in reach.points:
			if Vector2(p.x - at.x, p.z - at.z).length() < 24.0:
				return true
	return false


func _test_roads_and_crossings(context: WorldContext, sector: WorldSector) -> void:
	print("- roads and crossings")
	var config: WorldConfig = context.config
	var paths: PathNetwork = sector.paths
	var trunk_roads: int = 0
	for road in paths.roads:
		if road.is_trunk:
			trunk_roads += 1
	_check("local landmarks placed", paths.nodes.size() >= 2,
		"(%d)" % paths.nodes.size())
	_check("roads built", paths.roads.size() > trunk_roads,
		"(%d roads, %d of them atlas trunks)" % [paths.roads.size(), trunk_roads])

	var fords: int = 0
	var spans: int = 0
	var floating: int = 0
	for site in paths.bridges:
		if site.is_ford:
			fords += 1
			continue
		spans += 1
		if site.deck_height() < site.water_z + 1.0:
			floating += 1
	_check("water crossings classified", paths.bridges.size() > 0,
		"(%d fords, %d bridges)" % [fords, spans])
	_check("bridge decks clear the water", floating == 0, "(%d too low)" % floating)

	# A span is only a bridge if there is something under it. The macro layer can
	# be certain a channel crosses here while the density field, having already
	# benched the roadbed through the same ground, leaves no water at all — and
	# the result is a stone deck lying in a meadow, which every other check in
	# this suite is happy with.
	var dry_spans: int = 0
	var checked_spans: int = 0
	var noise: NoiseSet = NoiseSet.create(config)
	var continental: ContinentalTerrain = context.sampler()
	for site in paths.bridges:
		if site.is_ford or checked_spans >= 8:
			continue
		var center: Vector3 = site.center()
		if not sector.contains_point(center.x, center.z):
			continue
		checked_spans += 1
		var chunk: Vector2i = WorldCoords.chunk_of(config, center.x, center.z)
		var field: DensityField.Field = DensityField.build(
			config, sector, continental, noise, chunk, 0
		)
		if not _has_water_near(field, center, site.span_length() * 0.75):
			dry_spans += 1
	_check("bridges span open water", dry_spans == 0,
		"(%d of %d spans with a dry channel)" % [dry_spans, checked_spans])

	# A crossing is only useful if the road actually meets it. The deck used to
	# be anchored on macro cell centres, which put it up to half a cell off the
	# road it belonged to: a bridge standing in a meadow next to its own road.
	var stranded: int = 0
	var worst_offset: float = 0.0
	for site in paths.bridges:
		var road: RoadEdge = paths.roads[site.road_id]
		var center: Vector3 = site.center()
		var offset: float = _distance_to_polyline(
			road.points, Vector2(center.x, center.z)
		)
		worst_offset = maxf(worst_offset, offset)
		if offset > road.half_width + 1.5:
			stranded += 1
	_check("crossings sit on their road", stranded == 0,
		"(%d off the carriageway, worst offset %.1f m)" % [stranded, worst_offset])

	# Which classes of atlas road happen to pass through one 8 km square is the
	# atlas's business, so this only asks that the sector has more than one kind
	# of road: continental routes, and the local tracks that feed them.
	var tiers: Dictionary = {0: 0, 1: 0, 2: 0}
	for road in paths.roads:
		tiers[int(road.tier)] = int(tiers[int(road.tier)]) + 1
	var kinds: int = 0
	for tier in tiers:
		kinds += 1 if int(tiers[tier]) > 0 else 0
	_check("road hierarchy present", kinds >= 2,
		"(primary %d, secondary %d, trail %d)" % [tiers[0], tiers[1], tiers[2]])


func _test_chunks(context: WorldContext, sector: WorldSector) -> void:
	print("- chunk meshing")
	var config: WorldConfig = context.config
	var noise: NoiseSet = NoiseSet.create(config)
	var continental: ContinentalTerrain = context.sampler()

	var river_chunk: Vector2i = _find_chunk(config, sector, "river")
	var lake_chunk: Vector2i = _find_chunk(config, sector, "lake")
	var mountain_chunk: Vector2i = _find_chunk(config, sector, "mountain")

	var worst_error: float = 0.0
	var total_ms: int = 0
	var built: int = 0
	var bad_normals: int = 0
	var flipped_faces: int = 0
	var total_faces: int = 0
	var upward: int = 0
	var total_verts: int = 0

	for chunk in [river_chunk, lake_chunk, mountain_chunk]:
		if chunk == Vector2i(-1, -1):
			continue
		var t0: int = Time.get_ticks_msec()
		var field: DensityField.Field = DensityField.build(
			config, sector, continental, noise, chunk, 0
		)
		var mesh: MeshExtract.MeshData = MeshExtract.build(
			field, WorldCoords.chunk_origin(config, chunk), true
		)
		total_ms += Time.get_ticks_msec() - t0
		built += 1
		worst_error = maxf(worst_error, field.max_contract_error)
		_check("chunk %s meshes" % chunk, not mesh.is_empty(),
			"(%d verts, %d surface tris, %d skirt tris, field %s)" % [
				mesh.vertices.size(), mesh.surface_triangles,
				mesh.indices.size() / 3 - mesh.surface_triangles, field.dims
			])

		for normal in mesh.normals:
			total_verts += 1
			if absf(normal.length() - 1.0) > 0.01:
				bad_normals += 1
			elif normal.y > 0.7:
				upward += 1
		# Only the isosurface is checked: the skirt is deliberately double sided,
		# so half of its triangles always face away from their normal.
		for i in range(0, mesh.surface_triangles * 3, 3):
			var a: Vector3 = mesh.vertices[mesh.indices[i]]
			var b: Vector3 = mesh.vertices[mesh.indices[i + 1]]
			var c: Vector3 = mesh.vertices[mesh.indices[i + 2]]
			var face: Vector3 = (b - a).cross(c - a)
			if face.length_squared() < 1e-12:
				continue
			total_faces += 1
			var vertex_normal: Vector3 = (
				mesh.normals[mesh.indices[i]]
				+ mesh.normals[mesh.indices[i + 1]]
				+ mesh.normals[mesh.indices[i + 2]]
			)
			# Front facing in Godot means clockwise, so the right-hand-rule cross
			# product of a correctly wound triangle opposes its outward normal.
			# Getting this backwards makes the whole world invisible from above
			# while leaving every geometric test happily passing.
			if face.normalized().dot(vertex_normal.normalized()) > 0.0:
				flipped_faces += 1

	# A vertex normal that is not unit length reaches the shader as garbage, and
	# the slope term that picks ground colour is derived from it.
	# Ground that renders black looks identical to ground that is not drawn at
	# all, so the tint is checked as data before it ever reaches a shader.
	var dark_vertices: int = 0
	var sample_field: DensityField.Field = DensityField.build(
		config, sector, continental, noise, river_chunk, 0
	)
	var sample_mesh: MeshExtract.MeshData = MeshExtract.build(
		sample_field, WorldCoords.chunk_origin(config, river_chunk), false, false
	)
	for color in sample_mesh.colors:
		if color.r + color.g + color.b < 0.05:
			dark_vertices += 1
	_check("ground has colour", dark_vertices == 0,
		"(%d of %d near black, first %s)" % [
			dark_vertices, sample_mesh.colors.size(),
			sample_mesh.colors[0] if not sample_mesh.colors.is_empty() else Color.BLACK
		])

	# The colour the renderer sees is not necessarily the colour we handed over:
	# ArrayMesh quantises and can drop channels depending on the surface format.
	var array_mesh: ArrayMesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = sample_mesh.vertices
	arrays[Mesh.ARRAY_NORMAL] = sample_mesh.normals
	arrays[Mesh.ARRAY_COLOR] = sample_mesh.colors
	arrays[Mesh.ARRAY_TEX_UV] = sample_mesh.uvs
	arrays[Mesh.ARRAY_INDEX] = sample_mesh.indices
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var stored: Array = array_mesh.surface_get_arrays(0)
	var stored_colors: PackedColorArray = stored[Mesh.ARRAY_COLOR]
	var stored_uvs: PackedVector2Array = stored[Mesh.ARRAY_TEX_UV]
	_check("ArrayMesh keeps the vertex colour",
		not stored_colors.is_empty() and stored_colors[0].g > 0.1,
		"(stored %s, uv %s, format %d)" % [
			stored_colors[0] if not stored_colors.is_empty() else Color.BLACK,
			stored_uvs[0] if not stored_uvs.is_empty() else Vector2.ZERO,
			array_mesh.surface_get_format(0)
		])

	_check("vertex normals are unit length", bad_normals == 0,
		"(%d of %d degenerate)" % [bad_normals, total_verts])
	# Surface nets emits quads from edge crossings; if the winding disagrees with
	# the gradient the ground renders inside out.
	_check("face winding matches normals", flipped_faces * 20 < total_faces,
		"(%d of %d faces wound against the normal)" % [flipped_faces, total_faces])
	_check("ground mostly faces up", upward * 3 > total_verts,
		"(%d of %d vertices with normal.y > 0.7)" % [upward, total_verts])

	# Distant rings mesh the same ground at a coarser voxel. If a coarse LOD
	# stops producing a surface the world grows holes exactly where the player
	# is not looking closely, which is hard to catch any other way.
	var lod_probe: Vector2i = (
		mountain_chunk if mountain_chunk != Vector2i(-1, -1) else river_chunk
	)
	for lod in config.lod_count():
		var lod_field: DensityField.Field = DensityField.build(
			config, sector, continental, noise, lod_probe, lod
		)
		# Coarse rings carve the same water with fewer columns, and the contract
		# has to survive that: a distant lake with its far bank standing above it
		# is as wrong as a near one.
		worst_error = maxf(worst_error, lod_field.max_contract_error)
		var lod_mesh: MeshExtract.MeshData = MeshExtract.build(
			lod_field, WorldCoords.chunk_origin(config, lod_probe), false
		)
		_check("LOD %d meshes chunk %s" % [lod, lod_probe], lod_mesh.surface_triangles > 0,
			"(%d surface tris, %d skirt tris, field %s, voxel %.0f m)" % [
				lod_mesh.surface_triangles,
				lod_mesh.indices.size() / 3 - lod_mesh.surface_triangles,
				lod_field.dims, lod_field.voxel
			])

	# Spot checks pick interesting chunks; this sweep proves the boring ones mesh
	# too. A chunk that produces no surface is a hole in the world.
	var empty_chunks: int = 0
	var swept: int = 0
	var lowest_meshed: float = INF
	for probe in _sweep_chunks(config, sector):
		var sweep_field: DensityField.Field = DensityField.build(
			config, sector, continental, noise, probe, 1
		)
		var sweep_mesh: MeshExtract.MeshData = MeshExtract.build(
			sweep_field, WorldCoords.chunk_origin(config, probe), false, false
		)
		swept += 1
		if sweep_mesh.surface_triangles == 0:
			empty_chunks += 1
		else:
			lowest_meshed = minf(lowest_meshed, sweep_mesh.aabb.position.y)
	_check("every sampled chunk has ground", empty_chunks == 0,
		"(%d of %d empty, lowest meshed ground %.0f m)" % [
			empty_chunks, swept, lowest_meshed
		])

	# The sweep is the honest sample. Three hand-picked chunks passing the
	# contract says nothing about the sector, and a violation that only exists
	# two valleys over is exactly the kind that reaches a player first.
	var sweep_worst: float = _sweep_lod0(
		context, sector, noise, continental, [river_chunk, lake_chunk, mountain_chunk]
	)
	worst_error = maxf(worst_error, sweep_worst)

	_check("drainage-surface contract holds", worst_error <= config.corridor_epsilon,
		"(worst clearance deficit %.3f m, epsilon %.3f)" % [
			worst_error, config.corridor_epsilon
		])
	_assert_beds_below_water(context, sector, continental, noise)
	if built > 0:
		print("  chunk build: %.1f ms average at LOD0" % [float(total_ms) / float(built)])


## River (and lake) beds must sit strictly below the water that flows in them.
## This is the invariant WaterSurface actually draws against: a flush bed used
## to pass the old ground-above-water check with error 0 while the mesh culled
## the column as dry, which is how underground river spots kept coming back.
func _assert_beds_below_water(
	context: WorldContext,
	sector: WorldSector,
	continental: ContinentalTerrain,
	noise: NoiseSet
) -> void:
	print("- river beds sit strictly below their water")
	var config: WorldConfig = context.config
	var failing: int = 0
	var wet: int = 0
	var worst_clearance: float = INF
	var worst_chunk: Vector2i = Vector2i(-1, -1)
	var probes: Array[Vector2i] = _sweep_chunks(config, sector)
	var river_chunk: Vector2i = _find_chunk(config, sector, "river")
	var lake_chunk: Vector2i = _find_chunk(config, sector, "lake")
	if river_chunk != Vector2i(-1, -1):
		probes.append(river_chunk)
	if lake_chunk != Vector2i(-1, -1):
		probes.append(lake_chunk)
	for probe in probes:
		for lod in config.lod_count():
			var field: DensityField.Field = DensityField.build(
				config, sector, continental, noise, probe, lod
			)
			wet += field.wet_columns
			failing += field.wet_columns_failing_clearance
			if field.wet_columns > 0 and field.min_water_clearance < worst_clearance:
				worst_clearance = field.min_water_clearance
				worst_chunk = probe
	_check(
		"draw cull and density contract share one clearance",
		is_equal_approx(WaterSurface.WET_EPSILON, DensityField.MIN_VISIBLE_WATER_CLEARANCE),
		"(mesh %.3f m, field %.3f m)" % [
			WaterSurface.WET_EPSILON, DensityField.MIN_VISIBLE_WATER_CLEARANCE
		]
	)
	_check(
		"every wet column has bed below water",
		failing == 0 and wet > 0,
		"(%d of %d wet columns short of %.2f m clearance; worst %.3f m at chunk %s)" % [
			failing, wet, DensityField.MIN_VISIBLE_WATER_CLEARANCE,
			worst_clearance if worst_clearance < INF else 0.0, worst_chunk
		]
	)
	# Bed-below-water alone is not enough: a lake can carve a legal bed under a
	# sheet that sits metres below dry continental land beside a higher river.
	var deep_pits: int = 0
	var worst_pit: float = 0.0
	var pit_chunk: Vector2i = Vector2i(-1, -1)
	var max_pit: float = _max_sheet_pit()
	for probe in probes:
		var field: DensityField.Field = DensityField.build(
			config, sector, continental, noise, probe, 0
		)
		for iz in field.dims.z:
			for ix in field.dims.x:
				var col: int = field.column_index(ix, iz)
				var top: float = field.water_top[col]
				if top == -INF:
					continue
				var world: Vector3 = field.sample_world_position(ix, 0, iz)
				var pit: float = continental.height_at(world.x, world.z) - top
				if pit > max_pit:
					deep_pits += 1
					if pit > worst_pit:
						worst_pit = pit
						pit_chunk = probe
	_check(
		"no wet sheet sits in a deep pit under dry land",
		deep_pits == 0,
		"(%d pits, worst %.2f m at chunk %s; allow %.2f m)" % [
			deep_pits, worst_pit, pit_chunk, max_pit
		]
	)


## A grid of chunks spread over the sector core.
func _sweep_chunks(config: WorldConfig, sector: WorldSector) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var per: int = config.chunks_per_sector()
	var base: Vector2i = sector.sector * per
	for cz in range(4, per, SWEEP_STEP):
		for cx in range(4, per, SWEEP_STEP):
			out.append(base + Vector2i(cx, cz))
	return out


## Everything that can only be judged over a lot of finished chunks: props
## against water, and whether caves and overhangs exist at all.
##
## Three hand-picked chunks are not a sample. Whether one of them happens to
## contain a cave depends on which chunk the picker chose that run, so a tuning
## change to the terrain could turn the cave check red without touching caves.
func _sweep_lod0(
	context: WorldContext,
	sector: WorldSector,
	noise: NoiseSet,
	continental: ContinentalTerrain,
	chunks: Array
) -> float:
	var config: WorldConfig = context.config
	var specs: Array[PropPlacer.PropSpec] = PropPlacer.load_specs(
		"res://assets/catalog/props.json"
	)
	var placed: int = 0
	var submerged: int = 0
	var deepest: float = 0.0
	var wet_columns: int = 0
	var total_columns: int = 0
	var caves_found: int = 0
	var overhangs_found: int = 0
	var cave_chunks: int = 0
	var overhang_chunks: int = 0
	var swept: int = 0
	var contract_worst: float = 0.0
	var contract_chunk: Vector2i = Vector2i(-1, -1)

	var probes: Array = chunks.duplicate()
	probes.append_array(_sweep_chunks(config, sector))

	for chunk_variant in probes:
		var chunk: Vector2i = chunk_variant
		if chunk == Vector2i(-1, -1):
			continue
		var origin: Vector2 = WorldCoords.chunk_origin(config, chunk)
		var field: DensityField.Field = DensityField.build(
			config, sector, continental, noise, chunk, 0
		)
		for lod in range(1, config.lod_count()):
			var coarse: DensityField.Field = DensityField.build(
				config, sector, continental, noise, chunk, lod
			)
			if coarse.max_contract_error > contract_worst:
				contract_worst = coarse.max_contract_error
				contract_chunk = chunk
		var region: RegionData = RegionData.build(
			sector, WorldCoords.region_of_chunk(config, chunk)
		)
		var props: Dictionary = PropPlacer.place(
			config, specs, field, region, sector.claims, origin
		)

		swept += 1
		if field.max_contract_error > contract_worst:
			contract_worst = field.max_contract_error
			contract_chunk = chunk
		var caves: int = _count_caves(field)
		var overhangs: int = _count_overhangs(field)
		caves_found += caves
		overhangs_found += overhangs
		cave_chunks += 1 if caves > 0 else 0
		overhang_chunks += 1 if overhangs > 0 else 0

		for column in field.water_top.size():
			total_columns += 1
			if field.water_top[column] > field.surface_z[column]:
				wet_columns += 1

		for id_variant in props:
			for transform_variant in props[id_variant]:
				var transform: Transform3D = transform_variant
				var world_x: float = origin.x + transform.origin.x
				var world_z: float = origin.y + transform.origin.z
				var top: float = field.water_top[
					PropPlacer.column_of(field, world_x, world_z)
				]
				placed += 1
				if top > transform.origin.y:
					submerged += 1
					deepest = maxf(deepest, top - transform.origin.y)

	_check("props stay out of the water", submerged == 0,
		"(%d of %d placed underwater, deepest %.1f m; %.0f%% of sampled columns are wet)" % [
			submerged, placed, deepest,
			100.0 * float(wet_columns) / maxf(float(total_columns), 1.0)
		])
	_check("caves carve voids", caves_found > 0,
		"(%d subsurface air cells in %d of %d chunks)" % [
			caves_found, cave_chunks, swept
		])
	print("  overhangs here: %d multi-surface columns in %d of %d chunks" % [
		overhangs_found, overhang_chunks, swept
	])
	if contract_worst > config.corridor_epsilon:
		print("  worst contract error in the sweep: %.3f m at chunk %s" % [
			contract_worst, contract_chunk
		])
	return contract_worst


## Overhangs need relief, and a gentle coastal sector honestly has none. The
## claim worth testing is that the world *can* fold its surface back on itself,
## so it is tested where the atlas says the land is steep.
func _test_highland_relief(context: WorldContext) -> void:
	print("- steep ground overhangs")
	var config: WorldConfig = context.config
	var highland: Vector2i = _pick_relief_sector(context)
	var sector: WorldSector = WorldSector.generate(context, highland)
	var noise: NoiseSet = NoiseSet.create(config)
	var continental: ContinentalTerrain = context.sampler()

	var columns: int = 0
	var chunks: int = 0
	var steepest: float = 0.0
	for probe in _steepest_chunks(config, sector, 9):
		var field: DensityField.Field = DensityField.build(
			config, sector, continental, noise, probe, 0
		)
		var found: int = _count_overhangs(field)
		columns += found
		chunks += 1 if found > 0 else 0
		steepest = maxf(steepest, sector.terrain.max_elevation)
	_check("steep ground overhangs", columns > 0,
		"(sector %s, %d multi-surface columns in %d of 9 chunks, peaks at %.0f m)" % [
			highland, columns, chunks, steepest
		])


## The land sector with the most atlas relief, well inside the continent.
func _pick_relief_sector(context: WorldContext) -> Vector2i:
	var per: int = int(WorldCoords.SECTOR_SIZE / WorldCoords.ATLAS_CELL_SIZE)
	var sectors: int = context.config.atlas_size / per
	var best: Vector2i = Vector2i(1, 1)
	var best_relief: float = -1.0
	for sz in range(1, sectors - 1):
		for sx in range(1, sectors - 1):
			var total: float = 0.0
			for dz in per:
				for dx in per:
					var cell: Vector2i = Vector2i(sx * per + dx, sz * per + dz)
					total += context.fields.relief01[
						context.fields.index_of(cell.x, cell.y)
					]
			if total > best_relief:
				best_relief = total
				best = Vector2i(sx, sz)
	return best


## The [param wanted] chunks of a sector whose macro cells are steepest.
func _steepest_chunks(
	config: WorldConfig, sector: WorldSector, wanted: int
) -> Array[Vector2i]:
	var scored: Array[Vector3] = []
	var per: int = config.chunks_per_sector()
	var base: Vector2i = sector.sector * per
	for cz in range(2, per, 6):
		for cx in range(2, per, 6):
			var chunk: Vector2i = base + Vector2i(cx, cz)
			var origin: Vector2 = WorldCoords.chunk_origin(config, chunk)
			var centre: Vector2 = origin + Vector2.ONE * (config.chunk_size * 0.5)
			var here: float = sector.terrain.height_at(centre.x, centre.y)
			var dx: float = sector.terrain.height_at(centre.x + 32.0, centre.y) - here
			var dz: float = sector.terrain.height_at(centre.x, centre.y + 32.0) - here
			scored.append(Vector3(
				Vector2(dx, dz).length(), float(chunk.x), float(chunk.y)
			))
	scored.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.x > b.x)

	var out: Array[Vector2i] = []
	for i in mini(wanted, scored.size()):
		out.append(Vector2i(int(scored[i].y), int(scored[i].z)))
	return out


func _distance_to_polyline(points: PackedVector3Array, point: Vector2) -> float:
	var best: float = INF
	for i in range(points.size() - 1):
		var a: Vector2 = Vector2(points[i].x, points[i].z)
		var b: Vector2 = Vector2(points[i + 1].x, points[i + 1].z)
		var ab: Vector2 = b - a
		var length_sq: float = ab.length_squared()
		var t: float = 0.0
		if length_sq > 0.000001:
			t = clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
		best = minf(best, (a + ab * t).distance_to(point))
	return best


func _count_caves(field: DensityField.Field) -> int:
	var found: int = 0
	var dims: Vector3i = field.dims
	for iz in dims.z:
		for ix in dims.x:
			var surface: float = field.surface_z[iz * dims.x + ix]
			for iy in dims.y:
				var wy: float = field.origin.y + float(iy) * field.voxel
				if wy > surface - 8.0:
					continue
				if field.values[(iz * dims.y + iy) * dims.x + ix] < 0.0:
					found += 1
	return found


## A column with more than one solid-to-air transition can only exist if the
## surface folds back over itself, which is the definition of an overhang.
func _count_overhangs(field: DensityField.Field) -> int:
	var columns: int = 0
	var dims: Vector3i = field.dims
	for iz in dims.z:
		for ix in dims.x:
			var transitions: int = 0
			var previous: bool = field.values[(iz * dims.y) * dims.x + ix] >= 0.0
			for iy in range(1, dims.y):
				var solid: bool = field.values[(iz * dims.y + iy) * dims.x + ix] >= 0.0
				if solid != previous:
					transitions += 1
					previous = solid
			if transitions > 1:
				columns += 1
	return columns


## True when any column within [param radius] of [param at] carries water the
## ground is actually below, which is the same condition the water mesher uses.
func _has_water_near(field: DensityField.Field, at: Vector3, radius: float) -> bool:
	var samples: int = field.dims.x
	for iz in samples:
		for ix in samples:
			var column: int = iz * samples + ix
			var top: float = field.water_top[column]
			if top == -INF or field.surface_z[column] >= top:
				continue
			var world: Vector3 = field.sample_world_position(ix, 0, iz)
			if Vector2(world.x - at.x, world.z - at.z).length() <= radius:
				return true
	return false


func _find_chunk(config: WorldConfig, sector: WorldSector, kind: String) -> Vector2i:
	match kind:
		"river":
			for reach in sector.hydro.rivers:
				if reach.order < 3:
					continue
				var p: Vector3 = reach.points[reach.points.size() / 2]
				if sector.contains_point(p.x, p.z):
					return WorldCoords.chunk_of(config, p.x, p.z)
		"lake":
			if not sector.hydro.lakes.is_empty():
				var centre: Vector2 = sector.hydro.lakes[0].bounds.get_center()
				return WorldCoords.chunk_of(config, centre.x, centre.y)
		"mountain":
			var best: int = -1
			var best_h: float = -INF
			for cz in range(sector.core_min.y, sector.core_max.y + 1):
				for cx in range(sector.core_min.x, sector.core_max.x + 1):
					var i: int = cz * sector.terrain.cells + cx
					if sector.terrain.elevation[i] > best_h:
						best_h = sector.terrain.elevation[i]
						best = i
			var pos: Vector2 = sector.terrain.cell_center(
				best % sector.terrain.cells, best / sector.terrain.cells
			)
			return WorldCoords.chunk_of(config, pos.x, pos.y)
	return Vector2i(-1, -1)


func _test_determinism(
	config: WorldConfig, atlas: ContinentAtlas, reference: WorldSector
) -> void:
	print("- same seed rebuilds the same sector")
	var again: WorldSector = WorldSector.generate(
		WorldContext.create(config, atlas), reference.sector
	)
	_check("macro terrain identical",
		hash(again.terrain.elevation) == hash(reference.terrain.elevation))
	_check("drainage identical",
		hash(again.hydro.filled) == hash(reference.hydro.filled))
	_check("river count identical",
		again.hydro.rivers.size() == reference.hydro.rivers.size(),
		"(%d vs %d)" % [again.hydro.rivers.size(), reference.hydro.rivers.size()])
	_check("road count identical",
		again.paths.roads.size() == reference.paths.roads.size(),
		"(%d vs %d)" % [again.paths.roads.size(), reference.paths.roads.size()])

	# A different seed must give different land, or nothing above is proving
	# anything: identical output from identical input is easy if the input never
	# reached the generator.
	var other: WorldConfig = WorldConfig.new()
	other.atlas_size = config.atlas_size
	other.seed = config.seed + 1
	var other_atlas: ContinentAtlas = ContinentAtlas.generate(other.seed, other.atlas_size)
	var different: WorldSector = WorldSector.generate(
		WorldContext.create(other, other_atlas), reference.sector
	)
	_check("different seed differs",
		hash(different.terrain.elevation) != hash(reference.terrain.elevation))
