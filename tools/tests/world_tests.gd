extends SceneTree
## Headless verification of the world generator.
##
##   godot --headless --path <project> --script res://tools/tests/world_tests.gd
##
## Checks the invariants the design depends on: water never flows uphill, lakes
## sit at their own spill heights, the ground stays glued to the drainage
## surface, and the same seed rebuilds the same world.

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	var config: WorldConfig = WorldConfig.new()
	print("=== Orrun world tests ===")
	print("macro grid: %d x %d cells (%.0f m world)" % [
		config.macro_cells, config.macro_cells, config.world_size()
	])

	var t0: int = Time.get_ticks_msec()
	var map: WorldMap = WorldMap.generate(config)
	var bake_ms: int = Time.get_ticks_msec() - t0
	print("bake: %s" % [map.bake_timings])

	_report_world(map)
	_test_no_uphill_water(map)
	_test_lakes(map)
	_test_rivers_reach_outlets(map)
	_test_roads_and_crossings(config, map)
	_test_chunks(config, map)
	_test_determinism()

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


func _report_world(map: WorldMap) -> void:
	var hydro: Hydrology = map.hydro
	var max_order: int = 0
	var total_points: int = 0
	for reach in hydro.rivers:
		max_order = maxi(max_order, reach.order)
		total_points += reach.points.size()
	print("world: %d river reaches (%d stations, max Strahler %d), %d lakes, %d roads, %d bridges" % [
		hydro.rivers.size(), total_points, max_order, hydro.lakes.size(),
		map.paths.roads.size(), map.paths.bridges.size()
	])
	print("elevation range: %.1f .. %.1f m" % [
		map.terrain.min_elevation, map.terrain.max_elevation
	])

	var flooded: int = 0
	var largest: int = 0
	for lake in hydro.lakes:
		flooded += lake.cells.size()
		largest = maxi(largest, lake.cells.size())
	var cell_area: float = map.config.macro_cell_size * map.config.macro_cell_size
	print("lake cover: %.1f%% of the map, largest %.1f km2" % [
		100.0 * float(flooded) / float(map.terrain.cells * map.terrain.cells),
		float(largest) * cell_area / 1.0e6
	])


func _test_no_uphill_water(map: WorldMap) -> void:
	print("- water never flows uphill")
	var worst_rise: float = 0.0
	var offenders: int = 0
	for reach in map.hydro.rivers:
		for i in range(1, reach.points.size()):
			var rise: float = reach.points[i].y - reach.points[i - 1].y
			if rise > 0.0001:
				offenders += 1
				worst_rise = maxf(worst_rise, rise)
	_check("river profiles descend", offenders == 0,
		"(%d rising stations, worst +%.3f m)" % [offenders, worst_rise])

	# The drainage surface itself must never rise downstream either.
	var bad_cells: int = 0
	var hydro: Hydrology = map.hydro
	for i in hydro.filled.size():
		var down: int = hydro.receiver[i]
		if down >= 0 and hydro.filled[down] > hydro.filled[i] + 0.0001:
			bad_cells += 1
	_check("drainage surface descends", bad_cells == 0, "(%d bad cells)" % bad_cells)


func _test_lakes(map: WorldMap) -> void:
	print("- lakes sit at their own spill elevation")
	var hydro: Hydrology = map.hydro
	if hydro.lakes.is_empty():
		_check("world has lakes", false, "(none generated)")
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
			if map.terrain.elevation[cell] > lake.surface_z:
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


