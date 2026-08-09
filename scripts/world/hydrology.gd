class_name Hydrology
extends RefCounted
## Layer 2: where water actually is.
##
## Solved with a bucket-queue priority flood over the macro grid. That single
## pass gives us, in one consistent structure:
##   - a depression-filled drainage surface that never rises downstream,
##   - flow directions (each cell's receiver is whoever discovered it),
##   - a processing order (downstream cells always pop before upstream ones),
##   - lakes for free: any cell whose filled height exceeds its terrain is
##     underwater, and the fill height IS that basin's spill elevation.
##
## Consequences that the design depends on:
##   - river water_z is monotonically non-increasing downstream by construction,
##   - every lake sits at its own local spill height, never a global water level,
##   - a lake's outflow starts at the spill and descends from there.

static var NEIGHBOR_DX: PackedInt32Array = PackedInt32Array([1, 1, 0, -1, -1, -1, 0, 1])
static var NEIGHBOR_DZ: PackedInt32Array = PackedInt32Array([0, 1, 1, 1, 0, -1, -1, -1])
const LEVEL_STEP: float = 0.25
## How many breach-and-reflood rounds to run before accepting what is left.
const BREACH_ROUNDS: int = 2
## Metres each successive shoulder of a breached channel stands above the bed.
const BREACH_SHOULDER: float = 9.0
## Widest a breach may open, in cells either side of the channel.
const BREACH_MAX_RINGS: int = 5
const LAKE_EPSILON: float = 0.05

var config: WorldConfig
var terrain: MacroTerrain

## Depression-filled drainage surface (m). filled >= elevation everywhere.
var filled: PackedFloat32Array
## Downstream neighbour index, -1 for cells that drain off the map.
var receiver: PackedInt32Array
## Pop order of the priority flood: downstream before upstream.
var flow_order: PackedInt32Array
## Upslope contributing area, in weighted cells.
var accumulation: PackedFloat32Array
## Lake id per cell, -1 when dry.
var lake_id: PackedInt32Array
## True where flow is concentrated enough to be a visible channel.
var is_channel: PackedInt32Array
## Distance in metres to the nearest lake cell, capped.
var lake_distance: PackedFloat32Array
## Surface height of whichever lake that nearest cell belongs to, -INF when no
## lake is in range. Carried alongside the distance transform so a shoreline
## column knows which basin it is on the edge of, rather than guessing from
## bounding boxes and picking up a different lake across the valley.
var lake_surface_near: PackedFloat32Array
## Uncapped distance used only to carry the surface outward. Build scratch.
var _surface_reach: PackedFloat32Array

var lakes: Array[LakeData] = []
var rivers: Array[RiverPolyline] = []
var river_index: SpatialIndex2D

const MAX_LAKE_DISTANCE: float = 512.0


static func solve(cfg: WorldConfig, macro: MacroTerrain, noise: NoiseSet) -> Hydrology:
	var hydro: Hydrology = Hydrology.new()
	hydro.config = cfg
	hydro.terrain = macro
	hydro._priority_flood()
	# Draining one basin exposes the sub-basins inside it, so this converges
	# rather than finishing in one pass. Each round re-floods, because the land
	# itself changed and every height, receiver and pop order is now stale.
	for _round in BREACH_ROUNDS:
		if not hydro._breach_depressions():
			break
		hydro._priority_flood()
	hydro._accumulate()
	hydro._find_lakes()
	hydro._mark_channels()
	hydro._build_rivers(noise)
	hydro._build_lake_distance()
	return hydro


# --- Priority flood -----------------------------------------------------------

