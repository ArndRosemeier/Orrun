class_name BridgeLibrary
extends RefCounted
## Runtime meshes for modular bridge kits.
##
## Specs and .glb files are owned by the Asset Lab; tools/sync_assets.py copies
## mid and end pieces into res://assets/library. Catalog metadata carries the
## authored segment length and deck-top height so tiling does not guess bounds.

const LIBRARY_DIR: String = "res://assets/library/"
const DEFAULT_CATALOG: String = "res://assets/catalog/bridges.json"


class Kit extends RefCounted:
	var id: StringName = &""
	var mid_mesh: Mesh = null
	var end_mesh: Mesh = null
	var segment_length: float = 8.0
	var end_length: float = 0.0
	## Authored walking-surface height above the mesh origin (Y after glTF).
	var deck_top: float = 0.85
	var authored_width: float = 5.2


static var _kits: Dictionary = {}
static var _missing: Dictionary = {}
static var _loaded: bool = false


static func load_catalog(catalog_path: String = DEFAULT_CATALOG) -> void:
	_kits.clear()
	_missing.clear()
	_loaded = true

	var file: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	assert(file != null, "Bridge catalog missing at %s" % catalog_path)
	var root: Dictionary = JSON.parse_string(file.get_as_text())

	for entry_variant in root["kits"]:
		var entry: Dictionary = entry_variant
		var id: StringName = StringName(entry["id"])
		var mid_path: String = LIBRARY_DIR + String(entry["mid_source"])
		if not ResourceLoader.exists(mid_path):
			_report_missing(id, mid_path, FileAccess.file_exists(mid_path))
			continue
		var mid_mesh: Mesh = _mesh_from_scene(load(mid_path))
		if mid_mesh == null:
			_report_missing(id, mid_path, true)
			continue

		var kit: Kit = Kit.new()
		kit.id = id
		kit.mid_mesh = mid_mesh
		kit.segment_length = float(entry["segment_length"])
		kit.deck_top = float(entry["deck_top"])
		kit.authored_width = float(entry["authored_width"])

		if entry.has("end_source"):
			var end_path: String = LIBRARY_DIR + String(entry["end_source"])
			if ResourceLoader.exists(end_path):
				kit.end_mesh = _mesh_from_scene(load(end_path))
				kit.end_length = float(entry.get("end_length", 4.0))
			elif FileAccess.file_exists(end_path):
				push_error(
					"Bridge kit '%s' end mesh is on disk but not imported: %s"
					% [id, end_path]
				)

		_kits[id] = kit


static func _report_missing(id: StringName, path: String, on_disk: bool = false) -> void:
	_missing[id] = path
	if on_disk:
		push_error(
			"Bridge kit '%s' is on disk at %s but Godot has not imported it yet. "
			% [id, path]
			+ "Run the editor once, or: godot --path . --headless --editor --import"
		)
	else:
		push_error(
			"Bridge kit '%s' has no mid mesh at %s. "
			% [id, path]
			+ "Generate it in the Asset Lab and run: python tools/sync_assets.py"
		)


static func _mesh_from_scene(scene: PackedScene) -> Mesh:
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


static func kit_for(id: StringName) -> Kit:
	if not _loaded:
		load_catalog()
	if id == &"procedural_timber":
		id = &"timber"
	elif id == &"procedural_stone":
		id = &"stone"
	return _kits.get(id, null)


static func available_count() -> int:
	return _kits.size()
