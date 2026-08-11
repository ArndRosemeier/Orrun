class_name HitchLog
extends RefCounted
## Appends main-thread hitch breakdowns to [code]logs/streamer_hitches.log[/code].
##
## Call [method record] when a subsystem spent more than [member threshold_ms]
## on the main thread. Lines are plain text so agents can grep them after a walk.

const RELATIVE_LOG: String = "logs/streamer_hitches.log"
## Frames at or above this cost are written. 8 ms is half a 60 Hz budget.
const DEFAULT_THRESHOLD_MS: float = 8.0

static var threshold_ms: float = DEFAULT_THRESHOLD_MS
static var _path: String = ""
static var _opened: bool = false
static var hitch_count: int = 0
static var last_hitch_ms: float = 0.0
static var last_hitch_source: String = ""
static var last_hitch_detail: String = ""


static func configure(threshold: float) -> void:
	threshold_ms = threshold
	# Force a fresh file on the next ensure_open so threshold is in the header.
	_opened = false


static func ensure_open() -> void:
	if _opened:
		return
	var project_root: String = ProjectSettings.globalize_path("res://").rstrip("/\\")
	var log_dir: String = project_root.path_join("logs")
	DirAccess.make_dir_recursive_absolute(log_dir)
	_path = log_dir.path_join("streamer_hitches.log")
	var stamp: String = Time.get_datetime_string_from_system()
	var file: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	if file != null:
		file.store_string("--- Orrun hitch log %s (threshold %.1f ms) ---\n" % [
			stamp, threshold_ms
		])
		file.close()
	_opened = true
	hitch_count = 0


## [param parts] maps phase name -> milliseconds. Only recorded when total >= threshold.
static func record(source: String, total_ms: float, parts: Dictionary = {}, note: String = "") -> void:
	if total_ms < threshold_ms:
		return
	ensure_open()
	hitch_count += 1
	last_hitch_ms = total_ms
	last_hitch_source = source
	var ordered: PackedStringArray = PackedStringArray()
	var keys: Array = parts.keys()
	keys.sort_custom(func(a, b) -> bool: return float(parts[a]) > float(parts[b]))
	for key in keys:
		var ms: float = float(parts[key])
		if ms < 0.05:
			continue
		ordered.append("%s=%.2f" % [key, ms])
	var detail: String = " ".join(ordered)
	if not note.is_empty():
		detail = ("%s | %s" % [detail, note]) if not detail.is_empty() else note
	last_hitch_detail = detail
	var line: String = "t=%.3f frame=%d %s total=%.2fms %s\n" % [
		Time.get_ticks_msec() * 0.001,
		Engine.get_process_frames(),
		source,
		total_ms,
		detail,
	]
	var file: FileAccess = FileAccess.open(_path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		push_error("HitchLog: cannot open %s" % _path)
		return
	file.seek_end()
	file.store_string(line)
	file.close()


static func summary_line() -> String:
	if hitch_count <= 0:
		return "hitches 0 (log %s)" % RELATIVE_LOG
	return "hitches %d  last %.1fms %s [%s]" % [
		hitch_count, last_hitch_ms, last_hitch_source, last_hitch_detail
	]
