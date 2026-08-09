extends Node
## Renders the world from a few chosen viewpoints and writes PNGs to docs/shots.
##
## Ground level is read from the continental surface rather than from a bake, so
## a viewpoint may sit anywhere on the continent; the streamer bakes whatever
## sector it lands in while the shot waits for its chunk.
##
##   godot --path <project> --resolution 1600x900 res://tools/tests/screenshots.tscn
##
## Needs a real rendering device, so unlike the other tests this one opens a
## window. It is how the landscape gets judged: plains, a trunk river, a lake, a
## bridge crossing, high relief and a cave mouth, all from the same seed.
##
## Subjects - a particular river, lake or bridge - come from the sector the game
## spawns in, because that is the one sector already baked. High ground does
## not: a spawn beside a river mouth is coastal lowland by definition, and its
## tallest hill is not a mountain shot.

const OUTPUT_DIR: String = "res://docs/shots"
const SETTLE_FRAMES: int = 30
## The whole LOD ring has to be present before a shot means anything. A partly
## streamed world photographs as islands of ground floating in fog.
const MAX_WAIT_FRAMES: int = 6000

class Shot extends RefCounted:
	var name: String
	var eye: Vector3
	var target: Vector3
	var caption: String = ""

var main: MainWorld
var streamer: Streamer
var player: PlayerController
var camera: Camera3D
var continental: ContinentalTerrain

var shots: Array[Shot] = []
var index: int = -1
var wait_frames: int = 0
var settle: int = 0
var started: bool = false
var capturing: bool = false
var finished: bool = false
var suffix: String = ""
var _probes: Array[MeshInstance3D] = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	streamer = main.get_node("Streamer")
	player = main.get_node("Player")

	# Anything that changes generated geometry has to be set before the first
	# chunk is queued, not when the first shot is framed.
	if OS.get_cmdline_user_args().has("--no-skirts"):
		main.config.skirts_enabled = false
		suffix = "_noskirt"

	camera = Camera3D.new()
	camera.fov = 68.0
	camera.far = 14000.0
	add_child(camera)

	if OS.get_cmdline_user_args().has("--probe"):
		_build_probes()
		suffix += "_probe"


func _process(_delta: float) -> void:
	# quit() only takes effect at the end of the frame, so the last _advance()
	# would otherwise be followed by one more pass with no shot left to render.
	if finished:
		return

	if not started:
		if player.frozen:
			return
		started = true
		player.flying = true
		main.get_node("UI/DebugHud").visible = false
		var args: PackedStringArray = OS.get_cmdline_user_args()
		if args.has("--mark-sky"):
			_mark_sky()
			suffix += "_sky"
		if args.has("--plain-light"):
			_plain_light()
			suffix += "_plain"
		if args.has("--no-water"):
			streamer.water_visible = false
			suffix = "_dry"
		for arg in args:
			if arg.begins_with("--debug-view="):
				var view: int = int(arg.get_slice("=", 1))
				main.set_terrain_debug_view(view)
				suffix += "_view%d" % view
				if view != 0:
					_flatten_environment()
		_choose_shots()
		_advance()
		return

	if capturing:
		return

	wait_frames += 1
	var shot: Shot = shots[index]
	_place_probes()
	# The origin rebases as the player teleports around, so the camera has to be
	# re-derived from world space every frame rather than placed once.
	player.global_position = WorldOrigin.to_scene(shot.eye)
	camera.global_position = WorldOrigin.to_scene(shot.eye)
	camera.look_at(WorldOrigin.to_scene(shot.target), Vector3.UP)

	var chunk: Vector2i = WorldCoords.chunk_of(
		streamer.config, shots[index].eye.x, shots[index].eye.z
	)
	var ready: bool = streamer.is_chunk_ready(chunk) and streamer.queue_depth() == 0
	if not ready and wait_frames < MAX_WAIT_FRAMES:
		return

	settle += 1
	if settle < SETTLE_FRAMES:
		return

	capturing = true
	await RenderingServer.frame_post_draw
	var path: String = "%s/%s%s.png" % [OUTPUT_DIR, shot.name, suffix]
	get_viewport().get_texture().get_image().save_png(path)
	var eye_world: Vector3 = WorldOrigin.to_world(camera.global_position)
	print("  %s  (%s)" % [path, shot.caption])
	print("      eye %.0f,%.0f,%.0f | ground %.0f m | %d chunks | waited %d frames" % [
		eye_world.x, eye_world.y, eye_world.z,
		continental.height_at(eye_world.x, eye_world.z),
		streamer.stat_chunks_live, wait_frames
	])
	capturing = false
	_advance()


