class_name PathNetwork
extends RefCounted
## Layer 3: how people move through the land, as one sector sees it.
##
## Split in two, along the same line as the hydrology:
##
##   trunk roads   rebuilt from [AtlasCorridors] geometry, draped on the macro
##                 terrain with a pointwise filter. Both the geometry and the
##                 filter are pure functions of continental coordinates, so two
##                 sectors that share a trunk produce the same spline, the same
##                 grade and the same benched height at the boundary.
##   local tracks  least-cost paths between sector-local landmarks, confined to
##                 the sector core. A track never crosses a boundary, so no
##                 neighbour has to agree with it.
##
## Water crossings on trunk roads are found by intersecting the pure trunk road
## with the pure trunk river, so both neighbours find the same bridges at the
## same metres instead of each inventing its own near the boundary.

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
## Radius of the pointwise filter that drapes a trunk road on the terrain.
## Pointwise, not along-chain: a rolling average over the stations this sector
## happens to hold would give a different height wherever the chain is clipped.
const DRAPE_RADIUS: float = 44.0
const DRAPE_TAPS: int = 6

var config: WorldConfig
var terrain: MacroTerrain
var hydro: Hydrology
var claims: ClaimMask
var corridors: AtlasCorridors

## Local cell bounds of the sector core, inclusive.
var core_min: Vector2i = Vector2i.ZERO
var core_max: Vector2i = Vector2i.ZERO
## The core minus the keep-out band, which is as far as a local track may go.
var local_min: Vector2i = Vector2i.ZERO
var local_max: Vector2i = Vector2i.ZERO

## Local landmark positions, in continental metres.
var nodes: PackedVector2Array = PackedVector2Array()
var roads: Array[RoadEdge] = []
var bridges: Array[BridgeSite] = []
var road_index: SpatialIndex2D

var _slope: PackedFloat32Array
var _step_cost: PackedFloat32Array
## Cells no road may enter at any price: standing water, and everything outside
## the sector core, because a local track that leaves the core is a track the
## next sector never heard of.
var _blocked: PackedByteArray


static func build(
	cfg: WorldConfig,
	macro: MacroTerrain,
	water: Hydrology,
	claim_mask: ClaimMask,
	corr: AtlasCorridors,
	core_from: Vector2i,
	core_to: Vector2i
) -> PathNetwork:
	var net: PathNetwork = PathNetwork.new()
	net.config = cfg
	net.terrain = macro
	net.hydro = water
	net.claims = claim_mask
	net.corridors = corr
	net.core_min = core_from
	net.core_max = core_to
	var keepout: int = cfg.keepout_cells()
	net.local_min = core_from + Vector2i(keepout, keepout)
	net.local_max = core_to - Vector2i(keepout, keepout)
	net.road_index = SpatialIndex2D.new(160.0)
	net._compute_costs()
	net._build_trunk_roads()
	net._choose_local_nodes()
	net._connect_local()
	net._index_roads()
	return net


# --- Terrain cost -----------------------------------------------------------------

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
			# A track may not enter the keep-out band, let alone leave the core:
			# its bench and its corridor mask would reshape ground the next
			# sector also meshes, and that sector has never heard of the track.
			var outside: bool = (
				cx < local_min.x or cz < local_min.y
				or cx > local_max.x or cz > local_max.y
			)
			if outside or hydro.lake_id[i] != -1 or hydro.atlas_water[i] != 0:
				_blocked[i] = 1
			elif hydro.is_channel[i] != 0 or hydro.trunk[i] != 0:
				# A brook is a step; a trunk river is a project. The gradient is
				# what makes routes gather at a few sensible crossings instead of
				# either fording everywhere or detouring to every headwater.
				cost += 4.0 + float(hydro.accumulation[i]) * 0.02
			_step_cost[i] = cost


# --- Trunk roads --------------------------------------------------------------------

func _build_trunk_roads() -> void:
	var stride: int = AtlasCorridors.ROAD_STRIDE
	var rect: Rect2 = terrain.window_rect().grow(config.macro_cell_size * 4.0)
	var bases: PackedInt32Array = corridors.roads_in_rect(rect)
	bases.sort()

	var run: PackedInt32Array = PackedInt32Array()
	for base in bases:
		var continues_run: bool = (
			not run.is_empty()
			and base == run[run.size() - 1] + stride
			and corridors.road_feature_ids[base / stride]
				== corridors.road_feature_ids[run[run.size() - 1] / stride]
		)
		if continues_run:
			run.append(base)
			continue
		_emit_trunk_road(run)
		run = PackedInt32Array([base])
	_emit_trunk_road(run)


