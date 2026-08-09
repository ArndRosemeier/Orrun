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
			_report_missing(spec.id, path)
			continue
		var scene: PackedScene = load(path)
		var mesh: Mesh = _first_mesh(scene)
		if mesh == null:
			_report_missing(spec.id, path)
			continue
		_meshes[spec.id] = mesh


static func _report_missing(id: StringName, path: String) -> void:
	_missing[id] = path
	push_error(
		"Prop '%s' is in the catalog but has no mesh at %s. "
		% [id, path]
		+ "Run: python tools/sync_assets.py (and generate it in the Asset Lab first)."
	)


static func _first_mesh(scene: PackedScene) -> Mesh:
	var root: Node = scene.instantiate()
	var found: Mesh = _search_mesh(root)
	root.queue_free()
	return found


static func _search_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		var instance: MeshInstance3D = node
		if instance.mesh != null:
			return instance.mesh
	for child in node.get_children():
		var found: Mesh = _search_mesh(child)
		if found != null:
			return found
	return null


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