func _test_rivers_reach_outlets(map: WorldMap) -> void:
	print("- river network is connected")
	var hydro: Hydrology = map.hydro
	_check("rivers exist", hydro.rivers.size() > 20, "(%d reaches)" % hydro.rivers.size())

	var linked: int = 0
	var into_lake: int = 0
	var leaves_map: int = 0
	var dangling: int = 0
	var size: float = map.config.world_size()
	var rim: float = map.config.macro_cell_size * 3.0
	for reach in hydro.rivers:
		if reach.downstream_id >= 0:
			linked += 1
		elif reach.ends_in_lake >= 0:
			into_lake += 1
		else:
			var last: Vector3 = reach.points[reach.points.size() - 1]
			if last.x < rim or last.z < rim or last.x > size - rim or last.z > size - rim:
				leaves_map += 1
			else:
				dangling += 1
				if dangling <= 3:
					var cell: Vector2i = WorldCoords.macro_cell_of(map.config, last.x, last.z)
					var index: int = cell.y * map.terrain.cells + cell.x
					var down_cell: int = hydro.receiver[index]
					printerr("        dangling reach %d ends at %s: order %d, acc %.0f, lake %d, channel %s, receiver %d (acc %.0f, lake %d)" % [
						reach.id, last, reach.order, hydro.accumulation[index],
						hydro.lake_id[index], hydro.is_channel[index] != 0, down_cell,
						hydro.accumulation[down_cell] if down_cell >= 0 else -1.0,
						hydro.lake_id[down_cell] if down_cell >= 0 else -2,
					])
	# Every reach must resolve: into another reach, into a lake, or off the map.
	_check("every reach has an outlet", dangling * 20 < hydro.rivers.size(),
		"(%d linked, %d into lakes, %d off-map, %d dangling)" % [
			linked, into_lake, leaves_map, dangling
		])

	var lakes_with_outflow: int = 0
	for lake in hydro.lakes:
		var cx: int = lake.outlet_cell % map.terrain.cells
		var cz: int = lake.outlet_cell / map.terrain.cells
		var pos: Vector2 = WorldCoords.macro_cell_center(map.config, Vector2i(cx, cz))
		if not hydro.nearest_reach(pos.x, pos.y, map.config.macro_cell_size * 3.0).is_empty():
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


func _test_roads_and_crossings(config: WorldConfig, map: WorldMap) -> void:
	print("- roads and crossings")
	var paths: PathNetwork = map.paths
	_check("settlements placed", paths.nodes.size() >= 8, "(%d)" % paths.nodes.size())
	_check("roads built", paths.roads.size() >= paths.nodes.size() - 1,
		"(%d roads)" % paths.roads.size())

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
	for site in paths.bridges:
		if site.is_ford or checked_spans >= 12:
			continue
		checked_spans += 1
		var center: Vector3 = site.center()
		var chunk: Vector2i = WorldCoords.chunk_of(config, center.x, center.z)
		var field: DensityField.Field = DensityField.build(config, map, noise, chunk, 0)
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

	var tiers: Dictionary = {0: 0, 1: 0, 2: 0}
	for road in paths.roads:
		tiers[int(road.tier)] = int(tiers[int(road.tier)]) + 1
	_check("road hierarchy present", int(tiers[0]) > 0 and int(tiers[2]) > 0,
		"(primary %d, secondary %d, trail %d)" % [tiers[0], tiers[1], tiers[2]])


