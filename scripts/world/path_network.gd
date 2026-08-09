class_name PathNetwork
extends RefCounted
## Layer 3: how people move through the land.
##
## Roads are least-cost paths on the macro grid, but they are built in tiers so
## the result reads as a network instead of a pile of shortest paths: a primary
## spine links the biggest settlements through the valleys, secondaries hang off
## it, and trails fill in. Water is expensive to cross, so crossings collect at
## a few sensible places, which is exactly where fords and bridges belong.

static var NEIGHBOR_DX: PackedInt32Array = PackedInt32Array([1, 1, 0, -1, -1, -1, 0, 1])
static var NEIGHBOR_DZ: PackedInt32Array = PackedInt32Array([0, 1, 1, 1, 0, -1, -1, -1])
const HEURISTIC_WEIGHT: float = 1.35
const BRIDGE_CLEARANCE: float = 2.6
## How far past the channel edge a deck lands, so it rests on bank rather than
## on the water it is spanning.
const BANK_MARGIN: float = 3.5
## Even the smallest structure has to be walkable and read as a bridge.
const MIN_SPAN: float = 9.0
const APPROACH_LENGTH: float = 48.0

var config: WorldConfig
var terrain: MacroTerrain
var hydro: Hydrology
var claims: ClaimMask

var nodes: PackedVector2Array = PackedVector2Array()
var roads: Array[RoadEdge] = []
var bridges: Array[BridgeSite] = []
var road_index: SpatialIndex2D

var _slope: PackedFloat32Array
var _step_cost: PackedFloat32Array
## Cells no road may enter at any price. Standing water is the only one: a
## bridge is a structure over a channel, and a deck laid across half a kilometre
## of lake is neither a bridge nor a road.
var _blocked: PackedByteArray


static func build(
	cfg: WorldConfig, macro: MacroTerrain, water: Hydrology, claim_mask: ClaimMask
) -> PathNetwork:
	var net: PathNetwork = PathNetwork.new()
	net.config = cfg
	net.terrain = macro
	net.hydro = water
	net.claims = claim_mask
	net.road_index = SpatialIndex2D.new(160.0)
	net._compute_costs()
	net._choose_settlements()
	net._connect()
	net._index_roads()
	return net


# --- Terrain cost ------------------------------------------------------------

func _compute_costs() -> void:
	var n: int = terrain.cells
	var count: int = n * n
	var cs: float = config.macro_cell_size
	_slope = PackedFloat32Array()
	_slope.resize(count)
	_step_cost = PackedFloat32Array()
	_step_cost.resize(count)
	_blocked = PackedByteArray()
	_blocked.resize(count)

	var elevation: PackedFloat32Array = terrain.elevation
	for cz in n:
		for cx in n:
			var i: int = cz * n + cx
			var left: float = elevation[terrain.clamped_index(cx - 1, cz)]
			var right: float = elevation[terrain.clamped_index(cx + 1, cz)]
			var up: float = elevation[terrain.clamped_index(cx, cz - 1)]
			var down: float = elevation[terrain.clamped_index(cx, cz + 1)]
			var gx: float = (right - left) / (2.0 * cs)
			var gz: float = (down - up) / (2.0 * cs)
			var slope: float = sqrt(gx * gx + gz * gz)
			_slope[i] = slope

			var cost: float = 1.0 + slope * 14.0 + slope * slope * 60.0
			if hydro.lake_id[i] != -1:
				_blocked[i] = 1
			elif hydro.is_channel[i] != 0:
				# A brook is a step; a trunk river is a project. The gradient is
				# what makes routes gather at a few sensible crossings instead of
				# either fording everywhere or detouring to every headwater.
				cost += 4.0 + float(hydro.accumulation[i]) * 0.02
			_step_cost[i] = cost


# --- Landmarks ---------------------------------------------------------------

