class_name FarTerrain
extends MeshInstance3D
## The land beyond the streaming ring.
##
## Chunks only exist for about a kilometre around the player, which is enough to
## walk on and nowhere near enough to look at: a mountain range reads as a range
## because you can see it from the next valley.
##
## There is no finite map to bake a backdrop for any more, so this is a moving
## patch instead: a coarse grid re-sampled from the same continental terrain
## function the chunks use, recentred whenever the player crosses into a new
## sector. Because it reads that function and not a separate approximation, the
## horizon and the ground under your feet are the same landscape.
##
## It is a backdrop, not a surface. Nothing collides with it and nothing stands
## on it. Two rules keep it from fighting near chunks:
##
##   1. Under the streamed Chebyshev ring the plate is dropped to
##      [member WorldConfig.world_floor], so a carved river trench cannot reveal
##      a green chord sitting above the bed.
##   2. Outside that ring, atlas trunks dent and tint the coarse grid so a
##      valley between two 256 m samples is not bridged at bank height.

## Metres the backdrop is sunk below the continental surface outside the hole.
## Small enough that the step at the edge of the streamed ring stays under fog.
const DROP: float = 3.0
## Metres below atlas water_z a far-sample sits when claimed by a trunk outside
## the hole. Must clear a high-order channel bed (depth + freeboard) so the
## horizon ribbon cannot ride above real water either.
const RIVER_SINK: float = 8.0
## Metres the patch spans, and how many quads across. 256 m quads hold a ridge
## line and cost nothing.
const SPAN: float = 24576.0
const QUADS: int = 96


class Patch extends RefCounted:
	var centre: Vector2 = Vector2.ZERO
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()


var centre: Vector2 = Vector2.ZERO
var _material: Material
var _has_patch: bool = false


static func create(material: Material) -> FarTerrain:
	var node: FarTerrain = FarTerrain.new()
	node.name = "FarTerrain"
	node._material = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Always behind the streamed chunks in the sort order, and never culled by
	# the ring: it is the horizon.
	node.extra_cull_margin = SPAN
	return node


func has_patch() -> bool:
	return _has_patch


## True when the player has walked far enough that the patch should recentre.
## Half a sector of slack keeps this from rebuilding every time they step back
## and forth across a boundary.
func needs_recentre(at: Vector2) -> bool:
	if not _has_patch:
		return true
	return at.distance_to(centre) > WorldCoords.SECTOR_SIZE * 0.5


func apply(patch: Patch) -> void:
	centre = patch.centre
	_has_patch = true

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = patch.vertices
	arrays[Mesh.ARRAY_NORMAL] = patch.normals
	arrays[Mesh.ARRAY_COLOR] = patch.colors
	arrays[Mesh.ARRAY_TEX_UV] = patch.uvs
	arrays[Mesh.ARRAY_INDEX] = patch.indices

	var built: ArrayMesh = ArrayMesh.new()
	built.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	built.surface_set_material(0, _material)
	mesh = built
	refresh_transform()


func refresh_transform() -> void:
	# Resolved at call time so this script still compiles under bare --script
	# tests that do not boot project autoloads.
	var origin: Node = get_tree().root.get_node_or_null("WorldOrigin")
	if origin == null:
		position = Vector3.ZERO
		return
	position = origin.call("to_scene", Vector3.ZERO) as Vector3


## Chebyshev half-extent of the streamed ring, plus one chunk of slack so the
## last LOD does not sit on a FarTerrain seam.
static func near_hole_half_extent(config: WorldConfig) -> float:
	var rings: int = int(config.lod_radius[config.lod_radius.size() - 1])
	return (float(rings) + 1.0) * config.chunk_size


## Builds one patch. Safe on a worker thread: it only reads the shared context
## and the sampler it makes for itself.
static func build_patch(
	context: WorldContext, continental: ContinentalTerrain, at: Vector2
) -> Patch:
	var patch: Patch = Patch.new()
	var step: float = SPAN / float(QUADS)
	# Snapped so the patch does not shimmer as it recentres.
	patch.centre = Vector2(
		floorf(at.x / step) * step, floorf(at.y / step) * step
	)
	var origin: Vector2 = patch.centre - Vector2.ONE * (SPAN * 0.5)
	var side: int = QUADS + 1
	var count: int = side * side
	var hole: float = near_hole_half_extent(context.config)

	patch.vertices.resize(count)
	patch.normals.resize(count)
	patch.colors.resize(count)
	patch.uvs.resize(count)
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(count)

	for iz in side:
		var wz: float = origin.y + float(iz) * step
		for ix in side:
			var wx: float = origin.x + float(ix) * step
			var index: int = iz * side + ix
			var sample: Dictionary = sample_column(
				context, continental, wx, wz, step, at, hole
			)
			var height: float = float(sample["height"])
			var flooded: bool = bool(sample["flooded"])
			heights[index] = height
			# Inside the hole height is already world_floor; DROP would dig
			# past the configured floor for no benefit.
			var draw_y: float = (
				height if bool(sample["in_hole"]) else height - DROP
			)
			patch.vertices[index] = Vector3(wx, draw_y, wz)
			patch.colors[index] = _tint(continental, wx, wz, height, flooded)
			# The corridor mask channel is meaningless out here, so it reads as
			# unmasked.
			patch.uvs[index] = Vector2.ONE

	for iz in side:
		for ix in side:
			var index: int = iz * side + ix
			var west: float = heights[iz * side + maxi(ix - 1, 0)]
			var east: float = heights[iz * side + mini(ix + 1, side - 1)]
			var north: float = heights[maxi(iz - 1, 0) * side + ix]
			var south: float = heights[mini(iz + 1, side - 1) * side + ix]
			patch.normals[index] = Vector3(
				west - east, step * 2.0, north - south
			).normalized()

	patch.indices.resize(QUADS * QUADS * 6)
	var cursor: int = 0
	for iz in QUADS:
		for ix in QUADS:
			var v00: int = iz * side + ix
			var v10: int = v00 + 1
			var v01: int = v00 + side
			var v11: int = v01 + 1
			# Front faces point at the sky. Wound the other way the whole backdrop
			# is culled except the slopes that happen to face away, which reads as
			# a world with its lowlands missing.
			patch.indices[cursor] = v00
			patch.indices[cursor + 1] = v10
			patch.indices[cursor + 2] = v11
			patch.indices[cursor + 3] = v00
			patch.indices[cursor + 4] = v11
			patch.indices[cursor + 5] = v01
			cursor += 6
	return patch


