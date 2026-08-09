class_name BridgeBuilder
extends RefCounted
## Spans for road crossings.
##
## Asset Lab kits: abutment + tiled mids + abutment. Deck height is
## BridgeSite.deck_z (anchors share that Y). Density hard-sets abutments to the
## same height after settlement terracing. Piers drop from the deck underside
## into the water. Missing kits fall back to the box placeholder.

const PARAPET_HEIGHT: float = 0.85
const PARAPET_THICKNESS: float = 0.38
const DECK_THICKNESS: float = 0.55
const PIER_SPACING: float = 11.0
## How far below the water surface pier feet dig.
const PIER_FOOTING: float = 1.6


class BuildResult extends RefCounted:
	var mid_mesh: Mesh = null
	var mid_transforms: Array[Transform3D] = []
	var end_mesh: Mesh = null
	var end_transforms: Array[Transform3D] = []
	## Procedural deck/piers (vertex colors), or pier-only under a kit.
	var procedural_mesh: ArrayMesh = null
	var uses_kit: bool = false


static func build(site: BridgeSite, chunk_origin: Vector2) -> BuildResult:
	var result: BuildResult = BuildResult.new()
	var kit: BridgeLibrary.Kit = BridgeLibrary.kit_for(site.catalog_id)
	if kit != null and kit.mid_mesh != null:
		result.uses_kit = true
		result.mid_mesh = kit.mid_mesh
		result.end_mesh = kit.end_mesh
		_tile_kit(site, chunk_origin, kit, result)
		result.procedural_mesh = _build_piers(site, chunk_origin, kit.deck_top)
		return result

	result.procedural_mesh = _build_procedural(site, chunk_origin)
	return result


static func _tile_kit(
	site: BridgeSite,
	chunk_origin: Vector2,
	kit: BridgeLibrary.Kit,
	result: BuildResult
) -> void:
	var a: Vector3 = site.anchor_a - Vector3(chunk_origin.x, 0.0, chunk_origin.y)
	var b: Vector3 = site.anchor_b - Vector3(chunk_origin.x, 0.0, chunk_origin.y)
	var span: float = site.span_length()
	assert(span > 0.05, "BridgeSite span must be positive")

	var dir: Vector2 = site.direction()
	var width_scale: float = site.deck_width / kit.authored_width
	var end_len: float = kit.end_length if kit.end_mesh != null else 0.0
	var mid_budget: float = maxf(span - 2.0 * end_len, kit.segment_length * 0.5)
	if kit.end_mesh == null:
		mid_budget = span
		end_len = 0.0

	var mid_count: int = maxi(int(round(mid_budget / kit.segment_length)), 1)
	var mid_scale: float = mid_budget / (float(mid_count) * kit.segment_length)
	var end_scale: float = 1.0
	if end_len > 0.05:
		# Keep abutments near authored length; absorb leftover in mid scale.
		var used_ends: float = 2.0 * end_len
		if used_ends + mid_budget > span + 0.01:
			end_scale = (span * 0.35) / maxf(end_len, 0.01)
			mid_budget = maxf(span - 2.0 * end_len * end_scale, kit.segment_length * 0.4)
			mid_count = maxi(int(round(mid_budget / kit.segment_length)), 1)
			mid_scale = mid_budget / (float(mid_count) * kit.segment_length)

	var mid_basis: Basis = Basis(
		Vector3(dir.x, 0.0, dir.y),
		Vector3.UP,
		Vector3(-dir.y, 0.0, dir.x)
	).scaled(Vector3(mid_scale, 1.0, width_scale))

	var mid_start: float = end_len * end_scale
	for i in mid_count:
		var along: float = mid_start + (float(i) + 0.5) * kit.segment_length * mid_scale
		var t: float = along / span
		var at: Vector3 = a.lerp(b, t)
		result.mid_transforms.append(
			Transform3D(mid_basis, Vector3(at.x, at.y - kit.deck_top, at.z))
		)

	if kit.end_mesh == null or end_len <= 0.05:
		return

	var end_basis_a: Basis = Basis(
		Vector3(dir.x, 0.0, dir.y),
		Vector3.UP,
		Vector3(-dir.y, 0.0, dir.x)
	).scaled(Vector3(end_scale, 1.0, width_scale))
	var end_basis_b: Basis = Basis(
		Vector3(-dir.x, 0.0, -dir.y),
		Vector3.UP,
		Vector3(dir.y, 0.0, -dir.x)
	).scaled(Vector3(end_scale, 1.0, width_scale))

	var half_end: float = end_len * end_scale * 0.5
	var at_a: Vector3 = a.lerp(b, half_end / span)
	var at_b: Vector3 = a.lerp(b, 1.0 - half_end / span)
	result.end_transforms.append(
		Transform3D(end_basis_a, Vector3(at_a.x, at_a.y - kit.deck_top, at_a.z))
	)
	result.end_transforms.append(
		Transform3D(end_basis_b, Vector3(at_b.x, at_b.y - kit.deck_top, at_b.z))
	)


