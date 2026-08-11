class_name DensityField
extends RefCounted
## Layer 4: the solid world, as a signed field. Positive is rock, negative is air.
##
## The shape is assembled in a strict order, and that order is the whole design:
##
##   1. macro height              - the drainage surface everything agrees on
##                                  (settlement detail damp softens relief_amp)
##   2. hydro and road carves     - valleys, beds, banks, benched roadways
##   3. water-over-ground seal    - suppress land bridges over the sheet
##   4. axial bridge grades LAST  - hard abutment set to BridgeSite.deck_z
##   5. relief (masked) + caves   - 3D detail never undoes the water/bridge contract
##
## Settlement flattening lives in ContinentalTerrain (atlas node basins), not
## here — density-field plaza terraces fought roads and hydro. Bridge grades
## still run last so abutments own deck_z. Relief is multiplied by a corridor
## mask so 3D detail cannot lift the ground through a river or drop it away
## from a road.

const TILE_DIVISIONS: int = 4
## Metres the ground stands above the water at the lip of a channel.
const BANK_RISE: float = 1.1
## Metres the water sheet sits below the continental bed under the channel.
## Zero leaves water_top == the land rim: the sheet z-fights the mesh and
## WaterSurface culls columns whose surface comes within WET_EPSILON of the
## waterline, which reads as the river diving underground in patches.
const WATER_FREEBOARD: float = 0.45
## How far below the local continental bed a draped polyline chord may pull the
## sheet when the macro sample is still a believable bed. Past
## [constant CHORD_BREAK_FACTOR] × this, the macro height is treated as a false
## bridge and the sheet trusts the polyline instead.
const MAX_CHORD_BURY: float = 1.6
const CHORD_BREAK_FACTOR: float = 2.5
## Hard floor on how deep a river bed is cut below the water sheet, even at the
## banks and on fords. Must stay above [constant MIN_VISIBLE_WATER_CLEARANCE].
const MIN_BED_CLEARANCE: float = 0.12
## Metres the bed must sit below [member Field.water_top] for WaterSurface to
## emit the column. The draw path and the contract use the same number: a bed
## flush with the sheet used to score a perfect contract error of 0 while the
## mesh culled the water as dry.
const MIN_VISIBLE_WATER_CLEARANCE: float = 0.02
## Inland metres over which a river sheet is pulled down to the atlas water
## plane. Without this, shore freeboard lifts the drape and the ocean join
## becomes a climbing canal then a vertical water wall. Long enough that a
## sharp atlas waterline (km cells) still gets a multi-station descent.
const ESTUARY_BLEND_METRES: float = 220.0
## On a low coastal shelf, full order-N bed depth digs a bathtub that reads as a
## mini-lake (and drowns bridge landings / bank trees). Cap how far below the
## atlas water plane a channel bed may go when the macro land itself is near sea.
const COASTAL_BED_MAX_BELOW_PLANE: float = 2.2
## Inland reach of the coastal bed cap (past [constant ESTUARY_BLEND_METRES] so
## the last river bends before the mouth stay shallow too).
const COASTAL_BED_BLEND_METRES: float = 440.0
## Outside the lake mask, only a thin shore may share the spill sheet. Deeper
## land below the spill (neighbouring valleys, outflow slopes) used to get the
## full lake level as a floating pane through trees.
const LAKE_SHORE_BAND_CELLS: float = 0.85
const LAKE_SHORE_MAX_INUNDATION: float = 2.5
const SOLID: float = 1e6
const AIR: float = -1e6
## Deep rock is stored as [constant SOLID] so the volume pass can skip it, but a
## cave has to be able to open in it. Inside the cave band the field is capped
## to this instead, which is still unambiguously solid and still lets a tunnel
## carve through with a smooth wall rather than a step off an enormous value.
const CAVE_SOLID_CAP: float = 9.0
## Metres of air a fully developed tunnel opens. Comfortably past the cap, or
## caves would only ever appear in the few metres just under the surface.
const CAVE_STRENGTH: float = 26.0
## Packed bridge grade: cx, cz, axis_x, axis_z, deck_z, gap_half, abutment_s,
## ramp_length, grade_half_width, plateau_length.
const BRIDGE_GRADE_STRIDE: int = 10
## Hard-set radius around each abutment contact (metres).
const BRIDGE_CONTACT_RADIUS: float = 5.5
## Max |surface - deck_z| allowed at abutments after density build.
const BRIDGE_FLUSH_EPSILON: float = 0.05
## Finite stand-in for dry water markers across the OrrunGen FFI. Godot
## PackedFloat32Array does not reliably round-trip ±INF into Rust.
const NO_WATER_FFI: float = -1.0e20
const NO_WATER_FFI_THRESH: float = -1.0e19
const NO_CLEARANCE_FFI: float = 1.0e20


