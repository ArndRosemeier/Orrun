class_name FaunaSim
extends Node3D
## Near-player wildlife simulation. Spawns live [FaunaAgent] nodes from habitat.

const CATALOG_PATH: String = "res://assets/catalog/fauna.json"
const _HitchLog: GDScript = preload("res://scripts/core/hitch_log.gd")

var context: WorldContext
var sectors: SectorManager
## Duck-typed streamer ([method Streamer.is_chunk_ready]); kept untyped so
## headless [code]--script[/code] tests do not need the Streamer autoload graph.
var streamer: Node
var player: Node3D
var specs: Array[FaunaCatalog.FaunaSpec] = []

var agent_count: int = 0
var stat_spawned: int = 0
var stat_despawned: int = 0
var stat_caught: int = 0

var _agents: Array[FaunaAgent] = []
var _occupied_cells: Dictionary = {}
## Cells already occupancy-rolled (spawned or declined). Prevents re-scoring the
## whole lattice every refresh while collision/streaming is still catching up.
var _settled_cells: Dictionary = {}
var _next_agent_id: int = 1
var _next_flock_id: int = 1
var _refresh_accum: float = 0.0
var _enabled: bool = true
## Resume scan across frames so one refresh cannot monopolise the main thread.
var _scan_cx: int = 0
var _scan_cz: int = 0
var _scan_min_cx: int = 0
var _scan_max_cx: int = -1
var _scan_min_cz: int = 0
var _scan_max_cz: int = -1
## Soft cap for one refresh slice (microseconds).
const REFRESH_BUDGET_USEC: int = 2000


func setup(
	world_context: WorldContext,
	sector_manager: SectorManager,
	world_streamer: Node,
	player_node: Node3D
) -> void:
	context = world_context
	sectors = sector_manager
	streamer = world_streamer
	player = player_node
	specs = FaunaCatalog.load_catalog(CATALOG_PATH)
	FaunaCatalog.preload_scenes()
	_enabled = context.config.fauna_enabled
	_origin().register_root(self)


func _exit_tree() -> void:
	if get_tree() != null:
		_origin().unregister_root(self)


func _process(delta: float) -> void:
	if not _enabled or context == null or player == null:
		return
	# PlayerController exposes `frozen` during boot; duck-type to avoid a hard
	# script dependency that breaks headless --script parses.
	if bool(player.get("frozen")):
		return

	_refresh_accum += delta
	if _refresh_accum >= context.config.fauna_refresh_interval:
		_refresh_accum = 0.0
		var t0: int = Time.get_ticks_usec()
		var before: int = agent_count
		_refresh_population()
		var refresh_ms: float = (Time.get_ticks_usec() - t0) * 0.001
		_HitchLog.record(
			"fauna_refresh",
			refresh_ms,
			{"refresh": refresh_ms},
			"agents=%d->%d spawned=%d" % [before, agent_count, stat_spawned]
		)

	var t_tick: int = Time.get_ticks_usec()
	var live: Array[FaunaAgent] = _agents.duplicate()
	for agent in live:
		if not is_instance_valid(agent):
			continue
		agent.tick(delta, _agents)
	var tick_ms: float = (Time.get_ticks_usec() - t_tick) * 0.001
	_HitchLog.record(
		"fauna_tick",
		tick_ms,
		{"tick": tick_ms},
		"agents=%d" % agent_count
	)


func debug_summary() -> String:
	var by_species: Dictionary = {}
	var by_state: Dictionary = {}
	for agent in _agents:
		var sid: String = String(agent.species_id())
		by_species[sid] = int(by_species.get(sid, 0)) + 1
		var st: String = agent.state_name()
		by_state[st] = int(by_state.get(st, 0)) + 1
	var parts: PackedStringArray = PackedStringArray()
	for key in by_species.keys():
		parts.append("%s:%d" % [key, by_species[key]])
	var states: PackedStringArray = PackedStringArray()
	for key in by_state.keys():
		states.append("%s:%d" % [key, by_state[key]])
	return "fauna %d/%d [%s] {%s}" % [
		agent_count, context.config.fauna_max_agents,
		", ".join(parts) if not parts.is_empty() else "-",
		", ".join(states) if not states.is_empty() else "-",
	]


