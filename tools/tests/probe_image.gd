extends SceneTree
## Prints the colour of a few pixels in a screenshot.
##
##   godot --headless --path <project> --script res://tools/tests/probe_image.gd -- <png> ...
##
## Eyes are unreliable about very dark pixels: ground that is merely
## underexposed and ground that is not drawn at all look the same in a review,
## and the difference decides which bug is being chased.

static var SAMPLE_ROWS: PackedFloat32Array = PackedFloat32Array([0.15, 0.45, 0.75, 0.95])
static var SAMPLE_COLS: PackedFloat32Array = PackedFloat32Array([0.2, 0.5, 0.8])


func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		var image: Image = Image.load_from_file(path)
		print("%s  %dx%d" % [path, image.get_width(), image.get_height()])
		for row in SAMPLE_ROWS:
			var line: String = "  y=%.2f " % row
			for col in SAMPLE_COLS:
				var color: Color = image.get_pixel(
					int(col * float(image.get_width() - 1)),
					int(row * float(image.get_height() - 1))
				)
				line += "  (%.3f %.3f %.3f)" % [color.r, color.g, color.b]
			print(line)
	quit(0)