class Field extends RefCounted:
	var chunk: Vector2i
	var lod: int = 0
	var voxel: float = 2.0
	## World position of sample index (0,0,0). Includes the -1 sample pad.
	var origin: Vector3 = Vector3.ZERO
	## Sample counts per axis.
	var dims: Vector3i = Vector3i.ZERO
	var values: PackedFloat32Array = PackedFloat32Array()

	## Per-column data, indexed [cz * dims.x + cx] over the horizontal samples.
	var surface_z: PackedFloat32Array = PackedFloat32Array()
	var corridor_mask: PackedFloat32Array = PackedFloat32Array()
	var wetness: PackedFloat32Array = PackedFloat32Array()
	## How much of the column is worn roadway, 0 off the road and 1 on the
	## running surface. Drives the dirt band that makes a road legible.
	var roadness: PackedFloat32Array = PackedFloat32Array()
	var biome: PackedByteArray = PackedByteArray()
	var temperature: PackedFloat32Array = PackedFloat32Array()
	## Biome tint for this column, blended from the macro fields rather than
	## looked up from the classified biome, so hillsides have no contour lines.
	var ground_color: PackedColorArray = PackedColorArray()
	## Metres of 3D overhang deviation allowed in this column (already masked).
	var overhang_amp: PackedFloat32Array = PackedFloat32Array()
	## Clearance deficit per wet column: how far [member surface_z] sits above
	## [code]water_top - MIN_VISIBLE_WATER_CLEARANCE[/code]. Zero means the bed
	## is strictly below the sheet by enough for the water mesh to draw.
	var contract_error: PackedFloat32Array = PackedFloat32Array()
	## Highest water surface touching each column, or -INF when dry.
	var water_top: PackedFloat32Array = PackedFloat32Array()

	var has_water: bool = false
	var max_contract_error: float = 0.0
	## Smallest [code]water_top - surface_z[/code] over wet columns, or INF when
	## the chunk is dry. Negative means the bed pokes through the sheet.
	var min_water_clearance: float = INF
	## Wet columns whose bed is not strictly below the sheet.
	var wet_columns_failing_clearance: int = 0
	var wet_columns: int = 0
	## Timing split for the HUD (filled by [method DensityField.build]).
	var columns_ms: int = 0
	var volume_ms: int = 0

	func sample_index(ix: int, iy: int, iz: int) -> int:
		return (iz * dims.y + iy) * dims.x + ix

	func column_index(ix: int, iz: int) -> int:
		return iz * dims.x + ix

	func sample_world_position(ix: int, iy: int, iz: int) -> Vector3:
		return origin + Vector3(float(ix), float(iy), float(iz)) * voxel


