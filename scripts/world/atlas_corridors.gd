class_name AtlasCorridors
extends RefCounted
## The atlas river and road network, reconstructed once in continental metres.
##
## This is the single most important object for seamlessness. Every trunk river
## and every atlas road is built here, from the atlas alone, in one pass over
## the whole continent - so a corridor is the *same polyline* no matter which
## sector is looking at it. Sectors never re-derive a trunk from their own 8 km
## of catchment, because 8 km of catchment cannot tell you how big a river is.
##
## Geometry rules that make neighbouring atlas cells agree exactly:
##   - an edge port is one shared [AtlasPort], so both cells read one position
##     and one surface height for the crossing;
##   - every in-cell link is pinned through the cell centre with no jitter, so
##     two cells meeting at a port produce a continuous curve;
##   - station heights interpolate between endpoint heights, and atlas rivers
##     are monotonic, so the reconstruction descends by construction.
##
## Immutable after [method build]. Worker threads only read it.

## [ax, water_z, az, bx, water_z, bz, half_a, half_b, feature_class]
const RIVER_STRIDE: int = 9
## [ax, grade_z, az, bx, grade_z, bz, half_width, road_class]
const ROAD_STRIDE: int = 8
## Stations per in-cell link. Six segments over a kilometre is enough curve for
## a 32 m macro grid to see, and cheap enough to hold the whole continent.
const LINK_STEPS: int = 6
const INDEX_BUCKET: float = 500.0

var rivers: PackedFloat32Array = PackedFloat32Array()
var river_feature_ids: PackedInt32Array = PackedInt32Array()
var river_index: SpatialIndex2D

var roads: PackedFloat32Array = PackedFloat32Array()
var road_feature_ids: PackedInt32Array = PackedInt32Array()
var road_index: SpatialIndex2D

## Every place a trunk river reaches the ocean. Keys: position (Vector2),
## cell (Vector2i), feature_class (int), surface_z (float).
var mouths: Array[Dictionary] = []

## Widest valley any corridor carves, so callers know how far to look.
var max_valley_radius: float = 0.0

var _config: WorldConfig
var _atlas: ContinentAtlas


static func build(config: WorldConfig, atlas: ContinentAtlas) -> AtlasCorridors:
	var built: AtlasCorridors = AtlasCorridors.new()
	built._config = config
	built._atlas = atlas
	built.river_index = SpatialIndex2D.new(INDEX_BUCKET)
	built.road_index = SpatialIndex2D.new(INDEX_BUCKET)
	built._build_rivers()
	built._build_roads()
	built.max_valley_radius = (
		config.trunk_valley_radius + config.trunk_valley_per_class * 3.0
	)
	return built


# --- Public geometry ----------------------------------------------------------

## Half-width of a trunk of this atlas river class, in metres.
func river_half_width(feature_class: int) -> float:
	return _config.river_width_base + float(trunk_order(feature_class) - 1) * _config.river_width_per_order


## Strahler order a trunk of this atlas class is published with. Fixed by the
## atlas, never by local accumulation.
func trunk_order(feature_class: int) -> int:
	return _config.trunk_order_base + clampi(feature_class, 1, 4) - 1


## How far from the channel the continental surface is pulled down into a
## valley. Wider for bigger rivers, and identical on both sides of any sector
## boundary because it only depends on the atlas class.
func river_valley_radius(feature_class: int) -> float:
	return (
		_config.trunk_valley_radius
		+ _config.trunk_valley_per_class * float(clampi(feature_class, 1, 4) - 1)
	)


func road_half_width(road_class: int) -> float:
	match road_class:
		AtlasFeatures.RoadClass.PRIMARY:
			return _config.road_width_primary * 0.5
		AtlasFeatures.RoadClass.SECONDARY:
			return _config.road_width_secondary * 0.5
	return _config.road_width_trail * 0.5


func river_segment_count() -> int:
	return river_feature_ids.size()


func road_segment_count() -> int:
	return road_feature_ids.size()


## Segment base offsets whose bounding box (grown by their valley) overlaps the
## rect. Base offsets index [member rivers]; divide by the stride for the id.
func rivers_in_rect(rect: Rect2) -> PackedInt32Array:
	return river_index.query_rect(rect)


func roads_in_rect(rect: Rect2) -> PackedInt32Array:
	return road_index.query_rect(rect)


# --- Rivers ---------------------------------------------------------------------

