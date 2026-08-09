extends Control
## Pan/zoom top-down view of a ContinentAtlas.
##
## Drag with left mouse to pan, wheel to zoom. When a cell is large enough on
## screen, its climate fields and local feature counts are drawn as text so the
## generator can be judged cell by cell. This view is also the seed of a future
## player-facing map.

const MIN_ZOOM: float = 0.15
## Deep zoom so a single kilometre cell can fill enough pixels for field text.
const MAX_ZOOM: float = 384.0
## Per-cell overlay starts once a cell is large enough to hold several lines.
const DETAIL_CELL_PX: float = 56.0
static var VIEW_MODE_NAMES: PackedStringArray = PackedStringArray([
	"biome", "elevation", "humidity", "relief", "population"
])

var atlas: ContinentAtlas

var _zoom: float = 1.0
var _pan: Vector2 = Vector2.ZERO
var _dragging: bool = false
var _drag_from: Vector2 = Vector2.ZERO
var _pan_from: Vector2 = Vector2.ZERO
var _texture: ImageTexture
var _hover: Vector2i = Vector2i(-1, -1)
var _view_mode: int = 0
var _status: String = ""


func setup(p_atlas: ContinentAtlas) -> void:
	atlas = p_atlas
	_texture = ImageTexture.create_from_image(_render_overview())
	# Frame the whole map.
	var fit: float = mini(size.x, size.y) / float(maxi(atlas.size, 1))
	_zoom = clampf(fit * 0.92, MIN_ZOOM, MAX_ZOOM)
	_pan = Vector2.ZERO
	_status = "seed %d | %d km | %d lakes | %d nodes | %d crossings | %d ms" % [
		atlas.world_seed, atlas.size, atlas.lakes.size(), atlas.nodes.size(),
		atlas.crossings.size(), atlas.generate_ms
	]
	queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and atlas != null:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if atlas == null:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_from = mb.position
				_pan_from = _pan
			else:
				_dragging = false
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.0 / 1.15)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_view_mode = (_view_mode + 1) % VIEW_MODE_NAMES.size()
			_texture = ImageTexture.create_from_image(_render_overview())
			queue_redraw()
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		_hover = _screen_to_cell(mm.position)
		if _dragging:
			_pan = _pan_from + (mm.position - _drag_from)
		queue_redraw()
	elif event is InputEventKey and event.pressed:
		var key: InputEventKey = event
		if key.keycode == KEY_R:
			_view_mode = 0
			_texture = ImageTexture.create_from_image(_render_overview())
			queue_redraw()
		elif key.keycode == KEY_F:
			var fit: float = mini(size.x, size.y) / float(maxi(atlas.size, 1))
			_zoom = clampf(fit * 0.92, MIN_ZOOM, MAX_ZOOM)
			_pan = Vector2.ZERO
			queue_redraw()


func _zoom_at(screen: Vector2, factor: float) -> void:
	var before: Vector2 = (screen - _pan) / _zoom
	_zoom = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	_pan = screen - before * _zoom
	queue_redraw()


