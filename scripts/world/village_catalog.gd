class_name VillageCatalog
extends RefCounted
## Quaternius Medieval Village meshes and placement metadata.

const CATALOG_PATH: String = "res://assets/catalog/village.json"


class Spec extends RefCounted:
	var id: StringName = &""
	var source: String = ""
	var role: StringName = &"prop"
	var footprint: float = 2.0
	var height: float = 2.0
	## Oriented local XZ size in metres (door along ±Z). Required for dwelling/civic.
	var size_x: float = 0.0
	var size_z: float = 0.0
	## Extra yaw baked into placement so mesh door faces lab −local Z.
	var yaw_offset: float = 0.0
	## 0=hamlet … 3=port; parts use 99 so they never auto-place.
	var min_tier: int = 0

	func is_dwelling() -> bool:
		return role == &"dwelling"

	func is_civic() -> bool:
		return role == &"civic"

	func is_prop() -> bool:
		return role == &"prop"

	func needs_collision() -> bool:
		return role == &"dwelling" or role == &"civic" or footprint >= 2.4

	func half_x() -> float:
		return size_x * 0.5

	func half_z() -> float:
		return size_z * 0.5

	func has_oriented_size() -> bool:
		return size_x > 0.0 and size_z > 0.0


static var _specs: Array[Spec] = []
static var _by_id: Dictionary = {}
## Extra uniform scale on top of FBX node transform (see village.json mesh_scale).
static var _mesh_scale: float = 1.0


static func load_catalog(catalog_path: String = CATALOG_PATH) -> Array[Spec]:
	var file: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	assert(file != null, "Village catalog missing at %s" % catalog_path)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary, "Village catalog is not a JSON object")
	var root: Dictionary = parsed
	assert(root.has("village"), "Village catalog missing 'village' array")
	assert(root.has("mesh_scale"), "Village catalog missing mesh_scale")
	_mesh_scale = float(root["mesh_scale"])
	assert(_mesh_scale > 0.0, "Village mesh_scale must be positive")

	_specs.clear()
	_by_id.clear()
	for entry_variant in root["village"]:
		var entry: Dictionary = entry_variant
		var spec: Spec = Spec.new()
		spec.id = StringName(entry["id"])
		spec.source = String(entry["source"])
		spec.role = StringName(entry["role"])
		spec.footprint = float(entry["footprint"])
		spec.height = float(entry["height"])
		spec.min_tier = int(entry["min_tier"])
		if entry.has("size_x"):
			spec.size_x = float(entry["size_x"])
		if entry.has("size_z"):
			spec.size_z = float(entry["size_z"])
		if entry.has("yaw_offset"):
			spec.yaw_offset = float(entry["yaw_offset"])
		if spec.is_dwelling() or spec.is_civic():
			assert(
				spec.has_oriented_size(),
				"Village '%s' needs size_x/size_z — run tools/measure_village_footprints.gd"
				% String(spec.id)
			)
		elif not spec.has_oriented_size():
			# Props: square fallback from legacy footprint.
			spec.size_x = spec.footprint
			spec.size_z = spec.footprint
		_specs.append(spec)
		_by_id[spec.id] = spec
	return _specs


static func mesh_scale() -> float:
	return _mesh_scale


static func all_specs() -> Array[Spec]:
	return _specs


static func has_id(id: StringName) -> bool:
	return _by_id.has(id)


static func spec_for(id: StringName) -> Spec:
	assert(_by_id.has(id), "Unknown village id '%s'" % String(id))
	return _by_id[id]


static func footprint_of(id: StringName) -> float:
	return spec_for(id).footprint


static func height_of(id: StringName) -> float:
	return spec_for(id).height


static func needs_collision(id: StringName) -> bool:
	return spec_for(id).needs_collision()


static func mesh_sources() -> Dictionary:
	var out: Dictionary = {}
	for spec in _specs:
		out[spec.id] = spec.source
	return out


static func ids_with_role(role: StringName, max_tier: int) -> Array[StringName]:
	var out: Array[StringName] = []
	for spec in _specs:
		if spec.role == role and spec.min_tier <= max_tier:
			out.append(spec.id)
	return out
