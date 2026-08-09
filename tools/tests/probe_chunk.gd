extends SceneTree
## Prints why one chunk breaks the drainage-surface contract.
##
##   godot --headless --path <project> --script res://tools/tests/probe_chunk.gd -- 165 65 [lod]
##
## The suite reports a worst error and a chunk; this says which column, how the
## carve got there, and what the hydrology thought the water was doing.


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var chunk: Vector2i = Vector2i(int(args[0]), int(args[1]))
	var lod: int = int(args[2]) if args.size() > 2 else 0

	var config: WorldConfig = WorldConfig.new()
	var map: WorldMap = WorldMap.generate(config)
	var noise: NoiseSet = NoiseSet.create(config)
	var field: DensityField.Field = DensityField.build(config, map, noise, chunk, lod)

	print("chunk %s lod %d, voxel %.1f m, worst %.3f m" % [
		chunk, lod, field.voxel, field.max_contract_error
	])

	var samples: int = field.dims.x
	var reported: int = 0
	for iz in samples:
		for ix in samples:
			var column: int = iz * samples + ix
			if field.contract_error[column] < 1.0 or reported >= 6:
				continue
			reported += 1
			var world: Vector3 = field.sample_world_position(ix, 0, iz)
			var lake_surface: float = map.hydro.lake_surface_near_at(world.x, world.z)
			print("  %.0f,%.0f  error %.2f  surface %.2f  water_top %.2f  wet %.2f" % [
				world.x, world.z, field.contract_error[column],
				field.surface_z[column], field.water_top[column],
				field.wetness[column]
			])
			print("      macro %.2f  drainage %.2f  lake_near %.2f  lake_dist %.0f  mask %.2f" % [
				map.terrain.height_at(world.x, world.z),
				map.hydro.drainage_at(world.x, world.z),
				lake_surface,
				map.hydro.lake_distance_at(world.x, world.z),
				field.corridor_mask[column]
			])
	quit(0)
