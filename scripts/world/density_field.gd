class_name DensityField
extends RefCounted
## Layer 4: the solid world, as a signed field. Positive is rock, negative is air.
##
## The shape is assembled in a strict order, and that order is the whole design:
##
##   1. macro height              - the drainage surface everything agrees on
##   2. hydro and road carves     - valleys, beds, banks, benched roadways
##   3. relief, MASKED            - cliffs and overhangs, suppressed near water
##   4. caves                     - subsurface voids, never under a river bed
##
## Step 3 is multiplied by a corridor mask so 3D detail can never lift the
## ground through a river or drop it away from a road. That mask is the entire
## reason rivers stay glued to the mesh instead of floating over it.

const TILE_DIVISIONS: int = 4
## Metres the ground stands above the water at the lip of a channel.
const BANK_RISE: float = 1.1
## Metres the water sheet sits below the continental bed under the channel.
## Zero leaves water_top == the land rim: the sheet z-fights the mesh and
## WaterSurface culls columns whose surface comes within WET_EPSILON of the
## waterline, which reads as the river diving underground in patches.
const WATER_FREEBOARD: float = 0.45
## How far below the local continental bed a draped polyline chord may pull the
## sheet. Deeper than this and the density field would cut a slot canyon that
## coarse LODs bridge with ground, hiding the river again.
const MAX_CHORD_BURY: float = 1.6
## Hard floor on how deep a river bed is cut below the water sheet, even at the
## banks and on fords. Must stay above [constant MIN_VISIBLE_WATER_CLEARANCE].
const MIN_BED_CLEARANCE: float = 0.12
## Metres the bed must sit below [member Field.water_top] for WaterSurface to
## emit the column. The draw path and the contract use the same number: a bed
## flush with the sheet used to score a perfect contract error of 0 while the
## mesh culled the water as dry.
const MIN_VISIBLE_WATER_CLEARANCE: float = 0.02
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
	var bridge_gaps: PackedVector4Array = _collect_bridge_gaps(sector, query_rect)

	var tile_span: float = (cfg.chunk_size + field.voxel * 2.0) / float(TILE_DIVISIONS)
	var river_tiles: Array[PackedInt32Array] = _bin_segments(
		rivers, WorldSector.RIVER_STRIDE, origin_x, origin_z, tile_span, influence
	)
	var road_tiles: Array[PackedInt32Array] = _bin_segments(
		roads, WorldSector.ROAD_STRIDE, origin_x, origin_z, tile_span, influence
	)

	_build_columns(
		cfg, sector, continental, noise, field, samples_h, origin_x, origin_z,
		rivers, roads, river_tiles, road_tiles, tile_span, fords, bridge_gaps
	)
	_build_volume(cfg, noise, field, samples_h, origin_x, origin_z)
	return field


static func _max_influence(cfg: WorldConfig) -> float:
	return (
		cfg.river_valley_base + cfg.river_valley_per_order * 6.0
		+ cfg.corridor_outer + cfg.meander_amplitude + 48.0
	)


# --- Column pass (2D) -----------------------------------------------------------