func _emit_trunk_road(run: PackedInt32Array) -> void:
	if run.is_empty():
		return
	var stride: int = AtlasCorridors.ROAD_STRIDE
	var road_class: int = int(corridors.roads[run[0] + 7])

	var road: RoadEdge = RoadEdge.new()
	road.id = roads.size()
	road.is_trunk = true
	road.feature_id = corridors.road_feature_ids[run[0] / stride]
	road.tier = _tier_of(road_class)
	road.half_width = corridors.road_half_width(road_class)

	var points: PackedVector3Array = PackedVector3Array()
	for i in run.size():
		var base: int = run[i]
		if i == 0:
			points.append(_draped(corridors.roads[base], corridors.roads[base + 2]))
		points.append(_draped(corridors.roads[base + 3], corridors.roads[base + 5]))
	if points.size() < 2:
		return

	road.points = points
	_find_trunk_crossings(road)
	_apply_crossing_profile(road)
	road.compute_bounds()
	roads.append(road)


static func _tier_of(road_class: int) -> RoadEdge.Tier:
	match road_class:
		AtlasFeatures.RoadClass.PRIMARY:
			return RoadEdge.Tier.PRIMARY
		AtlasFeatures.RoadClass.SECONDARY:
			return RoadEdge.Tier.SECONDARY
	return RoadEdge.Tier.TRAIL


## Road surface at a point: the macro terrain averaged over a small disc.
##
## A disc average and not a rolling average along the polyline, because a
## rolling average depends on how much of the polyline this sector happens to
## hold. This filter reads the same macro grid values both neighbours have, at
## the same continental positions, so both compute the same road height.
func _draped(world_x: float, world_z: float) -> Vector3:
	var total: float = terrain.height_at(world_x, world_z)
	var samples: int = 1
	for i in DRAPE_TAPS:
		var angle: float = TAU * float(i) / float(DRAPE_TAPS)
		total += terrain.height_at(
			world_x + cos(angle) * DRAPE_RADIUS, world_z + sin(angle) * DRAPE_RADIUS
		)
		samples += 1
	return Vector3(world_x, total / float(samples), world_z)


## Crossings where a trunk road meets a trunk river. Both polylines are pure
## continental geometry, so both neighbours find the same intersections.
func _find_trunk_crossings(road: RoadEdge) -> void:
	for i in range(road.points.size() - 1):
		var a: Vector2 = Vector2(road.points[i].x, road.points[i].z)
		var b: Vector2 = Vector2(road.points[i + 1].x, road.points[i + 1].z)
		var rect: Rect2 = Rect2(a, Vector2.ZERO).expand(b).grow(4.0)
		for encoded in hydro.river_index.query_rect(rect):
			var reach: RiverPolyline = hydro.rivers[encoded >> 16]
			if not reach.is_trunk:
				continue
			var si: int = encoded & 0xFFFF
			var c: Vector3 = reach.points[si]
			var d: Vector3 = reach.points[si + 1]
			var hit: Vector2 = _segment_intersection(
				a, b, Vector2(c.x, c.z), Vector2(d.x, d.z)
			)
			if hit == Vector2.INF:
				continue
			if _already_crossed(road, hit):
				continue
			var water_z: float = lerpf(
				c.y, d.y, _param_on(Vector2(c.x, c.z), Vector2(d.x, d.z), hit)
			)
			var half: float = lerpf(reach.half_width[si], reach.half_width[si + 1], 0.5)
			_make_crossing(road, hit, (b - a).normalized(), water_z, half, reach.order)


func _already_crossed(road: RoadEdge, at: Vector2) -> bool:
	for site in road.crossings:
		var centre: Vector3 = site.center()
		if Vector2(centre.x - at.x, centre.z - at.y).length() < 24.0:
			return true
	return false


static func _param_on(a: Vector2, b: Vector2, point: Vector2) -> float:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq < 0.000001:
		return 0.0
	return clampf((point - a).dot(ab) / len_sq, 0.0, 1.0)


## Intersection of two 2D segments, or Vector2.INF when they do not cross.
static func _segment_intersection(
	a: Vector2, b: Vector2, c: Vector2, d: Vector2
) -> Vector2:
	var r: Vector2 = b - a
	var s: Vector2 = d - c
	var denom: float = r.cross(s)
	if absf(denom) < 0.000001:
		return Vector2.INF
	var t: float = (c - a).cross(s) / denom
	var u: float = (c - a).cross(r) / denom
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return Vector2.INF
	return a + r * t


# --- Local landmarks ------------------------------------------------------------------