func _priority_flood() -> void:
	var n: int = terrain.cells
	var count: int = n * n
	var elevation: PackedFloat32Array = terrain.elevation

	filled = PackedFloat32Array()
	filled.resize(count)
	receiver = PackedInt32Array()
	receiver.resize(count)
	flow_order = PackedInt32Array()
	flow_order.resize(count)

	var visited: PackedByteArray = PackedByteArray()
	visited.resize(count)

	var base: float = terrain.min_elevation
	var levels: int = int((terrain.max_elevation - base) / LEVEL_STEP) + 4
	var buckets: Array[PackedInt32Array] = []
	buckets.resize(levels)
	for i in levels:
		buckets[i] = PackedInt32Array()
	var head: PackedInt32Array = PackedInt32Array()
	head.resize(levels)

	# Seed the whole map rim: water leaves the world at its edges.
	for cx in n:
		_seed(buckets, visited, elevation, cx, 0, n, base, levels)
		_seed(buckets, visited, elevation, cx, n - 1, n, base, levels)
	for cz in range(1, n - 1):
		_seed(buckets, visited, elevation, 0, cz, n, base, levels)
		_seed(buckets, visited, elevation, n - 1, cz, n, base, levels)

	var level: int = 0
	var popped: int = 0
	while level < levels:
		if head[level] >= buckets[level].size():
			level += 1
			continue
		var cell: int = buckets[level][head[level]]
		head[level] += 1
		flow_order[popped] = cell
		popped += 1

		var cx: int = cell % n
		var cz: int = cell / n
		var cell_filled: float = filled[cell]
		for k in 8:
			var nx: int = cx + NEIGHBOR_DX[k]
			var nz: int = cz + NEIGHBOR_DZ[k]
			if nx < 0 or nz < 0 or nx >= n or nz >= n:
				continue
			var nb: int = nz * n + nx
			if visited[nb] != 0:
				continue
			visited[nb] = 1
			var nb_filled: float = maxf(elevation[nb], cell_filled)
			filled[nb] = nb_filled
			receiver[nb] = cell
			var nb_level: int = maxi(level, int((nb_filled - base) / LEVEL_STEP))
			buckets[clampi(nb_level, 0, levels - 1)].append(nb)

	assert(popped == count, "Priority flood left %d cells unreached" % (count - popped))


func _seed(
	buckets: Array[PackedInt32Array],
	visited: PackedByteArray,
	elevation: PackedFloat32Array,
	cx: int,
	cz: int,
	n: int,
	base: float,
	levels: int
) -> void:
	var index: int = cz * n + cx
	if visited[index] != 0:
		return
	visited[index] = 1
	filled[index] = elevation[index]
	receiver[index] = -1
	var level: int = clampi(int((elevation[index] - base) / LEVEL_STEP), 0, levels - 1)
	buckets[level].append(index)


# --- Breaching -----------------------------------------------------------------

## Cuts outlets for depressions the land could plausibly have drained itself,
## and returns whether anything was carved.
##
## A priority flood alone answers "how high does this hollow fill before it
## spills", which on a broad, nearly level lowland is "until it is a sea". Real
## drainage does the opposite first: the outflow erodes its own notch through the
## rim, and the hollow only stays wet if the rim is too high to cut. So every
## depression gets one attempt at an outlet, capped at [member WorldConfig.breach_limit]
## metres of cut, and lakes are what is left over — deep bowls, not flooded
## plains.
##
## The channel is written into the macro elevation, so it is real terrain: rivers
## run down it, roads must cross it, and the density field carves a valley around
## it like any other reach.
func _breach_depressions() -> bool:
	var n: int = terrain.cells
	var count: int = n * n
	var elevation: PackedFloat32Array = terrain.elevation
	var cell_size: float = terrain.cell_size
	var diagonal: float = cell_size * sqrt(2.0)

	# Depression cells grouped into basins, each visited from its lowest point.
	# Order is grid order, so the same seed always breaches in the same sequence.
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(count)
	var stack: PackedInt32Array = PackedInt32Array()
	var basin: PackedInt32Array = PackedInt32Array()
	var carved: bool = false

	for start in count:
		if seen[start] != 0 or filled[start] - elevation[start] <= LAKE_EPSILON:
			continue

		basin.clear()
		stack.clear()
		stack.append(start)
		seen[start] = 1
		var pit: int = start
		while not stack.is_empty():
			var cell: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			basin.append(cell)
			if elevation[cell] < elevation[pit]:
				pit = cell

			var cx: int = cell % n
			var cz: int = cell / n
			for k in 8:
				var nx: int = cx + NEIGHBOR_DX[k]
				var nz: int = cz + NEIGHBOR_DZ[k]
				if nx < 0 or nz < 0 or nx >= n or nz >= n:
					continue
				var nb: int = nz * n + nx
				if seen[nb] != 0 or filled[nb] - elevation[nb] <= LAKE_EPSILON:
					continue
				seen[nb] = 1
				stack.append(nb)

		var limit: float = config.breach_limit
		if basin.size() > config.breach_area_cells:
			limit = INF
		if _breach_from(pit, limit, elevation, n, cell_size, diagonal):
			carved = true

	if not carved:
		return false

	var lowest: float = INF
	var highest: float = -INF
	for i in count:
		lowest = minf(lowest, elevation[i])
		highest = maxf(highest, elevation[i])
	terrain.min_elevation = lowest
	terrain.max_elevation = highest
	return true