static func _build_columns(
	cfg: WorldConfig,
	sector: WorldSector,
	continental: ContinentalTerrain,
	noise: NoiseSet,
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
	bridge_gaps: PackedVector4Array
) -> void:
	var count: int = samples_h * samples_h
	field.has_water = false
	field.max_contract_error = 0.0
	field.min_water_clearance = INF
	field.wet_columns_failing_clearance = 0
	field.wet_columns = 0
	field.surface_z = PackedFloat32Array()
	field.surface_z.resize(count)
	field.corridor_mask = PackedFloat32Array()
	field.corridor_mask.resize(count)
	field.wetness = PackedFloat32Array()
	field.wetness.resize(count)
	field.roadness = PackedFloat32Array()
	field.roadness.resize(count)
	field.biome = PackedByteArray()
	field.biome.resize(count)
	field.temperature = PackedFloat32Array()
	field.temperature.resize(count)
	field.ground_color = PackedColorArray()
	field.ground_color.resize(count)
	field.overhang_amp = PackedFloat32Array()
	field.overhang_amp.resize(count)
	field.contract_error = PackedFloat32Array()
	field.contract_error.resize(count)
	field.water_top = PackedFloat32Array()
	field.water_top.resize(count)

	var terrain: MacroTerrain = sector.terrain
	var hydro: Hydrology = sector.hydro
	var voxel: float = field.voxel
	var worst_error: float = 0.0

	for iz in samples_h:
		var wz: float = origin_z + float(iz) * voxel
		var tile_z: int = clampi(int((wz - origin_z) / tile_span), 0, TILE_DIVISIONS - 1)
		for ix in samples_h:
			var wx: float = origin_x + float(ix) * voxel
			var tile_x: int = clampi(int((wx - origin_x) / tile_span), 0, TILE_DIVISIONS - 1)
			var tile: int = tile_z * TILE_DIVISIONS + tile_x

			var height: float = terrain.height_at(wx, wz)
			var amp: float = terrain.relief_amp_at(wx, wz)
			var moisture: float = terrain.moisture_at(wx, wz)
			var temperature: float = terrain.temperature_at(wx, wz)
			var biome: int = BiomeTable.classify(moisture, temperature, height, amp)
			var tint: Color = BiomeTable.ground_color(moisture, temperature, height, amp)
			amp *= BiomeTable.relief_scale(biome)

			# --- nearest channel -------------------------------------------------
			var river_d: float = INF
			var river_edge_d: float = INF
			var river_water_z: float = -INF
			var river_depth: float = 0.0
			var river_valley: float = 1.0
			var river_half: float = 0.0
			for si in river_tiles[tile]:
				var base: int = si
				var ax: float = rivers[base]
				var ay: float = rivers[base + 1]
				var az: float = rivers[base + 2]
				var bx: float = rivers[base + 3]
				var by: float = rivers[base + 4]
				var bz: float = rivers[base + 5]
				var t: float = _segment_param(wx, wz, ax, az, bx, bz)
				var px: float = ax + (bx - ax) * t
				var pz: float = az + (bz - az) * t
				var d: float = sqrt((wx - px) * (wx - px) + (wz - pz) * (wz - pz))
				if d >= river_d:
					continue
				river_d = d
				river_half = lerpf(rivers[base + 6], rivers[base + 7], t)
				river_water_z = ay + (by - ay) * t
				river_depth = rivers[base + 8]
				river_valley = rivers[base + 9]
				river_edge_d = d - river_half

			# --- nearest road ----------------------------------------------------
			var road_d: float = INF
			var road_edge_d: float = INF
			var road_z: float = 0.0
			var road_half: float = 0.0
			for si in road_tiles[tile]:
				var base: int = si
				var ax: float = roads[base]
				var ay: float = roads[base + 1]
				var az: float = roads[base + 2]
				var bx: float = roads[base + 3]
				var by: float = roads[base + 4]
				var bz: float = roads[base + 5]
				var t: float = _segment_param(wx, wz, ax, az, bx, bz)
				var px: float = ax + (bx - ax) * t
				var pz: float = az + (bz - az) * t
				var d: float = sqrt((wx - px) * (wx - px) + (wz - pz) * (wz - pz))
				if d >= road_d:
					continue
				road_d = d
				road_half = roads[base + 6]
				road_z = ay + (by - ay) * t
				road_edge_d = d - road_half

			# --- local lake --------------------------------------------------------
			# A column is under a lake when the land itself sits below the lake's
			# spill height and the drainage surface is above the land (standing
			# water). The old test omitted "land below the spill": any column
			# within two macro cells of a lake whose filled drainage sat a few
			# centimetres above the land - interpolation noise, usually - was
			# carved down to the lake bed and painted with that lower sheet.
			# Next to a higher trunk that reads as the river diving underground
			# into a stepped hole.
			var lake_edge_d: float = hydro.lake_distance_at(wx, wz)
			var lake_surface: float = -INF
			if lake_edge_d <= cfg.macro_cell_size * 2.0:
				var flat: float = hydro.lake_surface_near_at(wx, wz)
				if (
					flat > -INF
					and height < flat
					and hydro.drainage_at(wx, wz) > height
				):
					lake_surface = flat

			# --- ocean and atlas lakes -----------------------------------------------
			# Not a per-sector decision at all: the waterline is the zero of the
			# global signed shoreline function, and its height is the nearest
			# atlas body's own surface. Two sectors sharing a coast read the same
			# function at the same metres, so the shore cannot step at a seam.
			var shore_d: float = continental.shore_distance(wx, wz)
			var atlas_surface: float = -INF
			if shore_d <= 0.0:
				atlas_surface = continental.water_plane_at(wx, wz)

			# --- corridor mask: the drainage-surface contract ---------------------
			var nearest_wet: float = minf(river_edge_d, lake_edge_d)
			nearest_wet = minf(nearest_wet, maxf(shore_d, 0.0))
			var nearest_feature: float = minf(nearest_wet, road_edge_d)
			var mask: float = smoothstep(cfg.corridor_inner, cfg.corridor_outer, nearest_feature)

			var relief: float = _relief_value(noise, wx, wz)
			var surface: float = height + relief * amp * mask

			# --- carve: river bed and banks ---------------------------------------
			var wet: float = 0.0
			var water_top: float = -INF
			# Contract reference: the water surface this column must sit BELOW.
			# Banks are legitimately above water, so only submerged ground counts.
			var submerged_z: float = -INF
			if river_d < river_half + river_valley:
				var depth: float = river_depth * _ford_relief(fords, wx, wz)
				# Sheet height from the draped polyline:
				#   - never above the local continental bed (no floating canal)
				#   - never far below it (no slot canyon that LOD bridges shut)
				#   - then a fixed freeboard so the sheet is not flush with the rim
				# Using the polyline (not per-column height) keeps the sheet
				# level across the channel instead of climbing every bank.
				var draped: float = minf(river_water_z, height)
				draped = maxf(draped, height - MAX_CHORD_BURY)
				var channel_water: float = draped - WATER_FREEBOARD
				if river_d <= river_half:
					var across: float = river_d / maxf(river_half, 0.001)
					# Elliptical bed, but never pinch to zero at the banks. A bed
					# that meets the waterline leaves surface_z == water_top and
					# the water mesh drops the column as dry, which reads as the
					# ground creeping over the river.
					var profile: float = sqrt(maxf(1.0 - across * across, 0.0))
					profile = maxf(profile, 0.4)
					var bed: float = (
						channel_water - maxf(depth * profile, MIN_BED_CLEARANCE)
					)
					surface = minf(surface, bed)
					submerged_z = channel_water
					# Only the channel carries water. Claiming the whole valley
					# would paint the river's level across every lower thing in
					# it, including the lake it is about to join.
					water_top = channel_water
				else:
					var ramp: float = smoothstep(
						0.0, river_valley, river_d - river_half
					)
					# The bank starts just above the water rather than at it.
					# Blending to the water line instead leaves a wide apron of
					# ground within centimetres of the surface, which floods as
					# a shallow pan and reads as foam rather than as a river.
					surface = minf(
						surface, lerpf(channel_water + BANK_RISE, surface, ramp)
					)
				wet = 1.0 - smoothstep(0.0, river_half + 12.0, river_d)

			# --- carve: lake basin --------------------------------------------------
			# The basin already exists in the macro terrain, so this only has to
			# stop detail poking through: anything the drainage says is under
			# water is forced below that lake's own surface. Only cells the flood
			# actually claimed are carved; the shore band merely reports where
			# the water would be if the ground were low enough.
			if lake_surface > -INF:
				# The bed is the macro basin itself, only nudged below the water
				# line. Flattening it to a fixed depth would turn every lake into
				# a shallow tray and every shore into a step.
				surface = minf(
					surface, minf(height, lake_surface) - MIN_BED_CLEARANCE
				)
				water_top = maxf(water_top, lake_surface)
				submerged_z = maxf(submerged_z, lake_surface)
				wet = maxf(wet, smoothstep(0.0, 2.5, lake_surface - height))

			# --- carve: sea and atlas lake basins -------------------------------------
			# The continental surface already sits below the plane wherever the
			# signed shoreline says so; this only stops relief detail poking a
			# 3 m rock through an otherwise flat sea.
			if atlas_surface > -INF:
				surface = minf(
					surface, minf(height, atlas_surface) - MIN_BED_CLEARANCE
				)
				water_top = maxf(water_top, atlas_surface)
				submerged_z = maxf(submerged_z, atlas_surface)
				wet = maxf(wet, smoothstep(0.0, 2.5, atlas_surface - height))

			# --- carve: road bench ---------------------------------------------------
			# Roads both cut and fill, which is the one carve that can raise the
			# ground. It is clamped below any water surface here so an approach
			# embankment can never dam a river it is supposed to ford.
			var roadness: float = 0.0
			if road_d < road_half + 16.0:
				var gap: float = _bridge_gap(bridge_gaps, wx, wz)
				var bench: float = 1.0 - smoothstep(road_half, road_half + 14.0, road_d)
				# Clamp the target the bench is heading for, not the result. The
				# carve has already put the ground under the water here, so a
				# target below the water keeps every point of the interpolation
				# below it too. Clamping afterwards instead leaves ground above
				# the water wherever the bench is only partly applied, and
				# clamping afterwards at full strength drops the ground in one
				# step at the exact metre the road's influence ends, which
				# surface nets meshes as a wall of shards on an invisible circle.
				var bench_z: float = road_z
				if submerged_z > -INF:
					bench_z = minf(road_z, submerged_z - 0.1)
				surface = lerpf(surface, bench_z, bench * (1.0 - gap))
				# The bridge gap holds the bench back so an embankment cannot dam
				# the channel, but the worn earth of the approach runs right up
				# to the abutment. Cutting the dirt too leaves a bridge sitting
				# in untouched grass with no road arriving at it.
				roadness = 1.0 - smoothstep(road_half * 0.6, road_half + 1.6, road_d)

			var error: float = 0.0
			if water_top > -INF:
				field.has_water = true
				field.wet_columns += 1
				# Same predicate WaterSurface uses to decide whether a column is
				# wet. Measuring against submerged_z alone used to call a flush
				# bed (surface == water) a pass, while the mesh dropped it.
				var clearance: float = water_top - surface
				field.min_water_clearance = minf(field.min_water_clearance, clearance)
				var need: float = water_top - MIN_VISIBLE_WATER_CLEARANCE
				error = maxf(surface - need, 0.0)
				if clearance < MIN_VISIBLE_WATER_CLEARANCE:
					field.wet_columns_failing_clearance += 1
				worst_error = maxf(worst_error, error)
			elif submerged_z > -INF:
				# Bank / approach columns that must stay below a nearby water
				# plane without carrying a sheet of their own.
				error = maxf(surface - submerged_z, 0.0)
				worst_error = maxf(worst_error, error)

			var index: int = iz * samples_h + ix
			field.surface_z[index] = surface
			field.corridor_mask[index] = mask
			field.wetness[index] = clampf(wet, 0.0, 1.0)
			field.roadness[index] = clampf(roadness, 0.0, 1.0)
			field.biome[index] = biome
			field.temperature[index] = temperature
			field.ground_color[index] = tint
			# Overhangs are relief too, so they answer to the same corridor mask,
			# squared: an undercut needs more clearance than a bump does. At the
			# edge of a carved bank a half-strength overhang folds the surface
			# back on ground that is already steep, and surface nets turn that
			# into a fan of shards.
			field.overhang_amp[index] = (
				maxf(amp - cfg.relief_amp_plains, 0.0) * cfg.overhang_amount * mask * mask
			)
			field.contract_error[index] = error
			field.water_top[index] = water_top

	field.max_contract_error = worst_error
	_damp_overhangs_on_steep_ground(field, samples_h, voxel)


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