func _test_chunks(config: WorldConfig, map: WorldMap) -> void:
	print("- chunk meshing")
	var noise: NoiseSet = NoiseSet.create(config)

	var river_chunk: Vector2i = _find_chunk(config, map, "river")
	var lake_chunk: Vector2i = _find_chunk(config, map, "lake")
	var mountain_chunk: Vector2i = _find_chunk(config, map, "mountain")

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
		var field: DensityField.Field = DensityField.build(config, map, noise, chunk, 0)
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
		config, map, noise, river_chunk, 0
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
	var lod_probe: Vector2i = mountain_chunk if mountain_chunk != Vector2i(-1, -1) else river_chunk
	for lod in config.lod_count():
		var lod_field: DensityField.Field = DensityField.build(
			config, map, noise, lod_probe, lod
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
	var per_axis: int = config.chunks_per_axis()
	for step_z in range(4, per_axis, per_axis / 7):
		for step_x in range(4, per_axis, per_axis / 7):
			var probe: Vector2i = Vector2i(step_x, step_z)
			var sweep_field: DensityField.Field = DensityField.build(
				config, map, noise, probe, 1
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
	# contract says nothing about the map, and a violation that only exists two
	# valleys over is exactly the kind that reaches a player first.
	var sweep_worst: float = _sweep_lod0(
		config, map, noise, [river_chunk, lake_chunk, mountain_chunk]
	)
	worst_error = maxf(worst_error, sweep_worst)

	_check("drainage-surface contract holds", worst_error <= config.corridor_epsilon,
		"(worst ground-above-water %.3f m, epsilon %.2f)" % [worst_error, config.corridor_epsilon])
	if built > 0:
		print("  chunk build: %.1f ms average at LOD0" % [float(total_ms) / float(built)])


## Everything that can only be judged over a lot of finished chunks: props
## against water, and whether caves and overhangs exist at all.
##
## Three hand-picked chunks are not a sample. Whether one of them happens to
## contain a cave depends on which chunk the picker chose that run, so a tuning
## change to the terrain could turn the cave check red without touching caves.
func _sweep_lod0(
	config: WorldConfig, map: WorldMap, noise: NoiseSet, chunks: Array
) -> float:
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

	# The interesting chunks alone place a handful of props between them. A
	# sweep is what turns this from an anecdote into a measurement.
	var probes: Array = chunks.duplicate()
	var per_axis: int = config.chunks_per_axis()
	for step_z in range(6, per_axis, per_axis / 5):
		for step_x in range(6, per_axis, per_axis / 5):
			probes.append(Vector2i(step_x, step_z))

	for chunk_variant in probes:
		var chunk: Vector2i = chunk_variant
		if chunk == Vector2i(-1, -1):
			continue
		var origin: Vector2 = WorldCoords.chunk_origin(config, chunk)
		var field: DensityField.Field = DensityField.build(config, map, noise, chunk, 0)
		for lod in range(1, config.lod_count()):
			var coarse: DensityField.Field = DensityField.build(config, map, noise, chunk, lod)
			if coarse.max_contract_error > contract_worst:
				contract_worst = coarse.max_contract_error
				contract_chunk = chunk
		var region: RegionData = RegionData.build(
			map, WorldCoords.region_of_chunk(config, chunk)
		)
		var props: Dictionary = PropPlacer.place(
			config, specs, field, region, map.claims, origin
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
	_check("terrain overhangs", overhangs_found > 0,
		"(%d multi-surface columns in %d of %d chunks)" % [
			overhangs_found, overhang_chunks, swept
		])
	if contract_worst > config.corridor_epsilon:
		print("  worst contract error in the sweep: %.3f m at chunk %s" % [
			contract_worst, contract_chunk
		])
	return contract_worst


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


func _find_chunk(config: WorldConfig, map: WorldMap, kind: String) -> Vector2i:
	match kind:
		"river":
			for reach in map.hydro.rivers:
				if reach.order >= 3:
					var p: Vector3 = reach.points[reach.points.size() / 2]
					return WorldCoords.chunk_of(config, p.x, p.z)
		"lake":
			if not map.hydro.lakes.is_empty():
				var center: Vector2 = map.hydro.lakes[0].bounds.get_center()
				return WorldCoords.chunk_of(config, center.x, center.y)
		"mountain":
			var best: int = -1
			var best_h: float = -INF
			for i in map.terrain.elevation.size():
				if map.terrain.elevation[i] > best_h:
					best_h = map.terrain.elevation[i]
					best = i
			var cx: int = best % map.terrain.cells
			var cz: int = best / map.terrain.cells
			var pos: Vector2 = WorldCoords.macro_cell_center(config, Vector2i(cx, cz))
			return WorldCoords.chunk_of(config, pos.x, pos.y)
	return Vector2i(-1, -1)


func _test_determinism() -> void:
	print("- same seed rebuilds the same world")
	var small: WorldConfig = WorldConfig.new()
	small.macro_cells = 128
	small.settlement_count = 8

	var a: WorldMap = WorldMap.generate(small)
	var b: WorldMap = WorldMap.generate(small)
	_check("macro terrain identical", _hash_floats(a.terrain.elevation) == _hash_floats(b.terrain.elevation))
	_check("drainage identical", _hash_floats(a.hydro.filled) == _hash_floats(b.hydro.filled))
	_check("river count identical", a.hydro.rivers.size() == b.hydro.rivers.size(),
		"(%d vs %d)" % [a.hydro.rivers.size(), b.hydro.rivers.size()])
	_check("road count identical", a.paths.roads.size() == b.paths.roads.size(),
		"(%d vs %d)" % [a.paths.roads.size(), b.paths.roads.size()])

	var different: WorldConfig = WorldConfig.new()
	different.macro_cells = 128
	different.settlement_count = 8
	different.seed = small.seed + 1
	var c: WorldMap = WorldMap.generate(different)
	_check("different seed differs",
		_hash_floats(a.terrain.elevation) != _hash_floats(c.terrain.elevation))


func _hash_floats(values: PackedFloat32Array) -> int:
	return hash(values)
