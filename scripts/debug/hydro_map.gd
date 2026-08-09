extends Control
## Always-on sector minimap: relief, drainage, lakes and roads under the player.
##
## This is the bake underfoot, not the continent. Open the world map (M) to see
## the whole atlas and teleport. The minimap only redraws when the player
## crosses into a new sector.

var sectors: SectorManager
var player: Node3D

var _texture: ImageTexture
var _drawn_sector: Vector2i = Vector2i(2147483647, 2147483647)
var _sector: WorldSector
var _origin: Vector2 = Vector2.ZERO
var _side: float = 1.0


func build(sector_manager: SectorManager, player_node: Node3D) -> void:
	sectors = sector_manager
	player = player_node
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = true


func _refresh() -> void:
	var world_pos: Vector3 = WorldOrigin.to_world(player.global_position)
	var coord: Vector2i = WorldCoords.sector_of(world_pos.x, world_pos.z)
	if coord == _drawn_sector and _texture != null:
		return
	var sector: WorldSector = sectors.get_sector(coord)
	if sector == null:
		return
	_sector = sector
	_drawn_sector = coord
	_texture = ImageTexture.create_from_image(_render_sector(sector))


func _render_sector(sector: WorldSector) -> Image:
	var cells: int = sector.terrain.cells
	var image: Image = Image.create_empty(cells, cells, false, Image.FORMAT_RGB8)

	var low: float = sector.terrain.min_elevation
	var high: float = sector.terrain.max_elevation
	var span: float = maxf(high - low, 1.0)

	for cz in cells:
		for cx in cells:
			var index: int = cz * cells + cx
			var height: float = sector.terrain.elevation[index]
			var t: float = (height - low) / span

			var left: float = sector.terrain.elevation[
				sector.terrain.clamped_index(cx - 1, cz)
			]
			var up: float = sector.terrain.elevation[
				sector.terrain.clamped_index(cx, cz - 1)
			]
			var shade: float = clampf(
				0.5 + (height - (left + up) * 0.5) * 0.06, 0.15, 1.0
			)

			var color: Color = Color(0.30, 0.36, 0.24).lerp(Color(0.62, 0.58, 0.48), t)
			if t > 0.72:
				color = color.lerp(Color(0.93, 0.94, 0.96), smoothstep(0.72, 0.95, t))
			color *= shade

			if sector.hydro.atlas_water[index] != 0:
				color = Color(0.08, 0.20, 0.38)
			var lake: int = sector.hydro.lake_id[index]
			if lake >= 0:
				var depth: float = sector.hydro.lakes[lake].surface_z - height
				color = Color(0.16, 0.34, 0.52).lerp(
					Color(0.04, 0.12, 0.28), clampf(depth / 18.0, 0.0, 1.0)
				)
			image.set_pixel(cx, cz, color)

	_draw_rivers(image)
	_draw_roads(image)
	_draw_claims(image)
	return image


func _draw_rivers(image: Image) -> void:
	for reach in _sector.hydro.rivers:
		var tone: Color = Color(0.30, 0.62, 0.86).lerp(
			Color(0.10, 0.36, 0.72), clampf(float(reach.order - 1) / 4.0, 0.0, 1.0)
		)
		if reach.is_trunk:
			tone = Color(0.20, 0.85, 0.95)
		var thickness: int = clampi(reach.order, 1, 3)
		for i in range(reach.points.size() - 1):
			_line(image, reach.points[i], reach.points[i + 1], tone, thickness)


func _draw_roads(image: Image) -> void:
	for road in _sector.paths.roads:
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

	for site in _sector.paths.bridges:
		var center: Vector3 = site.center()
		_dot(
			image, Vector2(center.x, center.z),
			Color(0.95, 0.45, 0.25) if not site.is_ford else Color(0.55, 0.85, 0.95), 2
		)


func _draw_claims(image: Image) -> void:
	for claim in _sector.claims.claims:
		match claim.kind:
			&"settlement":
				_dot(image, claim.center, Color(1.0, 0.95, 0.35), 3)
			&"dungeon_mouth":
				_dot(image, claim.center, Color(0.72, 0.35, 0.85), 2)


func _to_pixel(world_x: float, world_z: float) -> Vector2i:
	return _sector.terrain.local_cell_of(world_x, world_z)


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
	var size_px: int = image.get_width()
	for dz in range(-radius + 1, radius):
		for dx in range(-radius + 1, radius):
			var x: int = p.x + dx
			var z: int = p.y + dz
			if x < 0 or z < 0 or x >= size_px or z >= size_px:
				continue
			image.set_pixel(x, z, color)


func _draw() -> void:
	if _texture == null or _sector == null:
		return
	var pad: float = 8.0
	_side = minf(size.x, size.y) - pad * 2.0
	_origin = Vector2((size.x - _side) * 0.5, (size.y - _side) * 0.5)
	var pixels: float = float(_sector.terrain.cells)

	draw_rect(
		Rect2(_origin - Vector2.ONE * 4.0, Vector2.ONE * (_side + 8.0)),
		Color(0.05, 0.05, 0.07, 0.82)
	)
	draw_texture_rect(_texture, Rect2(_origin, Vector2.ONE * _side), false)

	var core_scale: float = _side / pixels
	draw_rect(
		Rect2(
			_origin + Vector2(_sector.core_min) * core_scale,
			Vector2(_sector.core_max - _sector.core_min + Vector2i.ONE) * core_scale
		),
		Color(1.0, 1.0, 1.0, 0.35), false, 1.0
	)

	if player != null:
		var world_pos: Vector3 = WorldOrigin.to_world(player.global_position)
		var cell: Vector2 = Vector2(
			_sector.terrain.local_cell_of(world_pos.x, world_pos.z)
		)
		var marker: Vector2 = _origin + cell * core_scale
		draw_circle(marker, 4.0, Color(1.0, 0.25, 0.2))
		draw_circle(marker, 1.8, Color.WHITE)

	draw_string(
		ThemeDB.fallback_font,
		_origin + Vector2(2.0, _side + 12.0),
		"%d,%d  M: world" % [_drawn_sector.x, _drawn_sector.y],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.85, 0.9)
	)


func _process(_delta: float) -> void:
	if not visible or sectors == null or player == null:
		return
	_refresh()
	queue_redraw()
