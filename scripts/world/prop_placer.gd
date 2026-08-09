class_name PropPlacer
extends RefCounted
## Scatters Asset Lab meshes over a finished chunk.
##
## Placement reads the density field that was just built, not the macro height,
## so props land on the surface the player actually walks on - including the top
## of an overhang. Water, road corridors and reserved claims are left clear.

## Metres of dry ground a prop needs above the waterline before it may stand.
const WATERLINE_MARGIN: float = 0.25


class PropSpec extends RefCounted:
	var id: StringName = &""
	var footprint: float = 1.0
	var max_slope_deg: float = 35.0
	var min_scale: float = 1.0
	var max_scale: float = 1.0
	var avoid_water: float = 1.0
	var clearance_road: float = 3.0
	var density: float = 0.5
	var biome_weight: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])


static func load_specs(catalog_path: String) -> Array[PropSpec]:
	var file: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	assert(file != null, "Prop catalog missing at %s" % catalog_path)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary, "Prop catalog is not a JSON object")
	var root: Dictionary = parsed

	var specs: Array[PropSpec] = []
	for entry_variant in root["props"]:
		var entry: Dictionary = entry_variant
		var spec: PropSpec = PropSpec.new()
		spec.id = StringName(entry["id"])
		spec.footprint = float(entry["footprint"])
		spec.max_slope_deg = float(entry["max_slope_deg"])
		spec.min_scale = float(entry["min_scale"])
		spec.max_scale = float(entry["max_scale"])
		spec.avoid_water = float(entry["avoid_water"])
		spec.clearance_road = float(entry["clearance_road"])
		spec.density = float(entry["density"])
		var biomes: Dictionary = entry["biomes"]
		spec.biome_weight = PackedFloat32Array([
			float(biomes["plains"]), float(biomes["forest_hills"]),
			float(biomes["rocky_badlands"]), float(biomes["alpine"]),
		])
		specs.append(spec)
	return specs


## Returns prop id -> Array[Transform3D], in chunk-local space.
static func place(
	config: WorldConfig,
	specs: Array[PropSpec],
	field: DensityField.Field,
	region: RegionData,
	claims: ClaimMask,
	chunk_origin: Vector2
) -> Dictionary:
	var result: Dictionary = {}
	if specs.is_empty():
		return result

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = config.layer_seed("props") ^ WorldCoords.chunk_key(field.chunk)

	var steps: int = maxi(int(config.chunk_size / config.prop_spacing), 1)
	var step: float = config.chunk_size / float(steps)
	var max_slope: float = cos(deg_to_rad(config.prop_max_slope_deg))

	for gz in steps:
		for gx in steps:
			var local_x: float = (float(gx) + rng.randf()) * step
			var local_z: float = (float(gz) + rng.randf()) * step
			var world_x: float = chunk_origin.x + local_x
			var world_z: float = chunk_origin.y + local_z

			var hit: Vector2 = _surface_hit(field, world_x, world_z)
			if hit.y < 0.5:
				continue
			var surface_y: float = hit.x

			var column: int = column_of(field, world_x, world_z)
			# Nothing stands in a river. Wetness only thins a shoreline out;
			# the water surface itself is a hard boundary, and a pine growing
			# out of a lake is the single loudest way to lose the illusion.
			# WaterSurface also pulls dry corners of a wet quad up to the sheet,
			# so a neighbour column under water is enough to put a trunk in the
			# visible pond even when this sample stayed dry.
			if _flooded_at(field, column, surface_y):
				continue
			var wetness: float = field.wetness[column]
			var mask: float = field.corridor_mask[column]
			var biome: int = field.biome[column]

			var normal: Vector3 = _surface_normal(field, world_x, world_z, surface_y)
			if normal.y < max_slope:
				continue
			# A reservation clears its core and thins its margin. Rejecting on
			# the radius alone leaves a bare disc inside a ring of trees, which
			# reads as a crop circle rather than as a clearing.
			var reserved: float = claims.reservation_depth(world_x, world_z)
			if reserved > 0.0 and rng.randf() < smoothstep(0.0, 0.55, reserved):
				continue
			if _road_distance(region, world_x, world_z) < 0.0:
				continue

			var spec: PropSpec = _pick(specs, biome, wetness, mask, normal.y, rng)
			if spec == null:
				continue
			if _road_distance(region, world_x, world_z) < spec.clearance_road:
				continue

			var scale: float = rng.randf_range(spec.min_scale, spec.max_scale)
			var basis: Basis = Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
				Vector3.ONE * scale
			)
			var transform: Transform3D = Transform3D(
				basis, Vector3(local_x, surface_y, local_z)
			)

			var list: Array = result.get(spec.id, [])
			list.append(transform)
			result[spec.id] = list

	return result