func _choose_settlements() -> void:
	var n: int = terrain.cells
	var cs: float = config.macro_cell_size
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = config.layer_seed("settlements")

	var scored: Array[Vector3] = []
	for cz in range(2, n - 2):
		for cx in range(2, n - 2):
			var i: int = cz * n + cx
			if hydro.lake_id[i] != -1 or hydro.is_channel[i] != 0:
				continue
			if terrain.elevation[i] < 2.0:
				continue
			var flatness: float = 1.0 - clampf(_slope[i] / 0.16, 0.0, 1.0)
			if flatness <= 0.05:
				continue
			var water_pull: float = 0.0
			var lake_d: float = hydro.lake_distance[i]
			water_pull += clampf(1.0 - lake_d / 420.0, 0.0, 1.0) * 0.7
			water_pull += clampf(hydro.accumulation[i] / config.river_accum_threshold, 0.0, 1.0) * 0.3
			var score: float = flatness * 1.4 + water_pull + rng.randf() * 0.35
			scored.append(Vector3(score, float(cx), float(cz)))

	scored.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.x > b.x)

	var min_spacing: float = maxf(config.world_size() / 9.0, 700.0)
	var chosen: PackedVector2Array = PackedVector2Array()
	for entry in scored:
		if chosen.size() >= config.settlement_count:
			break
		var pos: Vector2 = WorldCoords.macro_cell_center(
			config, Vector2i(int(entry.y), int(entry.z))
		)
		var too_close: bool = false
		for existing in chosen:
			if existing.distance_to(pos) < min_spacing:
				too_close = true
				break
		if not too_close:
			chosen.append(pos)

	nodes = chosen
	for i in nodes.size():
		var pos: Vector2 = nodes[i]
		claims.add(
			&"settlement", pos, 150.0 + float(i % 3) * 40.0,
			terrain.height_at(pos.x, pos.y)
		)

	_reserve_dungeon_mouths(rng)
	assert(nodes.size() >= 2, "World produced fewer than two settlement sites")


func _reserve_dungeon_mouths(rng: RandomNumberGenerator) -> void:
	# Steep ground away from water is where cave mouths will be worth entering.
	var n: int = terrain.cells
	var wanted: int = maxi(6, config.settlement_count / 3)
	var placed: int = 0
	var attempts: int = 0
	while placed < wanted and attempts < 4000:
		attempts += 1
		var cx: int = rng.randi_range(3, n - 4)
		var cz: int = rng.randi_range(3, n - 4)
		var i: int = cz * n + cx
		if hydro.lake_id[i] != -1 or hydro.is_channel[i] != 0:
			continue
		if _slope[i] < 0.35:
			continue
		var pos: Vector2 = WorldCoords.macro_cell_center(config, Vector2i(cx, cz))
		if claims.is_reserved(pos.x, pos.y):
			continue
		claims.add(&"dungeon_mouth", pos, 70.0, terrain.elevation[i])
		placed += 1


# --- Network -----------------------------------------------------------------

func _connect() -> void:
	var count: int = nodes.size()
	if count < 2:
		return

	# Primary spine: a minimum spanning tree over the settlements, so the trunk
	# network is connected without the spaghetti of all-pairs shortest paths.
	var in_tree: PackedByteArray = PackedByteArray()
	in_tree.resize(count)
	var best_cost: PackedFloat32Array = PackedFloat32Array()
	best_cost.resize(count)
	var best_from: PackedInt32Array = PackedInt32Array()
	best_from.resize(count)
	for i in count:
		best_cost[i] = INF
		best_from[i] = -1
	best_cost[0] = 0.0

	var edges: Array[Vector2i] = []
	for _step in count:
		var pick: int = -1
		var pick_cost: float = INF
		for i in count:
			if in_tree[i] == 0 and best_cost[i] < pick_cost:
				pick_cost = best_cost[i]
				pick = i
		if pick < 0:
			break
		in_tree[pick] = 1
		if best_from[pick] >= 0:
			edges.append(Vector2i(best_from[pick], pick))
		for i in count:
			if in_tree[i] != 0:
				continue
			var d: float = nodes[pick].distance_to(nodes[i])
			if d < best_cost[i]:
				best_cost[i] = d
				best_from[i] = pick

	for edge in edges:
		_route(edge.x, edge.y, RoadEdge.Tier.PRIMARY)

	# Secondary loops: a few extra links between nearby settlements turn the
	# tree into a network you can travel around rather than always backtrack.
	var extra: int = maxi(2, count / 4)
	var added: int = 0
	for a in count:
		if added >= extra:
			break
		var nearest: int = -1
		var nearest_d: float = INF
		for b in count:
			if a == b:
				continue
			if _has_road_between(a, b):
				continue
			var d: float = nodes[a].distance_to(nodes[b])
			if d < nearest_d:
				nearest_d = d
				nearest = b
		if nearest >= 0 and nearest_d < config.world_size() * 0.22:
			_route(a, nearest, RoadEdge.Tier.SECONDARY)
			added += 1

	# Trails: short spurs from settlements to the nearest lake shore.
	for a in count:
		var shore: Vector2 = _nearest_lake_shore(nodes[a], 900.0)
		if shore != Vector2.INF:
			_route_positions(nodes[a], shore, RoadEdge.Tier.TRAIL, a, -1)


