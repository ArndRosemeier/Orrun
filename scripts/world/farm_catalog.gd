class_name FarmCatalog
extends RefCounted
## Quaternius farm buildings + crop meshes for settlement fringe packing.

const CATALOG_PATH: String = "res://assets/catalog/farm.json"


class Spec extends RefCounted:
	var id: StringName = &""
	var source: String = ""
	var role: StringName = &"crop"
	var footprint: float = 1.0
	var height: float = 1.0
	## 0=hamlet … 3=port
	var min_tier: int = 0

	func is_farm_building() -> bool:
		return role == &"farm_building"

	func is_crop() -> bool:
		return role == &"crop"

	func is_prop() -> bool:
		return role == &"prop"

	func needs_collision() -> bool:
		return role == &"farm_building"


static var _specs: Array[Spec] = []
static var _by_id: Dictionary = {}
static var _mesh_scale: float = 1.0


static func load_catalog(catalog_path: String = CATALOG_PATH) -> Array[Spec]:
	var file: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	assert(file != null, "Farm catalog missing at %s" % catalog_path)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary, "Farm catalog is not a JSON object")
	var root: Dictionary = parsed
	assert(root.has("farm"), "Farm catalog missing 'farm' array")
	assert(root.has("mesh_scale"), "Farm catalog missing mesh_scale")
	_mesh_scale = float(root["mesh_scale"])
	assert(_mesh_scale > 0.0, "Farm mesh_scale must be positive")

	_specs.clear()
	_by_id.clear()
	for entry_variant in root["farm"]:
		var entry: Dictionary = entry_variant
		var spec: Spec = Spec.new()
		spec.id = StringName(entry["id"])
		spec.source = String(entry["source"])
		spec.role = StringName(entry["role"])
		spec.footprint = float(entry["footprint"])
		spec.height = float(entry["height"])
		spec.min_tier = int(entry["min_tier"])
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
	assert(_by_id.has(id), "Unknown farm id '%s'" % String(id))
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