static func build(
	cfg: WorldConfig,
	sector: WorldSector,
	continental: ContinentalTerrain,
	noise: NoiseSet,
	chunk: Vector2i,
	lod: int
) -> Field:
	var field: Field = Field.new()
	field.chunk = chunk
	field.lod = lod
	field.voxel = cfg.voxel_size_for_lod(lod)

	var cells: int = int(round(cfg.chunk_size / field.voxel))
	var samples_h: int = cells + 2
	var chunk_origin: Vector2 = WorldCoords.chunk_origin(cfg, chunk)
	var origin_x: float = chunk_origin.x - field.voxel
	var origin_z: float = chunk_origin.y - field.voxel

	var influence: float = _max_influence(cfg)
	var query_rect: Rect2 = Rect2(
		origin_x - influence, origin_z - influence,
		cfg.chunk_size + field.voxel * 2.0 + influence * 2.0,
		cfg.chunk_size + field.voxel * 2.0 + influence * 2.0
	)
	var rivers: PackedFloat32Array = sector.collect_river_segments(query_rect)
	var roads: PackedFloat32Array = sector.collect_road_segments(query_rect)
	var fords: PackedVector3Array = _collect_fords(sector, query_rect)
	var bridge_grades: PackedFloat32Array = _collect_bridge_grades(sector, query_rect)

	var tile_span: float = (cfg.chunk_size + field.voxel * 2.0) / float(TILE_DIVISIONS)
	var river_tiles: Array[PackedInt32Array] = _bin_segments(
		rivers, WorldSector.RIVER_STRIDE, origin_x, origin_z, tile_span, influence
	)
	var road_tiles: Array[PackedInt32Array] = _bin_segments(
		roads, WorldSector.ROAD_STRIDE, origin_x, origin_z, tile_span, influence
	)

	assert(ClassDB.class_exists("OrrunGen"), "OrrunGen missing — rebuild addons/orrun_gen")
	var gen: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
	var t_cols: int = Time.get_ticks_msec()
	_build_columns(
		cfg, sector, continental, noise, field, samples_h, origin_x, origin_z,
		rivers, roads, river_tiles, road_tiles, tile_span, fords, bridge_grades, gen
	)
	field.columns_ms = Time.get_ticks_msec() - t_cols
	var t_vol: int = Time.get_ticks_msec()
	_build_volume(cfg, noise, field, samples_h, origin_x, origin_z, gen)
	field.volume_ms = Time.get_ticks_msec() - t_vol
	# Translate FFI dry markers to -INF for the rest of the game.
	for i in field.water_top.size():
		if field.water_top[i] <= NO_WATER_FFI_THRESH:
			field.water_top[i] = -INF
	if field.min_water_clearance >= NO_CLEARANCE_FFI * 0.5:
		field.min_water_clearance = INF
	return field


static func _max_influence(cfg: WorldConfig) -> float:
	return (
		cfg.river_valley_base + cfg.river_valley_per_order * 6.0
		+ cfg.corridor_outer + cfg.meander_amplitude + 48.0
	)


# --- Column pass (2D) -----------------------------------------------------------

static func _flatten_tiles(tiles: Array[PackedInt32Array]) -> Dictionary:
	var starts: PackedInt32Array = PackedInt32Array()
	var indices: PackedInt32Array = PackedInt32Array()
	starts.resize(tiles.size() + 1)
	for t in tiles.size():
		starts[t] = indices.size()
		for si in tiles[t]:
			indices.append(int(si))
	starts[tiles.size()] = indices.size()
	return {"starts": starts, "indices": indices}


