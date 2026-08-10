class_name HousePlacer
extends RefCounted
## Resolves sector house sites onto the density-field surface for one chunk.
##
## The slab is a flat box: Y is the lowest footprint corner (plus sink), so no
## corner hangs in the air on a slope. Any wet or missing corner rejects the
## site — half-over-river placements are dropped, not sunk into the channel.

const WATERLINE_MARGIN: float = 0.35
## ~28° — natural continental slopes; terrace pads no longer flatten towns.
const MIN_UPNESS: float = 0.88
## Across oriented body (not inflated square footprint). Lab packs on flat 2D;
## real hills need headroom or nearly every house is dropped.
const MAX_FOOTPRINT_RELIEF: float = 2.8
## Sample inset vs catalog size so eaves/beams do not veto seating.
const SEAT_INSET: float = 0.82


## Returns catalog id -> Array[Transform3D] in chunk-local space (merged like props).
static func place(
	sites: Array[HouseSite],
	field: DensityField.Field,
	chunk_origin: Vector2,
	chunk_size: float
) -> Dictionary:
	var result: Dictionary = {}
	var bounds: Rect2 = Rect2(chunk_origin, Vector2.ONE * chunk_size)
	var candidates: int = 0
	var seated: int = 0
	for site in sites:
		if not bounds.has_point(Vector2(site.world_x, site.world_z)):
			continue
		candidates += 1
		var seating: Dictionary = _footprint_seating(field, site)
		if not bool(seating.get("ok", false)):
			continue
		seated += 1
		var surface_y: float = float(seating["min_y"])
		var basis: Basis = Basis(Vector3.UP, site.yaw)
		var local: Vector3 = Vector3(
			site.world_x - chunk_origin.x,
			surface_y - site.seat_sink,
			site.world_z - chunk_origin.y
		)
		var list: Array = result.get(site.catalog_id, [])
		list.append(Transform3D(basis, local))
		result[site.catalog_id] = list
	if candidates >= 8 and seated * 3 < candidates:
		push_error(
			"HousePlacer: seated only %d/%d sites in chunk at (%.0f, %.0f) — terrain too rough for lab pack"
			% [seated, candidates, chunk_origin.x, chunk_origin.y]
		)
	return result


## Samples centre + four oriented body corners. Keys: ok (bool), min_y (float).
static func _footprint_seating(field: DensityField.Field, site: HouseSite) -> Dictionary:
	var half_x: float = site.footprint * 0.5
	var half_z: float = half_x
	if VillageCatalog.has_id(site.catalog_id):
		var spec: VillageCatalog.Spec = VillageCatalog.spec_for(site.catalog_id)
		if spec.has_oriented_size():
			half_x = spec.half_x() * SEAT_INSET
			half_z = spec.half_z() * SEAT_INSET
	var basis: Basis = Basis(Vector3.UP, site.yaw)
	var samples: Array[Vector2] = [Vector2(site.world_x, site.world_z)]
	for ox in [-half_x, half_x]:
		for oz in [-half_z, half_z]:
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
