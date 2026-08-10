class_name HamletLabPlanner
extends RefCounted
## Evolutionary marketplace hamlet (2D lab).
##
## 1. Declare a perturbed N-gon green (n = tier_level * 6).
## 2. Settlers pack against the market (frontier grows only when full).
## 3. Occupancy is a pixel grid so non-aligned houses cannot overlap.
## 4. Leftover wedges too tight for another house become future roads.
## Crofts/fences/fields omitted for now.


class Shape extends RefCounted:
	enum Kind { HOUSE, MARKET }

	var kind: int = Kind.HOUSE
	var center: Vector2 = Vector2.ZERO
	var half_size: Vector2 = Vector2.ONE
	var yaw: float = 0.0
	var radius: float = 0.0
	## VillageCatalog id for buildings (empty for MARKET).
	var catalog_id: StringName = &""
	## Closed polygon verts for MARKET (world metres). Last edge wraps to first.
	var polygon: PackedVector2Array = PackedVector2Array()


class Plan2D extends RefCounted:
	var shapes: Array[Shape] = []
	var plaza: Vector2 = Vector2.ZERO
	var market_radius: float = 12.0
	var market_sides: int = 6
	## Primary marketplace polygon (also markets[0]).
	var market_polygon: PackedVector2Array = PackedVector2Array()
	## All market polygons (primary first, then secondaries).
	var markets: Array[PackedVector2Array] = []
	var market_centers: PackedVector2Array = PackedVector2Array()
	var built_envelope: float = 20.0
	var house_count: int = 0
	var civic_count: int = 0
	var want_count: int = 0
	## Non-empty when house_count < want_count.
	var underfill_message: String = ""
	## Optional debug: occupied cell centres in world metres.
	var occupancy_dots: PackedVector2Array = PackedVector2Array()


class _Occupancy extends RefCounted:
	var cell: float = 0.35
	var origin: Vector2 = Vector2.ZERO
	var width: int = 0
	var height: int = 0
	var cells: PackedByteArray = PackedByteArray()

	func setup(world_half: float, cell_size: float) -> void:
		cell = maxf(cell_size, 0.1)
		var span: float = world_half * 2.0
		width = int(ceil(span / cell)) + 2
		height = width
		origin = Vector2(-world_half - cell, -world_half - cell)
		cells.resize(width * height)
		cells.fill(0)

	func _index(ix: int, iy: int) -> int:
		return iy * width + ix

	func _in_bounds(ix: int, iy: int) -> bool:
		return ix >= 0 and iy >= 0 and ix < width and iy < height

	func world_to_cell(p: Vector2) -> Vector2i:
		return Vector2i(
			int(floor((p.x - origin.x) / cell)),
			int(floor((p.y - origin.y) / cell))
		)

	func cell_center(ix: int, iy: int) -> Vector2:
		return origin + Vector2((float(ix) + 0.5) * cell, (float(iy) + 0.5) * cell)

	func fits_obb(center: Vector2, half_x: float, half_z: float, yaw: float, inflate: float) -> bool:
		return not _stamp_obb(center, half_x, half_z, yaw, inflate, false)

	func stamp_obb(center: Vector2, half_x: float, half_z: float, yaw: float, inflate: float) -> void:
		_stamp_obb(center, half_x, half_z, yaw, inflate, true)

	func stamp_polygon(poly: PackedVector2Array) -> void:
		if poly.size() < 3:
			push_error("HamletLabPlanner: market polygon needs >= 3 verts")
			assert(false)
			return
		var min_x: float = INF
		var min_y: float = INF
		var max_x: float = -INF
		var max_y: float = -INF
		for p in poly:
			min_x = minf(min_x, p.x)
			min_y = minf(min_y, p.y)
			max_x = maxf(max_x, p.x)
			max_y = maxf(max_y, p.y)
		var min_c: Vector2i = world_to_cell(Vector2(min_x, min_y))
		var max_c: Vector2i = world_to_cell(Vector2(max_x, max_y))
		for iy in range(min_c.y, max_c.y + 1):
			for ix in range(min_c.x, max_c.x + 1):
				if not _in_bounds(ix, iy):
					continue
				if HamletLabPlanner._point_in_polygon(cell_center(ix, iy), poly):
					cells[_index(ix, iy)] = 1

	func _stamp_obb(
		center: Vector2, half_x: float, half_z: float, yaw: float, inflate: float, write: bool
	) -> bool:
		var hx: float = half_x + inflate
		var hz: float = half_z + inflate
		var x_axis: Vector2 = Vector2(cos(yaw), -sin(yaw))
		var z_axis: Vector2 = Vector2(sin(yaw), cos(yaw))
		var corners: Array[Vector2] = [
			center + x_axis * hx + z_axis * hz,
			center - x_axis * hx + z_axis * hz,
			center - x_axis * hx - z_axis * hz,
			center + x_axis * hx - z_axis * hz,
		]
		var min_x: float = INF
		var min_y: float = INF
		var max_x: float = -INF
		var max_y: float = -INF
		for c in corners:
			min_x = minf(min_x, c.x)
			min_y = minf(min_y, c.y)
			max_x = maxf(max_x, c.x)
			max_y = maxf(max_y, c.y)
		var min_c: Vector2i = world_to_cell(Vector2(min_x, min_y))
		var max_c: Vector2i = world_to_cell(Vector2(max_x, max_y))
		for iy in range(min_c.y, max_c.y + 1):
			for ix in range(min_c.x, max_c.x + 1):
				if not _in_bounds(ix, iy):
					if not write:
						return true
					continue
				var p: Vector2 = cell_center(ix, iy)
				var local: Vector2 = p - center
				var lx: float = local.dot(x_axis)
				var lz: float = local.dot(z_axis)
				if absf(lx) <= hx and absf(lz) <= hz:
					if write:
						cells[_index(ix, iy)] = 1
					elif cells[_index(ix, iy)] != 0:
						return true
		return false

	func occupied_dots(stride: int = 2) -> PackedVector2Array:
		var out: PackedVector2Array = PackedVector2Array()
		for iy in range(0, height, stride):
			for ix in range(0, width, stride):
				if cells[_index(ix, iy)] != 0:
					out.append(cell_center(ix, iy))
		return out