static func _build_columns(
	cfg: WorldConfig,
	sector: WorldSector,
	continental: ContinentalTerrain,
	_noise: NoiseSet,
	field: Field,
	samples_h: int,
	origin_x: float,
	origin_z: float,
	rivers: PackedFloat32Array,
	roads: PackedFloat32Array,
	river_tiles: Array[PackedInt32Array],
	road_tiles: Array[PackedInt32Array],
	tile_span: float,
	fords: PackedVector3Array,
	bridge_grades: PackedFloat32Array,
	gen: RefCounted
) -> void:
	var count: int = samples_h * samples_h
	field.has_water = false
	field.max_contract_error = 0.0
	field.min_water_clearance = NO_CLEARANCE_FFI
	field.wet_columns_failing_clearance = 0
	field.wet_columns = 0

	var terrain: MacroTerrain = sector.terrain
	var hydro: Hydrology = sector.hydro
	var voxel: float = field.voxel

	# Pre-sample macro/hydro grids (cheap); carves + segment scans run in Rust.
	var height: PackedFloat32Array = PackedFloat32Array()
	var amp: PackedFloat32Array = PackedFloat32Array()
	var moisture: PackedFloat32Array = PackedFloat32Array()
	var temperature: PackedFloat32Array = PackedFloat32Array()
	var shore_d: PackedFloat32Array = PackedFloat32Array()
	var atlas_plane: PackedFloat32Array = PackedFloat32Array()
	var lake_edge_d: PackedFloat32Array = PackedFloat32Array()
	var lake_surface: PackedFloat32Array = PackedFloat32Array()
	var drainage_z: PackedFloat32Array = PackedFloat32Array()
	var lake_surface_near: PackedFloat32Array = PackedFloat32Array()
	height.resize(count)
	amp.resize(count)
	moisture.resize(count)
	temperature.resize(count)
	shore_d.resize(count)
	atlas_plane.resize(count)
	lake_edge_d.resize(count)
	lake_surface.resize(count)
	drainage_z.resize(count)
	lake_surface_near.resize(count)

	for iz in samples_h:
		var wz: float = origin_z + float(iz) * voxel
		for ix in samples_h:
			var wx: float = origin_x + float(ix) * voxel
			var index: int = iz * samples_h + ix
			height[index] = terrain.height_at(wx, wz)
			amp[index] = terrain.relief_amp_at(wx, wz)
			moisture[index] = terrain.moisture_at(wx, wz)
			temperature[index] = terrain.temperature_at(wx, wz)
			shore_d[index] = continental.shore_distance(wx, wz)
			atlas_plane[index] = continental.water_plane_at(wx, wz)
			lake_edge_d[index] = hydro.lake_distance_at(wx, wz)
			var lake_id_here: int = hydro.lake_at(wx, wz)
			var ls: float = NO_WATER_FFI
			if lake_id_here >= 0:
				ls = hydro.lakes[lake_id_here].surface_z
			elif lake_edge_d[index] <= cfg.macro_cell_size * LAKE_SHORE_BAND_CELLS:
				var flat: float = hydro.lake_surface_near_at(wx, wz)
				if (
					flat > -INF
					and height[index] < flat
					and flat - height[index] <= LAKE_SHORE_MAX_INUNDATION
					and hydro.drainage_at(wx, wz) > height[index]
				):
					ls = flat
			lake_surface[index] = ls
			drainage_z[index] = hydro.drainage_at(wx, wz)
			var near_ls: float = hydro.lake_surface_near_at(wx, wz)
			lake_surface_near[index] = near_ls if near_ls > -INF else NO_WATER_FFI

	var river_flat: Dictionary = _flatten_tiles(river_tiles)
	var road_flat: Dictionary = _flatten_tiles(road_tiles)
	var river_starts: PackedInt32Array = river_flat["starts"]
	var river_indices: PackedInt32Array = river_flat["indices"]
	var road_starts: PackedInt32Array = road_flat["starts"]
	var road_indices: PackedInt32Array = road_flat["indices"]
	var tile_starts := PackedInt32Array()
	tile_starts.resize(34) # 17 river starts + 17 road starts
	for i in 17:
		tile_starts[i] = river_starts[i]
		tile_starts[17 + i] = road_starts[i]
	var tile_indices := PackedInt32Array()
	tile_indices.append_array(river_indices)
	tile_indices.append_array(road_indices)
	# Channel-major grids — avoid Dictionary packing of many PackedFloat32Arrays.
	var grids := PackedFloat32Array()
	grids.resize(count * 10)
	for i in count:
		grids[i] = height[i]
		grids[count + i] = amp[i]
		grids[count * 2 + i] = moisture[i]
		grids[count * 3 + i] = temperature[i]
		grids[count * 4 + i] = shore_d[i]
		grids[count * 5 + i] = atlas_plane[i]
		grids[count * 6 + i] = lake_edge_d[i]
		grids[count * 7 + i] = lake_surface[i]
		grids[count * 8 + i] = drainage_z[i]
		grids[count * 9 + i] = lake_surface_near[i]
	var params: Dictionary = {
		"samples_h": samples_h,
		"voxel": voxel,
		"origin_x": origin_x,
		"origin_z": origin_z,
		"tile_span": tile_span,
		"corridor_inner": cfg.corridor_inner,
		"corridor_outer": cfg.corridor_outer,
		"macro_cell_size": cfg.macro_cell_size,
		"relief_amp_mountains": cfg.relief_amp_mountains,
		"relief_amp_plains": cfg.relief_amp_plains,
		"overhang_amount": cfg.overhang_amount,
		"seed_relief": cfg.layer_seed("relief"),
		"seed_relief_fine": cfg.layer_seed("relief_fine"),
	}
	var result: Dictionary = gen.call(
		"build_columns",
		grids,
		rivers,
		roads,
		tile_starts,
		tile_indices,
		river_indices.size(),
		fords,
		bridge_grades,
		params
	)
	assert(result.has("surface_z"), "OrrunGen.build_columns returned no surface_z")
	field.surface_z = result["surface_z"]
	field.corridor_mask = result["corridor_mask"]
	field.wetness = result["wetness"]
	field.roadness = result["roadness"]
	field.biome = result["biome"]
	field.temperature = result["temperature"]
	field.ground_color = result["ground_color"]
	field.overhang_amp = result["overhang_amp"]
	field.contract_error = result["contract_error"]
	field.water_top = result["water_top"]
	assert(field.surface_z.size() == count, "native columns surface_z size")
	assert(field.water_top.size() == count, "native columns water_top size")
	# Spot-check only — full scans were a multi-ms tax on every worker job.
	var probe: float = field.surface_z[0]
	assert(
		is_finite(probe) and probe > NO_WATER_FFI_THRESH,
		"native columns surface_z[0]=%s is not land height" % probe
	)
	field.has_water = bool(result["has_water"])
	field.wet_columns = int(result["wet_columns"])
	field.wet_columns_failing_clearance = int(result["wet_columns_failing_clearance"])
	field.min_water_clearance = float(result["min_water_clearance"])
	field.max_contract_error = float(result["max_contract_error"])
	field.origin = Vector3(origin_x, 0.0, origin_z)
	field.dims = Vector3i(samples_h, 0, samples_h)