func _has_road_between(a: int, b: int) -> bool:
	for road in roads:
		if (road.from_node == a and road.to_node == b) or (road.from_node == b and road.to_node == a):
			return true
	return false


## Dry land beside the water, never a flooded cell: a trail that ends in the
## lake has to be routed through it, and that is how a road ends up on stilts.
func _nearest_lake_shore(from: Vector2, max_distance: float) -> Vector2:
	var n: int = terrain.cells
	var best: Vector2 = Vector2.INF
	var best_d: float = max_distance
	for lake in hydro.lakes:
		if not lake.bounds.grow(max_distance).has_point(from):
			continue
		for cell in lake.cells:
			var cx: int = cell % n
			var cz: int = cell / n
			for k in 8:
				var nx: int = cx + NEIGHBOR_DX[k]
				var nz: int = cz + NEIGHBOR_DZ[k]
				if nx < 1 or nz < 1 or nx >= n - 1 or nz >= n - 1:
					continue
				if _blocked[nz * n + nx] != 0:
					continue
				var pos: Vector2 = WorldCoords.macro_cell_center(config, Vector2i(nx, nz))
				var d: float = pos.distance_to(from)
				if d < best_d:
					best_d = d
					best = pos
	return best


func _route(from_node: int, to_node: int, tier: RoadEdge.Tier) -> void:
	_route_positions(nodes[from_node], nodes[to_node], tier, from_node, to_node)


func _route_positions(
	from_pos: Vector2, to_pos: Vector2, tier: RoadEdge.Tier, from_node: int, to_node: int
) -> void:
	var start_cell: Vector2i = WorldCoords.macro_cell_of(config, from_pos.x, from_pos.y)
	var goal_cell: Vector2i = WorldCoords.macro_cell_of(config, to_pos.x, to_pos.y)
	var path: PackedInt32Array = _astar(
		start_cell.y * terrain.cells + start_cell.x,
		goal_cell.y * terrain.cells + goal_cell.x,
		tier
	)
	if path.size() < 2:
		return

	var road: RoadEdge = RoadEdge.new()
	road.id = roads.size()
	road.tier = tier
	road.from_node = from_node
	road.to_node = to_node
	match tier:
		RoadEdge.Tier.PRIMARY:
			road.half_width = config.road_width_primary * 0.5
		RoadEdge.Tier.SECONDARY:
			road.half_width = config.road_width_secondary * 0.5
		_:
			road.half_width = config.road_width_trail * 0.5

	road.points = _path_to_polyline(path)
	_find_crossings(road, path)
	_smooth_profile(road)
	road.compute_bounds()
	roads.append(road)