## Two spheres in front of the lens, one with a stock material and one with the
## terrain shader. If the stock one is lit and the other is not, the fault is in
## the shader rather than in the scene's lighting.
func _build_probes() -> void:
	var stock: StandardMaterial3D = StandardMaterial3D.new()
	stock.albedo_color = Color(0.8, 0.8, 0.8)
	_probes.append(_probe_sphere(stock))
	_probes.append(_probe_sphere(main._terrain_material))


func _probe_sphere(material: Material) -> MeshInstance3D:
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 1.5
	sphere.height = 3.0
	sphere.material = material
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.mesh = sphere
	add_child(instance)
	return instance


func _place_probes() -> void:
	if _probes.is_empty():
		return
	var basis: Basis = camera.global_transform.basis
	var ahead: Vector3 = camera.global_position - basis.z * 8.0 - basis.y * 1.5
	_probes[0].global_position = ahead - basis.x * 2.2
	_probes[1].global_position = ahead + basis.x * 2.2


## Debug views encode data as colour, so tonemapping and colour grading have to
## be off or the values read back wrong.
func _flatten_environment() -> void:
	var env: Environment = _environment()
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.adjustment_enabled = false
	env.fog_enabled = false
	env.ssao_enabled = false


## Replaces the sky with a flat colour nothing in the world uses, so any pixel
## that is not that colour is geometry. Pale ground against a pale sky is
## otherwise impossible to tell from a hole in the world.
func _mark_sky() -> void:
	var env: Environment = _environment()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1.0, 0.0, 0.6)
	env.fog_enabled = false


## Strips the scene back to one flat ambient term with no shadowing, to tell a
## material that is genuinely dark from one that is merely unlit.
func _plain_light() -> void:
	var env: Environment = _environment()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1.0, 1.0, 1.0)
	env.ambient_light_energy = 1.0
	env.ssao_enabled = false
	env.fog_enabled = false
	var sun: DirectionalLight3D = main.get_node("Sun")
	sun.shadow_enabled = false


func _environment() -> Environment:
	var world_env: WorldEnvironment = main.get_node("WorldEnvironment")
	return world_env.environment


func _advance() -> void:
	index += 1
	wait_frames = 0
	settle = 0
	if index >= shots.size():
		finished = true
		print("wrote %d screenshots to %s" % [shots.size(), OUTPUT_DIR])
		streamer.shutdown()
		get_tree().quit(0)
		return

	var shot: Shot = shots[index]
	player.global_position = WorldOrigin.to_scene(shot.eye)
	camera.global_position = WorldOrigin.to_scene(shot.eye)
	camera.look_at(WorldOrigin.to_scene(shot.target), Vector3.UP)
	camera.current = true


## Eye height is measured from the ground under the camera, never from the
## subject, otherwise a viewpoint ends up buried in a hillside or under water.
func _add(
	name: String, eye_xz: Vector2, above_ground: float, target: Vector3, caption: String
) -> void:
	var ground: float = continental.height_at(eye_xz.x, eye_xz.y)
	var shot: Shot = Shot.new()
	shot.name = name
	shot.eye = Vector3(eye_xz.x, maxf(ground, target.y) + above_ground, eye_xz.y)
	shot.target = target
	shot.caption = caption
	shots.append(shot)


