extends SceneTree
## Stress-check atlas lake contiguity across seeds/sizes.
##
##   godot --headless --path <project> --script res://tools/tests/atlas_lake_stress.gd


func _initialize() -> void:
	print("=== Atlas lake contiguity stress ===")
	var failures: int = 0
	var cases: Array = [
		[20260809, 128],
		[42, 128],
		[7, 256],
		[42, 256],
		[99, 256],
		[20260809, 256],
		[1, 512],
		[42, 512],
	]
	for case_variant in cases:
		var case: Array = case_variant
		var seed_i: int = int(case[0])
		var size_i: int = int(case[1])
		var atlas: ContinentAtlas = ContinentAtlas.generate(seed_i, size_i)
		var errors: PackedStringArray = atlas.validate()
		var lake_errs: PackedStringArray = PackedStringArray()
		for err in errors:
			if str(err).begins_with("lake "):
				lake_errs.append(err)
		var m: Dictionary = atlas.depression_metrics
		var band_line: String = (
			"raw=%d promoted=%d coast=%d plains=%d hills=%d alpine=%d"
			% [
				int(m.get("raw_depressions", 0)),
				int(m.get("promoted", 0)),
				int(m.get("band_coast", 0)),
				int(m.get("band_plains", 0)),
				int(m.get("band_hills", 0)),
				int(m.get("band_alpine", 0)),
			]
		)
		var plains: int = int(m.get("band_plains", 0))
		var hills: int = int(m.get("band_hills", 0))
		var alpine: int = int(m.get("band_alpine", 0))
		# Fail if every promoted lake is a plains sheet (lowland flood mode).
		var plains_flood: bool = (
			atlas.lakes.size() >= 4
			and plains > 0
			and hills + alpine == 0
			and plains >= atlas.lakes.size()
		)
		if plains_flood:
			failures += 1
			print(
				"  FAIL  seed=%d size=%d plains-only flood lakes=%d | %s" % [
					seed_i, size_i, atlas.lakes.size(), band_line
				]
			)
		elif lake_errs.is_empty() and errors.is_empty():
			print(
				"  PASS  seed=%d size=%d lakes=%d secondary=%d ms=%d | %s" % [
					seed_i, size_i, atlas.lakes.size(), atlas.secondary_massif_count,
					atlas.generate_ms, band_line
				]
			)
		elif lake_errs.is_empty():
			print(
				"  WARN  seed=%d size=%d non-lake errors=%d (ignored here) | %s" % [
					seed_i, size_i, errors.size(), band_line
				]
			)
			for err in errors:
				print("        · ", err)
		else:
			failures += 1
			print(
				"  FAIL  seed=%d size=%d lakes=%d | %s" % [
					seed_i, size_i, atlas.lakes.size(), band_line
				]
			)
			for err in lake_errs:
				print("        · ", err)
	print("---")
	print("%d lake-failure cases" % failures)
	quit(1 if failures > 0 else 0)