func _astar(start: int, goal: int, tier: RoadEdge.Tier) -> PackedInt32Array:
	var n: int = terrain.cells
	var count: int = n * n
	var cs: float = config.macro_cell_size

	var g_score: PackedFloat32Array = PackedFloat32Array()
	g_score.resize(count)
	for i in count:
		g_score[i] = INF
	var came_from: PackedInt32Array = PackedInt32Array()
	came_from.resize(count)
	for i in count:
		came_from[i] = -1
	var closed: PackedByteArray = PackedByteArray()
	closed.resize(count)

	var heap_cell: PackedInt32Array = PackedInt32Array()
	var heap_cost: PackedFloat32Array = PackedFloat32Array()

	g_score[start] = 0.0
	_heap_push(heap_cell, heap_cost, start, 0.0)

	var gx: int = goal % n
	var gz: int = goal / n
	var trail_penalty: float = 1.0 if tier == RoadEdge.Tier.PRIMARY else 0.6

	while not heap_cell.is_empty():
		var current: int = _heap_pop(heap_cell, heap_cost)
		if current == goal:
			break
		if closed[current] != 0:
			continue
		closed[current] = 1

		var cx: int = current % n
		var cz: int = current / n
		for k in 8:
			var nx: int = cx + NEIGHBOR_DX[k]
			var nz: int = cz + NEIGHBOR_DZ[k]
			if nx < 1 or nz < 1 or nx >= n - 1 or nz >= n - 1:
				continue
			var nb: int = nz * n + nx
			if closed[nb] != 0 or _blocked[nb] != 0:
				continue

			var diagonal: bool = NEIGHBOR_DX[k] != 0 and NEIGHBOR_DZ[k] != 0
			# A diagonal step between two wet cells slips through the corner of
			# the water without ever entering it: the road appears to walk on
			# the lake, and a river crossing is never recorded as one.
			if diagonal and _wet_corner(cz * n + nx, nz * n + cx):
				continue
			var length: float = cs * (1.41421356 if diagonal else 1.0)
			var step: float = length * (_step_cost[current] + _step_cost[nb]) * 0.5
			if claims.kind_at(
				(float(nx) + 0.5) * cs, (float(nz) + 0.5) * cs
			) == &"dungeon_mouth":
				step += 900.0
			step *= trail_penalty

			var tentative: float = g_score[current] + step
			if tentative >= g_score[nb]:
				continue
			g_score[nb] = tentative
			came_from[nb] = current
			var h: float = (
				Vector2(float(nx - gx), float(nz - gz)).length() * cs * HEURISTIC_WEIGHT
			)
			_heap_push(heap_cell, heap_cost, nb, tentative + h)

	if came_from[goal] < 0 and goal != start:
		return PackedInt32Array()

	var reverse: PackedInt32Array = PackedInt32Array()
	var walk: int = goal
	while walk >= 0:
		reverse.append(walk)
		if walk == start:
			break
		walk = came_from[walk]
	reverse.reverse()
	return reverse


## Closest point on a road's finished polyline, with the road's heading there.
## Keys: position (Vector2), axis (Vector2, unit or zero).
static func _project_on_road(road: RoadEdge, point: Vector2) -> Dictionary:
	var points: PackedVector3Array = road.points
	var best_position: Vector2 = point
	var best_axis: Vector2 = Vector2.ZERO
	var best_distance: float = INF

	for i in range(points.size() - 1):
		var a: Vector2 = Vector2(points[i].x, points[i].z)
		var b: Vector2 = Vector2(points[i + 1].x, points[i + 1].z)
		var ab: Vector2 = b - a
		var length_sq: float = ab.length_squared()
		if length_sq < 0.000001:
			continue
		var t: float = clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
		var candidate: Vector2 = a + ab * t
		var distance: float = candidate.distance_squared_to(point)
		if distance >= best_distance:
			continue
		best_distance = distance
		best_position = candidate
		best_axis = ab / sqrt(length_sq)

	return {"position": best_position, "axis": best_axis}


func _wet_corner(a: int, b: int) -> bool:
	if _blocked[a] != 0 or _blocked[b] != 0:
		return true
	return hydro.is_channel[a] != 0 and hydro.is_channel[b] != 0


