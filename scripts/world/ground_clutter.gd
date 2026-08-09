class_name GroundClutter
extends RefCounted
## Close-range ground cover (grass tufts). Separate from PropPlacer so spacing
## can be denser and weights can key off wetness / slope without competing with
## trees and boulders.
##
## Placement rules (by design, not just "humidity"):
## - hard skip: water, roads, steep rock, settlement cores
## - wetness mid → lush tufts; dry → dry tufts; very wet mud → sparse only
## - biome weights for plains / forest vs alpine / badlands
##
## Sampling is a world-space square lattice rotated off the axes, with one
## uniform hash sample per cell. Chunk-local grids stripe along X/Z; hex grids
## with partial jitter still read as parallel aisles; sin-hashes stripe on
## diagonals. Full-cell jitter + an integer hash removes the lattice look.

const CATALOG_PATH: String = "res://assets/catalog/clutter.json"
const WATERLINE_MARGIN: float = 0.2
const MIN_UPNESS: float = 0.78
const ROAD_CLEARANCE: float = 2.2
## Fixed yaw for the sampling lattice (~37°). Shared by every chunk so seams
## stay continuous and stripes never lock to world axes.
const LATTICE_YAW: float = 0.645772
## Keep probability after lattice points — thins cover without reintroducing rows.
const KEEP_FRACTION: float = 0.78


class Spec extends RefCounted:
	var id: StringName = &""
	var min_scale: float = 0.75
	var max_scale: float = 1.25
	## Ideal wetness centre (0 dry … 1 shoreline mud).
	var wet_center: float = 0.25
	var wet_sigma: float = 0.28
	var biome_weight: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var density: float = 0.55


static func load_specs(path: String = CATALOG_PATH) -> Array[Spec]:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	assert(file != null, "Clutter catalog missing at %s" % path)
	var root: Dictionary = JSON.parse_string(file.get_as_text())
	var specs: Array[Spec] = []
	for entry_variant in root["clutter"]:
		var entry: Dictionary = entry_variant
		var spec: Spec = Spec.new()
		spec.id = StringName(entry["id"])
		spec.min_scale = float(entry["min_scale"])
		spec.max_scale = float(entry["max_scale"])
		spec.wet_center = float(entry["wet_center"])
		spec.wet_sigma = float(entry["wet_sigma"])
		spec.density = float(entry["density"])
		var biomes: Dictionary = entry["biomes"]
		spec.biome_weight = PackedFloat32Array([
			float(biomes["plains"]), float(biomes["forest_hills"]),
			float(biomes["rocky_badlands"]), float(biomes["alpine"]),
		])
		specs.append(spec)
	return specs


static func mesh_sources(path: String = CATALOG_PATH) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	assert(file != null, "Clutter catalog missing at %s" % path)
	var root: Dictionary = JSON.parse_string(file.get_as_text())
	var sources: Dictionary = {}
	for entry_variant in root["clutter"]:
		var entry: Dictionary = entry_variant
		sources[StringName(entry["id"])] = String(entry["source"])
	return sources