func _choose_shots() -> void:
	var map: WorldSector = main.spawn_sector
	continental = main.context.sampler()

	# A high, steeply angled view first: if the landscape is wrong at all, it is
	# obvious here, and every ground-level shot after it can be trusted or not
	# on that basis.
	var vista: Vector3 = _highest_point(map)
	_add("00_overview",
		Vector2(vista.x - 700.0, vista.z - 700.0), 520.0,
		Vector3(vista.x, vista.y * 0.4, vista.z),
		"spawn sector overview toward its high ground")

	var trunk: RiverPolyline = _biggest_river(map)
	var mid: int = trunk.points.size() / 2
	var station: Vector3 = trunk.points[mid]
	var ahead: Vector3 = trunk.points[mini(mid + 14, trunk.points.size() - 1)]
	var along: Vector2 = Vector2(ahead.x - station.x, ahead.z - station.z).normalized()
	_add("01_river_valley",
		Vector2(station.x, station.z) - along * 70.0, 18.0,
		Vector3(ahead.x, ahead.y, ahead.z),
		"trunk river, order %d" % trunk.order)

	# Looking along a shoreline from just inland. Climbing high enough to frame a
	# whole basin puts the camera outside the streamed ring, where the shot is
	# mostly the hole where the world stops.
	#
	# A sector need not own a lake at all now that basins belong to whichever
	# sector contains them, so this viewpoint is skipped rather than faked.
	var lake: LakeData = _biggest_lake(map)
	if lake != null:
		var shore: Vector2 = _lake_shore(map, lake)
		var inward: Vector2 = (_lake_centroid(map, lake) - shore).normalized()
		_add("02_lake_shore",
			shore - inward * 55.0, 26.0,
			Vector3(shore.x + inward.x * 220.0, lake.surface_z, shore.y + inward.y * 220.0),
			"lake at %.0f m, %d cells" % [lake.surface_z, lake.cells.size()])
	else:
		print("  skipping 02_lake_shore: sector %s owns no lake" % map.sector)

	var bridge: BridgeSite = _first_bridge(map)
	if bridge != null:
		var center: Vector3 = bridge.center()
		# A traveller's view, standing on the road itself. Anywhere off the
		# carriageway is a bank, and a bank beside a bridge is by definition
		# uphill of it, so a camera there films the inside of a hillside.
		var stand: Vector3 = _road_approach(map, bridge, 34.0)
		var eye_ground: float = map.terrain.height_at(stand.x, stand.z)
		# Well clear of the ground, because "ground" here is the macro height and
		# the mesh carries relief on top of it. Two metres over the macro surface
		# is regularly two metres inside a hill.
		_add("03_bridge", Vector2(stand.x, stand.z),
			maxf(stand.y + 9.0 - eye_ground, 9.0),
			Vector3(center.x, center.y + 0.5, center.z),
			"%s span, %.0f m" % [bridge.catalog_id, bridge.span_length()])

	var peak: Vector3 = _most_rugged_on_continent()
	_add("04_mountains",
		Vector2(peak.x - 700.0, peak.z - 700.0), 180.0, peak,
		"most rugged ground on the continent, %.0f m" % peak.y)

	# Close enough to the same peak to read the rock, far enough not to be
	# inside it. This is where overhangs and cliff detail get judged.
	_add("05_relief_detail",
		Vector2(peak.x - 150.0, peak.z - 150.0), 40.0, peak,
		"relief detail on the high ground")

	# Framed along the roadway rather than across it, so the shot answers whether
	# the ribbon reads as a road at all.
	var road: RoadEdge = _road_in_plains(map)
	var road_mid: int = road.points.size() / 2
	var road_here: Vector3 = road.points[road_mid]
	var road_ahead: Vector3 = road.points[mini(road_mid + 12, road.points.size() - 1)]
	var road_dir: Vector2 = Vector2(
		road_ahead.x - road_here.x, road_ahead.z - road_here.z
	).normalized()
	_add("06_road_plains",
		Vector2(road_here.x, road_here.z) - road_dir * 30.0, 8.0, road_ahead,
		"%s road, %.1f m wide" % [
			RoadEdge.tier_name(road.tier), road.half_width * 2.0
		])

	_apply_shot_filter()