## WaterSurface extends the sheet under dry corners of a wet quad. If those
## corners still have high [member Field.surface_z], the terrain draws a land
## bridge over visible water — the wedge in the user's screenshot. Pull
## in-channel misses open and clamp near-bank neighbors to the bank lip.
static func _suppress_ground_over_water(
	field: Field,
	river_dist: PackedFloat32Array,
	wet_half_of: PackedFloat32Array,
	samples_h: int,
	voxel: float,
	worst_error: float
) -> float:
	var last: int = samples_h - 1
	var offsets: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	]
	for iz in samples_h:
		for ix in samples_h:
			var index: int = iz * samples_h + ix
			var top: float = field.water_top[index]
			if top == -INF:
				continue
			var need: float = top - MIN_VISIBLE_WATER_CLEARANCE
			if field.surface_z[index] >= need:
				field.surface_z[index] = need - MIN_BED_CLEARANCE * 0.5
			for off in offsets:
				var nx: int = ix + off.x
				var nz: int = iz + off.y
				if nx < 0 or nz < 0 or nx > last or nz > last:
					continue
				var ni: int = nz * samples_h + nx
				if field.surface_z[ni] < top - MIN_VISIBLE_WATER_CLEARANCE:
					continue
				var n_half: float = maxf(wet_half_of[ni], wet_half_of[index])
				if river_dist[ni] <= n_half * 1.05:
					# In-channel sample that stayed dry/high — open it.
					field.surface_z[ni] = top - MIN_BED_CLEARANCE
					field.water_top[ni] = top
					field.wetness[ni] = maxf(field.wetness[ni], 0.9)
					field.has_water = true
				elif river_dist[ni] <= n_half + voxel:
					# Immediate bank that would occlude the extended sheet.
					field.surface_z[ni] = minf(field.surface_z[ni], top + BANK_RISE)

	# Recompute contract tallies after the seal.
	field.wet_columns = 0
	field.wet_columns_failing_clearance = 0
	field.min_water_clearance = INF
	var err: float = 0.0
	for i in field.water_top.size():
		var top: float = field.water_top[i]
		if top == -INF:
			field.contract_error[i] = 0.0
			continue
		field.wet_columns += 1
		var clearance: float = top - field.surface_z[i]
		field.min_water_clearance = minf(field.min_water_clearance, clearance)
		var need: float = top - MIN_VISIBLE_WATER_CLEARANCE
		var col_err: float = maxf(field.surface_z[i] - need, 0.0)
		field.contract_error[i] = col_err
		err = maxf(err, col_err)
		if clearance < MIN_VISIBLE_WATER_CLEARANCE:
			field.wet_columns_failing_clearance += 1
	return maxf(worst_error, err)


## Takes the overhang budget away from ground that is already steep.
##
## The corridor mask answers "how close is this to a river", which is the wrong
## question at the lip of a gorge: forty metres from the channel the mask is
## nearly open, but the ground there falls away at sixty degrees because the
## breach cut it. Folding an undercut into a face that steep gives surface nets
## several surfaces per column within one voxel, and it resolves them as a fan
## of shards. Slope is measured on the finished 2D surface, so it sees carves,
## not just the macro shape.
static func _damp_overhangs_on_steep_ground(
	field: Field, samples_h: int, voxel: float
) -> void:
	var surface: PackedFloat32Array = field.surface_z
	var last: int = samples_h - 1
	for iz in samples_h:
		for ix in samples_h:
			var index: int = iz * samples_h + ix
			if field.overhang_amp[index] <= 0.05:
				continue
			var west: float = surface[iz * samples_h + maxi(ix - 1, 0)]
			var east: float = surface[iz * samples_h + mini(ix + 1, last)]
			var north: float = surface[maxi(iz - 1, 0) * samples_h + ix]
			var south: float = surface[mini(iz + 1, last) * samples_h + ix]
			var run: float = voxel * 2.0
			var slope: float = Vector2(east - west, south - north).length() / run
			# Only genuinely cliff-like ground is disqualified. Damping ordinary
			# hillsides costs the world its overhangs and its caves, which are
			# the reason the terrain is a density field and not a heightmap.
			field.overhang_amp[index] *= 1.0 - 0.9 * smoothstep(1.1, 2.1, slope)


