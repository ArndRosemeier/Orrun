extends Control
## 2D evolutionary marketplace hamlet lab.
## Close window + re-run hamletplaner.bat after script edits.


const COLOR_BG := Color(0.12, 0.14, 0.12, 1.0)
const COLOR_GRID := Color(0.22, 0.25, 0.22, 1.0)
const COLOR_MARKET := Color(0.55, 0.62, 0.38, 0.55)
const COLOR_MARKET_EDGE := Color(0.85, 0.8, 0.45, 0.95)
const COLOR_HOUSE_EDGE := Color(0.15, 0.1, 0.08, 1.0)
const COLOR_OCC := Color(0.9, 0.2, 0.2, 0.35)

## Fixed colors for known VillageCatalog forms; others get a stable hash hue.
const FORM_COLORS := {
	&"House_1": Color(0.78, 0.38, 0.28),
	&"House_2": Color(0.72, 0.48, 0.22),
	&"House_3": Color(0.68, 0.32, 0.36),
	&"House_4": Color(0.62, 0.42, 0.30),
	&"Well": Color(0.35, 0.55, 0.70),
	&"Inn": Color(0.55, 0.28, 0.45),
	&"Blacksmith": Color(0.45, 0.45, 0.48),
	&"Mill": Color(0.40, 0.58, 0.38),
	&"Sawmill": Color(0.50, 0.42, 0.28),
	&"Stable": Color(0.58, 0.50, 0.32),
	&"Bell_Tower": Color(0.48, 0.32, 0.72),
	&"Gazebo": Color(0.32, 0.62, 0.55),
}

var _config: HamletLabConfig = HamletLabConfig.new()
var _plan: HamletLabPlanner.Plan2D = HamletLabPlanner.Plan2D.new()
var _canvas: Control
var _sidebar: VBoxContainer
var _status: Label
var _legend: Label
var _controls: Dictionary = {}
var _applying_ui: bool = false
var _metres_per_pixel: float = 0.45


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if VillageCatalog.all_specs().is_empty():
		VillageCatalog.load_catalog()
	_build_ui()
	_config.apply_tier_defaults(0)
	_sync_ui_from_config()
	_regenerate()


func _build_ui() -> void:
	var root: HBoxContainer = HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	_canvas = Control.new()
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.draw.connect(_draw_plan)
	_canvas.resized.connect(_canvas.queue_redraw)
	root.add_child(_canvas)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	_sidebar = VBoxContainer.new()
	_sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_sidebar)

	var title: Label = Label.new()
	title.text = "Hamlet Lab — marketplace race"
	title.add_theme_font_size_override("font_size", 18)
	_sidebar.add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sidebar.add_child(_status)

	_add_header("Session")
	_add_int("seed", "Seed", 0, 999999, 1)
	_add_option("tier", "Tier", ["Hamlet", "Village", "Town", "Port"])
	_add_bool("show_occupancy", "Show occupancy")

	_add_header("Marketplace")
	_add_float("market_radius", "Market mean semi-axis m", 4.0, 80.0, 0.5)
	_add_float("market_aspect_min", "Ellipse aspect min", 1.05, 4.0, 0.05)
	_add_float("market_aspect_max", "Ellipse aspect max", 1.05, 4.0, 0.05)
	_add_float("market_radius_jitter", "Market radius jitter", 0.0, 0.9, 0.01)
	_add_float("market_angle_jitter", "Market angle jitter", 0.0, 0.95, 0.01)
	_add_float("market_front_gap", "Front gap m", 0.5, 10.0, 0.1)
	_add_float("max_settle_radius", "Max settle radius m", 20.0, 600.0, 1.0)

	_add_header("Settlers / fitness")
	_add_int("dwelling_min", "Settlers min", 1, 2000, 1)
	_add_int("dwelling_max", "Settlers max", 1, 2000, 1)
	_add_int("candidates_per_settler", "Candidates / settler", 10, 300, 5)
	_add_float("select_temperature", "Select temperature", 0.05, 2.0, 0.05)
	_add_float("weight_market", "Weight: near market", 0.0, 3.0, 0.05)
	_add_float("wall_share_boost", "Wall-share score boost", 0.0, 1.0, 0.01)
	_add_float("fitness_noise", "Fitness noise", 0.0, 1.0, 0.01)
	_add_float("alley", "Alley dilation m", 0.0, 3.0, 0.05)
	_add_float("occupancy_cell", "Occupancy cell m", 0.15, 1.0, 0.05)

	_add_header("Building forms (VillageCatalog)")
	_legend = Label.new()
	_legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_legend.add_theme_font_size_override("font_size", 12)
	_sidebar.add_child(_legend)

	_add_header("View")
	_add_float("view_scale", "Metres / pixel", 0.1, 1.2, 0.01)
	_controls["view_scale"].value = _metres_per_pixel

	var help: Label = Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = (
		"Buildings use real VillageCatalog size_x/size_z (House_1–4, Well, Bell_Tower, …). "
		+ "Civics place first, then dwellings. Wall-share vs free sample, best wins. "
		+ "Farms deferred. Re-run hamletplaner.bat after code edits."
	)
	_sidebar.add_child(help)