## Walks the flow path out of one depression twice: once to price the cut, once
## to make it. Pricing first matters — a half-dug channel that stops at the
## divide drains nothing and leaves a scar across the hillside for no reason.
func _breach_from(
	pit: int,
	limit: float,
	elevation: PackedFloat32Array,
	n: int,
	cell_size: float,
	diagonal: float
) -> bool:
	var deepest: float = 0.0
	var cell: int = pit
	var target: float = elevation[pit]
	var steps: int = 0
	while true:
		var down: int = receiver[cell]
		if down < 0:
			break
		target -= config.breach_slope * _step_length(cell, down, n, cell_size, diagonal)
		if elevation[down] <= target:
			break
		deepest = maxf(deepest, elevation[down] - target)
		if deepest > limit:
			return false
		cell = down
		steps += 1
		if steps > n * 4:
			return false

	if steps == 0:
		return false

	cell = pit
	target = elevation[pit]
	for _i in steps:
		var down: int = receiver[cell]
		target -= config.breach_slope * _step_length(cell, down, n, cell_size, diagonal)
		var cut: float = elevation[down] - target
		elevation[down] = target
		_widen(down, cell, target, cut, elevation, n)
		cell = down
	return true


## Opens the channel out sideways in proportion to how deep it had to cut.
##
## A one-cell cut is a 32 m slot with vertical walls, and a deep one is worse
## than useless: the drainage says the water is sixty metres down while the
## interpolated land two metres to the side is still up on the divide, so the
## chunk mesher cannot get its river valley anywhere near the water and the
## drainage-surface contract breaks. Taking the shoulders down one ring per
## [constant BREACH_SHOULDER] metres of cut makes the outlet a valley instead,
## which is both what the contract needs and what a river actually leaves behind.
func _widen(
	down: int,
	from_cell: int,
	target: float,
	cut: float,
	elevation: PackedFloat32Array,
	n: int
) -> void:
	var rings: int = mini(int(ceil(cut / BREACH_SHOULDER)), BREACH_MAX_RINGS)
	if rings <= 0:
		return
	var dx: int = down % n - from_cell % n
	var dz: int = down / n - from_cell / n
	var cx: int = down % n
	var cz: int = down / n
	for ring in range(1, rings + 1):
		var level: float = target + float(ring) * BREACH_SHOULDER
		for side in [1, -1]:
			var sx: int = cx - dz * side * ring
			var sz: int = cz + dx * side * ring
			if sx < 0 or sz < 0 or sx >= n or sz >= n:
				continue
			var index: int = sz * n + sx
			elevation[index] = minf(elevation[index], level)


static func _step_length(
	from_cell: int, to_cell: int, n: int, cell_size: float, diagonal: float
) -> float:
	var dx: int = absi(to_cell % n - from_cell % n)
	var dz: int = absi(to_cell / n - from_cell / n)
	return diagonal if dx != 0 and dz != 0 else cell_size


# --- Flow accumulation ---------------------------------------------------------

func _accumulate() -> void:
	var count: int = filled.size()
	accumulation = PackedFloat32Array()
	accumulation.resize(count)
	var moisture: PackedFloat32Array = terrain.moisture
	for i in count:
		accumulation[i] = 0.55 + moisture[i] * 0.9

	# flow_order runs downstream-first, so walking it backwards guarantees every
	# contributor is finished before its receiver is touched.
	for i in range(count - 1, -1, -1):
		var cell: int = flow_order[i]
		var down: int = receiver[cell]
		if down >= 0:
			accumulation[down] += accumulation[cell]