static func _relief_value(
	noise: NoiseSet, wx: float, wz: float, amp: float, mountain_amp: float
) -> float:
	var ridge: float = noise.relief.get_noise_2d(wx, wz)
	var fine: float = noise.relief_fine.get_noise_2d(wx, wz)
	# High-amp columns already carry continental ridges; fine freckles read as
	# micro-mountains from the air, so fade them out toward mountain amp.
	var fine_w: float = lerpf(
		0.08, 0.02, clampf(amp / maxf(mountain_amp, 1.0), 0.0, 1.0)
	)
	return ridge * (1.0 - fine_w) + fine * fine_w


static func _segment_param(
	px: float, pz: float, ax: float, az: float, bx: float, bz: float
) -> float:
	var dx: float = bx - ax
	var dz: float = bz - az
	var len_sq: float = dx * dx + dz * dz
	if len_sq < 0.000001:
		return 0.0
	return clampf(((px - ax) * dx + (pz - az) * dz) / len_sq, 0.0, 1.0)


## Fords keep a shallow bed so the crossing is walkable instead of a trench.
static func _ford_relief(fords: PackedVector3Array, wx: float, wz: float) -> float:
	var scale: float = 1.0
	for ford in fords:
		var d: float = Vector2(wx - ford.x, wz - ford.y).length()
		if d < ford.z:
			scale = minf(scale, lerpf(0.22, 1.0, smoothstep(0.0, ford.z, d)))
	return scale


## Axial water gap for a bridge grade: 1 over the channel slab, feathers out.
static func _axial_bridge_gap(grades: PackedFloat32Array, wx: float, wz: float) -> float:
	var gap: float = 0.0
	var count: int = grades.size() / BRIDGE_GRADE_STRIDE
	for i in count:
		var base: int = i * BRIDGE_GRADE_STRIDE
		var centre: Vector2 = Vector2(grades[base], grades[base + 1])
		var axis: Vector2 = Vector2(grades[base + 2], grades[base + 3])
		var gap_half: float = grades[base + 5]
		var half_w: float = grades[base + 8]
		var delta: Vector2 = Vector2(wx, wz) - centre
		var along: float = absf(delta.dot(axis))
		var lateral: float = absf(delta.x * axis.y - delta.y * axis.x)
		if lateral > half_w + 4.0 or along > gap_half + 4.0:
			continue
		var along_w: float = 1.0 - smoothstep(gap_half, gap_half + 4.0, along)
		var lat_w: float = 1.0 - smoothstep(half_w, half_w + 4.0, lateral)
		gap = maxf(gap, along_w * lat_w)
	return clampf(gap, 0.0, 1.0)


