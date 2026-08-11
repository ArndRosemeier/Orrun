class_name BridgeBuilder
extends RefCounted
## Spans for road crossings.
##
## Asset Lab kits: abutment + tiled mids + abutment. Deck height is
## BridgeSite.deck_z (anchors share that Y). Density hard-sets abutments to the
## same height after settlement terracing. Piers drop from the deck underside
## into the water. Missing kits fall back to the box placeholder.
##
## [method build] is safe for worker threads: it returns mesh references,
## transforms, procedural arrays and collision faces — never SceneTree nodes.

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
	var procedural_vertices: PackedVector3Array = PackedVector3Array()
	var procedural_normals: PackedVector3Array = PackedVector3Array()
	var procedural_colors: PackedColorArray = PackedColorArray()
	var procedural_indices: PackedInt32Array = PackedInt32Array()
	## Triangle soup for ConcavePolygonShape3D, already in chunk-local space.
	var collision_faces: PackedVector3Array = PackedVector3Array()
	var uses_kit: bool = false

	func has_procedural_mesh() -> bool:
		return not procedural_indices.is_empty()


static func build(
	site: BridgeSite, chunk_origin: Vector2, want_collision: bool = false
) -> BuildResult:
	var result: BuildResult = BuildResult.new()
	var kit: BridgeLibrary.Kit = BridgeLibrary.kit_for(site.catalog_id)
	if kit != null and kit.mid_mesh != null:
		result.uses_kit = true
		result.mid_mesh = kit.mid_mesh
		result.end_mesh = kit.end_mesh
		_tile_kit(site, chunk_origin, kit, result)
		_fill_procedural(result, _build_piers(site, chunk_origin, kit.deck_top))
		if want_collision:
			_pack_kit_collision(result)
			_pack_procedural_collision(result)
		return result

	_fill_procedural(result, _build_procedural(site, chunk_origin))
	if want_collision:
		_pack_procedural_collision(result)
	return result


static func _fill_procedural(result: BuildResult, arrays: Dictionary) -> void:
	if arrays.is_empty():
		return
	result.procedural_vertices = arrays["vertices"]
	result.procedural_normals = arrays["normals"]
	result.procedural_colors = arrays["colors"]
	result.procedural_indices = arrays["indices"]


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
) -> Dictionary:
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
		return {}

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

	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"indices": indices,
	}


static func _build_procedural(site: BridgeSite, chunk_origin: Vector2) -> Dictionary:
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

	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"indices": indices,
	}


static func _pack_kit_collision(result: BuildResult) -> void:
	_append_mesh_collision_faces(
		result.collision_faces, result.mid_mesh, result.mid_transforms
	)
	_append_mesh_collision_faces(
		result.collision_faces, result.end_mesh, result.end_transforms
	)


static func _pack_procedural_collision(result: BuildResult) -> void:
	if not result.has_procedural_mesh():
		return
	var verts: PackedVector3Array = result.procedural_vertices
	var indices: PackedInt32Array = result.procedural_indices
	for i in range(0, indices.size(), 3):
		result.collision_faces.append(verts[indices[i]])
		result.collision_faces.append(verts[indices[i + 1]])
		result.collision_faces.append(verts[indices[i + 2]])


static func _append_mesh_collision_faces(
	out: PackedVector3Array, mesh: Mesh, transforms: Array[Transform3D]
) -> void:
	if mesh == null or transforms.is_empty():
		return
	for xform in transforms:
		for surface_i in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface_i)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if indices.is_empty():
				for i in range(0, verts.size(), 3):
					out.append(xform * verts[i])
					out.append(xform * verts[i + 1])
					out.append(xform * verts[i + 2])
			else:
				for i in range(0, indices.size(), 3):
					out.append(xform * verts[indices[i]])
					out.append(xform * verts[indices[i + 1]])
					out.append(xform * verts[indices[i + 2]])


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
