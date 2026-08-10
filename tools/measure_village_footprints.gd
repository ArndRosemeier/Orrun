extends SceneTree
## Measure oriented XZ sizes for village dwelling/civic meshes and patch village.json.
## Usage: godot --headless --path . --script res://tools/measure_village_footprints.gd


const PROPS_PATH: String = "res://assets/catalog/props.json"
const VILLAGE_PATH: String = "res://assets/catalog/village.json"
const CLEARANCE: float = 1.15


func _initialize() -> void:
	var prop_specs: Array[PropPlacer.PropSpec] = PropPlacer.load_specs(PROPS_PATH)
	PropLibrary.load_catalog(prop_specs, PROPS_PATH)

	var file: FileAccess = FileAccess.open(VILLAGE_PATH, FileAccess.READ)
	assert(file != null, "missing %s" % VILLAGE_PATH)
	var root: Dictionary = JSON.parse_string(file.get_as_text())
	file = null
	assert(root.has("mesh_scale") and root.has("village"), "bad village.json")

	var mesh_scale: float = float(root["mesh_scale"])
	var sources: Dictionary = {}
	for entry_variant in root["village"]:
		var e: Dictionary = entry_variant
		sources[StringName(e["id"])] = String(e["source"])
	PropLibrary.load_sources(sources, mesh_scale)

	var entries: Array = root["village"]
	var updated: int = 0
	for i in entries.size():
		var entry: Dictionary = entries[i]
		var role: String = String(entry["role"])
		if role != "dwelling" and role != "civic":
			continue
		var id: StringName = StringName(entry["id"])
		var mesh: Mesh = PropLibrary.mesh_for(id)
		if mesh == null:
			push_error("No mesh for %s" % String(id))
			assert(false)
			quit(1)
			return
		var aabb: AABB = mesh.get_aabb()
		var size_x: float = aabb.size.x
		var size_z: float = aabb.size.z
		var height: float = aabb.size.y
		assert(size_x > 0.05 and size_z > 0.05, "degenerate AABB for %s" % String(id))
		entry["size_x"] = snappedf(size_x, 0.01)
		entry["size_z"] = snappedf(size_z, 0.01)
		entry["height"] = snappedf(height, 0.01)
		entry["footprint"] = snappedf(maxf(size_x, size_z) * CLEARANCE, 0.01)
		if not entry.has("yaw_offset"):
			entry["yaw_offset"] = 0.0
		entries[i] = entry
		updated += 1
		print(
			"%s  size_x=%.2f  size_z=%.2f  h=%.2f  footprint=%.2f"
			% [id, entry["size_x"], entry["size_z"], entry["height"], entry["footprint"]]
		)

	root["comment"] = (
		"Quaternius Medieval Village Pack. Meshes under assets/library/village/. "
		+ "mesh_scale is gameplay human-scale. "
		+ "size_x/size_z are oriented local XZ metres after mesh_scale (door axis = local Z). "
		+ "footprint = max(size_x,size_z)*1.15 for legacy square seating. "
		+ "min_tier: 0=hamlet 1=village 2=town 3=port. role=part is catalog-only."
	)
	root["village"] = entries

	var out: FileAccess = FileAccess.open(VILLAGE_PATH, FileAccess.WRITE)
	assert(out != null, "cannot write %s" % VILLAGE_PATH)
	out.store_string(JSON.stringify(root, "\t"))
	out.store_string("\n")
	print("Updated %d dwelling/civic entries in %s" % [updated, VILLAGE_PATH])
	quit(0)