func _choose_local_nodes() -> void:
	var n: int = terrain.cells
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = config.place_seed("local_nodes", terrain.origin_cell)

	var scored: Array[Vector3] = []
	for cz in range(local_min.y + 2, local_max.y - 1):
		for cx in range(local_min.x + 2, local_max.x - 1):
			var i: int = cz * n + cx
			if _blocked[i] != 0 or hydro.is_channel[i] != 0 or hydro.trunk[i] != 0:
				continue
			if terrain.elevation[i] < 2.0:
				continue
			var flatness: float = 1.0 - clampf(_slope[i] / 0.16, 0.0, 1.0)
			if flatness <= 0.05:
				continue
			var water_pull: float = 0.0
			water_pull += clampf(1.0 - hydro.lake_distance[i] / 420.0, 0.0, 1.0) * 0.7
			water_pull += clampf(
				hydro.accumulation[i] / config.river_accum_threshold, 0.0, 1.0
			) * 0.3
			var score: float = flatness * 1.4 + water_pull + rng.randf() * 0.35
			scored.append(Vector3(score, float(cx), float(cz)))

	scored.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.x > b.x)

	var min_spacing: float = WorldCoords.SECTOR_SIZE / 6.0
	var chosen: PackedVector2Array = PackedVector2Array()
	for entry in scored:
		if chosen.size() >= config.local_node_count:
			break
		var pos: Vector2 = terrain.cell_center(int(entry.y), int(entry.z))
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
			&"landmark", pos, 110.0 + float(i % 3) * 30.0,
			terrain.height_at(pos.x, pos.y)
		)
	_reserve_dungeon_mouths(rng)


func _reserve_dungeon_mouths(rng: RandomNumberGenerator) -> void:
	# Steep ground away from water is where cave mouths will be worth entering.
	var n: int = terrain.cells
	var wanted: int = maxi(3, config.local_node_count / 2)
	var placed: int = 0
	var attempts: int = 0
	while placed < wanted and attempts < 3000:
		attempts += 1
		var cx: int = rng.randi_range(local_min.x + 1, local_max.x - 1)
		var cz: int = rng.randi_range(local_min.y + 1, local_max.y - 1)
		var i: int = cz * n + cx
		if _blocked[i] != 0 or hydro.is_channel[i] != 0 or hydro.trunk[i] != 0:
			continue
		if _slope[i] < 0.35:
			continue
		var pos: Vector2 = terrain.cell_center(cx, cz)
		if claims.is_reserved(pos.x, pos.y):
			continue
		claims.add(&"dungeon_mouth", pos, 70.0, terrain.elevation[i])
		placed += 1


# --- Local network ------------------------------------------------------------------------

func _connect_local() -> void:
	var count: int = nodes.size()
	if count < 1:
		return

	if count >= 2:
		# A minimum spanning tree over the landmarks, so the local network is
		# connected without the spaghetti of all-pairs shortest paths.
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
			_route_positions(
				nodes[edge.x], nodes[edge.y], RoadEdge.Tier.SECONDARY, edge.x, edge.y
			)

	# Every landmark wants to reach the continental network, so the local tracks
	# feed the trunk roads instead of forming an island of their own.
	for a in count:
		var join: Vector2 = _nearest_trunk_point(nodes[a])
		if join != Vector2.INF:
			_route_positions(nodes[a], join, RoadEdge.Tier.TRAIL, a, -1)


## Nearest point on a trunk road that lies inside the core, or INF.
func _nearest_trunk_point(from: Vector2) -> Vector2:
	var best: Vector2 = Vector2.INF
	var best_d: float = WorldCoords.SECTOR_SIZE
	for road in roads:
		if not road.is_trunk:
			continue
		for p in road.points:
			var cell: Vector2i = terrain.local_cell_of(p.x, p.z)
			if not terrain.contains_local(cell.x, cell.y):
				continue
			if _blocked[cell.y * terrain.cells + cell.x] != 0:
				continue
			var d: float = Vector2(p.x, p.z).distance_to(from)
			if d < best_d:
				best_d = d
				best = Vector2(p.x, p.z)
	return best


func _route_positions(
	from_pos: Vector2, to_pos: Vector2, tier: RoadEdge.Tier, from_node: int, to_node: int
) -> void:
	var start_cell: Vector2i = terrain.local_cell_of(from_pos.x, from_pos.y)
	var goal_cell: Vector2i = terrain.local_cell_of(to_pos.x, to_pos.y)
	if not terrain.contains_local(start_cell.x, start_cell.y):
		return
	if not terrain.contains_local(goal_cell.x, goal_cell.y):
		return
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
	_find_local_crossings(road, path)
	_smooth_profile(road)
	_apply_crossing_profile(road)
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
			var centre: Vector2 = terrain.cell_center(nx, nz)
			if claims.kind_at(centre.x, centre.y) == &"dungeon_mouth":
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
		var centre: Vector2 = terrain.cell_center(cell % n, cell / n)
		raw.append(Vector3(centre.x, terrain.elevation[cell], centre.y))
	return Hydrology._chaikin(raw, 2)