## Last writer: hard apron at deck_z, then an eased inland ramp. Runs after
## the water-over-ground seal. Bank columns marked wet by the seal still get
## the apron — skipping them left entry steps and exit hills.
static func _apply_bridge_grades(
	field: Field,
	grades: PackedFloat32Array,
	samples_h: int,
	origin_x: float,
	origin_z: float,
	voxel: float
) -> void:
	if grades.is_empty():
		return
	var count: int = grades.size() / BRIDGE_GRADE_STRIDE
	var contact_r2: float = BRIDGE_CONTACT_RADIUS * BRIDGE_CONTACT_RADIUS
	for iz in samples_h:
		var wz: float = origin_z + float(iz) * voxel
		for ix in samples_h:
			var wx: float = origin_x + float(ix) * voxel
			var index: int = iz * samples_h + ix
			var surface: float = field.surface_z[index]
			for gi in count:
				var base: int = gi * BRIDGE_GRADE_STRIDE
				var centre: Vector2 = Vector2(grades[base], grades[base + 1])
				var axis: Vector2 = Vector2(grades[base + 2], grades[base + 3])
				var deck_z: float = grades[base + 4]
				var gap_half: float = grades[base + 5]
				var abut_s: float = grades[base + 6]
				var ramp_len: float = grades[base + 7]
				var half_w: float = grades[base + 8]
				var plateau: float = grades[base + 9]
				var hard_end: float = abut_s + plateau
				var delta: Vector2 = Vector2(wx, wz) - centre
				var along: float = delta.dot(axis)
				var abs_along: float = absf(along)
				var lateral: float = absf(delta.x * axis.y - delta.y * axis.x)
				if lateral > half_w or abs_along > hard_end + ramp_len:
					continue
				# Water gap: leave the channel alone.
				if abs_along < gap_half:
					continue
				var lat_w: float = 1.0 - smoothstep(half_w * 0.45, half_w, lateral)
				if lat_w <= 0.001:
					continue
				var abut_pt: Vector2 = centre + axis * (abut_s if along >= 0.0 else -abut_s)
				var near_abut: bool = Vector2(wx, wz).distance_squared_to(abut_pt) <= contact_r2
				# Bank shelf + inland apron + contact disk: force deck_z.
				if near_abut or abs_along <= hard_end:
					var apron_w: float = 1.0 if near_abut or lateral < half_w * 0.4 else lat_w
					surface = lerpf(surface, deck_z, apron_w)
					# Approach is walkable ground, not channel — drop a wet flag
					# the seal may have painted onto the bank.
					if (
						apron_w > 0.85
						and field.water_top[index] > -INF
						and deck_z >= field.water_top[index] - 0.05
					):
						field.water_top[index] = -INF
						field.wetness[index] = minf(field.wetness[index], 0.2)
					continue
				# Inland ramp: ease out of deck_z so hills get cut and gaps fill.
				var t: float = (abs_along - hard_end) / maxf(ramp_len, 0.001)
				t = clampf(t, 0.0, 1.0)
				var natural: float = surface
				var target: float = lerpf(deck_z, natural, t * t)
				var ramp_w: float = lat_w
				if natural > deck_z + 0.15:
					# Exit hills need a firm cut along the carriageway.
					ramp_w = maxf(lat_w, 0.9)
				elif natural < deck_z - 0.15:
					ramp_w = maxf(lat_w, 0.85)
				surface = lerpf(surface, target, ramp_w)
			field.surface_z[index] = surface


## Nearest-column surface sample (world XZ).
static func surface_at(field: Field, wx: float, wz: float) -> float:
	var samples_h: int = field.dims.x
	if samples_h <= 0 or field.surface_z.is_empty():
		push_error("DensityField.surface_at: empty field")
		return 0.0
	var ix: int = clampi(roundi((wx - field.origin.x) / field.voxel), 0, samples_h - 1)
	var iz: int = clampi(roundi((wz - field.origin.z) / field.voxel), 0, samples_h - 1)
	return field.surface_z[iz * samples_h + ix]


static func assert_bridge_flush(field: Field, sites: Array[BridgeSite]) -> void:
	var samples_h: int = field.dims.x
	if samples_h <= 0:
		return
	var min_x: float = field.origin.x
	var min_z: float = field.origin.z
	var max_x: float = min_x + float(samples_h - 1) * field.voxel
	var max_z: float = min_z + float(samples_h - 1) * field.voxel
	for site in sites:
		if site.is_ford:
			continue
		var axis: Vector2 = site.direction()
		var checks: Array[Vector2] = [
			site.abutment_a_xz(),
			site.abutment_b_xz(),
			site.center_xz - axis * (site.abutment_s + site.plateau_length * 0.5),
			site.center_xz + axis * (site.abutment_s + site.plateau_length * 0.5),
		]
		for abut in checks:
			if abut.x < min_x or abut.y < min_z or abut.x > max_x or abut.y > max_z:
				continue
			var surface: float = surface_at(field, abut.x, abut.y)
			var delta: float = absf(surface - site.deck_z)
			if delta > BRIDGE_FLUSH_EPSILON:
				push_error(
					"Bridge %d abutment flush failed: surface=%.3f deck_z=%.3f delta=%.3f at (%.1f, %.1f)"
					% [site.id, surface, site.deck_z, delta, abut.x, abut.y]
				)


static func _collect_fords(sector: WorldSector, rect: Rect2) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	for site in sector.paths.bridges:
		if not site.is_ford:
			continue
		var center: Vector3 = site.center()
		if rect.has_point(Vector2(center.x, center.z)):
			out.append(Vector3(center.x, center.z, maxf(site.span_length(), 12.0)))
	return out


