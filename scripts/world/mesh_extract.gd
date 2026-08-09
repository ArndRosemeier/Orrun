class_name MeshExtract
extends RefCounted
## Surface nets over the density field: one vertex per cell that straddles the
## isosurface, placed at the average of its edge crossings.
##
## Dual contouring style extraction is what lets the world have overhangs and
## caves at all - a heightmap grid cannot produce either. Neighbouring chunks
## sample the same global grid and each owns a disjoint set of edges, so the
## seams line up exactly instead of cracking.

static var CORNER_OFFSET: Array[Vector3i] = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]
static var EDGE_CORNERS: Array[Vector2i] = [
	Vector2i(0, 1), Vector2i(2, 3), Vector2i(4, 5), Vector2i(6, 7),
	Vector2i(0, 2), Vector2i(1, 3), Vector2i(4, 6), Vector2i(5, 7),
	Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
]

const SKIRT_DEPTH_FACTOR: float = 0.75


class MeshData extends RefCounted:
	## Vertices are local to the chunk column origin (world XZ minus chunk
	## origin); Y stays absolute so heights are directly comparable.
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	## UV.x is the corridor mask, UV.y the wetness. Vertex alpha would be the
	## obvious place for them, but a mesh vertex colour with a zero alpha comes
	## out of the renderer black, which silently destroys the ground tint.
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var collision_faces: PackedVector3Array = PackedVector3Array()
	var aabb: AABB = AABB()
	## Triangles belonging to the isosurface itself, before the LOD skirt was
	## appended. A chunk that is mostly skirt has failed to mesh its ground.
	var surface_triangles: int = 0

	func is_empty() -> bool:
		return indices.is_empty()


