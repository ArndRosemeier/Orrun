class_name SettlementOccupancy
extends RefCounted
## Yawed OBB occupancy for one settlement plan.
##
## Circle packing is not enough: Quaternius houses face a street and their
## AABBs interpenetrate while centre distances still look fine. Acceptance is
## always OBB vs OBB (plus optional road corridors).

class Body extends RefCounted:
	var center: Vector2 = Vector2.ZERO
	var half_x: float = 1.0
	var half_z: float = 1.0
	var yaw: float = 0.0
	var margin: float = 0.0


class Corridor extends RefCounted:
	var a: Vector2 = Vector2.ZERO
	var b: Vector2 = Vector2.ZERO
	var half_width: float = 1.0


var bodies: Array[Body] = []
var corridors: Array[Corridor] = []


func clear() -> void:
	bodies.clear()
	corridors.clear()


func add_site(site: HouseSite, margin: float, depth_scale: float = 0.85) -> void:
	var body: Body = Body.new()
	body.center = Vector2(site.world_x, site.world_z)
	var half: float = site.footprint * 0.5
	body.half_x = half
	body.half_z = half * depth_scale
	body.yaw = site.yaw
	body.margin = margin
	bodies.append(body)


func add_rect(center: Vector2, half_x: float, half_z: float, yaw: float, margin: float) -> void:
	var body: Body = Body.new()
	body.center = center
	body.half_x = half_x
	body.half_z = half_z
	body.yaw = yaw
	body.margin = margin
	bodies.append(body)


func add_road_edge(road: RoadEdge, extra_margin: float = 0.75) -> void:
	if road.points.size() < 2:
		return
	for i in range(road.points.size() - 1):
		var corridor: Corridor = Corridor.new()
		corridor.a = Vector2(road.points[i].x, road.points[i].z)
		corridor.b = Vector2(road.points[i + 1].x, road.points[i + 1].z)
		corridor.half_width = road.half_width + extra_margin
		corridors.append(corridor)


func add_polyline(points: PackedVector2Array, half_width: float) -> void:
	if points.size() < 2:
		return
	for i in range(points.size() - 1):
		var corridor: Corridor = Corridor.new()
		corridor.a = points[i]
		corridor.b = points[i + 1]
		corridor.half_width = half_width
		corridors.append(corridor)


func fits_site(
	site: HouseSite,
	margin: float,
	depth_scale: float = 0.85,
	ignore_corridors: bool = false
) -> bool:
	var probe: Body = Body.new()
	probe.center = Vector2(site.world_x, site.world_z)
	var half: float = site.footprint * 0.5
	probe.half_x = half
	probe.half_z = half * depth_scale
	probe.yaw = site.yaw
	probe.margin = margin
	return fits_body(probe, ignore_corridors)


func fits_rect(
	center: Vector2,
	half_x: float,
	half_z: float,
	yaw: float,
	margin: float,
	ignore_corridors: bool = false
) -> bool:
	var probe: Body = Body.new()
	probe.center = center
	probe.half_x = half_x
	probe.half_z = half_z
	probe.yaw = yaw
	probe.margin = margin
	return fits_body(probe, ignore_corridors)


func fits_body(probe: Body, ignore_corridors: bool = false) -> bool:
	for other in bodies:
		if _obb_overlap(probe, other):
			return false
	if not ignore_corridors:
		for corridor in corridors:
			if _body_hits_corridor(probe, corridor):
				return false
	return true


func any_obb_overlap() -> bool:
	for i in bodies.size():
		for j in range(i + 1, bodies.size()):
			if _obb_overlap(bodies[i], bodies[j]):
				return true
	return false


static func _obb_overlap(a: Body, b: Body) -> bool:
	## Separating-axis test in XZ for two oriented boxes expanded by margin.
	var axes: Array[Vector2] = [
		_axis(a.yaw, true),
		_axis(a.yaw, false),
		_axis(b.yaw, true),
		_axis(b.yaw, false),
	]
	var delta: Vector2 = b.center - a.center
	# Flush faces (lab wall-share) land on ra+rb; absorb float + grid error.
	const TOUCH_EPS: float = 0.05
	for axis in axes:
		var ra: float = _projection_radius(a, axis) + a.margin
		var rb: float = _projection_radius(b, axis) + b.margin
		if absf(delta.dot(axis)) >= ra + rb - TOUCH_EPS:
			return false
	return true


static func _projection_radius(body: Body, axis: Vector2) -> float:
	var x_axis: Vector2 = _axis(body.yaw, true)
	var z_axis: Vector2 = _axis(body.yaw, false)
	return body.half_x * absf(axis.dot(x_axis)) + body.half_z * absf(axis.dot(z_axis))


static func _axis(yaw: float, along_x: bool) -> Vector2:
	var c: float = cos(yaw)
	var s: float = sin(yaw)
	if along_x:
		return Vector2(c, -s).normalized()
	return Vector2(s, c).normalized()


static func _body_hits_corridor(body: Body, corridor: Corridor) -> bool:
	## Conservative: test body centre and four corners against the segment capsule.
	var samples: Array[Vector2] = [body.center]
	var x_axis: Vector2 = _axis(body.yaw, true)
	var z_axis: Vector2 = _axis(body.yaw, false)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			samples.append(
				body.center + x_axis * (body.half_x * sx) + z_axis * (body.half_z * sz)
			)
	var need: float = corridor.half_width + body.margin
	for p in samples:
		if _point_segment_distance(p, corridor.a, corridor.b) < need:
			return true
	return false


static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq < 1e-8:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
