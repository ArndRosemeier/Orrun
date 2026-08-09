extends Control
## Live knobs for continental interpretation (not the atlas).
##
## Mutates the shared [WorldConfig], then asks the streamer to rebake nearby
## sectors and remesh. Debounced so dragging a slider does not enqueue a bake
## per pixel.

const DEBOUNCE_S: float = 0.45
## Peak-spacing slider maps denseness 0..1 → wavelength max..min.
const SPACING_MIN_M: float = 400.0
const SPACING_MAX_M: float = 8000.0

var streamer: Streamer
var config: WorldConfig

var _panel: PanelContainer
var _status: Label
var _debounce_left: float = 0.0
var _dirty: bool = false
var _sliders: Dictionary = {}
var _density_slider: HSlider
var _density_label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -360.0
	offset_top = 12.0
	offset_right = -12.0
	offset_bottom = 700.0

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.11, 0.88)
	style.set_corner_radius_all(6)
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var title := Label.new()
	title.text = "Terrain tune (F4)"
	title.add_theme_font_size_override("font_size", 15)
	root.add_child(title)

	var hint := Label.new()
	hint.text = (
		"Macro contrast steepens atlas mountain flanks.\n"
		+ "Peak denseness RIGHT = closer peaks (not spacing).\n"
		+ "Peak height alone cannot fix a smooth horizon.\n"
		+ "Release slider → sector rebake."
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.75, 0.78, 0.84))
	root.add_child(hint)

	_add_slider(root, "mountain_macro_contrast", "Macro contrast (flank steepness)", 1.0, 5.0, 0.05)
	_add_slider(root, "mountain_detail", "Peak height (m)", 0.0, 400.0, 1.0)
	_add_density_slider(root)
	_add_slider(root, "mountain_sharpness", "Ridge sharpness", 0.8, 3.0, 0.05)
	_add_slider(root, "mountain_octaves", "Peak layers (octaves)", 1.0, 6.0, 1.0)
	_add_slider(root, "mountain_gain", "Layer strength", 0.2, 0.7, 0.02)
	_add_slider(root, "swell_height", "Swell amp (m)", 0.0, 80.0, 1.0)
	_add_slider(root, "swell_scale", "Swell wavelength (m)", 200.0, 3000.0, 50.0)
	_add_slider(root, "warp_strength", "Warp strength (m)", 0.0, 500.0, 10.0)
	_add_slider(root, "warp_scale", "Warp wavelength (m)", 200.0, 2500.0, 50.0)
	_add_slider(root, "relief_amp_hills", "Mesh relief hills (m)", 0.0, 40.0, 0.5)
	_add_slider(root, "relief_amp_mountains", "Mesh relief mountains (m)", 0.0, 80.0, 0.5)

	var row := HBoxContainer.new()
	root.add_child(row)
	var apply_btn := Button.new()
	apply_btn.text = "Rebake now"
	apply_btn.pressed.connect(_force_rebake)
	row.add_child(apply_btn)

	_status = Label.new()
	_status.text = "Idle"
	_status.add_theme_font_size_override("font_size", 12)
	root.add_child(_status)


func bind(world_streamer: Streamer, world_config: WorldConfig) -> void:
	streamer = world_streamer
	config = world_config
	_sync_from_config()


func _add_slider(
	parent: Control,
	property: String,
	caption: String,
	min_v: float,
	max_v: float,
	step: float
) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	parent.add_child(box)

	var label := Label.new()
	label.name = "Caption"
	label.add_theme_font_size_override("font_size", 12)
	box.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(
		func(v: float) -> void: _on_slider(property, label, caption, v)
	)
	box.add_child(slider)
	_sliders[property] = {"slider": slider, "label": label, "caption": caption}


func _add_density_slider(parent: Control) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	parent.add_child(box)

	_density_label = Label.new()
	_density_label.add_theme_font_size_override("font_size", 12)
	box.add_child(_density_label)

	_density_slider = HSlider.new()
	_density_slider.min_value = 0.0
	_density_slider.max_value = 1.0
	_density_slider.step = 0.01
	_density_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_density_slider.value_changed.connect(_on_density)
	box.add_child(_density_slider)


func _spacing_to_density(spacing_m: float) -> float:
	return 1.0 - clampf(
		(spacing_m - SPACING_MIN_M) / (SPACING_MAX_M - SPACING_MIN_M), 0.0, 1.0
	)


func _density_to_spacing(density: float) -> float:
	return lerpf(SPACING_MAX_M, SPACING_MIN_M, clampf(density, 0.0, 1.0))


func _set_density_caption(spacing_m: float) -> void:
	_density_label.text = "Peak denseness  (spacing %.0f m)" % spacing_m


func _on_density(density: float) -> void:
	if config == null:
		return
	var spacing: float = _density_to_spacing(density)
	config.mountain_noise_scale = spacing
	_set_density_caption(spacing)
	_dirty = true
	_debounce_left = DEBOUNCE_S
	_status.text = "Pending rebake…"


func _sync_from_config() -> void:
	if config == null:
		return
	for property in _sliders:
		var entry: Dictionary = _sliders[property]
		var slider: HSlider = entry["slider"]
		var value: float = float(config.get(property))
		slider.set_value_no_signal(value)
		_set_caption(entry["label"], entry["caption"], value)
	var spacing: float = config.mountain_noise_scale
	_density_slider.set_value_no_signal(_spacing_to_density(spacing))
	_set_density_caption(spacing)


func _set_caption(label: Label, caption: String, value: float) -> void:
	if is_equal_approx(value, roundf(value)):
		label.text = "%s  %.0f" % [caption, value]
	else:
		label.text = "%s  %.2f" % [caption, value]


func _on_slider(property: String, label: Label, caption: String, value: float) -> void:
	if config == null:
		return
	if typeof(config.get(property)) == TYPE_INT:
		config.set(property, int(round(value)))
	else:
		config.set(property, value)
	_set_caption(label, caption, value)
	_dirty = true
	_debounce_left = DEBOUNCE_S
	_status.text = "Pending rebake…"


func _force_rebake() -> void:
	_dirty = false
	_debounce_left = 0.0
	_rebake()


func _process(delta: float) -> void:
	if not visible:
		return
	if _dirty:
		_debounce_left -= delta
		if _debounce_left <= 0.0:
			_dirty = false
			_rebake()
		return
	if streamer == null or streamer.sectors == null:
		return
	if streamer.sectors.pending_count() > 0 or streamer.stat_chunks_waiting_on_sector > 0:
		_status.text = "Baking… sectors %d, chunks waiting %d" % [
			streamer.sectors.pending_count(), streamer.stat_chunks_waiting_on_sector
		]
	elif _status.text.begins_with("Bak") or _status.text.begins_with("Reb"):
		_status.text = "Idle — values applied nearby"


func _rebake() -> void:
	if streamer == null:
		return
	streamer.rebake_interpretation()
	_status.text = "Rebaking sectors + chunks…"