static func _heap_push(
	cells: PackedInt32Array, costs: PackedFloat32Array, cell: int, cost: float
) -> void:
	cells.append(cell)
	costs.append(cost)
	var i: int = cells.size() - 1
	while i > 0:
		var parent: int = (i - 1) >> 1
		if costs[parent] <= costs[i]:
			break
		var tc: int = cells[parent]
		var tf: float = costs[parent]
		cells[parent] = cells[i]
		costs[parent] = costs[i]
		cells[i] = tc
		costs[i] = tf
		i = parent


static func _heap_pop(cells: PackedInt32Array, costs: PackedFloat32Array) -> int:
	var top: int = cells[0]
	var last: int = cells.size() - 1
	cells[0] = cells[last]
	costs[0] = costs[last]
	cells.resize(last)
	costs.resize(last)
	var size: int = cells.size()
	var i: int = 0
	while true:
		var left: int = i * 2 + 1
		var right: int = left + 1
		var smallest: int = i
		if left < size and costs[left] < costs[smallest]:
			smallest = left
		if right < size and costs[right] < costs[smallest]:
			smallest = right
		if smallest == i:
			break
		var tc: int = cells[smallest]
		var tf: float = costs[smallest]
		cells[smallest] = cells[i]
		costs[smallest] = costs[i]
		cells[i] = tc
		costs[i] = tf
		i = smallest
	return top


func _path_to_polyline(path: PackedInt32Array) -> PackedVector3Array:
	var n: int = terrain.cells
	var raw: PackedVector3Array = PackedVector3Array()
	for cell in path:
		var cx: int = cell % n
		var cz: int = cell / n
		var center: Vector2 = WorldCoords.macro_cell_center(config, Vector2i(cx, cz))
		raw.append(Vector3(center.x, terrain.elevation[cell], center.y))
	return Hydrology._chaikin(raw, 2)


func _find_crossings(road: RoadEdge, path: PackedInt32Array) -> void:
	var n: int = terrain.cells
	var run_start: int = -1
	for i in path.size():
		var cell: int = path[i]
		var wet: bool = hydro.is_channel[cell] != 0 or hydro.lake_id[cell] != -1
		if wet and run_start < 0:
			run_start = i
		elif not wet and run_start >= 0:
			_make_crossing(road, path, run_start, i - 1, n)
			run_start = -1
	if run_start >= 0:
		_make_crossing(road, path, run_start, path.size() - 1, n)