## Small lift so hoof soles clear density-mesh z-fighting.
const FOOT_CLEARANCE: float = 0.06


func can_stand(spec: FaunaCatalog.FaunaSpec, world_x: float, world_z: float) -> bool:
	var sector: WorldSector = _sector_at(world_x, world_z)
	if sector == null:
		return false
	if not HabitatQuery.may_stand(spec, sector, context.sampler(), world_x, world_z):
		return false
	# Mesh slope can be steeper than the macro sample used by HabitatQuery.
	var surface: Dictionary = sample_surface(world_x, world_z)
	if surface.is_empty():
		return false
	var normal: Vector3 = surface["normal"] as Vector3
	return normal.y >= cos(deg_to_rad(spec.max_slope_deg))


## Ray against streamed collision. Empty when the chunk is not ready — callers
## must not invent a height (macro loft buries animals on real slopes).
func sample_surface(world_x: float, world_z: float) -> Dictionary:
	assert(is_inside_tree(), "sample_surface needs FaunaSim in the scene tree")
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	assert(space != null, "No physics space for fauna ground sample")
	var origin: Node = _origin()
	var scene_xz: Vector2 = origin.to_scene_xz(world_x, world_z)
	var hint_y: float = context.sampler().height_at(world_x, world_z)
	var hit: Dictionary = WorldQuery.trace_ground(
		space, scene_xz.x, scene_xz.y, hint_y
	)
	if hit.is_empty():
		return {}
	var world_hit: Vector3 = origin.to_world(hit["position"])
	var normal: Vector3 = hit["normal"]
	if normal.length_squared() < 1e-8:
		normal = Vector3.UP
	else:
		normal = normal.normalized()
	return {
		"y": world_hit.y + FOOT_CLEARANCE,
		"normal": normal,
	}


func ground_at(world_x: float, world_z: float) -> float:
	var surface: Dictionary = sample_surface(world_x, world_z)
	assert(not surface.is_empty(), "fauna ground_at with no collision under (%.0f, %.0f)" % [world_x, world_z])
	return float(surface["y"])


func random_stand_near(
	spec: FaunaCatalog.FaunaSpec,
	world_x: float,
	world_z: float,
	radius: float,
	rng: RandomNumberGenerator
) -> Vector2:
	for _i in 8:
		var ang: float = rng.randf() * TAU
		var dist: float = rng.randf_range(radius * 0.35, radius)
		var x: float = world_x + cos(ang) * dist
		var z: float = world_z + sin(ang) * dist
		if can_stand(spec, x, z):
			return Vector2(x, z)
	return Vector2(world_x, world_z)


func catch_prey(prey: FaunaAgent) -> void:
	assert(prey != null and is_instance_valid(prey), "catch_prey on invalid agent")
	stat_caught += 1
	_despawn(prey)