static func plan(config: HamletLabConfig) -> Plan2D:
	_ensure_catalog()
	var out: Plan2D = Plan2D.new()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = config.seed
	out.plaza = Vector2.ZERO
	out.market_radius = config.market_radius
	out.market_sides = config.market_side_count()
	out.market_polygon = _build_market_polygon(
		config, out.plaza, out.market_sides, config.market_radius, rng
	)
	out.markets.append(out.market_polygon)
	out.market_centers.append(out.plaza)

	var market: Shape = Shape.new()
	market.kind = Shape.Kind.MARKET
	market.center = out.plaza
	market.radius = config.market_radius
	market.polygon = out.market_polygon
	out.shapes.append(market)

	if config.tier >= 2:
		_add_secondary_markets(config, out, rng)

	var world_half: float = config.max_settle_radius + 16.0
	var occ: _Occupancy = _Occupancy.new()
	occ.setup(world_half, config.occupancy_cell)
	for poly in out.markets:
		occ.stamp_polygon(poly)

	var dwelling_ids: Array[StringName] = VillageCatalog.ids_with_role(&"dwelling", config.tier)
	assert(not dwelling_ids.is_empty(), "no dwelling forms for tier %d" % config.tier)
	var max_depth: float = 0.0
	for id in dwelling_ids:
		max_depth = maxf(max_depth, VillageCatalog.spec_for(id).size_z)

	var want: int = rng.randi_range(
		mini(config.dwelling_min, config.dwelling_max),
		maxi(config.dwelling_min, config.dwelling_max)
	)
	out.want_count = want
	var houses: Array[Dictionary] = []

	# Start tight around markets; expand only when a settler cannot place.
	var frontier_r: float = 0.0
	for i in out.markets.size():
		var extent: float = _polygon_extent_from(out.market_centers[i], out.markets[i])
		frontier_r = maxf(
			frontier_r,
			out.market_centers[i].length()
			+ extent
			+ config.market_front_gap
			+ max_depth
			+ 4.0
		)
	var expand_step: float = max_depth * 0.65 + config.alley

	# Civics first (Well, Bell_Tower, …), then dwellings.
	var civic_ids: Array[StringName] = _civic_ids_for_tier(config.tier)
	for civic_id in civic_ids:
		var placed: Dictionary = _place_building(
			config, out, occ, houses, rng, civic_id, frontier_r, expand_step, true
		)
		if placed.is_empty():
			push_error("HamletLabPlanner: failed to place civic %s" % String(civic_id))
			assert(false)
		frontier_r = maxf(frontier_r, float(placed.get("frontier_r", frontier_r)))
		out.civic_count += 1

	for _settler in want:
		var catalog_id: StringName = dwelling_ids[rng.randi_range(0, dwelling_ids.size() - 1)]
		var placed: Dictionary = _place_building(
			config, out, occ, houses, rng, catalog_id, frontier_r, expand_step, false
		)
		if placed.is_empty():
			continue
		frontier_r = maxf(frontier_r, float(placed.get("frontier_r", frontier_r)))

	out.house_count = 0
	for h in houses:
		if VillageCatalog.spec_for(h["catalog_id"]).is_dwelling():
			out.house_count += 1
	if out.house_count < out.want_count:
		out.underfill_message = (
			"UNDERFILL: placed %d / %d dwellings (tier %d, markets %d, settle_r %.0f)"
			% [
				out.house_count,
				out.want_count,
				config.tier,
				out.markets.size(),
				config.max_settle_radius,
			]
		)
		push_error("HamletLabPlanner: %s" % out.underfill_message)

	var max_d: float = 0.0
	for i in out.markets.size():
		max_d = maxf(
			max_d,
			out.market_centers[i].length()
			+ _polygon_extent_from(out.market_centers[i], out.markets[i])
		)
	for h in houses:
		max_d = maxf(max_d, Vector2(h["center"]).length() + float(h["half_z"]))
	out.built_envelope = max_d + 3.0

	if config.show_occupancy:
		out.occupancy_dots = occ.occupied_dots(3)
	return out