# --- Lakes ---------------------------------------------------------------------

func _find_lakes() -> void:
	var n: int = terrain.cells
	var count: int = n * n
	var elevation: PackedFloat32Array = terrain.elevation
	lake_id = PackedInt32Array()
	lake_id.resize(count)
	for i in count:
		lake_id[i] = -1

	var stack: PackedInt32Array = PackedInt32Array()
	for start in count:
		if lake_id[start] != -1:
			continue
		if filled[start] - elevation[start] <= LAKE_EPSILON:
			continue

		var surface: float = filled[start]
		var lake: LakeData = LakeData.new()
		lake.id = lakes.size()
		lake.surface_z = surface

		stack.clear()
		stack.append(start)
		lake_id[start] = lake.id
		var members: PackedInt32Array = PackedInt32Array()
		var deepest: float = 0.0
		var min_x: float = INF
		var min_z: float = INF
		var max_x: float = -INF
		var max_z: float = -INF

		while not stack.is_empty():
			var cell: int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			members.append(cell)
			deepest = maxf(deepest, surface - elevation[cell])

			var cx: int = cell % n
			var cz: int = cell / n
			var center: Vector2 = WorldCoords.macro_cell_center(config, Vector2i(cx, cz))
			min_x = minf(min_x, center.x)
			max_x = maxf(max_x, center.x)
			min_z = minf(min_z, center.y)
			max_z = maxf(max_z, center.y)

			for k in 8:
				var nx: int = cx + NEIGHBOR_DX[k]
				var nz: int = cz + NEIGHBOR_DZ[k]
				if nx < 0 or nz < 0 or nx >= n or nz >= n:
					continue
				var nb: int = nz * n + nx
				if lake_id[nb] != -1:
					continue
				if filled[nb] - elevation[nb] <= LAKE_EPSILON:
					continue
				if absf(filled[nb] - surface) > 0.02:
					continue
				lake_id[nb] = lake.id
				stack.append(nb)

		if members.size() < config.lake_min_cells or deepest < config.lake_min_depth:
			for cell in members:
				lake_id[cell] = -1
			continue

		lake.cells = members
		lake.max_depth = deepest
		var half: float = config.macro_cell_size * 0.5
		lake.bounds = Rect2(
			min_x - half, min_z - half,
			(max_x - min_x) + config.macro_cell_size,
			(max_z - min_z) + config.macro_cell_size
		)
		lake.outlet_cell = _find_outlet(lake)
		lakes.append(lake)


func _find_outlet(lake: LakeData) -> int:
	# The outlet is the member whose receiver leaves the basin: that is the cell
	# the priority flood spilled through, so the outflow starts exactly there.
	var best: int = -1
	var best_acc: float = -1.0
	for cell in lake.cells:
		var down: int = receiver[cell]
		if down < 0:
			return cell
		if lake_id[down] != lake.id and accumulation[cell] > best_acc:
			best_acc = accumulation[cell]
			best = cell
	return best


# --- Channels ------------------------------------------------------------------

func _mark_channels() -> void:
	var count: int = filled.size()
	is_channel = PackedInt32Array()
	is_channel.resize(count)
	var threshold: float = config.river_accum_threshold
	for i in count:
		var channel: bool = (
			accumulation[i] >= threshold
			and lake_id[i] == -1
			and receiver[i] >= 0
		)
		is_channel[i] = 1 if channel else 0


# --- River reaches ---------------------------------------------------------------