func _screen_to_cell(screen: Vector2) -> Vector2i:
	var map_pos: Vector2 = (screen - _pan) / _zoom
	var ax: int = floori(map_pos.x)
	var az: int = floori(map_pos.y)
	if atlas == null or not atlas.in_bounds(ax, az):
		return Vector2i(-1, -1)
	return Vector2i(ax, az)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.08))
	if atlas == null or _texture == null:
		draw_string(
			ThemeDB.fallback_font, Vector2(16, 28), "No atlas loaded",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.8, 0.8)
		)
		return

	var map_size: Vector2 = Vector2(float(atlas.size), float(atlas.size)) * _zoom
	draw_texture_rect(_texture, Rect2(_pan, map_size), false)

	# Cell dim/text first; rivers and roads must paint above that overlay or
	# deep zoom looks like broken, gappy channels.
	if _zoom >= DETAIL_CELL_PX:
		_draw_cell_details()
	_draw_feature_overlays()

	# HUD
	var mode_name: String = VIEW_MODE_NAMES[_view_mode]
	draw_rect(Rect2(0, 0, size.x, 44), Color(0, 0, 0, 0.55))
	draw_string(
		ThemeDB.fallback_font, Vector2(12, 18),
		"Atlas viewer  |  %s  |  zoom %.1f px/cell  |  right-click (%s)  |  F fit  |  zoom in for cell text" % [
			_status, _zoom, mode_name
		],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.9, 0.92, 0.95)
	)
	if _hover.x >= 0:
		var packed: int = atlas.cell_at(_hover.x, _hover.y)
		var line: String = "cell %d,%d  %s  elev %d (%dm)  hum %d  relief %d  pop %d  mass %d" % [
			_hover.x, _hover.y,
			AtlasBiomes.name_of(AtlasPack.biome(packed)),
			AtlasPack.elevation(packed),
			AtlasPack.elevation_to_metres(AtlasPack.elevation(packed)),
			AtlasPack.humidity(packed),
			AtlasPack.relief(packed),
			AtlasPack.population(packed),
			atlas.landmass_id[atlas.index_of(_hover.x, _hover.y)]
		]
		var rcount: int = atlas.links_in_cell(
			_hover.x, _hover.y, AtlasFeatures.Kind.RIVER
		).size()
		var pcount: int = atlas.links_in_cell(
			_hover.x, _hover.y, AtlasFeatures.Kind.ROAD
		).size()
		line += "  rivers %d  roads %d" % [rcount, pcount]
		draw_string(
			ThemeDB.fallback_font, Vector2(12, 36), line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.88, 0.7)
		)


func _draw_feature_overlays() -> void:
	# Rivers as soft polylines; roads as amber. Keep class-1 rivers visible even
	# at overview scale; generation already filters insignificant runoff.
	var min_river_class: int = 1 if _zoom < 12.0 else 0
	for cell_idx in atlas.river_links:
		var ax: int = int(cell_idx) % atlas.size
		var az: int = int(cell_idx) / atlas.size
		var links: Array = atlas.river_links[cell_idx]
		for link_variant in links:
			var link: AtlasLink = link_variant
			if link.feature_class < min_river_class:
				continue
			var width: float = 1.0 + float(link.feature_class) * 0.7
			_draw_link_curve(ax, az, link, Color(0.25, 0.65, 0.95, 0.9), width)

	for cell_idx in atlas.road_links:
		var ax: int = int(cell_idx) % atlas.size
		var az: int = int(cell_idx) / atlas.size
		var links: Array = atlas.road_links[cell_idx]
		for link_variant in links:
			var link: AtlasLink = link_variant
			var width: float = 1.2 if link.feature_class == 0 else 0.8
			_draw_link_curve(ax, az, link, Color(0.85, 0.72, 0.35, 0.9), width)

	for node in atlas.nodes:
		var p: Vector2 = _cell_to_screen(node.ax, node.az) + Vector2(_zoom, _zoom) * 0.5
		var color: Color = Color(0.95, 0.4, 0.35)
		match node.kind:
			AtlasFeatures.NodeKind.COASTAL_GATE:
				color = Color(0.95, 0.85, 0.35)
			AtlasFeatures.NodeKind.LAKE_SHORE:
				color = Color(0.4, 0.75, 0.95)
			AtlasFeatures.NodeKind.PASS:
				color = Color(0.75, 0.75, 0.8)
			AtlasFeatures.NodeKind.CLAIM_RESERVED:
				color = Color(0.85, 0.25, 0.7)
			AtlasFeatures.NodeKind.SETTLEMENT:
				color = Color(1.0, 0.97, 0.85)
		var radius: float = maxf(_zoom * 0.18, 2.0)
		if node.kind == AtlasFeatures.NodeKind.SETTLEMENT:
			# Towns are the road hubs; make them read before wilderness dots.
			radius = maxf(_zoom * 0.3, 3.5)
			draw_circle(p, radius * 1.6, Color(0.15, 0.09, 0.05, 0.75))
		draw_circle(p, radius, color)


