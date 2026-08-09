extends Control
## Boots a ContinentAtlas and hosts the interactive 2D viewer.
##
##   godot --path <project> res://scenes/atlas_viewer.tscn
##   godot --path <project> res://scenes/atlas_viewer.tscn -- --seed=42 --size=256

@onready var viewer: Control = $AtlasViewer
@onready var loading: Label = $Loading
@onready var seed_label: Label = $SeedControls/SeedLabel
@onready var randomize_button: Button = $SeedControls/RandomizeButton

var _seed: int = 0
## Default to a responsive preview size; production atlas is ContinentAtlas.SIZE.
var _size: int = 256
var _generating: bool = false


func _ready() -> void:
	_seed = _new_random_seed(-1)
	_parse_args()
	randomize_button.pressed.connect(_on_randomize_pressed)
	await _generate_current_seed()


func _on_randomize_pressed() -> void:
	if _generating:
		return
	_seed = _new_random_seed(_seed)
	await _generate_current_seed()


func _generate_current_seed() -> void:
	_generating = true
	randomize_button.disabled = true
	seed_label.text = "Seed: %d" % _seed
	loading.text = "Generating continent atlas (seed %d, %d²)…" % [_seed, _size]
	loading.visible = true
	print("Generating atlas: seed=%d size=%d" % [_seed, _size])
	await get_tree().process_frame
	var atlas: ContinentAtlas = ContinentAtlas.generate(_seed, _size)
	var errors: PackedStringArray = atlas.validate()
	loading.visible = false
	viewer.setup(atlas)
	if not errors.is_empty():
		push_warning("Atlas validation warnings:\n- " + "\n- ".join(errors))
		print("Atlas validation warnings:")
		for err in errors:
			print("  - ", err)
	else:
		print(
			"Atlas ok: seed=%d | %d lakes, %d nodes, %d river edges, %d road edges, %d crossings, %d ms" % [
				_seed, atlas.lakes.size(), atlas.nodes.size(),
				atlas.river_ports.size(), atlas.road_ports.size(),
				atlas.crossings.size(), atlas.generate_ms
			]
		)
	_generating = false
	randomize_button.disabled = false


func _new_random_seed(previous_seed: int) -> int:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var generated: int = rng.randi_range(1, 0x7fffffff)
	while generated == previous_seed:
		generated = rng.randi_range(1, 0x7fffffff)
	return generated


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_seed = int(arg.get_slice("=", 1))
		elif arg.begins_with("--size="):
			_size = clampi(int(arg.get_slice("=", 1)), 64, ContinentAtlas.SIZE)
