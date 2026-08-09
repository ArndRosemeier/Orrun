class_name HousePlacer
extends RefCounted
## Resolves sector house sites onto the density-field surface for one chunk.
##
## The slab is a flat box: Y is the lowest footprint corner (plus sink), so no
## corner hangs in the air on a slope. Any wet or missing corner rejects the
## site — half-over-river placements are dropped, not sunk into the channel.

const WATERLINE_MARGIN: float = 0.35
## ~18° — houses want a pad, not a hillside.
const MIN_UPNESS: float = 0.95
## Bury most of the authored plinth; a short band still shows above grade.
const FOUNDATION_SINK: float = 0.55
## Reject if the finished surface still tilts this much across the footprint.
const MAX_FOOTPRINT_RELIEF: float = 0.65


## Returns catalog id -> Array[Transform3D] in chunk-local space (merged like props).
static func place(
	sites: Array[HouseSite],
	field: DensityField.Field,
	chunk_origin: Vector2,
	chunk_size: float
) -> Dictionary:
	var result: Dictionary = {}
	var bounds: Rect2 = Rect2(chunk_origin, Vector2.ONE * chunk_size)
	for site in sites:
		if not bounds.has_point(Vector2(site.world_x, site.world_z)):
			continue
		var seating: Dictionary = _footprint_seating(field, site)
		if not bool(seating.get("ok", false)):
			continue
		var surface_y: float = float(seating["min_y"])
		var basis: Basis = Basis(Vector3.UP, site.yaw)
		var local: Vector3 = Vector3(
			site.world_x - chunk_origin.x,
			surface_y - FOUNDATION_SINK,
			site.world_z - chunk_origin.y
		)
		var list: Array = result.get(site.catalog_id, [])
		list.append(Transform3D(basis, local))
		result[site.catalog_id] = list
	return result


## Samples centre + four oriented corners. Keys: ok (bool), min_y (float).
static func _footprint_seating(field: DensityField.Field, site: HouseSite) -> Dictionary:
	var half: float = site.footprint * 0.5
	var basis: Basis = Basis(Vector3.UP, site.yaw)
	var samples: Array[Vector2] = [Vector2(site.world_x, site.world_z)]
	for ox in [-half, half]:
		for oz in [-half, half]:
			var offset: Vector3 = basis * Vector3(ox, 0.0, oz)
			samples.append(Vector2(site.world_x + offset.x, site.world_z + offset.z))

	var min_y: float = INF
	var max_y: float = -INF
	for sample in samples:
		var hit: Vector2 = PropPlacer._surface_hit(field, sample.x, sample.y)
		if hit.y < 0.5:
			return {"ok": false}
		var surface_y: float = hit.x
		var column: int = PropPlacer.column_of(field, sample.x, sample.y)
		if field.water_top[column] > surface_y - WATERLINE_MARGIN:
			return {"ok": false}
		var normal: Vector3 = PropPlacer._surface_normal(
			field, sample.x, sample.y, surface_y
		)
		if normal.y < MIN_UPNESS:
			return {"ok": false}
		min_y = minf(min_y, surface_y)
		max_y = maxf(max_y, surface_y)

	if max_y - min_y > MAX_FOOTPRINT_RELIEF:
		return {"ok": false}
	return {"ok": true, "min_y": min_y}
