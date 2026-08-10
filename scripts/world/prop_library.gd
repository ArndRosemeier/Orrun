class_name PropLibrary
extends RefCounted
## Runtime meshes for catalog props.
##
## The Asset Lab owns the .glb files; tools/sync_assets.py copies them into
## res://assets/library. A prop that is in the catalog but not on disk is a real
## problem, so it is reported loudly once and then skipped rather than silently
## producing an empty world.

const LIBRARY_DIR: String = "res://assets/library/"

static var _meshes: Dictionary = {}
static var _missing: Dictionary = {}
static var _loaded: bool = false


static func load_catalog(specs: Array[PropPlacer.PropSpec], catalog_path: String) -> void:
	_meshes.clear()
	_missing.clear()
	_loaded = true

	var file: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	assert(file != null, "Prop catalog missing at %s" % catalog_path)
	var root: Dictionary = JSON.parse_string(file.get_as_text())

	var sources: Dictionary = {}
	for entry_variant in root["props"]:
		var entry: Dictionary = entry_variant
		sources[StringName(entry["id"])] = String(entry["source"])

	for spec in specs:
		var path: String = LIBRARY_DIR + String(sources[spec.id])
		if not ResourceLoader.exists(path):
			_report_missing(spec.id, path, FileAccess.file_exists(path))
			continue
		var scene: PackedScene = load(path)
		var mesh: Mesh = _first_mesh(scene)
		if mesh == null:
			_report_missing(spec.id, path, true)
			continue
		_meshes[spec.id] = mesh


static func load_sources(sources: Dictionary, extra_scale: float = 1.0) -> void:
	## Extra id -> filename entries (e.g. ground clutter) into the same library.
	assert(_loaded, "PropLibrary.load_catalog must run before load_sources")
	assert(extra_scale > 0.0, "PropLibrary.load_sources extra_scale must be positive")
	for id_variant in sources:
		var id: StringName = id_variant
		var path: String = LIBRARY_DIR + String(sources[id])
		if not ResourceLoader.exists(path):
			_report_missing(id, path, FileAccess.file_exists(path))
			continue
		var scene: PackedScene = load(path)
		var mesh: Mesh = _first_mesh(scene)
		if mesh == null:
			_report_missing(id, path, true)
			continue
		if not is_equal_approx(extra_scale, 1.0):
			var scale_xform := Transform3D(
				Basis.IDENTITY.scaled(Vector3.ONE * extra_scale), Vector3.ZERO
			)
			mesh = _mesh_with_transform(mesh, scale_xform)
		_meshes[id] = mesh


static func _report_missing(id: StringName, path: String, on_disk: bool = false) -> void:
	_missing[id] = path
	if on_disk:
		push_error(
			"Prop '%s' is on disk at %s but Godot has not imported it yet. "
			% [id, path]
			+ "Run the editor once, or: godot --path . --headless --editor --import"
		)
	else:
		push_error(
			"Prop '%s' is in the catalog but has no mesh at %s. "
			% [id, path]
			+ "Run: python tools/sync_assets.py (and generate it in the Asset Lab first)."
		)


static func _first_mesh(scene: PackedScene) -> Mesh:
	var root: Node = scene.instantiate()
	var found: Mesh = _search_mesh(root, Transform3D.IDENTITY)
	root.queue_free()
	return found


static func _search_mesh(node: Node, parent_xform: Transform3D) -> Mesh:
	## MultiMesh draws raw mesh data, so FBX node scale (Quaternius uses 100)
	## must be baked in — returning instance.mesh alone leaves centimetre props.
	var xform: Transform3D = parent_xform
	if node is Node3D:
		xform = parent_xform * (node as Node3D).transform
	if node is MeshInstance3D:
		var instance: MeshInstance3D = node
		if instance.mesh != null:
			return _mesh_with_transform(instance.mesh, xform)
	for child in node.get_children():
		var found: Mesh = _search_mesh(child, xform)
		if found != null:
			return found
	return null


static func _mesh_with_transform(mesh: Mesh, xform: Transform3D) -> Mesh:
	if xform.is_equal_approx(Transform3D.IDENTITY):
		return mesh
	var out: ArrayMesh = ArrayMesh.new()
	var normal_basis: Basis = xform.basis.inverse().transposed().orthonormalized()
	for surface_i in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_i)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			verts[i] = xform * verts[i]
		arrays[Mesh.ARRAY_VERTEX] = verts
		var normals_variant: Variant = arrays[Mesh.ARRAY_NORMAL]
		if normals_variant is PackedVector3Array:
			var normals: PackedVector3Array = normals_variant
			for i in normals.size():
				normals[i] = (normal_basis * normals[i]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = normals
		out.add_surface_from_arrays(mesh.surface_get_primitive_type(surface_i), arrays)
		out.surface_set_material(surface_i, mesh.surface_get_material(surface_i))
	return out


static func mesh_for(id: StringName) -> Mesh:
	assert(_loaded, "PropLibrary.load_catalog was never called")
	return _meshes.get(id, null)


static func available_count() -> int:
	return _meshes.size()


static func missing_ids() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for id in _missing:
		out.append(String(id))
	return out
