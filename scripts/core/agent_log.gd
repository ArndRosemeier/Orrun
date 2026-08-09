extends Node
## Boots a project-local error log for agent and human debugging.
##
## On-screen script-error dialogs disappear when dismissed. Everything that
## reaches Godot's error stream is also appended to
## [code]logs/godot_runtime.log[/code] under the project root so it can be read
## after the fact. Prefer that file over asking what the dialog said.
##
## Autoloaded as [code]AgentLog[/code] and registered before gameplay starts.
## Uses [code]preload[/code] rather than a [code]class_name[/code] type: autoload
## scripts are parsed before the global class cache is ready.

const RELATIVE_LOG: String = "logs/godot_runtime.log"
const _LOGGER_SCRIPT: GDScript = preload("res://scripts/core/agent_file_logger.gd")

var log_path: String = ""
var _logger: Logger


func _enter_tree() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").rstrip("/\\")
	var log_dir: String = project_root.path_join("logs")
	DirAccess.make_dir_recursive_absolute(log_dir)
	log_path = log_dir.path_join("godot_runtime.log")

	var stamp: String = Time.get_datetime_string_from_system()
	var header: FileAccess = FileAccess.open(log_path, FileAccess.WRITE)
	if header != null:
		header.store_string("--- Orrun session %s ---\n" % stamp)
		header.store_string("log_path %s\n" % log_path)
		header.close()

	_logger = _LOGGER_SCRIPT.new(log_path) as Logger
	OS.add_logger(_logger)
	# print() is fine here: AgentFileLogger ignores non-error messages, so this
	# cannot recurse through _log_message.
	print("AgentLog: errors -> %s" % log_path)
