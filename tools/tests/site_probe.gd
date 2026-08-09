extends SceneTree
## Probe dry gorge between lakes.
##
##   start.bat --headless --script res://tools/tests/site_probe.gd

const AT: Vector2 = Vector2(132646.0, 158463.0)
const SCAN: float = 200.0


func _init() -> void:
	var config: WorldConfig = WorldConfig.new()
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var continental: ContinentalTerrain = context.sampler()
	var sector: WorldSector = WorldSector.generate(
		context, WorldCoords.sector_of(AT.x, AT.y)
	)
	var hydro: Hydrology = sector.hydro
	var noise: NoiseSet = NoiseSet.create(config)
	print("probe %.0f,%.0f sector %s" % [AT.x, AT.y, sector.sector])
	print("macro=%.2f drain=%.2f lid=%d ld=%.1f ls=%.2f" % [
		continental.height_at(AT.x, AT.y), hydro.drainage_at(AT.x, AT.y),
		hydro.lake_at(AT.x, AT.y), hydro.lake_distance_at(AT.x, AT.y),
		hydro.lake_surface_near_at(AT.x, AT.y)
	])

	print("--- lakes near AT (by nearest member) ---")
	var ncells: int = hydro.terrain.cells
	for i in hydro.lakes.size():
		var lake: LakeData = hydro.lakes[i]
		var best_md: float = INF
		var best_m: Vector2 = Vector2.ZERO
		for cell in lake.cells:
			var c: Vector2 = hydro.terrain.cell_center(cell % ncells, int(cell / ncells))
			var md: float = c.distance_to(AT)
			if md < best_md:
				best_md = md
				best_m = c
		if best_md > SCAN:
			continue
		var out_pos: Vector2 = Vector2.INF
		if lake.outlet_cell >= 0:
			out_pos = hydro.terrain.cell_center(
				lake.outlet_cell % ncells, int(lake.outlet_cell / ncells)
			)
		print(
			"  lake[%d] surf=%.2f depth=%.2f cells=%d nearest_member=%.0f,%.0f d=%.0f outlet=%.0f,%.0f"
			% [
				i, lake.surface_z, lake.max_depth, lake.cells.size(),
				best_m.x, best_m.y, best_md,
				out_pos.x if out_pos != Vector2.INF else -1.0,
				out_pos.y if out_pos != Vector2.INF else -1.0,
			]
		)

	print("--- channel / trunk cells near gorge ---")
	for iz in range(-6, 7):
		for ix in range(-6, 7):
			var x: float = AT.x + float(ix) * 12.0
			var z: float = AT.y + float(iz) * 12.0
			var cell: Vector2i = hydro.terrain.local_cell_of(x, z)
			if not hydro.terrain.contains_local(cell.x, cell.y):
				continue
			var idx: int = cell.y * ncells + cell.x
			if hydro.is_channel[idx] == 0 and hydro.trunk[idx] == 0 and hydro.lake_id[idx] < 0:
				continue
			print(
				"  %.0f,%.0f ch=%d trunk=%d lid=%d elev=%.1f filled=%.1f accum=%.0f"
				% [
					x, z, hydro.is_channel[idx], hydro.trunk[idx], hydro.lake_id[idx],
					hydro.terrain.elevation[idx], hydro.filled[idx], hydro.accumulation[idx]
				]
			)

	print("--- reaches near AT ---")
	var reach: Dictionary = hydro.nearest_reach(AT.x, AT.y, 120.0)
	if reach.is_empty():
		print("  none within 120m")
	else:
		var rp: RiverPolyline = hydro.rivers[int(reach["reach"])]
		print(
			"  reach=%d trunk=%s order=%d d=%.1f half=%.1f water_z=%.2f pts=%d"
			% [
				rp.id, rp.is_trunk, rp.order, float(reach["distance"]),
				float(reach["half_width"]), float(reach["water_z"]), rp.points.size()
			]
		)
		# Walk stations near AT.
		for i in rp.points.size():
			var p: Vector3 = rp.points[i]
			if Vector2(p.x, p.z).distance_to(AT) > SCAN:
				continue
			print(
				"    st[%d] %.0f,%.0f y=%.2f h=%.2f lid=%d"
				% [
					i, p.x, p.z, p.y, continental.height_at(p.x, p.z),
					hydro.lake_at(p.x, p.z)
				]
			)

	var chunk_cache: Dictionary = {}
	print("--- density along connecting reach centreline ---")
	var r139: RiverPolyline = hydro.rivers[int(reach["reach"])] if not reach.is_empty() else null
	if r139 != null:
		for i in r139.points.size():
			var p: Vector3 = r139.points[i]
			if Vector2(p.x, p.z).distance_to(AT) > 220.0:
				continue
			var chunk: Vector2i = WorldCoords.chunk_of(config, p.x, p.z)
			var key: String = "%d,%d" % [chunk.x, chunk.y]
			if not chunk_cache.has(key):
				chunk_cache[key] = DensityField.build(
					config, sector, continental, noise, chunk, 0
				)
			var field: DensityField.Field = chunk_cache[key]
			var ix: int = clampi(
				int(round((p.x - field.origin.x) / field.voxel)), 0, field.dims.x - 1
			)
			var iz: int = clampi(
				int(round((p.z - field.origin.z) / field.voxel)), 0, field.dims.z - 1
			)
			var col: int = field.column_index(ix, iz)
			var half: float = r139.half_width[mini(i, r139.half_width.size() - 1)]
			print(
				"  st[%d] %.0f,%.0f y=%.2f half=%.1f dw=%s ds=%.2f h=%.2f"
				% [
					i, p.x, p.z, p.y, half,
					"dry" if field.water_top[col] == -INF else "%.2f" % field.water_top[col],
					field.surface_z[col], continental.height_at(p.x, p.z)
				]
			)

	print("--- gorge transect ( downhill guess: +z / -x toward lower lake) ---")
	# Sample a grid across the gorge from the screenshot orientation.
	for iz in range(-12, 13):
		for ix in range(-8, 9):
			var x: float = AT.x + float(ix) * 8.0
			var z: float = AT.y + float(iz) * 8.0
			var h: float = continental.height_at(x, z)
			var lid: int = hydro.lake_at(x, z)
			var chunk: Vector2i = WorldCoords.chunk_of(config, x, z)
			var key: String = "%d,%d" % [chunk.x, chunk.y]
			if not chunk_cache.has(key):
				chunk_cache[key] = DensityField.build(
					config, sector, continental, noise, chunk, 0
				)
			var field: DensityField.Field = chunk_cache[key]
			var col_ix: int = clampi(
				int(round((x - field.origin.x) / field.voxel)), 0, field.dims.x - 1
			)
			var col_iz: int = clampi(
				int(round((z - field.origin.z) / field.voxel)), 0, field.dims.z - 1
			)
			var col: int = field.column_index(col_ix, col_iz)
			var dw: float = field.water_top[col]
			var ds: float = field.surface_z[col]
			var nr: Dictionary = hydro.nearest_reach(x, z, 40.0)
			var rd: float = float(nr["distance"]) if not nr.is_empty() else INF
			var rh: float = float(nr["half_width"]) if not nr.is_empty() else -1.0
			var rw: float = float(nr["water_z"]) if not nr.is_empty() else -INF
			# Print wet, lake, or in-channel / low gorge samples.
			if (
				dw > -INF or lid >= 0 or rd < maxf(rh, 8.0)
				or (h < 310.0 and rd < 28.0)
			):
				print(
					"  %.0f,%.0f h=%.1f lid=%d dw=%s ds=%.1f rd=%.1f rh=%.1f rw=%.1f"
					% [
						x, z, h, lid,
						"dry" if dw == -INF else "%.1f" % dw,
						ds, rd, rh, rw
					]
				)
	quit(0)
