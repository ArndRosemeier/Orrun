extends Control
## Streaming and world state, so problems are visible while walking rather than
## only in a test run.

var streamer: Streamer
var map: WorldMap
var player: Node3D

var _label: Label


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(16.0, 12.0)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)


func bind(world_streamer: Streamer, world_map: WorldMap, player_node: Node3D) -> void:
	streamer = world_streamer
	map = world_map
	player = player_node


func _process(_delta: float) -> void:
	if not visible or map == null:
		return

	var world_pos: Vector3 = WorldOrigin.to_world(player.global_position)
	var chunk: Vector2i = WorldCoords.chunk_of(map.config, world_pos.x, world_pos.z)
	var region: Vector2i = WorldCoords.region_of(world_pos.x, world_pos.z)
	var info: Dictionary = map.describe_at(world_pos.x, world_pos.z)

	var water: float = WorldQuery.water_surface_at(map, world_pos.x, world_pos.z)
	var water_text: String = "dry" if water == -INF else "water at %.1f m" % water
	var clearance: float = WorldQuery.road_clearance(map, world_pos.x, world_pos.z)
	var road_text: String = (
		"on road" if clearance < 0.0 else "road %.0f m away" % clearance
	)

	_label.text = "\n".join(PackedStringArray([
		"Orrun  %.0f FPS" % Engine.get_frames_per_second(),
		"world %.0f, %.0f, %.0f   origin offset %.0f, %.0f" % [
			world_pos.x, world_pos.y, world_pos.z,
			WorldOrigin.offset.x, WorldOrigin.offset.z
		],
		"chunk %d,%d   region %d,%d   %d live, %d regions, queue %d" % [
			chunk.x, chunk.y, region.x, region.y,
			streamer.stat_chunks_live, streamer.region_count(), streamer.queue_depth()
		],
		"biome %s   ground %.1f m   drainage %.1f m   %s" % [
			info["biome"], info["macro_height"], info["drainage_height"], water_text
		],
		"flow %.0f cells   %s   %s   claim: %s" % [
			info["accumulation"],
			"channel" if info["channel"] else "no channel",
			road_text,
			info["claim"] if String(info["claim"]) != "" else "none"
		],
		"last chunk %d ms   worst ground-above-water %.3f m" % [
			streamer.stat_last_build_ms, streamer.stat_worst_contract_error
		],
		"F1 hud   F2 map   F3 corridor mask   V fly   Esc mouse",
	]))