func _build_rivers(noise: NoiseSet) -> void:
	var n: int = terrain.cells
	var count: int = filled.size()

	var strahler: PackedInt32Array = PackedInt32Array()
	strahler.resize(count)
	var max_up: PackedInt32Array = PackedInt32Array()
	max_up.resize(count)
	var max_up_count: PackedInt32Array = PackedInt32Array()
	max_up_count.resize(count)

	# Upstream-first pass: Strahler order only needs each cell's tributaries.
	# Non-channel cells still forward what reached them, so a trunk river that
	# crosses a lake leaves it as a trunk river instead of restarting at order 1.
	for i in range(count - 1, -1, -1):
		var cell: int = flow_order[i]
		var order: int = 0
		if is_channel[cell] != 0:
			order = 1
			if max_up[cell] > 0:
				order = max_up[cell] + 1 if max_up_count[cell] >= 2 else max_up[cell]
			strahler[cell] = order
		else:
			order = max_up[cell]
		if order <= 0:
			continue
		var down: int = receiver[cell]
		if down >= 0:
			if order > max_up[down]:
				max_up[down] = order
				max_up_count[down] = 1
			elif order == max_up[down]:
				max_up_count[down] += 1

	var consumed: PackedByteArray = PackedByteArray()
	consumed.resize(count)
	# Which reach owns each macro cell, and which cell each reach ended on.
	# Linking on cells rather than geometry survives meandering, which moves
	# stations off their cell centres.
	var cell_owner: PackedInt32Array = PackedInt32Array()
	cell_owner.resize(count)
	for i in count:
		cell_owner[i] = -1
	var end_cells: PackedInt32Array = PackedInt32Array()
	river_index = SpatialIndex2D.new(160.0)

	for i in range(count - 1, -1, -1):
		var start: int = flow_order[i]
		if is_channel[start] == 0 or consumed[start] != 0:
			continue

		var reach: RiverPolyline = RiverPolyline.new()
		reach.id = rivers.size()
		reach.order = strahler[start]
		reach.depth = config.river_depth_base + float(reach.order - 1) * config.river_depth_per_order
		reach.valley = config.river_valley_base + float(reach.order - 1) * config.river_valley_per_order

		var chain: PackedInt32Array = PackedInt32Array()
		var cell: int = start
		while true:
			consumed[cell] = 1
			chain.append(cell)
			var down: int = receiver[cell]
			if down < 0:
				break
			if lake_id[down] != -1:
				chain.append(down)
				reach.ends_in_lake = lake_id[down]
				break
			if is_channel[down] == 0:
				chain.append(down)
				break
			if strahler[down] != reach.order or consumed[down] != 0:
				chain.append(down)
				break
			cell = down

		if chain.size() < 2:
			continue

		_chain_to_polyline(reach, chain, n, noise)
		for k in chain.size() - 1:
			cell_owner[chain[k]] = reach.id
		end_cells.append(chain[chain.size() - 1])
		rivers.append(reach)

	_link_downstream(cell_owner, end_cells)
	_join_confluences()
	for reach in rivers:
		reach.compute_bounds()
	_index_rivers()


func _chain_to_polyline(
	reach: RiverPolyline, chain: PackedInt32Array, n: int, noise: NoiseSet
) -> void:
	var raw: PackedVector3Array = PackedVector3Array()
	var widths: PackedFloat32Array = PackedFloat32Array()

	for idx in chain.size():
		var cell: int = chain[idx]
		var cx: int = cell % n
		var cz: int = cell / n
		var center: Vector2 = WorldCoords.macro_cell_center(config, Vector2i(cx, cz))

		var order: float = float(maxi(reach.order, 1))
		var half_w: float = config.river_width_base + (order - 1.0) * config.river_width_per_order

		raw.append(Vector3(center.x, filled[cell], center.y))
		widths.append(half_w)

	_apply_meander(raw, noise)
	var smooth: PackedVector3Array = _chaikin(raw, 2)
	var smooth_widths: PackedFloat32Array = _resample_widths(widths, smooth.size())

	_force_monotonic(smooth)

	reach.points = smooth
	reach.half_width = smooth_widths