static func _ensure_catalog() -> void:
	if VillageCatalog.all_specs().is_empty():
		VillageCatalog.load_catalog()


static func _civic_ids_for_tier(tier: int) -> Array[StringName]:
	var raw: Array = HamletLabConfig.CIVIC_BY_TIER[clampi(tier, 0, 3)]
	var out: Array[StringName] = []
	for id_variant in raw:
		var id: StringName = id_variant
		assert(VillageCatalog.has_id(id), "unknown civic id %s" % String(id))
		var spec: VillageCatalog.Spec = VillageCatalog.spec_for(id)
		assert(spec.min_tier <= tier, "civic %s min_tier > settlement tier" % String(id))
		out.append(id)
	return out


static func _place_building(
	config: HamletLabConfig,
	plan: Plan2D,
	occ: _Occupancy,
	houses: Array[Dictionary],
	rng: RandomNumberGenerator,
	catalog_id: StringName,
	frontier_r: float,
	expand_step: float,
	require_place: bool
) -> Dictionary:
	var spec: VillageCatalog.Spec = VillageCatalog.spec_for(catalog_id)
	var half_x: float = spec.half_x()
	var half_z: float = spec.half_z()
	var yaw_offset: float = spec.yaw_offset

	var pick: Dictionary = {}
	var local_max: float = minf(frontier_r, config.max_settle_radius)
	var attempts: int = 0
	while pick.is_empty() and attempts < 8:
		attempts += 1
		var tries: int = config.candidates_per_settler
		if attempts >= 7:
			tries *= 3
		var hug_scored: Array[Dictionary] = _sample_wall_share_candidates(
			config, plan, occ, houses, rng, half_x, half_z, yaw_offset, local_max, tries
		)
		var free_scored: Array[Dictionary] = _sample_settler_candidates(
			config, plan, occ, houses, rng, half_x, half_z, yaw_offset, local_max, tries
		)
		var hug_pick: Dictionary = _best_scored(hug_scored)
		var free_pick: Dictionary = {}
		if not free_scored.is_empty():
			free_pick = _softmax_pick(free_scored, config.select_temperature, rng)
		if not hug_pick.is_empty() and not free_pick.is_empty():
			pick = hug_pick if float(hug_pick["score"]) >= float(free_pick["score"]) else free_pick
		elif not hug_pick.is_empty():
			pick = hug_pick
		elif not free_pick.is_empty():
			pick = free_pick
		else:
			var next_max: float = minf(local_max + expand_step, config.max_settle_radius)
			if next_max <= local_max + 1e-4:
				break
			local_max = next_max

	if pick.is_empty():
		if require_place:
			return {}
		return {}

	var house: Shape = Shape.new()
	house.kind = Shape.Kind.HOUSE
	house.center = pick["center"]
	house.half_size = Vector2(pick["half_x"], pick["half_z"])
	house.yaw = pick["yaw"]
	house.catalog_id = catalog_id
	plan.shapes.append(house)
	occ.stamp_obb(house.center, house.half_size.x, house.half_size.y, house.yaw, 0.0)

	houses.append({
		"center": house.center,
		"half_x": house.half_size.x,
		"half_z": house.half_size.y,
		"yaw": house.yaw,
		"door": pick["door"],
		"outward": pick["outward"],
		"catalog_id": catalog_id,
	})
	return {"frontier_r": maxf(frontier_r, local_max)}