## While chasing a rendering bug, waiting on all seven viewpoints costs minutes
## per iteration. --only=00,04 keeps just the shots whose names start that way.
func _apply_shot_filter() -> void:
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--only="):
			continue
		var wanted: PackedStringArray = arg.get_slice("=", 1).split(",", false)
		var kept: Array[Shot] = []
		for shot in shots:
			for prefix in wanted:
				if shot.name.begins_with(prefix):
					kept.append(shot)
					break
		shots = kept


func _biggest_river(map: WorldSector) -> RiverPolyline:
	var best: RiverPolyline = map.hydro.rivers[0]
	for reach in map.hydro.rivers:
		if reach.order > best.order or (
			reach.order == best.order and reach.points.size() > best.points.size()
		):
			best = reach
	return best


func _biggest_lake(map: WorldSector) -> LakeData:
	if map.hydro.lakes.is_empty():
		return null
	var best: LakeData = map.hydro.lakes[0]
	for lake in map.hydro.lakes:
		if lake.cells.size() > best.cells.size():
			best = lake
	return best


## The widest span carried by the highest road tier. A timber footbridge over a
## brook is a legitimate crossing and a useless photograph: nothing in frame
## says "road" except two metres of dirt hidden in the grass.
func _first_bridge(map: WorldSector) -> BridgeSite:
	var best: BridgeSite = null
	var best_score: float = -INF
	for site in map.paths.bridges:
		if site.is_ford:
			continue
		var road: RoadEdge = map.paths.roads[site.road_id]
		var here: Vector3 = site.center()
		# Relief is what buries a camera: on a broken bank there is no vantage
		# 30 m away that is not inside a hillside. Prefer a crossing standing in
		# open ground, even if a bigger one exists in a gorge.
		var score: float = (
			road.half_width * 10.0 + site.span_length()
			- map.terrain.relief_amp_at(here.x, here.z) * 3.0
		)
		if score <= best_score:
			continue
		best_score = score
		best = site
	return best


## A point on the crossing's own road, roughly [param back] metres before the
## deck. Walking the polyline rather than projecting a straight line matters on
## an approach that curves, which most of them do.
func _road_approach(map: WorldSector, bridge: BridgeSite, back: float) -> Vector3:
	var road: RoadEdge = map.paths.roads[bridge.road_id]
	var deck: Vector3 = bridge.center()
	var nearest: int = 0
	var nearest_d: float = INF
	for i in road.points.size():
		var d: float = Vector2(
			road.points[i].x - deck.x, road.points[i].z - deck.z
		).length_squared()
		if d < nearest_d:
			nearest_d = d
			nearest = i

	# Away from the deck in whichever direction has road left to walk.
	var step: int = -1 if nearest > road.points.size() / 2 else 1
	var walked: float = 0.0
	var at: int = nearest
	while walked < back:
		var next: int = at + step
		if next < 0 or next >= road.points.size():
			break
		walked += Vector2(
			road.points[next].x - road.points[at].x,
			road.points[next].z - road.points[at].z
		).length()
		at = next
	return road.points[at]