static func build(
	field: DensityField.Field,
	chunk_origin: Vector2,
	want_collision: bool,
	want_skirts: bool = true
) -> MeshData:
	var data: MeshData = MeshData.new()
	var dims: Vector3i = field.dims
	var voxel: float = field.voxel
	var values: PackedFloat32Array = field.values

	var cells: Vector3i = Vector3i(dims.x - 1, dims.y - 1, dims.z - 1)
	var cell_vertex: PackedInt32Array = PackedInt32Array()
	cell_vertex.resize(cells.x * cells.y * cells.z)
	for i in cell_vertex.size():
		cell_vertex[i] = -1

	var local_origin: Vector3 = field.origin - Vector3(chunk_origin.x, 0.0, chunk_origin.y)

	var min_v: Vector3 = Vector3.INF
	var max_v: Vector3 = -Vector3.INF

	# --- vertices ---------------------------------------------------------------
	for cz in cells.z:
		for cy in cells.y:
			for cx in cells.x:
				var corner: PackedFloat32Array = PackedFloat32Array()
				corner.resize(8)
				var negative: int = 0
				for c in 8:
					var o: Vector3i = CORNER_OFFSET[c]
					var v: float = values[
						((cz + o.z) * dims.y + (cy + o.y)) * dims.x + (cx + o.x)
					]
					corner[c] = v
					if v < 0.0:
						negative += 1
				if negative == 0 or negative == 8:
					continue

				var sum: Vector3 = Vector3.ZERO
				var crossings: int = 0
				for e in 12:
					var pair: Vector2i = EDGE_CORNERS[e]
					var a: float = corner[pair.x]
					var b: float = corner[pair.y]
					if (a < 0.0) == (b < 0.0):
						continue
					var t: float = a / (a - b)
					var pa: Vector3i = CORNER_OFFSET[pair.x]
					var pb: Vector3i = CORNER_OFFSET[pair.y]
					sum += Vector3(pa) + (Vector3(pb) - Vector3(pa)) * t
					crossings += 1

				var local: Vector3 = sum / float(crossings)
				var position: Vector3 = local_origin + (Vector3(
					float(cx), float(cy), float(cz)
				) + local) * voxel

				var normal: Vector3 = _gradient(values, dims, cx, cy, cz)
				var column: int = mini(cz, dims.z - 1) * dims.x + mini(cx, dims.x - 1)
				var slope01: float = clampf(1.0 - normal.y, 0.0, 1.0)
				var color: Color = BiomeTable.surface_color(
					field.ground_color[column],
					slope01,
					position.y,
					field.wetness[column],
					_snow_line(field.temperature[column]),
					field.roadness[column]
				)
				cell_vertex[(cz * cells.y + cy) * cells.x + cx] = data.vertices.size()
				data.vertices.append(position)
				data.normals.append(normal)
				data.colors.append(color)
				data.uvs.append(Vector2(
					field.corridor_mask[column], field.wetness[column]
				))
				min_v = min_v.min(position)
				max_v = max_v.max(position)

	if data.vertices.is_empty():
		return data

	# --- faces ------------------------------------------------------------------
	# One quad per sign-changing edge. The index window keeps each chunk to a
	# disjoint set of edges so neighbours meet exactly once.
	for iz in range(1, dims.z - 1):
		for iy in range(1, dims.y - 1):
			for ix in range(1, dims.x - 1):
				var here: float = values[(iz * dims.y + iy) * dims.x + ix]
				var solid_here: bool = here >= 0.0

				if ix + 1 < dims.x:
					var vx: float = values[(iz * dims.y + iy) * dims.x + (ix + 1)]
					if solid_here != (vx >= 0.0):
						_emit_quad(
							data, cell_vertex, cells,
							Vector3i(ix, iy - 1, iz - 1), Vector3i(ix, iy, iz - 1),
							Vector3i(ix, iy, iz), Vector3i(ix, iy - 1, iz),
							solid_here
						)
				if iy + 1 < dims.y:
					var vy: float = values[(iz * dims.y + (iy + 1)) * dims.x + ix]
					if solid_here != (vy >= 0.0):
						_emit_quad(
							data, cell_vertex, cells,
							Vector3i(ix - 1, iy, iz - 1), Vector3i(ix - 1, iy, iz),
							Vector3i(ix, iy, iz), Vector3i(ix, iy, iz - 1),
							solid_here
						)
				if iz + 1 < dims.z:
					var vz: float = values[((iz + 1) * dims.y + iy) * dims.x + ix]
					if solid_here != (vz >= 0.0):
						_emit_quad(
							data, cell_vertex, cells,
							Vector3i(ix - 1, iy - 1, iz), Vector3i(ix, iy - 1, iz),
							Vector3i(ix, iy, iz), Vector3i(ix - 1, iy, iz),
							solid_here
						)

	data.surface_triangles = data.indices.size() / 3
	if want_skirts:
		_add_skirts(data, cell_vertex, cells, voxel)

	data.aabb = AABB(min_v, max_v - min_v)
	if want_collision:
		data.collision_faces = _faces_from(data)
	return data


static func _snow_line(temperature: float) -> float:
	# Only summits should hold snow. Peaks in this world top out near 820 m, so
	# a line below ~600 m would put a white cap on ordinary hills and flatten
	# the whole silhouette into one pale mass.
	return 640.0 + temperature * 260.0


static func _emit_quad(
	data: MeshData,
	cell_vertex: PackedInt32Array,
	cells: Vector3i,
	c0: Vector3i,
	c1: Vector3i,
	c2: Vector3i,
	c3: Vector3i,
	flip: bool
) -> void:
	var v0: int = _cell_vertex_at(cell_vertex, cells, c0)
	var v1: int = _cell_vertex_at(cell_vertex, cells, c1)
	var v2: int = _cell_vertex_at(cell_vertex, cells, c2)
	var v3: int = _cell_vertex_at(cell_vertex, cells, c3)
	if v0 < 0 or v1 < 0 or v2 < 0 or v3 < 0:
		return
	# Godot treats clockwise triangles as front facing, which is the opposite of
	# the right-hand rule the gradient normals follow.
	if flip:
		data.indices.append_array(PackedInt32Array([v0, v2, v1, v0, v3, v2]))
	else:
		data.indices.append_array(PackedInt32Array([v0, v1, v2, v0, v2, v3]))