## Returns clutter id -> Array[Transform3D] in chunk-local space.
static func place(
	config: WorldConfig,
	specs: Array[Spec],
	field: DensityField.Field,
	region: RegionData,
	claims: ClaimMask,
	chunk_origin: Vector2
) -> Dictionary:
	var result: Dictionary = {}
	if specs.is_empty() or not config.props_enabled:
		return result

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = config.layer_seed("clutter") ^ WorldCoords.chunk_key(field.chunk)

	# Slightly denser than the old hex step so full-cell jitter + keep still
	# reads as a filled meadow.
	var spacing: float = maxf(config.prop_spacing * 0.13, 0.9)
	var ca: float = cos(LATTICE_YAW)
	var sa: float = sin(LATTICE_YAW)

	var origin_x: float = chunk_origin.x
	var origin_z: float = chunk_origin.y
	var size: float = config.chunk_size
	var x1: float = origin_x + size
	var z1: float = origin_z + size

	# Inverse-rotate chunk corners into lattice UV to get index bounds.
	var min_u: float = INF
	var max_u: float = -INF
	var min_v: float = INF
	var max_v: float = -INF
	for corner in [
		Vector2(origin_x, origin_z),
		Vector2(x1, origin_z),
		Vector2(origin_x, z1),
		Vector2(x1, z1),
	]:
		var u: float = corner.x * ca + corner.y * sa
		var v: float = -corner.x * sa + corner.y * ca
		min_u = minf(min_u, u)
		max_u = maxf(max_u, u)
		min_v = minf(min_v, v)
		max_v = maxf(max_v, v)

	var i0: int = floori(min_u / spacing) - 1
	var i1: int = ceili(max_u / spacing) + 1
	var j0: int = floori(min_v / spacing) - 1
	var j1: int = ceili(max_v / spacing) + 1

	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			# One uniform sample per cell (not centred jitter). Neighbouring
			# chunks share the same (i,j) → same world point on the boundary.
			var u: float = (float(i) + _hash01(i, j, 1)) * spacing
			var v: float = (float(j) + _hash01(i, j, 2)) * spacing
			var world_x: float = u * ca - v * sa
			var world_z: float = u * sa + v * ca
			if world_x < origin_x or world_z < origin_z or world_x >= x1 or world_z >= z1:
				continue
			if _hash01(i, j, 3) > KEEP_FRACTION:
				continue

			var local_x: float = world_x - origin_x
			var local_z: float = world_z - origin_z

			var hit: Vector2 = PropPlacer._surface_hit(field, world_x, world_z)
			if hit.y < 0.5:
				continue
			var surface_y: float = hit.x
			var column: int = PropPlacer.column_of(field, world_x, world_z)
			if field.water_top[column] > surface_y - WATERLINE_MARGIN:
				continue

			var wetness: float = field.wetness[column]
			# Standing-mud shore: leave bare or nearly bare.
			if wetness > 0.82:
				continue

			var normal: Vector3 = PropPlacer._surface_normal(
				field, world_x, world_z, surface_y
			)
			if normal.y < MIN_UPNESS:
				continue

			var road_d: float = PropPlacer._road_distance(region, world_x, world_z)
			if road_d < ROAD_CLEARANCE:
				continue

			var reserved: float = claims.reservation_depth(world_x, world_z)
			# Clear village greens harder than forest props do.
			if reserved > 0.0 and rng.randf() < smoothstep(0.0, 0.4, reserved):
				continue

			var biome: int = field.biome[column]
			var mask: float = field.corridor_mask[column]
			# Drainage corridors stay thinner — banks already read via wetness.
			var cover: float = clampf(mask * 0.55 + 0.45, 0.0, 1.0)

			var spec: Spec = _pick(specs, biome, wetness, cover, normal.y, rng)
			if spec == null:
				continue

			var scale: float = rng.randf_range(spec.min_scale, spec.max_scale)
			var yaw: float = rng.randf_range(0.0, TAU)
			var basis: Basis = Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale)
			var list: Array = result.get(spec.id, [])
			list.append(Transform3D(basis, Vector3(local_x, surface_y, local_z)))
			result[spec.id] = list

	return result


static func _hash01(ix: int, iz: int, salt: int) -> float:
	# Integer mix — sin(ax+bz) hashes stripe along diagonals and were visible
	# in the keep mask as foliage aisles.
	var n: int = ix * 374761393 + iz * 668265263 + salt * 362437991
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / float(0x7fffffff)


static func _pick(
	specs: Array[Spec],
	biome: int,
	wetness: float,
	cover: float,
	upness: float,
	rng: RandomNumberGenerator
) -> Spec:
	var total: float = 0.0
	var weights: PackedFloat32Array = PackedFloat32Array()
	weights.resize(specs.size())
	for i in specs.size():
		var spec: Spec = specs[i]
		var biome_w: float = spec.biome_weight[clampi(biome, 0, 3)]
		var wet_w: float = _wet_weight(wetness, spec.wet_center, spec.wet_sigma)
		var slope_w: float = clampf((upness - 0.72) * 4.0, 0.0, 1.0)
		var weight: float = biome_w * spec.density * wet_w * slope_w * cover
		weights[i] = weight
		total += weight

	if total <= 0.0001:
		return null
	# Leave some gaps, but plains with high weight should nearly fill the cell.
	if rng.randf() > minf(total, 1.45):
		return null
	var cursor: float = 0.0
	var pick: float = rng.randf() * total
	for i in specs.size():
		cursor += weights[i]
		if pick <= cursor:
			return specs[i]
	return null


static func _wet_weight(wetness: float, center: float, sigma: float) -> float:
	var d: float = (wetness - center) / maxf(sigma, 0.05)
	return exp(-0.5 * d * d)