func _draw_link_curve(
	ax: int, az: int, link: AtlasLink, color: Color, width: float
) -> void:
	var a: Vector2 = _endpoint_screen(ax, az, link.a)
	var b: Vector2 = _endpoint_screen(ax, az, link.b)
	# Pin through the cell centre with no random offset so neighbouring cells
	# that share an edge port meet exactly at that port.
	var mid: Vector2 = _cell_to_screen(ax, az) + Vector2(_zoom, _zoom) * 0.5
	var line_w: float = maxf(width * _zoom * 0.08, width)
	var points: PackedVector2Array = PackedVector2Array()
	if a.distance_squared_to(b) < 0.25:
		points.append(a)
		points.append(b)
	elif a.distance_squared_to(mid) < 0.25 or b.distance_squared_to(mid) < 0.25:
		points.append(a)
		points.append(b)
	else:
		var steps: int = 6
		for step in range(steps + 1):
			var t: float = float(step) / float(steps)
			points.append(
				(1.0 - t) * (1.0 - t) * a
				+ 2.0 * (1.0 - t) * t * mid
				+ t * t * b
			)
	draw_polyline(points, color, line_w, true)


func _endpoint_screen(ax: int, az: int, endpoint: AtlasEndpoint) -> Vector2:
	if endpoint.kind == AtlasFeatures.EndpointKind.EDGE_PORT:
		return _edge_port_screen(endpoint.ref_id, endpoint.port_id)
	if (
		endpoint.kind == AtlasFeatures.EndpointKind.OCEAN
		or endpoint.kind == AtlasFeatures.EndpointKind.LAKE
	):
		# Mouths terminate on the land cell edge that faces the sink, so the
		# channel visually reaches water instead of stopping at the cell centre.
		var idx: int = atlas.index_of(ax, az)
		if atlas.river_receiver.size() > idx:
			var down: int = atlas.river_receiver[idx]
			if down >= 0:
				var dx: int = (down % atlas.size) - ax
				var dz: int = (down / atlas.size) - az
				if absi(dx) + absi(dz) == 1:
					var local: Vector2 = Vector2(float(ax) + 0.5, float(az) + 0.5)
					local += Vector2(float(dx), float(dz)) * 0.5
					return _pan + local * _zoom
	if endpoint.kind == AtlasFeatures.EndpointKind.NODE and endpoint.ref_id >= 0:
		for node in atlas.nodes:
			if node.id == endpoint.ref_id:
				return _cell_to_screen(node.ax, node.az) + Vector2(_zoom, _zoom) * 0.5
	return _cell_to_screen(ax, az) + Vector2(_zoom, _zoom) * 0.5


func _edge_port_screen(edge_key: int, port_id: int) -> Vector2:
	var owner: Vector3i = AtlasFeatures.edge_owner(edge_key)
	var ports: Array = []
	if atlas.river_ports.has(edge_key):
		ports = atlas.river_ports[edge_key]
	elif atlas.road_ports.has(edge_key):
		ports = atlas.road_ports[edge_key]
	var t: float = 0.5
	for p in ports:
		var port: AtlasPort = p
		if port.id == port_id:
			t = port.t
			break
	# Fall back to the sole port on this edge when ids drifted.
	if ports.size() == 1:
		var only: AtlasPort = ports[0]
		t = only.t
	var local: Vector2
	if owner.z == AtlasFeatures.Dir.EAST:
		local = Vector2(float(owner.x + 1), float(owner.y) + t)
	else:
		local = Vector2(float(owner.x) + t, float(owner.y + 1))
	return _pan + local * _zoom