func _add_header(text: String) -> void:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.85, 0.9, 0.7))
	_sidebar.add_child(l)


func _add_float(key: String, label: String, min_v: float, max_v: float, step: float) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	var name_l: Label = Label.new()
	name_l.text = label
	name_l.custom_minimum_size = Vector2(160, 0)
	row.add_child(name_l)
	var box: SpinBox = SpinBox.new()
	box.min_value = min_v
	box.max_value = max_v
	box.step = step
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.value_changed.connect(_on_any_changed)
	row.add_child(box)
	_sidebar.add_child(row)
	_controls[key] = box


func _add_int(key: String, label: String, min_v: int, max_v: int, step: int) -> void:
	_add_float(key, label, float(min_v), float(max_v), float(step))
	(_controls[key] as SpinBox).rounded = true


func _add_bool(key: String, label: String) -> void:
	var box: CheckBox = CheckBox.new()
	box.text = label
	box.toggled.connect(func(_on: bool) -> void: _on_any_changed(0.0))
	_sidebar.add_child(box)
	_controls[key] = box


func _add_option(key: String, label: String, items: PackedStringArray) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	var name_l: Label = Label.new()
	name_l.text = label
	name_l.custom_minimum_size = Vector2(160, 0)
	row.add_child(name_l)
	var box: OptionButton = OptionButton.new()
	for item in items:
		box.add_item(item)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if key == "tier":
		box.item_selected.connect(_on_tier_changed)
	else:
		box.item_selected.connect(func(_i: int) -> void: _on_any_changed(0.0))
	row.add_child(box)
	_sidebar.add_child(row)
	_controls[key] = box


func _sync_ui_from_config() -> void:
	_applying_ui = true
	_set_num("seed", _config.seed)
	(_controls["tier"] as OptionButton).select(_config.tier)
	(_controls["show_occupancy"] as CheckBox).button_pressed = _config.show_occupancy
	_set_num("market_radius", _config.market_radius)
	_set_num("market_aspect_min", _config.market_aspect_min)
	_set_num("market_aspect_max", _config.market_aspect_max)
	_set_num("market_radius_jitter", _config.market_radius_jitter)
	_set_num("market_angle_jitter", _config.market_angle_jitter)
	_set_num("market_front_gap", _config.market_front_gap)
	_set_num("max_settle_radius", _config.max_settle_radius)
	_set_num("dwelling_min", _config.dwelling_min)
	_set_num("dwelling_max", _config.dwelling_max)
	_set_num("candidates_per_settler", _config.candidates_per_settler)
	_set_num("select_temperature", _config.select_temperature)
	_set_num("weight_market", _config.weight_market)
	_set_num("wall_share_boost", _config.wall_share_boost)
	_set_num("fitness_noise", _config.fitness_noise)
	_set_num("alley", _config.alley)
	_set_num("occupancy_cell", _config.occupancy_cell)
	_applying_ui = false