static func _build_piers(
	site: BridgeSite, chunk_origin: Vector2, deck_top: float = DECK_THICKNESS
) -> ArrayMesh:
	var a: Vector3 = site.anchor_a - Vector3(chunk_origin.x, 0.0, chunk_origin.y)
	var b: Vector3 = site.anchor_b - Vector3(chunk_origin.x, 0.0, chunk_origin.y)
	var span: float = site.span_length()
	var dir: Vector2 = site.direction()
	var basis: Basis = Basis(
		Vector3(dir.x, 0.0, dir.y),
		Vector3.UP,
		Vector3(-dir.y, 0.0, dir.x)
	)

	var stone: bool = site.catalog_id == &"stone" or site.catalog_id == &"procedural_stone"
	var trim_color: Color = Color(0.36, 0.34, 0.31) if stone else Color(0.28, 0.2, 0.12)

	var pier_count: int = maxi(int(span / PIER_SPACING) - 1, 0)
	if pier_count <= 0:
		return null

	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()

	var pier_bottom: float = site.water_z - PIER_FOOTING
	for i in pier_count:
		var t: float = float(i + 1) / float(pier_count + 1)
		var pier_center: Vector3 = a.lerp(b, t)
		# Top of pier just under the walking surface / kit deck.
		var pier_top: float = pier_center.y - maxf(deck_top * 0.15, 0.12)
		var pier_depth: float = maxf(pier_top - pier_bottom, 1.2)
		var mid_y: float = pier_bottom + pier_depth * 0.5
		_add_box(
			vertices, normals, colors, indices,
			Vector3(pier_center.x, mid_y, pier_center.z),
			basis, Vector3(1.6, pier_depth, site.deck_width * 0.65), trim_color
		)

	return _mesh_from_arrays(vertices, normals, colors, indices)


static func _build_procedural(site: BridgeSite, chunk_origin: Vector2) -> ArrayMesh:
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

	var stone: bool = (
		site.catalog_id == &"stone" or site.catalog_id == &"procedural_stone"
	)
	var deck_color: Color = Color(0.44, 0.42, 0.39) if stone else Color(0.35, 0.26, 0.17)
	var trim_color: Color = deck_color.darkened(0.18)

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

	var pier_count: int = maxi(int(span / PIER_SPACING) - 1, 0)
	var pier_bottom: float = site.water_z - PIER_FOOTING
	for i in pier_count:
		var t: float = float(i + 1) / float(pier_count + 1)
		var pier_center: Vector3 = a.lerp(b, t)
		var pier_top: float = pier_center.y - 0.12
		var pier_depth: float = maxf(pier_top - pier_bottom, 1.2)
		_add_box(
			vertices, normals, colors, indices,
			Vector3(pier_center.x, pier_bottom + pier_depth * 0.5, pier_center.z),
			basis, Vector3(1.6, pier_depth, site.deck_width * 0.65), trim_color
		)

	return _mesh_from_arrays(vertices, normals, colors, indices)


static func _mesh_from_arrays(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array
) -> ArrayMesh:
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