func _build_rivers() -> void:
	var size: int = _atlas.size
	for az in size:
		for ax in size:
			var links: Array = _atlas.links_in_cell(ax, az, AtlasFeatures.Kind.RIVER)
			for link_variant in links:
				var link: AtlasLink = link_variant
				_emit_river_link(ax, az, link)


func _emit_river_link(ax: int, az: int, link: AtlasLink) -> void:
	var a: Vector3 = _endpoint_point(ax, az, link.a, link.feature_class)
	var b: Vector3 = _endpoint_point(ax, az, link.b, link.feature_class)
	if link.b.kind == AtlasFeatures.EndpointKind.OCEAN:
		mouths.append({
			"position": Vector2(b.x, b.z),
			"cell": Vector2i(ax, az),
			"feature_class": link.feature_class,
			"surface_z": b.y,
		})

	var mid: Vector2 = _atlas.continental_centre(ax, az)
	var half: float = river_half_width(link.feature_class)
	var stations: PackedVector3Array = _curve(a, b, mid)
	for i in range(stations.size() - 1):
		var p: Vector3 = stations[i]
		var q: Vector3 = stations[i + 1]
		if absf(p.x - q.x) < 0.001 and absf(p.z - q.z) < 0.001:
			continue
		var base: int = rivers.size()
		rivers.append_array(PackedFloat32Array([
			p.x, p.y, p.z, q.x, q.y, q.z, half, half, float(link.feature_class)
		]))
		river_feature_ids.append(link.feature_id)
		river_index.insert_segment(p.x, p.z, q.x, q.z, base)


## Where one end of an in-cell link sits, and at what water height.
func _endpoint_point(ax: int, az: int, endpoint: AtlasEndpoint, feature_class: int) -> Vector3:
	var centre: Vector2 = _atlas.continental_centre(ax, az)
	var cell_z: float = float(AtlasPack.elevation_to_metres(
		AtlasPack.elevation(_atlas.cell_at(ax, az))
	))

	match endpoint.kind:
		AtlasFeatures.EndpointKind.EDGE_PORT:
			var port: AtlasPort = _port_of(endpoint, AtlasFeatures.Kind.RIVER)
			var owner: Vector3i = AtlasFeatures.edge_owner(endpoint.ref_id)
			var t: float = port.t if port != null else 0.5
			var pos: Vector2 = _atlas.port_continental_pos(owner.x, owner.y, owner.z, t)
			var z: float = float(port.surface_z) if port != null else cell_z
			return Vector3(pos.x, z, pos.y)
		AtlasFeatures.EndpointKind.OCEAN:
			var sink: Vector2 = _sink_edge_point(ax, az, centre)
			return Vector3(sink.x, float(_atlas.sea_surface_z), sink.y)
		AtlasFeatures.EndpointKind.LAKE:
			var lake_z: float = cell_z
			if endpoint.ref_id >= 0 and endpoint.ref_id < _atlas.lakes.size():
				lake_z = float(_atlas.lakes[endpoint.ref_id].surface_z)
			var shore: Vector2 = _sink_edge_point(ax, az, centre)
			return Vector3(shore.x, lake_z, shore.y)
		AtlasFeatures.EndpointKind.NODE:
			if endpoint.ref_id >= 0:
				for node_variant in _atlas.nodes:
					var node: AtlasGraphNode = node_variant
					if node.id == endpoint.ref_id:
						var np: Vector2 = _atlas.continental_centre(node.ax, node.az)
						var nz: float = float(AtlasPack.elevation_to_metres(
							AtlasPack.elevation(_atlas.cell_at(node.ax, node.az))
						))
						return Vector3(np.x, nz, np.y)
	return Vector3(centre.x, cell_z, centre.y)


## A mouth stops on the cell edge facing its receiver, not at the cell centre,
## so the channel visually reaches the water it drains into.
func _sink_edge_point(ax: int, az: int, centre: Vector2) -> Vector2:
	var idx: int = _atlas.index_of(ax, az)
	if _atlas.river_receiver.size() <= idx:
		return centre
	var down: int = _atlas.river_receiver[idx]
	if down < 0:
		return centre
	var dx: int = (down % _atlas.size) - ax
	var dz: int = (down / _atlas.size) - az
	if absi(dx) + absi(dz) != 1:
		return centre
	return centre + Vector2(float(dx), float(dz)) * (WorldCoords.ATLAS_CELL_SIZE * 0.5)