static func _collect_bridge_grades(sector: WorldSector, rect: Rect2) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	for site in sector.paths.bridges:
		if site.is_ford:
			continue
		var reach: float = (
			site.abutment_s + site.plateau_length + site.ramp_length + site.grade_half_width
		)
		if not rect.grow(reach).has_point(site.center_xz):
			continue
		out.append(site.center_xz.x)
		out.append(site.center_xz.y)
		out.append(site.axis.x)
		out.append(site.axis.y)
		out.append(site.deck_z)
		out.append(site.gap_half)
		out.append(site.abutment_s)
		out.append(site.ramp_length)
		out.append(site.grade_half_width)
		out.append(site.plateau_length)
	return out


static func _bin_segments(
	data: PackedFloat32Array,
	stride: int,
	origin_x: float,
	origin_z: float,
	tile_span: float,
	influence: float
) -> Array[PackedInt32Array]:
	var tiles: Array[PackedInt32Array] = []
	tiles.resize(TILE_DIVISIONS * TILE_DIVISIONS)
	for i in tiles.size():
		tiles[i] = PackedInt32Array()

	var segments: int = data.size() / stride
	for s in segments:
		var base: int = s * stride
		var ax: float = data[base]
		var az: float = data[base + 2]
		var bx: float = data[base + 3]
		var bz: float = data[base + 5]
		var min_x: float = minf(ax, bx) - influence
		var max_x: float = maxf(ax, bx) + influence
		var min_z: float = minf(az, bz) - influence
		var max_z: float = maxf(az, bz) + influence

		var tx0: int = clampi(floori((min_x - origin_x) / tile_span), 0, TILE_DIVISIONS - 1)
		var tx1: int = clampi(floori((max_x - origin_x) / tile_span), 0, TILE_DIVISIONS - 1)
		var tz0: int = clampi(floori((min_z - origin_z) / tile_span), 0, TILE_DIVISIONS - 1)
		var tz1: int = clampi(floori((max_z - origin_z) / tile_span), 0, TILE_DIVISIONS - 1)
		if max_x < origin_x or max_z < origin_z:
			continue
		for tz in range(tz0, tz1 + 1):
			for tx in range(tx0, tx1 + 1):
				tiles[tz * TILE_DIVISIONS + tx].append(base)
	return tiles


# --- Volume pass (3D) -------------------------------------------------------------

static func _build_volume(
	cfg: WorldConfig,
	_noise: NoiseSet,
	field: Field,
	samples_h: int,
	origin_x: float,
	origin_z: float,
	gen: RefCounted
) -> void:
	var caves: bool = cfg.cave_enabled and field.lod <= cfg.cave_max_lod
	var params: Dictionary = {
		"samples_h": samples_h,
		"voxel": field.voxel,
		"origin_x": origin_x,
		"origin_z": origin_z,
		"surface_band": cfg.surface_band,
		"vertical_margin": cfg.vertical_margin,
		"world_floor": cfg.world_floor,
		"world_ceiling": cfg.world_ceiling,
		"cave_enabled": caves,
		"cave_top_depth": cfg.cave_top_depth,
		"cave_bottom_depth": cfg.cave_bottom_depth,
		"cave_threshold": cfg.cave_threshold,
		"cave_water_clearance": cfg.cave_water_clearance,
		"seed_overhang": cfg.layer_seed("overhang"),
		"overhang_scale": cfg.overhang_scale,
		"seed_cave_a": cfg.layer_seed("cave_a"),
		"seed_cave_b": cfg.layer_seed("cave_b"),
		"cave_scale": cfg.cave_scale,
	}
	var result: Variant = gen.call(
		"build_volume",
		field.surface_z,
		field.corridor_mask,
		field.water_top,
		field.overhang_amp,
		params
	)
	assert(
		typeof(result) == TYPE_DICTIONARY,
		"OrrunGen.build_volume failed: %s" % [result]
	)
	var dict: Dictionary = result
	var y_min: float = float(dict["origin_y"])
	var samples_y: int = int(dict["samples_y"])
	field.origin = Vector3(origin_x, y_min, origin_z)
	field.dims = Vector3i(samples_h, samples_y, samples_h)
	field.values = dict["values"]


static func column_base(field: Field, ix: int, iz: int) -> int:
	return iz * field.dims.y * field.dims.x + ix
