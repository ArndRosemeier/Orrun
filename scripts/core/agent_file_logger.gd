class_name AgentFileLogger
extends Logger
## Appends Godot's error/warning stream to a project-local file so an agent (or
## a human) can read script errors after the on-screen dialog was dismissed.
##
## Registered from [AgentLog]. Thread-safe: the engine may call in from workers.

var _path: String = ""
var _mutex: Mutex = Mutex.new()


func _init(path: String) -> void:
	_path = path


func _log_message(message: String, error: bool) -> void:
	if not error:
		return
	_append("STDERR  %s" % message.strip_edges())


func _log_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	script_backtraces: Array
) -> void:
	var kind: String = "ERROR"
	match error_type:
		Logger.ERROR_TYPE_WARNING:
			kind = "WARNING"
		Logger.ERROR_TYPE_SCRIPT:
			kind = "SCRIPT"
		Logger.ERROR_TYPE_SHADER:
			kind = "SHADER"
	var lines: PackedStringArray = PackedStringArray()
	lines.append(
		"%s  %s:%d  in %s()" % [kind, file, line, function]
	)
	if not code.is_empty():
		lines.append("  code: %s" % code)
	if not rationale.is_empty():
		lines.append("  rationale: %s" % rationale)
	for backtrace_variant in script_backtraces:
		if backtrace_variant == null:
			continue
		lines.append("  backtrace:")
		lines.append("  %s" % str(backtrace_variant).replace("\n", "\n  "))
	_append("\n".join(lines))


func _append(text: String) -> void:
	_mutex.lock()
	var file: FileAccess = FileAccess.open(_path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		_mutex.unlock()
		return
	file.seek_end()
	file.store_string(text)
	file.store_string("\n")
	file.flush()
	file.close()
	_mutex.unlock()