func _draw_cell_details() -> void:
	var top_left: Vector2 = -_pan / _zoom
	var bottom_right: Vector2 = (size - _pan) / _zoom
	var x0: int = clampi(floori(top_left.x), 0, atlas.size - 1)
	var z0: int = clampi(floori(top_left.y), 0, atlas.size - 1)
	var x1: int = clampi(ceili(bottom_right.x), 0, atlas.size)
	var z1: int = clampi(ceili(bottom_right.y), 0, atlas.size)

	var font: Font = ThemeDB.fallback_font
	# Grow type with the cell so deeper zoom actually buys readable overlays.
	var font_size: int = clampi(int(_zoom * 0.16), 11, 42)
	var line_step: float = float(font_size) + 3.0
	var pad: float = maxf(4.0, _zoom * 0.04)
	for az in range(z0, z1):
		for ax in range(x0, x1):
			var origin: Vector2 = _cell_to_screen(ax, az)
			var cell_rect: Rect2 = Rect2(origin, Vector2(_zoom, _zoom))
			var packed: int = atlas.cell_at(ax, az)
			var biome: int = AtlasPack.biome(packed)
			# Dim the cell so white field text stays readable on any biome colour.
			draw_rect(cell_rect, Color(0, 0, 0, 0.42))
			draw_rect(cell_rect, Color(1, 1, 1, 0.18), false, 1.0)

			var rivers: int = atlas.links_in_cell(ax, az, AtlasFeatures.Kind.RIVER).size()
			var roads: int = atlas.links_in_cell(ax, az, AtlasFeatures.Kind.ROAD).size()
			var lid: int = atlas.lake_id[atlas.index_of(ax, az)]
			var pop: int = AtlasPack.population(packed)
			var metres: int = AtlasPack.elevation_to_metres(AtlasPack.elevation(packed))
			var lines: PackedStringArray = PackedStringArray([
				AtlasBiomes.name_of(biome),
				"e %d (%dm)" % [AtlasPack.elevation(packed), metres],
				"h %d" % AtlasPack.humidity(packed),
				"r %d" % AtlasPack.relief(packed),
			])
			if lid >= 0:
				lines.append("lake %d" % lid)
			if rivers > 0 or roads > 0:
				lines.append("riv %d  road %d" % [rivers, roads])
			if pop > 0:
				lines.append("pop %d" % pop)
			var mass: int = atlas.landmass_id[atlas.index_of(ax, az)]
			if mass >= 0:
				lines.append("mass %d" % mass)

			var max_lines: int = maxi(1, int((_zoom - pad * 2.0) / line_step))
			var shown: int = mini(lines.size(), max_lines)
			for i in shown:
				draw_string(
					font,
					origin + Vector2(pad, pad + float(i + 1) * line_step - 2.0),
					lines[i],
					HORIZONTAL_ALIGNMENT_LEFT,
					int(_zoom - pad * 2.0),
					font_size,
					Color(0.98, 0.98, 0.94)
				)


func _cell_to_screen(ax: int, az: int) -> Vector2:
	return _pan + Vector2(float(ax), float(az)) * _zoom


func _render_overview() -> Image:
	var n: int = atlas.size
	var image: Image = Image.create_empty(n, n, false, Image.FORMAT_RGB8)
	for az in n:
		for ax in n:
			var packed: int = atlas.cell_at(ax, az)
			var color: Color
			match _view_mode:
				1:
					var e: float = float(AtlasPack.elevation(packed)) / 255.0
					color = Color(e, e * 0.95, e * 0.85)
					if AtlasPack.biome(packed) == AtlasBiomes.Id.OCEAN:
						color = Color(0.08, 0.16, 0.32).lerp(Color(0.2, 0.4, 0.55), e)
					elif AtlasPack.biome(packed) == AtlasBiomes.Id.LAKE:
						color = Color(0.15, 0.35, 0.55)
				2:
					var h: float = float(AtlasPack.humidity(packed)) / 255.0
					color = Color(0.55, 0.4, 0.2).lerp(Color(0.15, 0.35, 0.7), h)
				3:
					var r: float = float(AtlasPack.relief(packed)) / 63.0
					color = Color(0.2, 0.25, 0.2).lerp(Color(0.85, 0.8, 0.7), r)
				4:
					color = Color(0.05, 0.07, 0.10)
					if AtlasBiomes.is_land(AtlasPack.biome(packed)):
						var p: float = float(AtlasPack.population(packed)) / 15.0
						color = Color(0.13, 0.14, 0.13)
						if p > 0.0:
							color = Color(0.35, 0.22, 0.10).lerp(Color(1.0, 0.92, 0.55), p)
				_:
					color = AtlasBiomes.color_of(AtlasPack.biome(packed))
					if AtlasBiomes.is_land(AtlasPack.biome(packed)):
						var shade: float = 0.75 + float(AtlasPack.elevation(packed)) / 255.0 * 0.35
						color *= shade
			image.set_pixel(ax, az, color)
	return image