func _find_local_crossings(road: RoadEdge, path: PackedInt32Array) -> void:
	var run_start: int = -1
	for i in path.size():
		var cell: int = path[i]
		var wet: bool = hydro.is_channel[cell] != 0 or hydro.lake_id[cell] != -1
		if wet and run_start < 0:
			run_start = i
		elif not wet and run_start >= 0:
			_make_local_crossing(road, path, run_start, i - 1)
			run_start = -1
	if run_start >= 0:
		_make_local_crossing(road, path, run_start, path.size() - 1)


func _make_local_crossing(
	road: RoadEdge, path: PackedInt32Array, from_i: int, to_i: int
) -> void:
	var n: int = terrain.cells
	var cell_mid: int = path[(from_i + to_i) / 2]
	var mid_pos: Vector2 = terrain.cell_center(cell_mid % n, cell_mid / n)

	var water_z: float = hydro.filled[cell_mid]
	var lake: int = hydro.lake_id[cell_mid]
	if lake != -1:
		water_z = hydro.lakes[lake].surface_z

	# Ask the actual channel how wide it is here rather than guessing from flow:
	# fords only make sense where there really is a shallow, narrow crossing.
	var reach: Dictionary = hydro.nearest_reach(
		mid_pos.x, mid_pos.y, config.macro_cell_size * 2.0
	)
	var crossed: Vector2 = reach.get("point", mid_pos) as Vector2
	var on_road: Dictionary = _project_on_road(road, crossed)
	var axis: Vector2 = on_road["axis"]
	if axis.length_squared() < 0.0001:
		axis = Vector2.RIGHT
	var run_half: float = float(to_i - from_i + 1) * 0.5 * config.macro_cell_size
	var channel_half: float = float(reach.get("half_width", 0.0))
	var span_half: float = maxf(
		run_half if lake != -1 else channel_half + BANK_MARGIN, MIN_SPAN * 0.5
	)
	_add_crossing(
		road, on_road["position"], axis,
		float(reach.get("water_z", water_z)),
		span_half, channel_half, int(reach.get("order", 1)), lake != -1
	)


func _make_crossing(
	road: RoadEdge, at: Vector2, axis: Vector2, water_z: float,
	channel_half: float, order: int
) -> void:
	var on_road: Dictionary = _project_on_road(road, at)
	var use_axis: Vector2 = on_road["axis"]
	if use_axis.length_squared() < 0.0001:
		use_axis = axis
	_add_crossing(
		road, on_road["position"], use_axis, water_z,
		maxf(channel_half + BANK_MARGIN, MIN_SPAN * 0.5), channel_half, order, false
	)


func _add_crossing(
	road: RoadEdge,
	centre: Vector2,
	axis: Vector2,
	water_z: float,
	span_half: float,
	channel_half: float,
	order: int,
	over_lake: bool
) -> void:
	var site: BridgeSite = BridgeSite.new()
	site.id = bridges.size()
	site.road_id = road.id
	site.water_z = water_z
	site.river_order = order
	site.deck_width = road.half_width * 2.0 + 1.2
	site.is_ford = (
		not over_lake and channel_half > 0.0
		and channel_half * 2.0 <= config.ford_max_width
	)

	var pos_a: Vector2 = centre - axis * span_half
	var pos_b: Vector2 = centre + axis * span_half
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
		claims.add(
			&"bridge", Vector2(site.center().x, site.center().z),
			site.span_length() * 0.6, deck_z
		)

	road.crossings.append(site)
	bridges.append(site)


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


func _smooth_profile(road: RoadEdge) -> void:
	var points: PackedVector3Array = road.points
	var count: int = points.size()
	if count < 3:
		return

	# Rolling average: roads bench into the hillside instead of tracing every
	# bump, and the density field carves the terrain to meet this profile. Only
	# local tracks get this - a trunk is draped pointwise instead, because a
	# rolling average would depend on where the sector clipped the chain.
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
	road.points = points


## Crossings win: force the deck height, then ramp the approaches back to the
## profile so nothing steps vertically at the bank.
func _apply_crossing_profile(road: RoadEdge) -> void:
	var points: PackedVector3Array = road.points
	for site in road.crossings:
		var centre: Vector3 = site.center()
		var deck: float = site.deck_height()
		for i in points.size():
			var d: float = Vector2(points[i].x - centre.x, points[i].z - centre.z).length()
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