func _port_of(endpoint: AtlasEndpoint, kind: int) -> AtlasPort:
	var store: Dictionary = (
		_atlas.river_ports if kind == AtlasFeatures.Kind.RIVER else _atlas.road_ports
	)
	if not store.has(endpoint.ref_id):
		return null
	var ports: Array = store[endpoint.ref_id]
	for p in ports:
		var port: AtlasPort = p
		if port.id == endpoint.port_id:
			return port
	return ports[0] if not ports.is_empty() else null


# --- Roads ------------------------------------------------------------------------

func _build_roads() -> void:
	var size: int = _atlas.size
	for az in size:
		for ax in size:
			var links: Array = _atlas.links_in_cell(ax, az, AtlasFeatures.Kind.ROAD)
			for link_variant in links:
				var link: AtlasLink = link_variant
				_emit_road_link(ax, az, link)


func _emit_road_link(ax: int, az: int, link: AtlasLink) -> void:
	var a: Vector3 = _road_endpoint_point(ax, az, link.a)
	var b: Vector3 = _road_endpoint_point(ax, az, link.b)
	var mid: Vector2 = _atlas.continental_centre(ax, az)
	var half: float = road_half_width(link.feature_class)
	var stations: PackedVector3Array = _curve(a, b, mid)
	for i in range(stations.size() - 1):
		var p: Vector3 = stations[i]
		var q: Vector3 = stations[i + 1]
		if absf(p.x - q.x) < 0.001 and absf(p.z - q.z) < 0.001:
			continue
		var base: int = roads.size()
		roads.append_array(PackedFloat32Array([
			p.x, p.y, p.z, q.x, q.y, q.z, half, float(link.feature_class)
		]))
		road_feature_ids.append(link.feature_id)
		road_index.insert_segment(p.x, p.z, q.x, q.z, base)


func _road_endpoint_point(ax: int, az: int, endpoint: AtlasEndpoint) -> Vector3:
	var centre: Vector2 = _atlas.continental_centre(ax, az)
	var cell_z: float = float(AtlasPack.elevation_to_metres(
		AtlasPack.elevation(_atlas.cell_at(ax, az))
	))
	if endpoint.kind == AtlasFeatures.EndpointKind.EDGE_PORT:
		var port: AtlasPort = _port_of(endpoint, AtlasFeatures.Kind.ROAD)
		var owner: Vector3i = AtlasFeatures.edge_owner(endpoint.ref_id)
		var t: float = port.t if port != null else 0.5
		var pos: Vector2 = _atlas.port_continental_pos(owner.x, owner.y, owner.z, t)
		var z: float = float(port.surface_z) if port != null else cell_z
		return Vector3(pos.x, z, pos.y)
	if endpoint.kind == AtlasFeatures.EndpointKind.NODE and endpoint.ref_id >= 0:
		for node_variant in _atlas.nodes:
			var node: AtlasGraphNode = node_variant
			if node.id == endpoint.ref_id:
				var np: Vector2 = _atlas.continental_centre(node.ax, node.az)
				var nz: float = float(AtlasPack.elevation_to_metres(
					AtlasPack.elevation(_atlas.cell_at(node.ax, node.az))
				))
				return Vector3(np.x, nz, np.y)
	return Vector3(centre.x, cell_z, centre.y)


# --- Shared curve ------------------------------------------------------------------

## Quadratic through the cell centre. Heights interpolate linearly in the curve
## parameter, which keeps a river monotonic whenever its endpoints are.
static func _curve(a: Vector3, b: Vector3, mid: Vector2) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	var flat_a: Vector2 = Vector2(a.x, a.z)
	var flat_b: Vector2 = Vector2(b.x, b.z)
	if (
		flat_a.distance_squared_to(mid) < 0.25
		or flat_b.distance_squared_to(mid) < 0.25
		or flat_a.distance_squared_to(flat_b) < 0.25
	):
		out.append(a)
		out.append(b)
		return out
	for step in range(LINK_STEPS + 1):
		var t: float = float(step) / float(LINK_STEPS)
		var one: float = 1.0 - t
		var p: Vector2 = one * one * flat_a + 2.0 * one * t * mid + t * t * flat_b
		out.append(Vector3(p.x, lerpf(a.y, b.y, t), p.y))
	return out
