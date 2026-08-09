extends SceneTree
## Prints the shape of the atlas elevation field: how high it gets, how steep it
## gets between neighbouring kilometres, and what the refined 3D surface makes
## of the steepest place it can find.
##
##   godot --headless --path <project> --script res://tools/tests/atlas_probe.gd


func _init() -> void:
	var config: WorldConfig = WorldConfig.new()
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var continental: ContinentalTerrain = context.sampler()

	var highest: int = 0
	var highest_cell: Vector2i = Vector2i.ZERO
	var most_relief: int = 0
	var steepest: int = 0
	var steepest_cell: Vector2i = Vector2i.ZERO
	var land: int = 0

	for az in atlas.size:
		for ax in atlas.size:
			if atlas.is_ocean(ax, az):
				continue
			land += 1
			var packed: int = atlas.cell_at(ax, az)
			var metres: int = AtlasPack.elevation_to_metres(AtlasPack.elevation(packed))
			if metres > highest:
				highest = metres
				highest_cell = Vector2i(ax, az)
			most_relief = maxi(most_relief, AtlasPack.relief(packed))
			if ax + 1 >= atlas.size:
				continue
			var east: int = AtlasPack.elevation_to_metres(
				AtlasPack.elevation(atlas.cell_at(ax + 1, az))
			)
			if absi(east - metres) > steepest:
				steepest = absi(east - metres)
				steepest_cell = Vector2i(ax, az)

	print("atlas %d km, %d land cells" % [atlas.size, land])
	print("highest land %d m at %s, max relief code %d" % [
		highest, highest_cell, most_relief
	])
	print("steepest kilometre %d m at %s" % [steepest, steepest_cell])

	_profile("highest", continental, highest_cell)
	_profile("steepest", continental, steepest_cell)
	quit(0)


## Walks 4 km east through a cell and prints the refined surface, so a plateau
## and a mountainside can be told apart.
func _profile(name: String, continental: ContinentalTerrain, cell: Vector2i) -> void:
	var origin: Vector2 = Vector2(cell) * ContinentAtlas.CELL_METRES
	var heights: PackedStringArray = PackedStringArray()
	var lowest: float = INF
	var top: float = -INF
	for i in 17:
		var at: Vector2 = origin + Vector2(float(i) * 250.0, 500.0)
		var h: float = continental.height_at(at.x, at.y)
		lowest = minf(lowest, h)
		top = maxf(top, h)
		heights.append("%.0f" % h)
	print("%s cell %s: %s" % [name, cell, " ".join(heights)])
	print("  relief amp %.1f m, span %.0f m over 4 km" % [
		continental.relief_amp_at(origin.x, origin.y + 500.0), top - lowest
	])
