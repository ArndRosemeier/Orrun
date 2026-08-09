extends Control
## Streaming and world state, so problems are visible while walking rather than
## only in a test run.

var streamer: Streamer
var sectors: SectorManager
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


func bind(
	world_streamer: Streamer, sector_manager: SectorManager, player_node: Node3D
) -> void:
	streamer = world_streamer
	sectors = sector_manager
	player = player_node


func _process(_delta: float) -> void:
	if not visible or sectors == null:
		return

	var config: WorldConfig = sectors.context.config
	var world_pos: Vector3 = WorldOrigin.to_world(player.global_position)
	var chunk: Vector2i = WorldCoords.chunk_of(config, world_pos.x, world_pos.z)
	var sector_coord: Vector2i = WorldCoords.sector_of(world_pos.x, world_pos.z)
	var sector: WorldSector = sectors.get_sector(sector_coord)

	var lines: PackedStringArray = PackedStringArray([
		"Orrun  %.0f FPS" % Engine.get_frames_per_second(),
		"continental %.0f, %.0f, %.0f   origin offset %.0f, %.0f" % [
			world_pos.x, world_pos.y, world_pos.z,
			WorldOrigin.offset.x, WorldOrigin.offset.z
		],
		"sector %d,%d   chunk %d,%d   %d live, %d pages, queue %d" % [
			sector_coord.x, sector_coord.y, chunk.x, chunk.y,
			streamer.stat_chunks_live, streamer.region_count(), streamer.queue_depth()
		],
		"sectors: %d cached, %d baking, %d evicted, last bake %d ms" % [
			sectors.live_count(), sectors.pending_count(),
			sectors.stat_evicted, sectors.stat_last_bake_ms
		],
	])

	if sector == null:
		lines.append("sector still baking - chunks held: %d" % streamer.stat_chunks_waiting_on_sector)
	else:
		var continental: ContinentalTerrain = sectors.context.sampler()
		var info: Dictionary = sector.describe_at(world_pos.x, world_pos.z)
		var water: float = WorldQuery.water_surface_at(
			sector, continental, world_pos.x, world_pos.z
		)
		var water_text: String = "dry" if water == -INF else "water at %.1f m" % water
		var clearance: float = WorldQuery.road_clearance(sector, world_pos.x, world_pos.z)
		var road_text: String = (
			"on road" if clearance < 0.0 else "road %.0f m away" % clearance
		)
		lines.append("biome %s   ground %.1f m   drainage %.1f m   %s" % [
			info["biome"], info["macro_height"], info["drainage_height"], water_text
		])
		lines.append("flow %.0f cells   %s%s%s   %s   claim: %s" % [
			info["accumulation"],
			"channel" if info["channel"] else "no channel",
			"  trunk" if info["trunk"] else "",
			"  sea/atlas lake" if info["atlas_water"] else "",
			road_text,
			info["claim"] if String(info["claim"]) != "" else "none"
		])

	lines.append("last chunk %d ms   worst ground-above-water %.3f m" % [
		streamer.stat_last_build_ms, streamer.stat_worst_contract_error
	])
	lines.append("F1 hud   F2 map   F3 corridor mask   V fly   Esc mouse")
	_label.text = "\n".join(lines)
