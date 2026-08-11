extends Node
## Boots main, walks for a fixed wall-clock window, then prints hitch log stats.
##
##   start.bat --path . res://tools/tests/hitch_probe.tscn
##   (or headless with the Godot voxel exe)
##
## Writes detailed lines to logs/streamer_hitches.log while walking.

const _HitchLog: GDScript = preload("res://scripts/core/hitch_log.gd")
const WARMUP_SECONDS: float = 240.0
const WALK_SECONDS: float = 25.0
const WALK_SPEED: float = 80.0

var main: Node3D
var streamer: Streamer
var player: PlayerController
var started_msec: int = 0
var walk_started_msec: int = 0
var phase: String = "warmup"
var _walk_dir: Vector3 = Vector3.RIGHT


func _ready() -> void:
	print("=== Orrun hitch probe ===")
	_HitchLog.configure(6.0)
	_HitchLog.ensure_open()
	started_msec = Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	streamer = main.get_node("Streamer")
	player = main.get_node("Player")


func _process(delta: float) -> void:
	match phase:
		"warmup":
			_warmup()
		"walk":
			_walk(delta)
		"done":
			pass


func _warmup() -> void:
	if player.frozen:
		if Time.get_ticks_msec() - started_msec > int(WARMUP_SECONDS * 1000.0):
			printerr("FAIL player never spawned")
			_finish(1)
		return
	var start: Vector3 = player.world_position()
	var rect: Rect2 = WorldCoords.sector_rect(WorldCoords.sector_of(start.x, start.z))
	var options: Array = [
		[Vector3.LEFT, start.x - rect.position.x],
		[Vector3.RIGHT, rect.end.x - start.x],
		[Vector3.FORWARD, start.z - rect.position.y],
		[Vector3.BACK, rect.end.y - start.z],
	]
	var best: Array = options[0]
	for option in options:
		if option[1] < best[1]:
			best = option
	_walk_dir = best[0]
	walk_started_msec = Time.get_ticks_msec()
	phase = "walk"
	print("spawned; walking %s for %.0f s at %.0f m/s" % [
		_walk_dir, WALK_SECONDS, WALK_SPEED
	])
	print("hitch log -> logs/streamer_hitches.log (threshold %.1f ms)" % _HitchLog.threshold_ms)


func _walk(delta: float) -> void:
	player.flying = true
	player.global_position += _walk_dir * WALK_SPEED * delta
	var elapsed: float = float(Time.get_ticks_msec() - walk_started_msec) * 0.001
	if elapsed >= WALK_SECONDS:
		_report()
		_finish(0)


func _report() -> void:
	print("--- hitch probe summary ---")
	print(_HitchLog.summary_line())
	print("streamer last frame %.2f ms install %.2f ms x%d" % [
		streamer.stat_frame_ms, streamer.stat_install_ms, streamer.stat_installed_this_frame
	])
	var path: String = ProjectSettings.globalize_path("res://").rstrip("/\\").path_join(
		"logs/streamer_hitches.log"
	)
	if FileAccess.file_exists(path):
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file != null:
			var text: String = file.get_as_text()
			file.close()
			var lines: PackedStringArray = text.split("\n", false)
			print("hitch log lines: %d" % lines.size())
			var sources: Dictionary = {}
			for line in lines:
				if not line.begins_with("t="):
					continue
				var parts: PackedStringArray = line.split(" ")
				for part in parts:
					if part in ["streamer", "fauna_refresh", "fauna_tick", "hydro_map"]:
						sources[part] = int(sources.get(part, 0)) + 1
						break
			print("by source: %s" % str(sources))
			# Print the 12 worst by total= field.
			var scored: Array = []
			for line in lines:
				if "total=" not in line:
					continue
				var total_token: String = ""
				for part in line.split(" "):
					if part.begins_with("total=") and part.ends_with("ms"):
						total_token = part.substr(6, part.length() - 8)
						break
				if total_token.is_empty():
					continue
				scored.append([float(total_token), line])
			scored.sort_custom(func(a, b) -> bool: return a[0] > b[0])
			print("worst hitches:")
			for i in mini(scored.size(), 12):
				print("  %s" % scored[i][1])


func _finish(code: int) -> void:
	phase = "done"
	print("=== hitch probe done (exit %d) ===" % code)
	get_tree().quit(code)