## Lateral wander only. Station heights are never touched, so the monotonic
## drainage profile survives meandering.
func _apply_meander(points: PackedVector3Array, noise: NoiseSet) -> void:
	var n_points: int = points.size()
	if n_points < 3:
		return
	for i in range(1, n_points - 1):
		var prev: Vector3 = points[i - 1]
		var next: Vector3 = points[i + 1]
		var dir: Vector2 = Vector2(next.x - prev.x, next.z - prev.z)
		if dir.length_squared() < 0.0001:
			continue
		dir = dir.normalized()
		var perp: Vector2 = Vector2(-dir.y, dir.x)

		var drop: float = absf(prev.y - next.y)
		var run: float = Vector2(next.x - prev.x, next.z - prev.z).length()
		var slope: float = drop / maxf(run, 0.001)
		# Meanders belong on flat ground; steep reaches stay in their valley.
		var flatness: float = 1.0 - smoothstep(0.01, 0.09, slope)

		var wander: float = noise.meander.get_noise_2d(points[i].x, points[i].z)
		var offset: float = wander * config.meander_amplitude * flatness
		points[i] = Vector3(
			points[i].x + perp.x * offset,
			points[i].y,
			points[i].z + perp.y * offset
		)


func _force_monotonic(points: PackedVector3Array) -> void:
	for i in range(1, points.size()):
		var prev_y: float = points[i - 1].y
		if points[i].y > prev_y:
			points[i] = Vector3(points[i].x, prev_y, points[i].z)


static func _chaikin(points: PackedVector3Array, iterations: int) -> PackedVector3Array:
	var current: PackedVector3Array = points
	for _i in iterations:
		if current.size() < 3:
			return current
		var next: PackedVector3Array = PackedVector3Array()
		next.append(current[0])
		for k in range(current.size() - 1):
			var a: Vector3 = current[k]
			var b: Vector3 = current[k + 1]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		next.append(current[current.size() - 1])
		current = next
	return current


static func _resample_widths(widths: PackedFloat32Array, target: int) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(target)
	var last: int = widths.size() - 1
	if last <= 0:
		for i in target:
			out[i] = widths[0] if widths.size() > 0 else 1.0
		return out
	for i in target:
		var t: float = float(i) / float(maxi(target - 1, 1)) * float(last)
		var i0: int = clampi(int(t), 0, last)
		var i1: int = mini(i0 + 1, last)
		out[i] = lerpf(widths[i0], widths[i1], t - float(i0))
	return out


func _link_downstream(cell_owner: PackedInt32Array, end_cells: PackedInt32Array) -> void:
	for reach in rivers:
		var owner: int = cell_owner[end_cells[reach.id]]
		if owner >= 0 and owner != reach.id:
			reach.downstream_id = owner


## Pull each tributary's last station onto the trunk it joins. Without this the
## meander offset would leave a visible gap at every confluence, and the two
## water surfaces would not meet.
func _join_confluences() -> void:
	for reach in rivers:
		if reach.downstream_id < 0:
			continue
		var trunk: RiverPolyline = rivers[reach.downstream_id]
		var last_index: int = reach.points.size() - 1
		var tip: Vector3 = reach.points[last_index]

		var best: Vector3 = trunk.points[0]
		var best_d: float = INF
		for p in trunk.points:
			var d: float = Vector2(p.x - tip.x, p.z - tip.z).length_squared()
			if d < best_d:
				best_d = d
				best = p

		var previous_y: float = reach.points[last_index - 1].y
		reach.points[last_index] = Vector3(best.x, minf(best.y, previous_y), best.z)


func _index_rivers() -> void:
	for reach in rivers:
		for i in range(reach.points.size() - 1):
			var a: Vector3 = reach.points[i]
			var b: Vector3 = reach.points[i + 1]
			river_index.insert_segment(a.x, a.z, b.x, b.z, reach.id * 65536 + i)


# --- Lake proximity --------------------------------------------------------------

