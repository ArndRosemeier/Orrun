class_name BridgeBuilder
extends RefCounted
## Procedural spans for road crossings.
##
## The catalog decides what a crossing should look like; until Asset Lab ships a
## bridge kit these are built from boxes. The important part is not the model,
## it is that the deck sits on the two bank anchors the path layer measured, so
## a bridge always meets ground the density field actually produced.

const PARAPET_HEIGHT: float = 0.85
const PARAPET_THICKNESS: float = 0.38
const DECK_THICKNESS: float = 0.55
const PIER_SPACING: float = 11.0


static func build(site: BridgeSite, chunk_origin: Vector2) -> ArrayMesh:
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()

	var a: Vector3 = site.anchor_a - Vector3(chunk_origin.x, 0.0, chunk_origin.y)
	var b: Vector3 = site.anchor_b - Vector3(chunk_origin.x, 0.0, chunk_origin.y)
	var center: Vector3 = (a + b) * 0.5
	var span: float = site.span_length()
	var dir: Vector2 = site.direction()
	var basis: Basis = Basis(
		Vector3(dir.x, 0.0, dir.y),
		Vector3.UP,
		Vector3(-dir.y, 0.0, dir.x)
	)

	var stone: bool = site.catalog_id == &"procedural_stone"
	var deck_color: Color = Color(0.44, 0.42, 0.39) if stone else Color(0.35, 0.26, 0.17)
	var trim_color: Color = deck_color.darkened(0.18)

	# Deck, sunk slightly so the approach ramps meet its top surface.
	_add_box(
		vertices, normals, colors, indices,
		center + Vector3(0.0, -DECK_THICKNESS * 0.5, 0.0),
		basis, Vector3(span + 2.4, DECK_THICKNESS, site.deck_width), deck_color
	)

	var side: Vector3 = basis.z * (site.deck_width * 0.5 - PARAPET_THICKNESS * 0.5)
	for sign_index in 2:
		var offset: Vector3 = side if sign_index == 0 else -side
		_add_box(
			vertices, normals, colors, indices,
			center + offset + Vector3(0.0, PARAPET_HEIGHT * 0.5, 0.0),
			basis, Vector3(span + 2.4, PARAPET_HEIGHT, PARAPET_THICKNESS), trim_color
		)

	# Piers reach from the deck down past the water line.
	var pier_count: int = maxi(int(span / PIER_SPACING) - 1, 0)
	if pier_count > 0:
		var pier_depth: float = maxf(center.y - (site.water_z - 1.2), 1.5)
		for i in pier_count:
			var t: float = float(i + 1) / float(pier_count + 1)
			var pier_center: Vector3 = a.lerp(b, t)
			_add_box(
				vertices, normals, colors, indices,
				Vector3(pier_center.x, center.y - DECK_THICKNESS - pier_depth * 0.5, pier_center.z),
				basis, Vector3(1.6, pier_depth, site.deck_width * 0.7), trim_color
			)

	var mesh: ArrayMesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _add_box(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	center: Vector3,
	basis: Basis,
	size: Vector3,
	color: Color
) -> void:
	var half: Vector3 = size * 0.5
	var axes: Array[Vector3] = [basis.x, basis.y, basis.z]
	var extents: Array[float] = [half.x, half.y, half.z]

	for axis in 3:
		for direction in 2:
			var sign_value: float = 1.0 if direction == 0 else -1.0
			var normal: Vector3 = axes[axis] * sign_value
			var u: Vector3 = axes[(axis + 1) % 3] * extents[(axis + 1) % 3]
			var v: Vector3 = axes[(axis + 2) % 3] * extents[(axis + 2) % 3]
			var face_center: Vector3 = center + normal * extents[axis]

			var base: int = vertices.size()
			vertices.append_array(PackedVector3Array([
				face_center - u - v, face_center + u - v,
				face_center + u + v, face_center - u + v
			]))
			for _k in 4:
				normals.append(normal)
				colors.append(color)
			if sign_value > 0.0:
				indices.append_array(PackedInt32Array([
					base, base + 1, base + 2, base, base + 2, base + 3
				]))
			else:
				indices.append_array(PackedInt32Array([
					base, base + 2, base + 1, base, base + 3, base + 2
				]))
