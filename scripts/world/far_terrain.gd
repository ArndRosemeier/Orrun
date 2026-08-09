class_name FarTerrain
extends MeshInstance3D
## The land beyond the streaming ring.
##
## Chunks only exist for about a kilometre around the player, which is enough to
## walk on and nowhere near enough to look at: a mountain range reads as a range
## because you can see it from the next valley. This is one static mesh built
## from the macro grid at bake time, covering the whole map at a resolution no
## chunk would ever use, drawn under everything the streamer produces.
##
## It is a backdrop, not a surface. Nothing collides with it and nothing stands
## on it; it sits slightly below the real ground so a loaded chunk always wins.

## Metres the backdrop is sunk below the macro surface. Enough that coarse
## sampling never pokes through a real chunk, small enough that the step at the
## edge of the loaded ring stays under the fog.
const DROP: float = 3.0
## Macro cells per backdrop quad. 4 gives ~128 m quads and ~18k triangles for a
## 12 km map, which costs nothing and still holds a ridge line.
const STRIDE: int = 4


static func create(cfg: WorldConfig, map: WorldMap, material: Material) -> FarTerrain:
	var node: FarTerrain = FarTerrain.new()
	node.name = "FarTerrain"
	node.mesh = _build(cfg, map, material)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Always behind the streamed chunks in the sort order, and never culled by
	# the ring: it is the horizon.
	node.extra_cull_margin = 16384.0
	return node


func refresh_transform() -> void:
	position = WorldOrigin.to_scene(Vector3.ZERO)


static func _build(cfg: WorldConfig, map: WorldMap, material: Material) -> ArrayMesh:
	var terrain: MacroTerrain = map.terrain
	var hydro: Hydrology = map.hydro
	var span: int = terrain.cells / STRIDE
	var side: int = span + 1
	var step: float = cfg.macro_cell_size * float(STRIDE)

	var vertices: PackedVector3Array = PackedVector3Array()
	vertices.resize(side * side)
	var colors: PackedColorArray = PackedColorArray()
	colors.resize(side * side)
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(side * side)

	for iz in side:
		var wz: float = float(iz) * step
		for ix in side:
			var wx: float = float(ix) * step
			var height: float = terrain.height_at(wx, wz)
			var cell: Vector2i = WorldCoords.macro_cell_of(cfg, wx, wz)
			var lake: int = hydro.lake_id[cell.y * terrain.cells + cell.x]
			var index: int = iz * side + ix

			heights[index] = height
			vertices[index] = Vector3(wx, height - DROP, wz)
			colors[index] = _tint(terrain, wx, wz, height, lake != -1)

	var normals: PackedVector3Array = PackedVector3Array()
	normals.resize(side * side)
	for iz in side:
		for ix in side:
			var index: int = iz * side + ix
			var west: float = heights[iz * side + maxi(ix - 1, 0)]
			var east: float = heights[iz * side + mini(ix + 1, side - 1)]
			var north: float = heights[maxi(iz - 1, 0) * side + ix]
			var south: float = heights[mini(iz + 1, side - 1) * side + ix]
			normals[index] = Vector3(west - east, step * 2.0, north - south).normalized()

	var indices: PackedInt32Array = PackedInt32Array()
	indices.resize(span * span * 6)
	var cursor: int = 0
	for iz in span:
		for ix in span:
			var v00: int = iz * side + ix
			var v10: int = v00 + 1
			var v01: int = v00 + side
			var v11: int = v01 + 1
			# Front faces point at the sky. Wound the other way the whole backdrop
			# is culled except the slopes that happen to face away, which reads as
			# a world with its lowlands missing.
			indices[cursor] = v00
			indices[cursor + 1] = v10
			indices[cursor + 2] = v11
			indices[cursor + 3] = v00
			indices[cursor + 4] = v11
			indices[cursor + 5] = v01
			cursor += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = _flat_uvs(side * side)
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


## The corridor mask channel is meaningless out here, so it reads as unmasked.
static func _flat_uvs(count: int) -> PackedVector2Array:
	var uvs: PackedVector2Array = PackedVector2Array()
	uvs.resize(count)
	for i in count:
		uvs[i] = Vector2.ONE
	return uvs


static func _tint(
	terrain: MacroTerrain, wx: float, wz: float, height: float, flooded: bool
) -> Color:
	var moisture: float = terrain.moisture_at(wx, wz)
	var temperature: float = terrain.temperature_at(wx, wz)
	var relief: float = terrain.relief_amp_at(wx, wz)
	var ground: Color = BiomeTable.ground_color(moisture, temperature, height, relief)
	# No water mesh reaches this far, so a distant lake has to be a colour. It
	# has to be an actual lake, too: the depression-filled drainage stands a few
	# centimetres over every flat lowland, and colouring by that floods half the
	# map with a sea that does not exist.
	if flooded:
		ground = BiomeTable.DISTANT_WATER
	var snow_line: float = 640.0 + temperature * 260.0
	if height > snow_line:
		ground = ground.lerp(
			BiomeTable.SNOW, smoothstep(snow_line, snow_line + 130.0, height)
		)
	return ground
