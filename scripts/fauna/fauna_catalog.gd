class_name FaunaCatalog
extends RefCounted
## Loads [code]assets/catalog/fauna.json[/code] and caches Quaternius scenes.

const CATALOG_PATH: String = "res://assets/catalog/fauna.json"
const LIBRARY_DIR: String = "res://assets/library/"


class FaunaSpec extends RefCounted:
	var id: StringName = &""
	var source: String = ""
	var role: StringName = &"grazer"
	var wilderness_spawn: bool = false
	var footprint: float = 1.0
	var scale: float = 1.0
	var max_slope_deg: float = 32.0
	var avoid_water: float = 2.0
	var clearance_road: float = 3.0
	var density: float = 0.0
	var biome_weight: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var flock_min: int = 1
	var flock_max: int = 1
	var walk_speed: float = 2.0
	var run_speed: float = 7.0
	var flee_radius: float = 0.0
	var hunt_range: float = 0.0
	var catch_radius: float = 0.0
	var anim_idle: StringName = &"Idle"
	var anim_walk: StringName = &"Walk"
	var anim_run: StringName = &"Gallop"
	var anim_eat: StringName = &"Eating"
	var anim_attack: StringName = &"Attack"

	func is_prey() -> bool:
		return role == &"grazer" or role == &"livestock"

	func is_predator() -> bool:
		return role == &"predator"


static var _specs: Array[FaunaSpec] = []
static var _by_id: Dictionary = {}
static var _scenes: Dictionary = {}


static func load_catalog(catalog_path: String = CATALOG_PATH) -> Array[FaunaSpec]:
	var file: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	assert(file != null, "Fauna catalog missing at %s" % catalog_path)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary, "Fauna catalog is not a JSON object")
	var root: Dictionary = parsed
	assert(root.has("fauna"), "Fauna catalog missing 'fauna' array")

	_specs.clear()
	_by_id.clear()
	for entry_variant in root["fauna"]:
		var entry: Dictionary = entry_variant
		var spec: FaunaSpec = FaunaSpec.new()
		spec.id = StringName(entry["id"])
		spec.source = String(entry["source"])
		spec.role = StringName(entry["role"])
		spec.wilderness_spawn = bool(entry["wilderness_spawn"])
		spec.footprint = float(entry["footprint"])
		spec.scale = float(entry["scale"])
		spec.max_slope_deg = float(entry["max_slope_deg"])
		spec.avoid_water = float(entry["avoid_water"])
		spec.clearance_road = float(entry["clearance_road"])
		spec.density = float(entry["density"])
		var biomes: Dictionary = entry["biomes"]
		spec.biome_weight = PackedFloat32Array([
			float(biomes["plains"]), float(biomes["forest_hills"]),
			float(biomes["rocky_badlands"]), float(biomes["alpine"]),
		])
		spec.flock_min = int(entry["flock_min"])
		spec.flock_max = int(entry["flock_max"])
		spec.walk_speed = float(entry["walk_speed"])
		spec.run_speed = float(entry["run_speed"])
		spec.flee_radius = float(entry["flee_radius"])
		spec.hunt_range = float(entry["hunt_range"])
		spec.catch_radius = float(entry["catch_radius"])
		var anims: Dictionary = entry["anims"]
		spec.anim_idle = StringName(anims["idle"])
		spec.anim_walk = StringName(anims["walk"])
		spec.anim_run = StringName(anims["run"])
		spec.anim_eat = StringName(anims["eat"])
		spec.anim_attack = StringName(anims["attack"])
		_specs.append(spec)
		_by_id[spec.id] = spec
	return _specs


static func all_specs() -> Array[FaunaSpec]:
	return _specs


static func wilderness_specs() -> Array[FaunaSpec]:
	var out: Array[FaunaSpec] = []
	for spec in _specs:
		if spec.wilderness_spawn:
			out.append(spec)
	return out


static func livestock_specs() -> Array[FaunaSpec]:
	var out: Array[FaunaSpec] = []
	for spec in _specs:
		if spec.role == &"livestock" and not spec.wilderness_spawn and spec.density > 0.0:
			out.append(spec)
	return out


static func spec_for(id: StringName) -> FaunaSpec:
	assert(_by_id.has(id), "Unknown fauna id '%s'" % String(id))
	return _by_id[id]


static func preload_scenes() -> void:
	assert(not _specs.is_empty(), "Call load_catalog before preload_scenes")
	_scenes.clear()
	for spec in _specs:
		var path: String = LIBRARY_DIR + spec.source
		assert(ResourceLoader.exists(path), "Fauna mesh missing at %s" % path)
		var packed: Resource = load(path)
		assert(packed is PackedScene, "Fauna source is not a PackedScene: %s" % path)
		_scenes[spec.id] = packed


static func scene_for(id: StringName) -> PackedScene:
	assert(_scenes.has(id), "Fauna scene not loaded for '%s'" % String(id))
	return _scenes[id]