func _build_lake_distance() -> void:
	var n: int = terrain.cells
	var count: int = n * n
	lake_distance = PackedFloat32Array()
	lake_distance.resize(count)
	lake_surface_near = PackedFloat32Array()
	lake_surface_near.resize(count)
	# The surface is carried on its own uncapped distance so it stays finite over
	# the whole grid. A field with holes in it cannot be sampled smoothly, and a
	# lake level read per cell puts a 32 m staircase around every shore.
	_surface_reach = PackedFloat32Array()
	_surface_reach.resize(count)
	for i in count:
		var id: int = lake_id[i]
		lake_distance[i] = 0.0 if id != -1 else MAX_LAKE_DISTANCE
		_surface_reach[i] = 0.0 if id != -1 else INF
		lake_surface_near[i] = lakes[id].surface_z if id != -1 else -INF

	var straight: float = config.macro_cell_size
	var diagonal: float = straight * 1.41421356

	for cz in n:
		for cx in n:
			var i: int = cz * n + cx
			if cx > 0:
				_relax_lake(i, i - 1, straight)
			if cz > 0:
				_relax_lake(i, i - n, straight)
			if cx > 0 and cz > 0:
				_relax_lake(i, i - n - 1, diagonal)
			if cx < n - 1 and cz > 0:
				_relax_lake(i, i - n + 1, diagonal)

	for cz in range(n - 1, -1, -1):
		for cx in range(n - 1, -1, -1):
			var i: int = cz * n + cx
			if cx < n - 1:
				_relax_lake(i, i + 1, straight)
			if cz < n - 1:
				_relax_lake(i, i + n, straight)
			if cx < n - 1 and cz < n - 1:
				_relax_lake(i, i + n + 1, diagonal)
			if cx > 0 and cz < n - 1:
				_relax_lake(i, i + n - 1, diagonal)


func _relax_lake(target: int, source: int, step: float) -> void:
	var reach: float = _surface_reach[source] + step
	if reach < _surface_reach[target]:
		_surface_reach[target] = reach
		lake_surface_near[target] = lake_surface_near[source]
	var candidate: float = lake_distance[source] + step
	if candidate < lake_distance[target]:
		lake_distance[target] = candidate


func lake_at(world_x: float, world_z: float) -> int:
	if not WorldCoords.in_bounds(config, world_x, world_z):
		return -1
	var cell: Vector2i = WorldCoords.macro_cell_of(config, world_x, world_z)
	return lake_id[cell.y * terrain.cells + cell.x]


## Nearest river station to a point, or an empty dictionary when none is close.
## Keys: distance, half_width, water_z, order, reach.
func nearest_reach(world_x: float, world_z: float, radius: float) -> Dictionary:
	var rect: Rect2 = Rect2(world_x - radius, world_z - radius, radius * 2.0, radius * 2.0)
	var best: Dictionary = {}
	var best_d: float = radius
	for encoded in river_index.query_rect(rect):
		var reach: RiverPolyline = rivers[encoded >> 16]
		var i: int = encoded & 0xFFFF
		var a: Vector3 = reach.points[i]
		var b: Vector3 = reach.points[i + 1]
		var ab: Vector2 = Vector2(b.x - a.x, b.z - a.z)
		var len_sq: float = ab.length_squared()
		var t: float = 0.0
		if len_sq > 0.000001:
			t = clampf(Vector2(world_x - a.x, world_z - a.z).dot(ab) / len_sq, 0.0, 1.0)
		var point: Vector2 = Vector2(a.x, a.z) + ab * t
		var d: float = point.distance_to(Vector2(world_x, world_z))
		if d >= best_d:
			continue
		best_d = d
		best = {
			"distance": d,
			"point": point,
			"half_width": lerpf(reach.half_width[i], reach.half_width[i + 1], t),
			"water_z": lerpf(a.y, b.y, t),
			"order": reach.order,
			"reach": reach.id,
		}
	return best


## The depression-filled drainage height, sampled as smoothly as the terrain it
## is compared against. Above the land surface means standing water; the two
## meet exactly at the waterline.
func drainage_at(world_x: float, world_z: float) -> float:
	return terrain.sample_field(filled, world_x, world_z)


func lake_distance_at(world_x: float, world_z: float) -> float:
	return maxf(terrain.sample_field(lake_distance, world_x, world_z), 0.0)


## Surface of the lake nearest this point, sampled as smoothly as the ground it
## is compared against, or -INF when the world has no lakes at all.
func lake_surface_near_at(world_x: float, world_z: float) -> float:
	if lakes.is_empty():
		return -INF
	return terrain.sample_field(lake_surface_near, world_x, world_z)
