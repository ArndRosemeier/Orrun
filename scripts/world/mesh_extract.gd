class_name MeshExtract
extends RefCounted
## Surface nets over the density field via OrrunGen.mesh_extract.
##
## Dual contouring style extraction is what lets the world have overhangs and
## caves at all - a heightmap grid cannot produce either. Neighbouring chunks
## sample the same global grid and each owns a disjoint set of edges, so the
## seams line up exactly instead of cracking.

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
	assert(
		ClassDB.class_exists("OrrunGen"),
		"OrrunGen is required for MeshExtract (build native/orrun_gen)"
	)
	var local_origin: Vector3 = field.origin - Vector3(chunk_origin.x, 0.0, chunk_origin.y)
	var native: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
	var result: Variant = native.call(
		"mesh_extract",
		field.values,
		field.ground_color,
		field.wetness,
		field.corridor_mask,
		field.temperature,
		field.roadness,
		field.dims.x,
		field.dims.y,
		field.dims.z,
		field.voxel,
		local_origin,
		want_collision,
		want_skirts
	)
	assert(
		typeof(result) == TYPE_DICTIONARY,
		"OrrunGen.mesh_extract failed: %s" % [result]
	)
	var dict: Dictionary = result
	var data: MeshData = MeshData.new()
	data.vertices = dict["vertices"]
	data.normals = dict["normals"]
	data.colors = dict["colors"]
	data.uvs = dict["uvs"]
	data.indices = dict["indices"]
	data.collision_faces = dict["collision_faces"]
	data.surface_triangles = int(dict["surface_triangles"])
	data.aabb = AABB(dict["aabb_position"], dict["aabb_size"])
	return data