static func _add_secondary_markets(
	config: HamletLabConfig, out: Plan2D, rng: RandomNumberGenerator
) -> void:
	## Tier n (>=2): two tier-(n-2) markets near the primary (target orbit = r*3).
	var child_tier: int = config.tier - 2
	var child_r: float = HamletLabConfig.tier_market_radius(child_tier)
	var child_sides: int = HamletLabConfig.tier_market_sides(child_tier)
	var preferred_orbit: float = config.market_radius * 3.0
	var primary_extent: float = _polygon_extent_from(out.plaza, out.market_polygon)
	var min_dist: float = (
		primary_extent + child_r * 1.9 + config.market_front_gap + 2.0
	)
	# Jittered primary can outgrow r*3; expand orbit just enough to clear it.
	var orbit: float = maxf(preferred_orbit, min_dist)
	if orbit > preferred_orbit + 0.05:
		push_warning(
			"HamletLabPlanner: secondary orbit %.1fm > market_radius*3 (%.1fm); primary extent %.1fm"
			% [orbit, preferred_orbit, primary_extent]
		)
	var base_ang: float = rng.randf() * TAU

	for i in 2:
		var placed := false
		for _attempt in 64:
			var ang: float = base_ang + float(i) * PI + rng.randf_range(-0.4, 0.4)
			var dist: float = rng.randf_range(maxf(min_dist, orbit * 0.7), orbit)
			dist = maxf(dist, min_dist)
			var center: Vector2 = out.plaza + Vector2(cos(ang), sin(ang)) * dist
			var clear := true
			for j in range(1, out.market_centers.size()):
				if center.distance_to(out.market_centers[j]) < child_r * 3.2:
					clear = false
					break
			if not clear:
				continue
			var poly: PackedVector2Array = _build_market_polygon(
				config, center, child_sides, child_r, rng
			)
			if _markets_overlap(out.market_polygon, poly):
				continue
			var overlaps_other := false
			for j in range(1, out.markets.size()):
				if _markets_overlap(out.markets[j], poly):
					overlaps_other = true
					break
			if overlaps_other:
				continue

			out.markets.append(poly)
			out.market_centers.append(center)
			var shape: Shape = Shape.new()
			shape.kind = Shape.Kind.MARKET
			shape.center = center
			shape.radius = child_r
			shape.polygon = poly
			out.shapes.append(shape)
			placed = true
			break
		if not placed:
			push_error("HamletLabPlanner: failed to place secondary marketplace %d" % i)
			assert(false)


static func _polygon_extent_from(center: Vector2, poly: PackedVector2Array) -> float:
	var best: float = 0.0
	for p in poly:
		best = maxf(best, p.distance_to(center))
	return best