func _set_num(key: String, value: float) -> void:
	(_controls[key] as SpinBox).value = value


func _read_ui_into_config() -> void:
	_config.seed = int((_controls["seed"] as SpinBox).value)
	_config.tier = (_controls["tier"] as OptionButton).selected
	_config.show_occupancy = (_controls["show_occupancy"] as CheckBox).button_pressed
	_config.market_radius = float((_controls["market_radius"] as SpinBox).value)
	_config.market_aspect_min = float((_controls["market_aspect_min"] as SpinBox).value)
	_config.market_aspect_max = float((_controls["market_aspect_max"] as SpinBox).value)
	_config.market_radius_jitter = float((_controls["market_radius_jitter"] as SpinBox).value)
	_config.market_angle_jitter = float((_controls["market_angle_jitter"] as SpinBox).value)
	_config.market_front_gap = float((_controls["market_front_gap"] as SpinBox).value)
	_config.max_settle_radius = float((_controls["max_settle_radius"] as SpinBox).value)
	_config.dwelling_min = int((_controls["dwelling_min"] as SpinBox).value)
	_config.dwelling_max = int((_controls["dwelling_max"] as SpinBox).value)
	_config.candidates_per_settler = int((_controls["candidates_per_settler"] as SpinBox).value)
	_config.select_temperature = float((_controls["select_temperature"] as SpinBox).value)
	_config.weight_market = float((_controls["weight_market"] as SpinBox).value)
	_config.wall_share_boost = float((_controls["wall_share_boost"] as SpinBox).value)
	_config.fitness_noise = float((_controls["fitness_noise"] as SpinBox).value)
	_config.alley = float((_controls["alley"] as SpinBox).value)
	_config.occupancy_cell = float((_controls["occupancy_cell"] as SpinBox).value)
	_metres_per_pixel = float((_controls["view_scale"] as SpinBox).value)


func _on_any_changed(_v: float = 0.0) -> void:
	if _applying_ui:
		return
	_regenerate()


func _on_tier_changed(_index: int) -> void:
	if _applying_ui:
		return
	_config.tier = (_controls["tier"] as OptionButton).selected
	_config.apply_tier_defaults(_config.tier)
	_sync_ui_from_config()
	_regenerate()


func _regenerate() -> void:
	_read_ui_into_config()
	if _config.dwelling_min > _config.dwelling_max:
		_config.dwelling_max = _config.dwelling_min
	_plan = HamletLabPlanner.plan(_config)
	var status: String = (
		"dwellings=%d/%d  civics=%d  markets=%d  primary_n=%d  mean_r=%.1f  built_r=%.1f"
		% [
			_plan.house_count,
			_plan.want_count,
			_plan.civic_count,
			_plan.markets.size(),
			_plan.market_sides,
			_plan.market_radius,
			_plan.built_envelope,
		]
	)
	if not _plan.underfill_message.is_empty():
		status += "\n" + _plan.underfill_message
		_status.add_theme_color_override("font_color", Color(1.0, 0.35, 0.25))
	else:
		_status.remove_theme_color_override("font_color")
	_status.text = status
	_legend.text = _legend_text()
	_canvas.queue_redraw()


func _legend_text() -> String:
	var counts: Dictionary = {}
	for s in _plan.shapes:
		if s.kind != HamletLabPlanner.Shape.Kind.HOUSE:
			continue
		var key: String = String(s.catalog_id)
		counts[key] = int(counts.get(key, 0)) + 1
	var keys: Array = counts.keys()
	keys.sort()
	var lines: PackedStringArray = PackedStringArray()
	for key_variant in keys:
		var key: String = key_variant
		var id: StringName = StringName(key)
		var col: Color = _color_for_form(id)
		var spec: VillageCatalog.Spec = VillageCatalog.spec_for(id)
		lines.append(
			"%s ×%d  (%.1f×%.1f m)  #%02x%02x%02x"
			% [
				key,
				counts[key],
				spec.size_x,
				spec.size_z,
				int(col.r * 255.0),
				int(col.g * 255.0),
				int(col.b * 255.0),
			]
		)
	if lines.is_empty():
		return "(no buildings)"
	return "\n".join(lines)