static func _cell_vertex_at(
	cell_vertex: PackedInt32Array, cells: Vector3i, c: Vector3i
) -> int:
	if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= cells.x or c.y >= cells.y or c.z >= cells.z:
		return -1
	return cell_vertex[(c.z * cells.y + c.y) * cells.x + c.x]


static func _gradient(
	values: PackedFloat32Array, dims: Vector3i, cx: int, cy: int, cz: int
) -> Vector3:
	var x0: int = maxi(cx - 1, 0)
	var x1: int = mini(cx + 2, dims.x - 1)
	var y0: int = maxi(cy - 1, 0)
	var y1: int = mini(cy + 2, dims.y - 1)
	var z0: int = maxi(cz - 1, 0)
	var z1: int = mini(cz + 2, dims.z - 1)
	var gx: float = (
		values[(cz * dims.y + cy) * dims.x + x1] - values[(cz * dims.y + cy) * dims.x + x0]
	)
	var gy: float = (
		values[(cz * dims.y + y1) * dims.x + cx] - values[(cz * dims.y + y0) * dims.x + cx]
	)
	var gz: float = (
		values[(z1 * dims.y + cy) * dims.x + cx] - values[(z0 * dims.y + cy) * dims.x + cx]
	)
	var g: Vector3 = Vector3(-gx, -gy, -gz)
	return g.normalized() if g.length_squared() > 0.000001 else Vector3.UP


## Vertical fringe around the chunk border. LOD rings mesh the same field at
## different voxel sizes, so their surfaces disagree slightly; the skirt fills
## that hairline instead of letting the sky show through.
##
## The fringe inherits the normal and colour of the edge it hangs from. A skirt
## with its own downward normal reads as an overhanging rock wall to the shader,
## and on steep ground those walls cover the hillside they were meant to patch.
static func _add_skirts(
	data: MeshData, cell_vertex: PackedInt32Array, cells: Vector3i, voxel: float
) -> void:
	var depth: float = voxel * SKIRT_DEPTH_FACTOR
	var borders: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(0, cells.x - 1), Vector2i(2, 1), Vector2i(2, cells.z - 1)
	]
	for border in borders:
		var axis: int = border.x
		var fixed: int = border.y
		var tangent_count: int = cells.z if axis == 0 else cells.x
		for cy in cells.y:
			for t in range(1, tangent_count - 1):
				var a: Vector3i = (
					Vector3i(fixed, cy, t) if axis == 0 else Vector3i(t, cy, fixed)
				)
				var b: Vector3i = (
					Vector3i(fixed, cy, t + 1) if axis == 0 else Vector3i(t + 1, cy, fixed)
				)
				var va: int = _cell_vertex_at(cell_vertex, cells, a)
				var vb: int = _cell_vertex_at(cell_vertex, cells, b)
				if va < 0 or vb < 0:
					continue
				var pa: Vector3 = data.vertices[va]
				var pb: Vector3 = data.vertices[vb]
				var na: Vector3 = data.normals[va]
				var nb: Vector3 = data.normals[vb]
				var ca: Color = data.colors[va]
				var cb: Color = data.colors[vb]
				var ua: Vector2 = data.uvs[va]
				var ub: Vector2 = data.uvs[vb]
				var base: int = data.vertices.size()
				data.vertices.append_array(PackedVector3Array([
					pa, pb, pb - Vector3(0.0, depth, 0.0), pa - Vector3(0.0, depth, 0.0)
				]))
				data.normals.append_array(PackedVector3Array([na, nb, nb, na]))
				data.colors.append_array(PackedColorArray([ca, cb, cb, ca]))
				data.uvs.append_array(PackedVector2Array([ua, ub, ub, ua]))
				data.indices.append_array(PackedInt32Array([
					base, base + 1, base + 2, base, base + 2, base + 3
				]))
				data.indices.append_array(PackedInt32Array([
					base, base + 2, base + 1, base, base + 3, base + 2
				]))


static func _faces_from(data: MeshData) -> PackedVector3Array:
	var faces: PackedVector3Array = PackedVector3Array()
	faces.resize(data.indices.size())
	for i in data.indices.size():
		faces[i] = data.vertices[data.indices[i]]
	return faces