static func _markets_overlap(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for p in a:
		if _point_in_polygon(p, b):
			return true
	for p in b:
		if _point_in_polygon(p, a):
			return true
	return false


static func _build_market_polygon(
	config: HamletLabConfig,
	plaza: Vector2,
	sides: int,
	mean_radius: float,
	rng: RandomNumberGenerator
) -> PackedVector2Array:
	## Oriented ellipse base (not axis-aligned), then strongly perturb each vertex.
	assert(sides >= 3, "market needs at least a triangle")
	var n: int = sides
	var mean_r: float = maxf(mean_radius, 1.0)
	var aspect: float = rng.randf_range(
		minf(config.market_aspect_min, config.market_aspect_max),
		maxi(config.market_aspect_min, config.market_aspect_max)
	)
	aspect = maxf(aspect, 1.05)
	# Conserve approx. area: a * b ≈ mean_r^2.
	var semi_major: float = mean_r * sqrt(aspect)
	var semi_minor: float = mean_r / sqrt(aspect)
	var ellipse_yaw: float = rng.randf() * TAU

	var sector: float = TAU / float(n)
	var max_ang_jit: float = sector * 0.5 * clampf(config.market_angle_jitter, 0.0, 0.95)
	var r_jit: float = clampf(config.market_radius_jitter, 0.0, 0.9)
	# Independent sample-frame rotation so verts aren't locked to ellipse axes.
	var sample_rot: float = rng.randf() * TAU

	var verts: PackedVector2Array = PackedVector2Array()
	verts.resize(n)
	for i in n:
		var ang: float = sample_rot + float(i) * sector + rng.randf_range(-max_ang_jit, max_ang_jit)
		var r_ell: float = _ellipse_polar_radius(ang, semi_major, semi_minor, ellipse_yaw)
		# Biased toward stronger dents: sample scale in a wide band, then occasional deep bite.
		var scale: float = rng.randf_range(1.0 - r_jit, 1.0 + r_jit)
		if rng.randf() < 0.28:
			scale *= rng.randf_range(0.55, 0.85)
		elif rng.randf() < 0.22:
			scale *= rng.randf_range(1.15, 1.45)
		var r: float = maxf(r_ell * scale, mean_r * 0.22)
		verts[i] = plaza + Vector2(cos(ang), sin(ang)) * r

	if not _point_in_polygon(plaza, verts):
		push_error("HamletLabPlanner: plaza left the market polygon — reduce jitter")
		assert(false)
	return verts


static func _ellipse_polar_radius(
	world_angle: float, semi_a: float, semi_b: float, ellipse_yaw: float
) -> float:
	## Polar radius of an oriented ellipse at a world-space ray angle from centre.
	var local: float = world_angle - ellipse_yaw
	var c: float = cos(local)
	var s: float = sin(local)
	var denom: float = (semi_b * c) * (semi_b * c) + (semi_a * s) * (semi_a * s)
	if denom < 1e-10:
		push_error("HamletLabPlanner: degenerate ellipse polar denom")
		assert(false)
		return 0.0
	return (semi_a * semi_b) / sqrt(denom)


static func _ray_hit_polygon_rim(
	origin: Vector2, dir: Vector2, poly: PackedVector2Array
) -> Dictionary:
	## Ray origin + t*dir (t>0) vs each edge; return nearest hit + outward normal.
	var d: Vector2 = dir.normalized()
	var best_t: float = INF
	var best_point: Vector2 = Vector2.ZERO
	var best_out: Vector2 = Vector2.ZERO
	var n: int = poly.size()
	for i in n:
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % n]
		var hit: Variant = _ray_segment_intersect(origin, d, a, b)
		if hit == null:
			continue
		var t: float = float(hit)
		if t < 1e-4 or t >= best_t:
			continue
		var point: Vector2 = origin + d * t
		var edge: Vector2 = b - a
		if edge.length_squared() < 1e-8:
			continue
		var nrm: Vector2 = Vector2(-edge.y, edge.x).normalized()
		# Outward = away from plaza (origin).
		if nrm.dot(point - origin) < 0.0:
			nrm = -nrm
		best_t = t
		best_point = point
		best_out = nrm
	if best_t >= INF:
		return {}
	return {"point": best_point, "outward": best_out, "t": best_t}


static func _ray_segment_intersect(
	origin: Vector2, dir: Vector2, a: Vector2, b: Vector2
) -> Variant:
	## Returns t along ray, or null if no hit. dir must be unit-ish; t is in metres.
	var v: Vector2 = b - a
	var cross_dv: float = dir.x * v.y - dir.y * v.x
	if absf(cross_dv) < 1e-8:
		return null
	var ao: Vector2 = a - origin
	var t: float = (ao.x * v.y - ao.y * v.x) / cross_dv
	var u: float = (ao.x * dir.y - ao.y * dir.x) / cross_dv
	if t > 0.0 and u >= 0.0 and u <= 1.0:
		return t
	return null


static func _point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	## Even-odd ray cast.
	var inside := false
	var n: int = poly.size()
	var j: int = n - 1
	for i in n:
		var pi: Vector2 = poly[i]
		var pj: Vector2 = poly[j]
		if (pi.y > p.y) != (pj.y > p.y):
			var x_cross: float = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
			if p.x < x_cross:
				inside = not inside
		j = i
	return inside


