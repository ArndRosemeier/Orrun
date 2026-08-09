extends Control
## Top-down view of the baked world: relief, drainage, lakes, roads, claims.
##
## This is the first thing to look at when the landscape feels wrong. If the
## drainage does not read as believable here, no amount of 3D detail will save
## it, so this view exists before any of the prettier ones.

const MAP_PIXELS: int = 512

var map: WorldMap
var player: Node3D

var _texture: ImageTexture
var _scale: float = 1.0
var _origin: Vector2 = Vector2.ZERO


func build(world_map: WorldMap, player_node: Node3D) -> void:
	map = world_map
	player = player_node
	_texture = ImageTexture.create_from_image(_render_map())
	visible = false


func _render_map() -> Image:
	var cells: int = map.terrain.cells
	var image: Image = Image.create_empty(cells, cells, false, Image.FORMAT_RGB8)

	var low: float = map.terrain.min_elevation
	var high: float = map.terrain.max_elevation
	var span: float = maxf(high - low, 1.0)

	for cz in cells:
		for cx in cells:
			var index: int = cz * cells + cx
			var height: float = map.terrain.elevation[index]
			var t: float = (height - low) / span

			# Cheap hillshade so ridges and valleys are legible.
			var left: float = map.terrain.elevation[map.terrain.clamped_index(cx - 1, cz)]
			var up: float = map.terrain.elevation[map.terrain.clamped_index(cx, cz - 1)]
			var shade: float = clampf(
				0.5 + (height - (left + up) * 0.5) * 0.06, 0.15, 1.0
			)

			var color: Color = Color(0.30, 0.36, 0.24).lerp(Color(0.62, 0.58, 0.48), t)
			if t > 0.72:
				color = color.lerp(Color(0.93, 0.94, 0.96), smoothstep(0.72, 0.95, t))
			color *= shade

			var lake: int = map.hydro.lake_id[index]
			if lake >= 0:
				var depth: float = map.hydro.lakes[lake].surface_z - height
				color = Color(0.16, 0.34, 0.52).lerp(
					Color(0.04, 0.12, 0.28), clampf(depth / 18.0, 0.0, 1.0)
				)
			image.set_pixel(cx, cz, color)

	_draw_rivers(image)
	_draw_roads(image)
	_draw_claims(image)
	return image


func _draw_rivers(image: Image) -> void:
	for reach in map.hydro.rivers:
		var tone: Color = Color(0.30, 0.62, 0.86).lerp(
			Color(0.10, 0.36, 0.72), clampf(float(reach.order - 1) / 4.0, 0.0, 1.0)
		)
		var thickness: int = clampi(reach.order, 1, 3)
		for i in range(reach.points.size() - 1):
			_line(image, reach.points[i], reach.points[i + 1], tone, thickness)


func _draw_roads(image: Image) -> void:
	for road in map.paths.roads:
		var tone: Color = Color(0.86, 0.76, 0.50)
		var thickness: int = 1
		match road.tier:
			RoadEdge.Tier.PRIMARY:
				tone = Color(0.94, 0.82, 0.42)
				thickness = 2
			RoadEdge.Tier.TRAIL:
				tone = Color(0.68, 0.60, 0.44)
		for i in range(road.points.size() - 1):
			_line(image, road.points[i], road.points[i + 1], tone, thickness)

	for site in map.paths.bridges:
		var center: Vector3 = site.center()
		_dot(image, Vector2(center.x, center.z),
			Color(0.95, 0.45, 0.25) if not site.is_ford else Color(0.55, 0.85, 0.95), 2)


func _draw_claims(image: Image) -> void:
	for claim in map.claims.claims:
		match claim.kind:
			&"settlement":
				_dot(image, claim.center, Color(1.0, 0.95, 0.35), 3)
			&"dungeon_mouth":
				_dot(image, claim.center, Color(0.72, 0.35, 0.85), 2)


func _to_pixel(world_x: float, world_z: float) -> Vector2i:
	var cs: float = map.config.macro_cell_size
	return Vector2i(int(world_x / cs), int(world_z / cs))


func _line(image: Image, a: Vector3, b: Vector3, color: Color, thickness: int) -> void:
	var pa: Vector2i = _to_pixel(a.x, a.z)
	var pb: Vector2i = _to_pixel(b.x, b.z)
	var steps: int = maxi(absi(pb.x - pa.x), absi(pb.y - pa.y))
	for s in steps + 1:
		var t: float = float(s) / float(maxi(steps, 1))
		_dot_pixel(image, Vector2i(
			roundi(lerpf(float(pa.x), float(pb.x), t)),
			roundi(lerpf(float(pa.y), float(pb.y), t))
		), color, thickness)


func _dot(image: Image, position: Vector2, color: Color, radius: int) -> void:
	_dot_pixel(image, _to_pixel(position.x, position.y), color, radius)


func _dot_pixel(image: Image, p: Vector2i, color: Color, radius: int) -> void:
	var size: int = image.get_width()
	for dz in range(-radius + 1, radius):
		for dx in range(-radius + 1, radius):
			var x: int = p.x + dx
			var z: int = p.y + dz
			if x < 0 or z < 0 or x >= size or z >= size:
				continue
			image.set_pixel(x, z, color)


func _draw() -> void:
	if _texture == null:
		return
	var side: float = minf(size.x, size.y) - 40.0
	_origin = Vector2((size.x - side) * 0.5, (size.y - side) * 0.5)
	_scale = side / float(map.terrain.cells)

	draw_rect(Rect2(_origin - Vector2.ONE * 6.0, Vector2.ONE * (side + 12.0)),
		Color(0.05, 0.05, 0.07, 0.88))
	draw_texture_rect(_texture, Rect2(_origin, Vector2.ONE * side), false)

	if player != null:
		var world_pos: Vector3 = WorldOrigin.to_world(player.global_position)
		var cell: Vector2 = Vector2(world_pos.x, world_pos.z) / map.config.macro_cell_size
		var marker: Vector2 = _origin + cell * _scale
		draw_circle(marker, 5.0, Color(1.0, 0.25, 0.2))
		draw_circle(marker, 2.0, Color.WHITE)

	draw_string(
		ThemeDB.fallback_font,
		_origin + Vector2(0.0, -12.0),
		"World map  -  blue: rivers by Strahler order  -  yellow: settlements  -  orange: bridges",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.85, 0.9)
	)


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()