func _make_crossing(
	road: RoadEdge, path: PackedInt32Array, from_i: int, to_i: int, n: int
) -> void:
	# Anchor on the dry cells either side of the wet run: those are the banks the
	# terrain will actually provide, so a deck between them cannot float.
	var before: int = maxi(from_i - 1, 0)
	var after: int = mini(to_i + 1, path.size() - 1)
	var cell_mid: int = path[(from_i + to_i) / 2]

	var water_z: float = hydro.filled[cell_mid]
	var lake: int = hydro.lake_id[cell_mid]
	if lake != -1:
		water_z = hydro.lakes[lake].surface_z

	var a_cell: int = path[before]
	var b_cell: int = path[after]
	var a_pos: Vector2 = WorldCoords.macro_cell_center(
		config, Vector2i(a_cell % n, a_cell / n)
	)
	var b_pos: Vector2 = WorldCoords.macro_cell_center(
		config, Vector2i(b_cell % n, b_cell / n)
	)

	var mid_pos: Vector2 = WorldCoords.macro_cell_center(
		config, Vector2i(cell_mid % n, cell_mid / n)
	)
	# Ask the actual channel how wide it is here rather than guessing from flow:
	# fords only make sense where there really is a shallow, narrow crossing.
	var reach: Dictionary = hydro.nearest_reach(
		mid_pos.x, mid_pos.y, config.macro_cell_size * 2.0
	)

	var site: BridgeSite = BridgeSite.new()
	site.id = bridges.size()
	site.road_id = road.id
	site.water_z = float(reach.get("water_z", water_z))
	site.river_order = int(reach.get("order", 1))
	site.deck_width = road.half_width * 2.0 + 1.2

	var channel_half: float = float(reach.get("half_width", 0.0))
	site.is_ford = (
		lake == -1 and channel_half > 0.0 and channel_half * 2.0 <= config.ford_max_width
	)
	water_z = site.water_z

	# A span is measured against the water it crosses, not against the macro
	# grid. Anchoring on cell centres two cells apart puts a 45 m deck over a
	# 6 m brook and stands its piers on dry land.
	#
	# It also has to sit on the road. The polyline is a smoothed version of the
	# cell path, so the deck is placed by projecting the crossing back onto the
	# road it belongs to rather than onto the cells the search walked through.
	var crossed: Vector2 = reach.get("point", mid_pos) as Vector2
	var on_road: Dictionary = _project_on_road(road, crossed)
	var center: Vector2 = on_road["position"]
	var axis: Vector2 = on_road["axis"]
	var fallback_axis: Vector2 = b_pos - a_pos
	if axis.length_squared() < 0.0001:
		axis = (
			fallback_axis.normalized() if fallback_axis.length_squared() > 0.0001
			else Vector2.RIGHT
		)

	var run_half: float = float(to_i - from_i + 1) * 0.5 * config.macro_cell_size
	var span_half: float = maxf(
		run_half if lake != -1 else channel_half + BANK_MARGIN, MIN_SPAN * 0.5
	)

	var pos_a: Vector2 = center - axis * span_half
	var pos_b: Vector2 = center + axis * span_half
	var bank_z: float = maxf(
		terrain.height_at(pos_a.x, pos_a.y), terrain.height_at(pos_b.x, pos_b.y)
	)
	var deck_z: float = (
		water_z - 0.2 if site.is_ford else maxf(bank_z, water_z + BRIDGE_CLEARANCE)
	)
	site.anchor_a = Vector3(pos_a.x, deck_z, pos_a.y)
	site.anchor_b = Vector3(pos_b.x, deck_z, pos_b.y)
	site.catalog_id = &"ford" if site.is_ford else (
		&"procedural_stone" if site.river_order >= 3 else &"procedural_timber"
	)

	if not site.is_ford:
		claims.add(&"bridge", Vector2(site.center().x, site.center().z), site.span_length() * 0.6, deck_z)

	road.crossings.append(site)
	bridges.append(site)


func _smooth_profile(road: RoadEdge) -> void:
	var points: PackedVector3Array = road.points
	var count: int = points.size()
	if count < 3:
		return

	# Rolling average: roads bench into the hillside instead of tracing every
	# bump, and the density field carves the terrain to meet this profile.
	var smoothed: PackedFloat32Array = PackedFloat32Array()
	smoothed.resize(count)
	var window: int = 3
	for i in count:
		var total: float = 0.0
		var samples: int = 0
		for k in range(maxi(i - window, 0), mini(i + window + 1, count)):
			total += points[k].y
			samples += 1
		smoothed[i] = total / float(samples)

	for i in count:
		points[i] = Vector3(points[i].x, smoothed[i], points[i].z)

	# Crossings win: force the deck height, then ramp the approaches back to the
	# smoothed profile so nothing steps vertically at the bank.
	for site in road.crossings:
		var center: Vector3 = site.center()
		var deck: float = site.deck_height()
		for i in count:
			var d: float = Vector2(points[i].x - center.x, points[i].z - center.z).length()
			if d > APPROACH_LENGTH:
				continue
			var blend: float = 1.0 - smoothstep(site.span_length() * 0.5, APPROACH_LENGTH, d)
			points[i] = Vector3(points[i].x, lerpf(points[i].y, deck, blend), points[i].z)

	road.points = points


func _index_roads() -> void:
	for road in roads:
		for i in range(road.points.size() - 1):
			var a: Vector3 = road.points[i]
			var b: Vector3 = road.points[i + 1]
			road_index.insert_segment(a.x, a.z, b.x, b.z, road.id * 65536 + i)