static func _signed_distance_to_polygon(p: Vector2, poly: PackedVector2Array) -> float:
	## Positive outside, negative inside. Magnitude = distance to nearest edge.
	var best: float = INF
	var n: int = poly.size()
	for i in n:
		best = minf(best, _point_segment_distance(p, poly[i], poly[(i + 1) % n]))
	if _point_in_polygon(p, poly):
		return -best
	return best


static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	return p.distance_to(_closest_point_on_segment(p, a, b))


static func _closest_point_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	var len2: float = ab.length_squared()
	if len2 < 1e-10:
		return a
	var t: float = clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return a + ab * t


static func _closest_point_on_polygon(p: Vector2, poly: PackedVector2Array) -> Vector2:
	var best: Vector2 = poly[0]
	var best_d2: float = INF
	var n: int = poly.size()
	for i in n:
		var q: Vector2 = _closest_point_on_segment(p, poly[i], poly[(i + 1) % n])
		var d2: float = p.distance_squared_to(q)
		if d2 < best_d2:
			best_d2 = d2
			best = q
	return best


static func _max_ray_in_disk(
	origin: Vector2, dir: Vector2, disk_center: Vector2, disk_r: float
) -> float:
	## Largest t>0 such that |origin + t*dir - disk_center| <= disk_r. -1 if none.
	var d: Vector2 = dir.normalized()
	var o: Vector2 = origin - disk_center
	var b: float = 2.0 * o.dot(d)
	var c: float = o.length_squared() - disk_r * disk_r
	var disc: float = b * b - 4.0 * c
	if disc < 0.0:
		return -1.0
	var t: float = (-b + sqrt(disc)) * 0.5
	if t <= 0.0:
		return -1.0
	return t


static func _pick_attractor_index(plan: Plan2D, rng: RandomNumberGenerator) -> int:
	## Bias toward the primary green; secondaries still get real traffic.
	if plan.markets.size() <= 1:
		return 0
	if rng.randf() < 0.55:
		return 0
	return 1 + rng.randi_range(0, plan.markets.size() - 2)


static func _closest_point_on_markets(
	p: Vector2, markets: Array[PackedVector2Array]
) -> Vector2:
	var best: Vector2 = markets[0][0]
	var best_d2: float = INF
	for poly in markets:
		var q: Vector2 = _closest_point_on_polygon(p, poly)
		var d2: float = p.distance_squared_to(q)
		if d2 < best_d2:
			best_d2 = d2
			best = q
	return best


static func _signed_distance_to_markets(
	p: Vector2, markets: Array[PackedVector2Array]
) -> float:
	## Negative if inside any market; else distance to nearest rim.
	var best_out: float = INF
	var best_in: float = 0.0
	var inside := false
	for poly in markets:
		var d: float = _signed_distance_to_polygon(p, poly)
		if d < 0.0:
			inside = true
			best_in = minf(best_in, d)
		else:
			best_out = minf(best_out, d)
	if inside:
		return best_in
	return best_out


static func _sample_wall_share_candidates(
	config: HamletLabConfig,
	plan: Plan2D,
	occ: _Occupancy,
	houses: Array[Dictionary],
	rng: RandomNumberGenerator,
	half_x: float,
	half_z: float,
	_yaw_offset: float,
	max_center_r: float,
	candidate_tries: int
) -> Array[Dictionary]:
	## Snap flush against an existing house on ±X or rear (+Z). Never on either door (-Z).
	var scored: Array[Dictionary] = []
	if houses.is_empty():
		return scored
	var tries: int = maxi(candidate_tries, 1)
	for _try in tries:
		var h: Dictionary = houses[rng.randi_range(0, houses.size() - 1)]
		var side: int = rng.randi_range(0, 2) # 0=+X, 1=-X, 2=+Z rear
		var pose: Dictionary = _wall_share_pose(h, half_x, half_z, side, rng)
		if pose.is_empty():
			continue
		var center: Vector2 = pose["center"]
		# Pose yaw already matches the neighbour's stamped OBB yaw (which includes
		# that form's yaw_offset). Do not add this settler's yaw_offset again —
		# that rotates the box off the flush wall and creates continuous overlaps
		# the occupancy grid can miss.
		var yaw: float = float(pose["yaw"])
		if center.distance_to(plan.plaza) + half_z > max_center_r:
			continue
		if not occ.fits_obb(center, half_x, half_z, yaw, 0.0):
			continue
		if _houses_obb_overlap(houses, center, half_x, half_z, yaw):
			continue
		var facing: Vector2 = Vector2(sin(yaw), cos(yaw))
		var door: Vector2 = center - facing * half_z
		if _signed_distance_to_markets(door, plan.markets) < 0.4:
			continue
		if _signed_distance_to_markets(center, plan.markets) < half_z:
			continue
		var score: float = (
			_fitness(config, plan.markets, door, rng) + config.wall_share_boost
		)
		scored.append({
			"score": score,
			"center": center,
			"yaw": yaw,
			"half_x": half_x,
			"half_z": half_z,
			"outward": facing,
			"door": door,
		})
	return scored