## Authoritative far-column height and flood flag, including the near-ring hole
## and the coarse-grid river dent.
static func sample_column(
	context: WorldContext,
	continental: ContinentalTerrain,
	world_x: float,
	world_z: float,
	step: float = SPAN / float(QUADS),
	hole_centre: Vector2 = Vector2(INF, INF),
	hole_extent: float = 0.0
) -> Dictionary:
	if (
		hole_extent > 0.0
		and maxf(absf(world_x - hole_centre.x), absf(world_z - hole_centre.y))
		<= hole_extent
	):
		return {
			"height": context.config.world_floor,
			"flooded": false,
			"in_hole": true,
		}

	var height: float = continental.height_at(world_x, world_z)
	var flooded: bool = continental.shore_signed(world_x, world_z) <= 0.0
	if flooded:
		height = minf(height, continental.water_plane_at(world_x, world_z))

	var corridors: AtlasCorridors = context.corridors
	var reach: float = corridors.max_valley_radius + step
	var rect: Rect2 = Rect2(
		world_x - reach, world_z - reach, reach * 2.0, reach * 2.0
	)
	for base in corridors.rivers_in_rect(rect):
		var ax: float = corridors.rivers[base]
		var ay: float = corridors.rivers[base + 1]
		var az: float = corridors.rivers[base + 2]
		var bx: float = corridors.rivers[base + 3]
		var by: float = corridors.rivers[base + 4]
		var bz: float = corridors.rivers[base + 5]
		var feature_class: int = int(corridors.rivers[base + 8])
		var half: float = corridors.river_half_width(feature_class)
		var valley: float = corridors.river_valley_radius(feature_class)
		var abx: float = bx - ax
		var abz: float = bz - az
		var len_sq: float = abx * abx + abz * abz
		var t: float = 0.0
		if len_sq > 0.000001:
			t = clampf(
				((world_x - ax) * abx + (world_z - az) * abz) / len_sq, 0.0, 1.0
			)
		var px: float = ax + abx * t
		var pz: float = az + abz * t
		var d: float = Vector2(world_x - px, world_z - pz).length()
		# One far-texel past the valley so a trunk that slips between samples
		# still dents the plate instead of being bridged at bank height.
		var influence: float = valley + step
		if d >= influence:
			continue
		var water_z: float = lerpf(ay, by, t)
		var floor_z: float = water_z - RIVER_SINK
		var ramp: float = smoothstep(0.0, influence, d)
		height = minf(height, lerpf(floor_z, height, ramp))
		# Widen the water tint by half a texel so the ribbon stays visible on
		# the coarse grid instead of collapsing to a single green sample.
		if d <= half + step * 0.5:
			flooded = true

	return {"height": height, "flooded": flooded, "in_hole": false}


## Drawn height of the backdrop at a point.
static func surface_y_at(
	context: WorldContext,
	continental: ContinentalTerrain,
	world_x: float,
	world_z: float,
	step: float = SPAN / float(QUADS),
	hole_centre: Vector2 = Vector2(INF, INF),
	hole_extent: float = 0.0
) -> float:
	var sample: Dictionary = sample_column(
		context, continental, world_x, world_z, step, hole_centre, hole_extent
	)
	if bool(sample["in_hole"]):
		return float(sample["height"])
	return float(sample["height"]) - DROP


static func _tint(
	continental: ContinentalTerrain, wx: float, wz: float, height: float, flooded: bool
) -> Color:
	var moisture: float = continental.moisture_at(wx, wz)
	var temperature: float = continental.temperature_for(wx, wz, height)
	var relief: float = continental.relief_amp_at(wx, wz)
	var ground: Color = BiomeTable.ground_color(moisture, temperature, height, relief)
	# No water mesh reaches this far, so a distant sea or lake has to be a
	# colour. It has to be real water, too: colouring by the drainage surface
	# floods every flat lowland with a sea that does not exist. Atlas trunks
	# get the same treatment so a coarse chord cannot read as a green bridge.
	if flooded:
		ground = BiomeTable.DISTANT_WATER
	var snow_line: float = 640.0 + temperature * 260.0
	if height > snow_line:
		ground = ground.lerp(
			BiomeTable.SNOW, smoothstep(snow_line, snow_line + 130.0, height)
		)
	return ground