func _refresh_population() -> void:
	var config: WorldConfig = context.config
	var player_world: Vector3 = _origin().to_world(player.global_position)
	var sim_r: float = config.fauna_sim_radius
	var drop_r: float = sim_r + config.fauna_despawn_hysteresis

	# Despawn far agents.
	var keep: Array[FaunaAgent] = []
	for agent in _agents:
		var d: float = Vector2(agent.world_pos.x - player_world.x, agent.world_pos.z - player_world.z).length()
		if d > drop_r:
			_despawn(agent)
		else:
			keep.append(agent)
	_agents = keep
	agent_count = _agents.size()

	# Drop settled/occupied marks that fell far behind the player.
	_prune_cell_marks(player_world, drop_r, config.fauna_cell_size)

	if agent_count >= config.fauna_max_agents:
		return

	var cell: float = config.fauna_cell_size
	var min_cx: int = floori((player_world.x - sim_r) / cell)
	var max_cx: int = floori((player_world.x + sim_r) / cell)
	var min_cz: int = floori((player_world.z - sim_r) / cell)
	var max_cz: int = floori((player_world.z + sim_r) / cell)
	# Restart the scan when the lattice window moves.
	if (
		min_cx != _scan_min_cx or max_cx != _scan_max_cx
		or min_cz != _scan_min_cz or max_cz != _scan_max_cz
	):
		_scan_min_cx = min_cx
		_scan_max_cx = max_cx
		_scan_min_cz = min_cz
		_scan_max_cz = max_cz
		_scan_cx = min_cx
		_scan_cz = min_cz

	var wild: Array[FaunaCatalog.FaunaSpec] = FaunaCatalog.wilderness_specs()
	assert(not wild.is_empty(), "No wilderness fauna specs loaded")
	var livestock: Array[FaunaCatalog.FaunaSpec] = FaunaCatalog.livestock_specs()

	var started: int = Time.get_ticks_usec()
	while _scan_cz <= _scan_max_cz:
		while _scan_cx <= _scan_max_cx:
			if agent_count >= config.fauna_max_agents:
				return
			if Time.get_ticks_usec() - started >= REFRESH_BUDGET_USEC:
				return
			var cx: int = _scan_cx
			var cz: int = _scan_cz
			_scan_cx += 1
			var key: Vector2i = Vector2i(cx, cz)
			if _occupied_cells.has(key) or _settled_cells.has(key):
				continue
			var center_x: float = (float(cx) + 0.5) * cell
			var center_z: float = (float(cz) + 0.5) * cell
			var dist: float = Vector2(center_x - player_world.x, center_z - player_world.z).length()
			if dist > sim_r:
				continue
			var chunk: Vector2i = WorldCoords.chunk_of(config, center_x, center_z)
			if streamer == null or not bool(streamer.call("is_chunk_ready", chunk)):
				# Chunk not ready yet — leave unsettled so a later slice can retry.
				continue
			var sector: WorldSector = _sector_at(center_x, center_z)
			if sector == null:
				continue
			var pool: Array[FaunaCatalog.FaunaSpec] = wild
			if (
				not livestock.is_empty()
				and sector.claims.kind_at(center_x, center_z) == &"settlement"
			):
				pool = livestock
			_try_spawn_cell(key, center_x, center_z, sector, pool)
			if Time.get_ticks_usec() - started >= REFRESH_BUDGET_USEC:
				return
		_scan_cx = _scan_min_cx
		_scan_cz += 1
	# Full window scanned; park the cursor until the window moves.
	_scan_cx = _scan_min_cx
	_scan_cz = _scan_min_cz


func _prune_cell_marks(player_world: Vector3, drop_r: float, cell: float) -> void:
	var doomed: Array[Vector2i] = []
	for key_variant in _settled_cells.keys():
		var key: Vector2i = key_variant
		var x: float = (float(key.x) + 0.5) * cell
		var z: float = (float(key.y) + 0.5) * cell
		if Vector2(x - player_world.x, z - player_world.z).length() > drop_r:
			doomed.append(key)
	for key in doomed:
		_settled_cells.erase(key)
	doomed.clear()
	for key_variant in _occupied_cells.keys():
		var key: Vector2i = key_variant
		var still: bool = false
		for agent in _agents:
			if agent.home_cell == key:
				still = true
				break
		if still:
			continue
		var x: float = (float(key.x) + 0.5) * cell
		var z: float = (float(key.y) + 0.5) * cell
		if Vector2(x - player_world.x, z - player_world.z).length() > drop_r:
			doomed.append(key)
	for key in doomed:
		_occupied_cells.erase(key)