static func _wall_share_pose(
	h: Dictionary,
	half_x: float,
	half_z: float,
	side: int,
	rng: RandomNumberGenerator
) -> Dictionary:
	var yaw_h: float = float(h["yaw"])
	var x_axis: Vector2 = _axis(yaw_h, true)
	var z_axis: Vector2 = _axis(yaw_h, false)
	var hx: float = float(h["half_x"])
	var hz: float = float(h["half_z"])
	var center: Vector2
	var yaw: float
	var tangent: Vector2
	var half_t_h: float
	var half_t_n: float
	match side:
		0:
			# Neighbour +X ↔ new -X (same yaw). Doors free.
			yaw = yaw_h
			center = Vector2(h["center"]) + x_axis * (hx + half_x)
			tangent = z_axis
			half_t_h = hz
			half_t_n = half_z
		1:
			yaw = yaw_h
			center = Vector2(h["center"]) - x_axis * (hx + half_x)
			tangent = z_axis
			half_t_h = hz
			half_t_n = half_z
		2:
			# Neighbour rear (+Z). Flip yaw so new rear touches, not new door.
			yaw = yaw_h + PI
			center = Vector2(h["center"]) + z_axis * (hz + half_z)
			tangent = x_axis
			half_t_h = hx
			half_t_n = half_x
		_:
			return {}
	# Slide along the shared wall; keep a positive overlap segment.
	var max_slide: float = half_t_h + half_t_n - 0.2
	if max_slide <= 0.0:
		return {}
	center += tangent * rng.randf_range(-max_slide, max_slide)
	var facing: Vector2 = Vector2(sin(yaw), cos(yaw))
	return {
		"center": center,
		"yaw": yaw,
		"door": center - facing * half_z,
		"outward": facing,
	}


static func _sample_settler_candidates(
	config: HamletLabConfig,
	plan: Plan2D,
	occ: _Occupancy,
	houses: Array[Dictionary],
	rng: RandomNumberGenerator,
	half_x: float,
	half_z: float,
	yaw_offset: float,
	max_center_r: float,
	candidate_tries: int = -1
) -> Array[Dictionary]:
	var scored: Array[Dictionary] = []
	var tries: int = candidate_tries if candidate_tries > 0 else config.candidates_per_settler
	for _try in tries:
		var attr_i: int = _pick_attractor_index(plan, rng)
		var attr_center: Vector2 = plan.market_centers[attr_i]
		var attr_poly: PackedVector2Array = plan.markets[attr_i]

		var ang: float = rng.randf() * TAU
		var dir: Vector2 = Vector2(cos(ang), sin(ang))
		var hit: Dictionary = _ray_hit_polygon_rim(attr_center, dir, attr_poly)
		if hit.is_empty():
			continue
		var rim_dist: float = float(hit["t"])
		var front_gap: float = config.market_front_gap + rng.randf_range(0.0, 1.2)
		var min_r: float = rim_dist + front_gap + half_z
		var max_r: float = _max_ray_in_disk(
			attr_center, dir, plan.plaza, maxf(max_center_r - half_z, 0.0)
		)
		if max_r < min_r:
			continue
		var center_dist: float = min_r + (max_r - min_r) * pow(rng.randf(), 2.4)
		var center: Vector2 = attr_center + dir * center_dist
		if center.distance_to(plan.plaza) + half_z > max_center_r:
			continue

		var nearest: Vector2 = _closest_point_on_markets(center, plan.markets)
		var away: Vector2 = center - nearest
		if away.length_squared() < 1e-8:
			away = dir
		var outward: Vector2 = away.normalized()
		var yaw: float = atan2(outward.x, outward.y) + yaw_offset
		yaw += rng.randf_range(-0.18, 0.18)
		var facing: Vector2 = Vector2(sin(yaw), cos(yaw))

		# Free plots keep an alley; shared-wall poses use a separate sampler.
		if not occ.fits_obb(center, half_x, half_z, yaw, config.alley * 0.5):
			continue
		if _houses_obb_overlap(houses, center, half_x, half_z, yaw):
			continue
		var door: Vector2 = center - facing * half_z
		if _signed_distance_to_markets(door, plan.markets) < 0.4:
			continue
		if _signed_distance_to_markets(center, plan.markets) < half_z:
			continue

		var score: float = _fitness(config, plan.markets, door, rng)
		scored.append({
			"score": score,
			"center": center,
			"yaw": yaw,
			"half_x": half_x,
			"half_z": half_z,
			"outward": facing,
			"door": door,
		})
	return scored