## The most rugged ground on the continent, found in the atlas and then refined
## on the continental surface.
##
## The spawn is a river mouth, so the mountains are wherever the atlas put them,
## which is routinely a hundred kilometres inland - searching near the spawn
## finds the tallest plain, not a mountain. Nothing out there is baked, and
## nothing needs to be: the streamer bakes whichever sector the camera lands in.
func _most_rugged_on_continent() -> Vector3:
	var atlas: ContinentAtlas = main.context.atlas
	var best_cell: Vector2i = Vector2i.ZERO
	var best_score: int = -1
	for az in atlas.size:
		for ax in atlas.size:
			if atlas.is_ocean(ax, az) or atlas.is_lake(ax, az):
				continue
			if not main.context.sector_in_atlas(
				WorldCoords.sector_of(
					(float(ax) + 0.5) * ContinentAtlas.CELL_METRES,
					(float(az) + 0.5) * ContinentAtlas.CELL_METRES
				)
			):
				continue
			var packed: int = atlas.cell_at(ax, az)
			var score: int = AtlasPack.relief(packed) * 4 + AtlasPack.elevation(packed)
			if score > best_score:
				best_score = score
				best_cell = Vector2i(ax, az)

	# One atlas cell is a kilometre; pick the roughest 128 m of it.
	var origin: Vector2 = Vector2(best_cell) * ContinentAtlas.CELL_METRES
	var best: Vector2 = origin
	var best_relief: float = -INF
	for iz in 8:
		for ix in 8:
			var at: Vector2 = origin + Vector2(float(ix), float(iz)) * 128.0
			var relief: float = continental.relief_amp_at(at.x, at.y)
			if relief > best_relief:
				best_relief = relief
				best = at
	return Vector3(best.x, continental.height_at(best.x, best.y), best.y)


## Highest cell of the sector core. The halo is excluded: it belongs to the
## neighbour, and a camera placed there films chunks nobody has baked.
func _highest_point(map: WorldSector) -> Vector3:
	var halo: int = map.config.halo_cells()
	var core: int = map.config.macro_cells_per_sector()
	var best: Vector2i = Vector2i(halo, halo)
	var best_z: float = -INF
	for cz in range(halo, halo + core):
		for cx in range(halo, halo + core):
			var value: float = map.terrain.elevation[map.terrain.index_of(cx, cz)]
			if value > best_z:
				best_z = value
				best = Vector2i(cx, cz)
	var pos: Vector2 = map.terrain.cell_center(best.x, best.y)
	return Vector3(pos.x, best_z, pos.y)


## The widest long road running over gentle ground. Tier alone is no longer a
## useful filter: a sector may hold nothing but local tracks, or nothing but a
## slice of one atlas trunk.
func _road_in_plains(map: WorldSector) -> RoadEdge:
	var best: RoadEdge = map.paths.roads[0]
	var best_score: float = -INF
	for road in map.paths.roads:
		if road.points.size() < 24:
			continue
		var mid: Vector3 = road.points[road.points.size() / 2]
		var score: float = (
			road.half_width * 10.0 - map.terrain.relief_amp_at(mid.x, mid.z)
		)
		if score > best_score:
			best_score = score
			best = road
	return best


## A flooded cell with a dry neighbour, i.e. a point on the actual waterline.
func _lake_shore(map: WorldSector, lake: LakeData) -> Vector2:
	var cells: int = map.terrain.cells
	var lake_id: PackedInt32Array = map.hydro.lake_id
	for cell in lake.cells:
		var cx: int = cell % cells
		var cz: int = cell / cells
		if cx <= 0 or cz <= 0 or cx >= cells - 1 or cz >= cells - 1:
			continue
		var dry: bool = (
			lake_id[cell - 1] != lake.id or lake_id[cell + 1] != lake.id
			or lake_id[cell - cells] != lake.id or lake_id[cell + cells] != lake.id
		)
		if dry:
			return map.terrain.cell_center(cx, cz)
	return _lake_centroid(map, lake)


## Lake bounds cover a great deal of dry land when a basin branches, so the
## camera aims at the mean of the flooded cells instead.
func _lake_centroid(map: WorldSector, lake: LakeData) -> Vector2:
	var cells: int = map.terrain.cells
	var sum: Vector2 = Vector2.ZERO
	for cell in lake.cells:
		sum += map.terrain.cell_center(cell % cells, cell / cells)
	return sum / float(lake.cells.size())