func _try_spawn_cell(
	cell_key: Vector2i,
	world_x: float,
	world_z: float,
	sector: WorldSector,
	wild: Array[FaunaCatalog.FaunaSpec]
) -> void:
	var config: WorldConfig = context.config
	var continental: ContinentalTerrain = context.sampler()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = config.place_seed("fauna", cell_key)

	var best_spec: FaunaCatalog.FaunaSpec = null
	var best_score: float = 0.0
	var scores: PackedFloat32Array = PackedFloat32Array()
	scores.resize(wild.size())
	var total: float = 0.0
	for i in wild.size():
		var score: float = HabitatQuery.suitability(wild[i], sector, continental, world_x, world_z)
		scores[i] = score
		total += score
		if score > best_score:
			best_score = score
			best_spec = wild[i]
	if total <= 0.0 or best_spec == null:
		_settled_cells[cell_key] = true
		return
	# Occupancy roll — denser habitat cells are more likely to host a group.
	var occupancy: float = clampf(total / float(wild.size()), 0.0, 0.85)
	if rng.randf() > occupancy:
		_settled_cells[cell_key] = true
		return

	var pick: float = rng.randf() * total
	var chosen: FaunaCatalog.FaunaSpec = best_spec
	for i in wild.size():
		pick -= scores[i]
		if pick <= 0.0:
			chosen = wild[i]
			break

	var jitter_x: float = world_x + rng.randf_range(-config.fauna_cell_size * 0.3, config.fauna_cell_size * 0.3)
	var jitter_z: float = world_z + rng.randf_range(-config.fauna_cell_size * 0.3, config.fauna_cell_size * 0.3)
	if not HabitatQuery.may_stand(chosen, sector, continental, jitter_x, jitter_z):
		jitter_x = world_x
		jitter_z = world_z
		if not HabitatQuery.may_stand(chosen, sector, continental, jitter_x, jitter_z):
			_settled_cells[cell_key] = true
			return

	var flock: int = _next_flock_id
	_next_flock_id += 1
	var count: int = rng.randi_range(chosen.flock_min, chosen.flock_max)
	count = mini(count, config.fauna_max_agents - agent_count)
	var spawned_any: bool = false
	for i in count:
		var ox: float = jitter_x + rng.randf_range(-3.5, 3.5) * float(i)
		var oz: float = jitter_z + rng.randf_range(-3.5, 3.5) * float(i)
		if not HabitatQuery.may_stand(chosen, sector, continental, ox, oz):
			ox = jitter_x
			oz = jitter_z
		var before: int = agent_count
		_spawn_agent(chosen, flock, ox, oz, rng.randf() * TAU, cell_key)
		if agent_count > before:
			spawned_any = true
	# Whether the physics ray found ground or not, do not re-roll this cell every
	# half-second — that was the ~1 Hz multi-hundred-ms hitch while moving.
	_settled_cells[cell_key] = true
	if spawned_any:
		_occupied_cells[cell_key] = true


func _spawn_agent(
	spec: FaunaCatalog.FaunaSpec,
	flock: int,
	world_x: float,
	world_z: float,
	facing: float,
	cell_key: Vector2i
) -> void:
	var surface: Dictionary = sample_surface(world_x, world_z)
	if surface.is_empty():
		return
	var spawn_normal: Vector3 = surface["normal"] as Vector3
	if spawn_normal.y < cos(deg_to_rad(spec.max_slope_deg)):
		return
	var agent: FaunaAgent = FaunaAgent.new()
	add_child(agent)
	var id: int = _next_agent_id
	_next_agent_id += 1
	agent.setup(
		self, spec, id, flock, cell_key,
		Vector3(world_x, float(surface["y"]), world_z), facing,
		context.config.place_seed("fauna_agent", Vector2i(cell_key.x * 31 + id, cell_key.y))
	)
	agent.apply_surface(spawn_normal)
	_agents.append(agent)
	agent_count = _agents.size()
	stat_spawned += 1


func _despawn(agent: FaunaAgent) -> void:
	if not is_instance_valid(agent):
		return
	var cell: Vector2i = agent.home_cell
	_agents.erase(agent)
	agent.queue_free()
	agent_count = _agents.size()
	stat_despawned += 1
	# Free the lattice cell once its last resident leaves so re-entry can
	# re-roll the same deterministic occupancy (agent ids themselves recycle).
	var still: bool = false
	for other in _agents:
		if other.home_cell == cell:
			still = true
			break
	if not still:
		_occupied_cells.erase(cell)


func world_to_scene(world: Vector3) -> Vector3:
	return _origin().to_scene(world)


func _origin() -> Node:
	var tree: SceneTree = get_tree()
	assert(tree != null, "FaunaSim needs a SceneTree for WorldOrigin")
	var origin: Node = tree.root.get_node_or_null("WorldOrigin")
	assert(origin != null, "WorldOrigin autoload missing")
	return origin


func _sector_at(world_x: float, world_z: float) -> WorldSector:
	return sectors.get_sector(WorldCoords.sector_of(world_x, world_z))