static func _relief_value(noise: NoiseSet, wx: float, wz: float) -> float:
	var ridge: float = noise.relief.get_noise_2d(wx, wz)
	var fine: float = noise.relief_fine.get_noise_2d(wx, wz)
	return ridge * 0.78 + fine * 0.22


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


## Terrain is not benched up to a bridge deck: the span crosses a real gap.
static func _bridge_gap(gaps: PackedVector4Array, wx: float, wz: float) -> float:
	var gap: float = 0.0
	for g in gaps:
		var d: float = Vector2(wx - g.x, wz - g.y).length()
		gap = maxf(gap, 1.0 - smoothstep(g.z * 0.5, g.z * 0.5 + g.w, d))
	return clampf(gap, 0.0, 1.0)


static func _collect_fords(sector: WorldSector, rect: Rect2) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	for site in sector.paths.bridges:
		if not site.is_ford:
			continue
		var center: Vector3 = site.center()
		if rect.has_point(Vector2(center.x, center.z)):
			out.append(Vector3(center.x, center.z, maxf(site.span_length(), 12.0)))
	return out


static func _collect_bridge_gaps(sector: WorldSector, rect: Rect2) -> PackedVector4Array:
	var out: PackedVector4Array = PackedVector4Array()
	for site in sector.paths.bridges:
		if site.is_ford:
			continue
		var center: Vector3 = site.center()
		if rect.has_point(Vector2(center.x, center.z)):
			out.append(Vector4(center.x, center.z, site.span_length(), 6.0))
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
	noise: NoiseSet,
	field: Field,
	samples_h: int,
	origin_x: float,
	origin_z: float
) -> void:
	var voxel: float = field.voxel
	var caves: bool = cfg.cave_enabled and field.lod <= cfg.cave_max_lod

	var lowest: float = INF
	var highest: float = -INF
	var band_max: float = 0.0
	for i in field.surface_z.size():
		var s: float = field.surface_z[i]
		lowest = minf(lowest, s)
		highest = maxf(highest, s)
	band_max = cfg.surface_band + voxel * 2.0

	var y_min: float = lowest - band_max - cfg.vertical_margin
	if caves:
		y_min = minf(y_min, lowest - cfg.cave_bottom_depth - cfg.vertical_margin)
	var y_max: float = highest + band_max + cfg.vertical_margin
	y_min = maxf(floorf(clampf(y_min, cfg.world_floor, cfg.world_ceiling) / voxel) * voxel, cfg.world_floor)
	y_max = minf(ceilf(clampf(y_max, cfg.world_floor, cfg.world_ceiling) / voxel) * voxel, cfg.world_ceiling)

	var samples_y: int = maxi(int(round((y_max - y_min) / voxel)) + 1, 2)
	field.origin = Vector3(origin_x, y_min, origin_z)
	field.dims = Vector3i(samples_h, samples_y, samples_h)

	var values: PackedFloat32Array = PackedFloat32Array()
	values.resize(samples_h * samples_y * samples_h)

	var overhang_noise: FastNoiseLite = noise.overhang
	var cave_a: FastNoiseLite = noise.cave_a
	var cave_b: FastNoiseLite = noise.cave_b
	var cave_threshold: float = cfg.cave_threshold

	for iz in samples_h:
		var wz: float = origin_z + float(iz) * voxel
		for ix in samples_h:
			var wx: float = origin_x + float(ix) * voxel
			var column: int = iz * samples_h + ix
			var surface: float = field.surface_z[column]
			var mask: float = field.corridor_mask[column]
			var water: float = field.water_top[column]

			var overhang_amp: float = field.overhang_amp[column]
			var band: float = overhang_amp + cfg.surface_band * 0.35 + voxel * 2.0

			var cave_allow: bool = caves and mask > 0.35
			var cave_ceiling: float = surface - cfg.cave_top_depth
			var cave_floor: float = surface - cfg.cave_bottom_depth
			if cave_allow and water > -INF:
				cave_ceiling = minf(cave_ceiling, water - cfg.cave_water_clearance)
				if cave_ceiling <= cave_floor:
					cave_allow = false

			var base_index: int = column_base(field, ix, iz)
			for iy in samples_y:
				var wy: float = y_min + float(iy) * voxel
				var base: float = surface - wy
				var value: float = base

				if base > band:
					value = SOLID if base > band + 1.0 else base
				elif base < -band:
					value = AIR if base < -band - 1.0 else base
				elif overhang_amp > 0.05:
					value = base + overhang_noise.get_noise_3d(wx, wy, wz) * overhang_amp

				if cave_allow and wy < cave_ceiling and wy > cave_floor and value > 0.0:
					var ca: float = cave_a.get_noise_3d(wx, wy * 1.65, wz)
					var cb: float = cave_b.get_noise_3d(wx + 411.0, wy * 1.65, wz - 233.0)
					# Two fields near zero at once means a tube, not a blob.
					var tube: float = cave_threshold - sqrt(ca * ca + cb * cb) * 3.4
					if tube > 0.0:
						var taper: float = minf(
							smoothstep(0.0, 6.0, cave_ceiling - wy),
							smoothstep(0.0, 8.0, wy - cave_floor)
						)
						value = (
							minf(value, CAVE_SOLID_CAP) - tube * CAVE_STRENGTH * taper
						)

				values[base_index + iy * samples_h] = value

	field.values = values


static func column_base(field: Field, ix: int, iz: int) -> int:
	return iz * field.dims.y * field.dims.x + ix