func _color_for_form(catalog_id: StringName) -> Color:
	if FORM_COLORS.has(catalog_id):
		return FORM_COLORS[catalog_id]
	var h: int = int(hash(catalog_id)) & 0x7fffffff
	return Color.from_hsv(float(h % 360) / 360.0, 0.55, 0.75)


func _draw_plan() -> void:
	var size: Vector2 = _canvas.size
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG, true)
	var origin: Vector2 = size * 0.5
	var mpp: float = maxf(_metres_per_pixel, 0.05)

	var grid_step: float = 10.0 / mpp
	var x0: float = fmod(origin.x, grid_step)
	while x0 < size.x:
		_canvas.draw_line(Vector2(x0, 0.0), Vector2(x0, size.y), COLOR_GRID, 1.0)
		x0 += grid_step
	var y0: float = fmod(origin.y, grid_step)
	while y0 < size.y:
		_canvas.draw_line(Vector2(0.0, y0), Vector2(size.x, y0), COLOR_GRID, 1.0)
		y0 += grid_step

	if _config.show_occupancy:
		for p in _plan.occupancy_dots:
			_canvas.draw_circle(_world_to_canvas(p, origin, mpp), 1.2, COLOR_OCC)

	for shape in _plan.shapes:
		if shape.kind == HamletLabPlanner.Shape.Kind.MARKET:
			var pts: PackedVector2Array = PackedVector2Array()
			for p in shape.polygon:
				pts.append(_world_to_canvas(p, origin, mpp))
			if pts.size() >= 3:
				_canvas.draw_colored_polygon(pts, COLOR_MARKET)
				for i in pts.size():
					_canvas.draw_line(pts[i], pts[(i + 1) % pts.size()], COLOR_MARKET_EDGE, 2.0)

	for shape in _plan.shapes:
		if shape.kind == HamletLabPlanner.Shape.Kind.HOUSE:
			var fill: Color = _color_for_form(shape.catalog_id)
			_draw_obb(shape, origin, mpp, fill, COLOR_HOUSE_EDGE)
			# Door on the market-facing edge (-local Z).
			var z_axis: Vector2 = Vector2(sin(shape.yaw), cos(shape.yaw))
			var door: Vector2 = shape.center - z_axis * shape.half_size.y
			_canvas.draw_circle(_world_to_canvas(door, origin, mpp), 2.5, COLOR_MARKET_EDGE)


func _draw_obb(
	shape: HamletLabPlanner.Shape,
	origin: Vector2,
	mpp: float,
	fill: Color,
	edge: Color
) -> void:
	var x_axis: Vector2 = Vector2(cos(shape.yaw), -sin(shape.yaw))
	var z_axis: Vector2 = Vector2(sin(shape.yaw), cos(shape.yaw))
	var corners: Array[Vector2] = [
		shape.center + x_axis * shape.half_size.x + z_axis * shape.half_size.y,
		shape.center - x_axis * shape.half_size.x + z_axis * shape.half_size.y,
		shape.center - x_axis * shape.half_size.x - z_axis * shape.half_size.y,
		shape.center + x_axis * shape.half_size.x - z_axis * shape.half_size.y,
	]
	var pts: PackedVector2Array = PackedVector2Array()
	for c in corners:
		pts.append(_world_to_canvas(c, origin, mpp))
	_canvas.draw_colored_polygon(pts, fill)
	for i in 4:
		_canvas.draw_line(pts[i], pts[(i + 1) % 4], edge, 1.5)


func _world_to_canvas(world: Vector2, origin: Vector2, mpp: float) -> Vector2:
	return origin + Vector2(world.x / mpp, world.y / mpp)