static func _fitness(
	config: HamletLabConfig,
	markets: Array[PackedVector2Array],
	door: Vector2,
	rng: RandomNumberGenerator
) -> float:
	var rim_dist: float = maxf(_signed_distance_to_markets(door, markets), 0.0)
	var market_score: float = exp(-rim_dist / maxf(config.market_front_gap * 1.1, 1.8))
	var noise: float = rng.randf_range(-config.fitness_noise, config.fitness_noise)
	return config.weight_market * market_score + noise


static func _best_scored(scored: Array[Dictionary]) -> Dictionary:
	if scored.is_empty():
		return {}
	var best: Dictionary = scored[0]
	for c in scored:
		if float(c["score"]) > float(best["score"]):
			best = c
	return best


static func _softmax_pick(
	scored: Array[Dictionary], temperature: float, rng: RandomNumberGenerator
) -> Dictionary:
	var temp: float = maxf(temperature, 0.05)
	var max_s: float = -INF
	for c in scored:
		max_s = maxf(max_s, float(c["score"]))
	var weights: PackedFloat32Array = PackedFloat32Array()
	var total: float = 0.0
	for c in scored:
		var w: float = exp((float(c["score"]) - max_s) / temp)
		weights.append(w)
		total += w
	var roll: float = rng.randf() * total
	var acc: float = 0.0
	for i in scored.size():
		acc += weights[i]
		if roll <= acc:
			return scored[i]
	return scored[scored.size() - 1]


static func _houses_obb_overlap(
	houses: Array[Dictionary],
	center: Vector2,
	half_x: float,
	half_z: float,
	yaw: float
) -> bool:
	## Continuous SAT against already-accepted houses (grid can miss thin overlaps).
	for h in houses:
		if _obb_overlap(
			center,
			half_x,
			half_z,
			yaw,
			Vector2(h["center"]),
			float(h["half_x"]),
			float(h["half_z"]),
			float(h["yaw"])
		):
			return true
	return false


static func _obb_overlap(
	a_c: Vector2,
	a_hx: float,
	a_hz: float,
	a_yaw: float,
	b_c: Vector2,
	b_hx: float,
	b_hz: float,
	b_yaw: float
) -> bool:
	var axes: Array[Vector2] = [
		_axis(a_yaw, true),
		_axis(a_yaw, false),
		_axis(b_yaw, true),
		_axis(b_yaw, false),
	]
	var delta: Vector2 = b_c - a_c
	# Flush wall-share lands on ra+rb; absorb float + occupancy-grid error.
	const TOUCH_EPS: float = 0.05
	for axis in axes:
		var ra: float = a_hx * absf(axis.dot(_axis(a_yaw, true))) + a_hz * absf(axis.dot(_axis(a_yaw, false)))
		var rb: float = b_hx * absf(axis.dot(_axis(b_yaw, true))) + b_hz * absf(axis.dot(_axis(b_yaw, false)))
		if absf(delta.dot(axis)) >= ra + rb - TOUCH_EPS:
			return false
	return true


static func _axis(yaw: float, along_x: bool) -> Vector2:
	var c: float = cos(yaw)
	var s: float = sin(yaw)
	if along_x:
		return Vector2(c, -s).normalized()
	return Vector2(s, c).normalized()