static func _pick(
	specs: Array[PropSpec],
	biome: int,
	wetness: float,
	mask: float,
	upness: float,
	rng: RandomNumberGenerator
) -> PropSpec:
	var total: float = 0.0
	var weights: PackedFloat32Array = PackedFloat32Array()
	weights.resize(specs.size())
	for i in specs.size():
		var spec: PropSpec = specs[i]
		var weight: float = spec.biome_weight[clampi(biome, 0, 3)] * spec.density
		# Wet ground and road corridors thin out, they do not hard-stop, so the
		# edges of a river bank still look inhabited.
		weight *= clampf(1.0 - wetness * spec.avoid_water, 0.0, 1.0)
		weight *= mask
		weight *= clampf((upness - 0.5) * 2.0, 0.0, 1.0)
		weights[i] = weight
		total += weight

	if total <= 0.0001:
		return null
	# The gap between total weight and 1.0 is empty ground: without it every
	# candidate point would spawn something and the world would be a carpet.
	var roll: float = rng.randf()
	if roll > total:
		return null
	var cursor: float = 0.0
	for i in specs.size():
		cursor += weights[i]
		if roll <= cursor:
			return specs[i]
	return null


## Highest solid-to-air transition in a column: the top of an overhang if there
## is one, otherwise the plain ground surface. Returns (height, found).
static func _surface_hit(field: DensityField.Field, world_x: float, world_z: float) -> Vector2:
	var ix: int = clampi(
		int(round((world_x - field.origin.x) / field.voxel)), 0, field.dims.x - 1
	)
	var iz: int = clampi(
		int(round((world_z - field.origin.z) / field.voxel)), 0, field.dims.z - 1
	)
	for iy in range(field.dims.y - 2, 0, -1):
		var here: float = field.values[(iz * field.dims.y + iy) * field.dims.x + ix]
		var above: float = field.values[(iz * field.dims.y + iy + 1) * field.dims.x + ix]
		if here >= 0.0 and above < 0.0:
			var t: float = here / maxf(here - above, 0.0001)
			return Vector2(field.origin.y + (float(iy) + t) * field.voxel, 1.0)
	return Vector2(0.0, 0.0)


static func _flooded_at(
	field: DensityField.Field, column: int, surface_y: float
) -> bool:
	var samples: int = field.dims.x
	var ix: int = column % samples
	var iz: int = int(column / samples)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var nx: int = ix + dx
			var nz: int = iz + dz
			if nx < 0 or nz < 0 or nx >= samples or nz >= field.dims.z:
				continue
			var top: float = field.water_top[nz * samples + nx]
			if top > surface_y - WATERLINE_MARGIN:
				return true
	return false


static func column_of(field: DensityField.Field, world_x: float, world_z: float) -> int:
	var ix: int = clampi(
		int(round((world_x - field.origin.x) / field.voxel)), 0, field.dims.x - 1
	)
	var iz: int = clampi(
		int(round((world_z - field.origin.z) / field.voxel)), 0, field.dims.z - 1
	)
	return iz * field.dims.x + ix


static func _surface_normal(
	field: DensityField.Field, world_x: float, world_z: float, surface_y: float
) -> Vector3:
	var step: float = field.voxel
	var east: Vector2 = _surface_hit(field, world_x + step, world_z)
	var west: Vector2 = _surface_hit(field, world_x - step, world_z)
	var south: Vector2 = _surface_hit(field, world_x, world_z + step)
	var north: Vector2 = _surface_hit(field, world_x, world_z - step)
	var dx: float = (
		(east.x if east.y > 0.5 else surface_y) - (west.x if west.y > 0.5 else surface_y)
	) / (2.0 * step)
	var dz: float = (
		(south.x if south.y > 0.5 else surface_y) - (north.x if north.y > 0.5 else surface_y)
	) / (2.0 * step)
	return Vector3(-dx, 1.0, -dz).normalized()


## Distance to the nearest road centre minus its half width; negative means the
## point is on the carriageway itself.
static func _road_distance(region: RegionData, world_x: float, world_z: float) -> float:
	var best: float = 1000.0
	var point: Vector2 = Vector2(world_x, world_z)
	for road in region.roads:
		if not road.bounds.grow(24.0).has_point(point):
			continue
		for i in range(road.points.size() - 1):
			var a: Vector3 = road.points[i]
			var b: Vector3 = road.points[i + 1]
			var ab: Vector2 = Vector2(b.x - a.x, b.z - a.z)
			var len_sq: float = ab.length_squared()
			var t: float = 0.0
			if len_sq > 0.000001:
				t = clampf(Vector2(world_x - a.x, world_z - a.z).dot(ab) / len_sq, 0.0, 1.0)
			var on_road: Vector2 = Vector2(a.x, a.z) + ab * t
			best = minf(best, on_road.distance_to(point) - road.half_width)
	return best
