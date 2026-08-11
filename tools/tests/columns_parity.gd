extends SceneTree
## Smoke + shape checks for native DensityField columns.
##
##   godot --headless --path <project> --script res://tools/tests/columns_parity.gd


func _initialize() -> void:
	print("=== columns parity / smoke ===")
	assert(ClassDB.class_exists("OrrunGen"), "OrrunGen missing")
	var gen: RefCounted = ClassDB.instantiate("OrrunGen")
	var ver: String = str(gen.call("version"))
	print("  native: ", ver)
	assert(ver.contains("columns"), "version should advertise columns")

	var n: int = 8
	var count: int = n * n
	var grids := PackedFloat32Array()
	grids.resize(count * 10)
	for i in count:
		grids[i] = 40.0 + float(i % n) * 0.5
		grids[count + i] = 8.0
		grids[count * 2 + i] = 0.55
		grids[count * 3 + i] = 0.5
		grids[count * 4 + i] = 500.0
		grids[count * 5 + i] = 0.0
		grids[count * 6 + i] = 999.0
		grids[count * 7 + i] = DensityField.NO_WATER_FFI
		grids[count * 8 + i] = grids[i] - 1.0
		grids[count * 9 + i] = DensityField.NO_WATER_FFI

	var starts := PackedInt32Array()
	starts.resize(34)
	for i in 34:
		starts[i] = 0
	var params := {
		"samples_h": n,
		"voxel": 2.0,
		"origin_x": 0.0,
		"origin_z": 0.0,
		"tile_span": 4.0,
		"corridor_inner": 6.0,
		"corridor_outer": 70.0,
		"macro_cell_size": 32.0,
		"relief_amp_mountains": 28.0,
		"relief_amp_plains": 3.0,
		"overhang_amount": 0.5,
		"seed_relief": 1,
		"seed_relief_fine": 2,
	}
	var result: Dictionary = gen.call(
		"build_columns",
		grids,
		PackedFloat32Array(),
		PackedFloat32Array(),
		starts,
		PackedInt32Array(),
		0,
		PackedVector3Array(),
		PackedFloat32Array(),
		params
	)
	assert(result.has("surface_z"), "missing surface_z")
	var surface: PackedFloat32Array = result["surface_z"]
	assert(surface.size() == count, "surface size")
	for i in count:
		assert(
			is_finite(surface[i]) and surface[i] > DensityField.NO_WATER_FFI_THRESH,
			"surface must be finite land height"
		)
	var water: PackedFloat32Array = result["water_top"]
	var dry := 0
	for i in count:
		if water[i] <= DensityField.NO_WATER_FFI_THRESH:
			dry += 1
	assert(dry == count, "dry grid must keep NO_WATER sentinel on every column")
	assert(int(result["wet_columns"]) == 0, "dry grid wet_columns")
	print("  PASS  synthetic dry grid (%d cells, surface[0]=%.2f, dry water markers)" % [
		count, surface[0]
	])
	print("---")
	quit(0)
