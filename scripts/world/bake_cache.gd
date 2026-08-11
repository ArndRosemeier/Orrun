class_name BakeCache
extends RefCounted
## Disk cache for continental atlas, baked world sectors, and underfoot LOD0 chunks.
##
## See [code]docs/BAKE_CACHE.md[/code] for the full agent-facing contract.
##
## Keys are derived from [method WorldConfig.content_hash] (atlas),
## [method WorldContext.content_key] (sectors), and [method chunk_key] (meshes).
## A header mismatch is never used as world data — the file is ignored and the
## artifact is regenerated. There is no silent migration of old layouts.
##
## Versioning (bump when the packed body changes):
## - [constant FORMAT_VERSION] — atlas.bin and sector_*.bin body layout
## - [constant CHUNK_FORMAT_VERSION] — chunk_*_lod0.bin body layout only
## Also invalidate via content hashes / [member ContinentAtlas.SCHEMA_VERSION]
## when generator meaning or config knobs change (even if the byte layout is
## unchanged).

## Atlas + sector blob format. Bump when pack/unpack field order or types change.
const FORMAT_VERSION: int = 1
## LOD0 chunk blob format. Bump independently when mesh/water/props packing changes.
const CHUNK_FORMAT_VERSION: int = 1
const MAGIC_ATLAS: int = 0x5441524F ## "ORAT" LE
const MAGIC_SECTOR: int = 0x5357524F ## "ORWS" LE
const MAGIC_CHUNK: int = 0x4B43524F ## "ORCK" LE
const CACHE_ROOT: String = "user://cache"
## Chebyshev ring cached for instant walk (3×3 underfoot).
const WARM_CHUNK_RING: int = 1


static func atlas_path(config: WorldConfig) -> String:
	return "%s/%d/atlas.bin" % [CACHE_ROOT, config.content_hash()]


static func sector_path(content_key: int, sector: Vector2i) -> String:
	return "%s/%d/sector_%d_%d.bin" % [CACHE_ROOT, content_key, sector.x, sector.y]


## Directory key for LOD0 chunk blobs: sector content plus mesh knobs + format.
static func chunk_key(context: WorldContext) -> int:
	var h: int = context.content_key()
	h = (h ^ hash(context.config.mesh_content_hash())) * 1099511628211
	h = (h ^ hash(CHUNK_FORMAT_VERSION)) * 1099511628211
	return h & 0x7FFFFFFFFFFFFFFF


static func chunk_path(chunk_key_value: int, chunk: Vector2i) -> String:
	return "%s/%d/chunk_%d_%d_lod0.bin" % [
		CACHE_ROOT, chunk_key_value, chunk.x, chunk.y
	]


static func has_chunk(context: WorldContext, chunk: Vector2i) -> bool:
	return FileAccess.file_exists(chunk_path(chunk_key(context), chunk))


static func is_warm_ring(priority: float) -> bool:
	return int(priority) <= WARM_CHUNK_RING


static func try_load_atlas(config: WorldConfig) -> ContinentAtlas:
	var path: String = atlas_path(config)
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("BakeCache: cannot open atlas cache %s (%s)" % [
			path, FileAccess.get_open_error()
		])
		return null
	var magic: int = file.get_32()
	var version: int = file.get_32()
	if magic != MAGIC_ATLAS or version != FORMAT_VERSION:
		push_warning(
			"BakeCache: atlas cache header mismatch (magic=0x%X ver=%d); regenerating" % [
				magic, version
			]
		)
		return null
	var world_seed: int = file.get_32()
	var size: int = file.get_32()
	var schema_version: int = file.get_32()
	if (
		world_seed != config.seed
		or size != config.atlas_size
		or schema_version != ContinentAtlas.SCHEMA_VERSION
	):
		push_warning(
			"BakeCache: atlas cache key mismatch (seed/size/schema); regenerating"
		)
		return null
	var atlas: ContinentAtlas = _read_atlas_body(file, world_seed, size, schema_version)
	if atlas == null:
		push_error("BakeCache: truncated or corrupt atlas cache at %s" % path)
		return null
	if file.get_position() != file.get_length():
		push_error(
			"BakeCache: atlas cache has trailing bytes at %s (%d leftover)" % [
				path, file.get_length() - file.get_position()
			]
		)
		return null
	return atlas


static func save_atlas(config: WorldConfig, atlas: ContinentAtlas) -> void:
	assert(atlas != null, "BakeCache.save_atlas: atlas is null")
	assert(atlas.world_seed == config.seed, "BakeCache.save_atlas: seed mismatch")
	assert(atlas.size == config.atlas_size, "BakeCache.save_atlas: size mismatch")
	var path: String = atlas_path(config)
	_ensure_parent_dir(path)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "BakeCache: cannot write atlas cache %s (%s)" % [
		path, FileAccess.get_open_error()
	])
	file.store_32(MAGIC_ATLAS)
	file.store_32(FORMAT_VERSION)
	file.store_32(atlas.world_seed)
	file.store_32(atlas.size)
	file.store_32(atlas.schema_version)
	_write_atlas_body(file, atlas)
	print("BakeCache: wrote atlas %s (%.1f MB)" % [
		path, float(file.get_position()) / (1024.0 * 1024.0)
	])


static func try_load_sector(context: WorldContext, sector: Vector2i) -> WorldSector:
	var key: int = context.content_key()
	var path: String = sector_path(key, sector)
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("BakeCache: cannot open sector cache %s (%s)" % [
			path, FileAccess.get_open_error()
		])
		return null
	var magic: int = file.get_32()
	var version: int = file.get_32()
	if magic != MAGIC_SECTOR or version != FORMAT_VERSION:
		push_warning(
			"BakeCache: sector cache header mismatch (magic=0x%X ver=%d); regenerating" % [
				magic, version
			]
		)
		return null
	var stored_key: int = file.get_64()
	var sx: int = file.get_32()
	var sz: int = file.get_32()
	if stored_key != key or sx != sector.x or sz != sector.y:
		push_warning(
			"BakeCache: sector cache key/coord mismatch; regenerating"
		)
		return null
	var built: WorldSector = _read_sector_body(file, context, sector)
	if built == null:
		push_error("BakeCache: truncated or corrupt sector cache at %s" % path)
		return null
	if file.get_position() != file.get_length():
		push_error(
			"BakeCache: sector cache has trailing bytes at %s (%d leftover)" % [
				path, file.get_length() - file.get_position()
			]
		)
		return null
	return built


static func save_sector(context: WorldContext, sector: WorldSector) -> void:
	assert(sector != null, "BakeCache.save_sector: sector is null")
	assert(sector.context == context, "BakeCache.save_sector: context mismatch")
	var key: int = context.content_key()
	var path: String = sector_path(key, sector.sector)
	_ensure_parent_dir(path)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "BakeCache: cannot write sector cache %s (%s)" % [
		path, FileAccess.get_open_error()
	])
	file.store_32(MAGIC_SECTOR)
	file.store_32(FORMAT_VERSION)
	file.store_64(key)
	file.store_32(sector.sector.x)
	file.store_32(sector.sector.y)
	_write_sector_body(file, sector)
	print("BakeCache: wrote sector %s (%.1f MB)" % [
		path, float(file.get_position()) / (1024.0 * 1024.0)
	])


# --- Atlas body ----------------------------------------------------------------

static func _write_atlas_body(file: FileAccess, atlas: ContinentAtlas) -> void:
	file.store_64(atlas.content_hash)
	file.store_32(atlas.sea_surface_z)
	_store_i32_array(file, atlas.cells)
	_store_i32_array(file, atlas.landmass_id)
	_store_i32_array(file, atlas.lake_id)
	_store_i32_array(file, atlas.river_receiver)
	_store_i32_array(file, atlas.mouth_distance)

	file.store_32(atlas.lakes.size())
	for lake_variant in atlas.lakes:
		var lake: AtlasLake = lake_variant
		file.store_32(lake.id)
		file.store_32(lake.spill_cell)
		file.store_32(lake.surface_code)
		file.store_32(lake.surface_z)
		_store_i32_array(file, lake.cells)

	file.store_32(atlas.nodes.size())
	for node_variant in atlas.nodes:
		var node: AtlasGraphNode = node_variant
		file.store_32(node.id)
		file.store_8(node.kind)
		file.store_32(node.cell)
		file.store_32(node.ax)
		file.store_32(node.az)
		file.store_32(node.landmass)

	file.store_32(atlas.crossings.size())
	for crossing_variant in atlas.crossings:
		var crossing: AtlasCrossing = crossing_variant
		file.store_32(crossing.id)
		file.store_32(crossing.cell)
		file.store_32(crossing.river_id)
		file.store_32(crossing.road_id)
		file.store_32(crossing.river_class)
		file.store_32(crossing.road_class)

	file.store_32(atlas.primary_road_edges.size())
	for edge in atlas.primary_road_edges:
		file.store_32(edge.x)
		file.store_32(edge.y)

	_write_port_dict(file, atlas.river_ports)
	_write_port_dict(file, atlas.road_ports)
	_write_link_dict(file, atlas.river_links)
	_write_link_dict(file, atlas.road_links)


static func _read_atlas_body(
	file: FileAccess, world_seed: int, size: int, schema_version: int
) -> ContinentAtlas:
	var atlas: ContinentAtlas = ContinentAtlas.new()
	atlas.world_seed = world_seed
	atlas.size = size
	atlas.schema_version = schema_version
	atlas.content_hash = file.get_64()
	atlas.sea_surface_z = file.get_32()
	atlas.cells = _get_i32_array(file)
	atlas.landmass_id = _get_i32_array(file)
	atlas.lake_id = _get_i32_array(file)
	atlas.river_receiver = _get_i32_array(file)
	atlas.mouth_distance = _get_i32_array(file)
	if (
		atlas.cells.size() != size * size
		or atlas.landmass_id.size() != size * size
		or atlas.lake_id.size() != size * size
		or atlas.river_receiver.size() != size * size
		or atlas.mouth_distance.size() != size * size
	):
		return null

	var lake_count: int = file.get_32()
	atlas.lakes.clear()
	for _i in lake_count:
		var lake: AtlasLake = AtlasLake.new()
		lake.id = file.get_32()
		lake.spill_cell = file.get_32()
		lake.surface_code = file.get_32()
		lake.surface_z = file.get_32()
		lake.cells = _get_i32_array(file)
		atlas.lakes.append(lake)

	var node_count: int = file.get_32()
	atlas.nodes.clear()
	for _i in node_count:
		var node: AtlasGraphNode = AtlasGraphNode.new()
		node.id = file.get_32()
		node.kind = file.get_8()
		node.cell = file.get_32()
		node.ax = file.get_32()
		node.az = file.get_32()
		node.landmass = file.get_32()
		atlas.nodes.append(node)

	var crossing_count: int = file.get_32()
	atlas.crossings.clear()
	for _i in crossing_count:
		var crossing: AtlasCrossing = AtlasCrossing.new()
		crossing.id = file.get_32()
		crossing.cell = file.get_32()
		crossing.river_id = file.get_32()
		crossing.road_id = file.get_32()
		crossing.river_class = file.get_32()
		crossing.road_class = file.get_32()
		atlas.crossings.append(crossing)

	var edge_count: int = file.get_32()
	atlas.primary_road_edges.clear()
	for _i in edge_count:
		atlas.primary_road_edges.append(Vector2i(file.get_32(), file.get_32()))

	atlas.river_ports = _read_port_dict(file)
	atlas.road_ports = _read_port_dict(file)
	atlas.river_links = _read_link_dict(file)
	atlas.road_links = _read_link_dict(file)
	if file.get_error() != OK and file.get_position() < file.get_length():
		return null
	return atlas


static func _write_port_dict(file: FileAccess, ports: Dictionary) -> void:
	file.store_32(ports.size())
	for edge_key in ports.keys():
		file.store_32(int(edge_key))
		var list: Array = ports[edge_key]
		file.store_32(list.size())
		for port_variant in list:
			var port: AtlasPort = port_variant
			file.store_32(port.id)
			file.store_float(port.t)
			file.store_8(port.kind)
			file.store_8(port.feature_class)
			file.store_8(port.flow_sign + 128)
			file.store_32(port.surface_z)
			file.store_32(port.feature_id)


static func _read_port_dict(file: FileAccess) -> Dictionary:
	var out: Dictionary = {}
	var entry_count: int = file.get_32()
	for _i in entry_count:
		var edge_key: int = file.get_32()
		var port_count: int = file.get_32()
		var list: Array[AtlasPort] = []
		for _j in port_count:
			var port: AtlasPort = AtlasPort.new()
			port.id = file.get_32()
			port.t = file.get_float()
			port.kind = file.get_8()
			port.feature_class = file.get_8()
			port.flow_sign = int(file.get_8()) - 128
			port.surface_z = file.get_32()
			port.feature_id = file.get_32()
			list.append(port)
		out[edge_key] = list
	return out


static func _write_link_dict(file: FileAccess, links: Dictionary) -> void:
	file.store_32(links.size())
	for cell_idx in links.keys():
		file.store_32(int(cell_idx))
		var list: Array = links[cell_idx]
		file.store_32(list.size())
		for link_variant in list:
			var link: AtlasLink = link_variant
			file.store_8(link.kind)
			file.store_8(link.feature_class)
			file.store_32(link.feature_id)
			_write_endpoint(file, link.a)
			_write_endpoint(file, link.b)


static func _read_link_dict(file: FileAccess) -> Dictionary:
	var out: Dictionary = {}
	var entry_count: int = file.get_32()
	for _i in entry_count:
		var cell_idx: int = file.get_32()
		var link_count: int = file.get_32()
		var list: Array[AtlasLink] = []
		for _j in link_count:
			var link: AtlasLink = AtlasLink.new()
			link.kind = file.get_8()
			link.feature_class = file.get_8()
			link.feature_id = file.get_32()
			link.a = _read_endpoint(file)
			link.b = _read_endpoint(file)
			list.append(link)
		out[cell_idx] = list
	return out


static func _write_endpoint(file: FileAccess, endpoint: AtlasEndpoint) -> void:
	file.store_8(endpoint.kind)
	file.store_32(endpoint.ref_id)
	file.store_32(endpoint.port_id)


static func _read_endpoint(file: FileAccess) -> AtlasEndpoint:
	var endpoint: AtlasEndpoint = AtlasEndpoint.new()
	endpoint.kind = file.get_8()
	endpoint.ref_id = file.get_32()
	endpoint.port_id = file.get_32()
	return endpoint


# --- Sector body ---------------------------------------------------------------

static func _write_sector_body(file: FileAccess, sector: WorldSector) -> void:
	file.store_32(sector.core_min.x)
	file.store_32(sector.core_min.y)
	file.store_32(sector.core_max.x)
	file.store_32(sector.core_max.y)

	var terrain: MacroTerrain = sector.terrain
	file.store_32(terrain.origin_cell.x)
	file.store_32(terrain.origin_cell.y)
	file.store_32(terrain.cells)
	file.store_float(terrain.cell_size)
	file.store_float(terrain.min_elevation)
	file.store_float(terrain.max_elevation)
	_store_f32_array(file, terrain.elevation)
	_store_f32_array(file, terrain.relief_amp)
	_store_f32_array(file, terrain.moisture)
	_store_f32_array(file, terrain.temperature)

	var hydro: Hydrology = sector.hydro
	file.store_32(hydro.core_min.x)
	file.store_32(hydro.core_min.y)
	file.store_32(hydro.core_max.x)
	file.store_32(hydro.core_max.y)
	file.store_32(hydro.local_min.x)
	file.store_32(hydro.local_min.y)
	file.store_32(hydro.local_max.x)
	file.store_32(hydro.local_max.y)
	_store_f32_array(file, hydro.filled)
	_store_i32_array(file, hydro.lake_id)
	_store_f32_array(file, hydro.accumulation)
	_store_i32_array(file, hydro.is_channel)
	_store_bytes(file, hydro.trunk)
	_store_bytes(file, hydro.atlas_water)
	_store_f32_array(file, hydro.lake_distance)
	_store_f32_array(file, hydro.lake_surface_near)

	file.store_32(hydro.lakes.size())
	for lake_variant in hydro.lakes:
		var lake: LakeData = lake_variant
		file.store_32(lake.id)
		file.store_float(lake.surface_z)
		file.store_32(lake.outlet_cell)
		file.store_float(lake.max_depth)
		file.store_float(lake.bounds.position.x)
		file.store_float(lake.bounds.position.y)
		file.store_float(lake.bounds.size.x)
		file.store_float(lake.bounds.size.y)
		_store_i32_array(file, lake.cells)

	file.store_32(hydro.rivers.size())
	for reach_variant in hydro.rivers:
		var reach: RiverPolyline = reach_variant
		file.store_32(reach.id)
		_store_v3_array(file, reach.points)
		_store_f32_array(file, reach.half_width)
		file.store_32(reach.order)
		file.store_float(reach.depth)
		file.store_float(reach.valley)
		file.store_32(reach.downstream_id)
		file.store_32(reach.ends_in_lake)
		file.store_8(1 if reach.is_trunk else 0)
		file.store_8(1 if reach.is_shared else 0)
		file.store_32(reach.feature_id)

	var claims: ClaimMask = sector.claims
	file.store_32(claims.claims.size())
	for claim_variant in claims.claims:
		var claim: ClaimMask.Claim = claim_variant
		file.store_32(claim.id)
		_store_string_name(file, claim.kind)
		file.store_float(claim.center.x)
		file.store_float(claim.center.y)
		file.store_float(claim.radius)
		file.store_float(claim.ground_z)
		file.store_float(claim.built_radius)

	var paths: PathNetwork = sector.paths
	file.store_32(paths.core_min.x)
	file.store_32(paths.core_min.y)
	file.store_32(paths.core_max.x)
	file.store_32(paths.core_max.y)
	file.store_32(paths.local_min.x)
	file.store_32(paths.local_min.y)
	file.store_32(paths.local_max.x)
	file.store_32(paths.local_max.y)

	file.store_32(paths.bridges.size())
	for bridge_variant in paths.bridges:
		var bridge: BridgeSite = bridge_variant
		file.store_32(bridge.id)
		file.store_32(bridge.road_id)
		_store_vector3(file, bridge.anchor_a)
		_store_vector3(file, bridge.anchor_b)
		file.store_float(bridge.water_z)
		file.store_32(bridge.river_order)
		file.store_float(bridge.deck_width)
		file.store_8(1 if bridge.is_ford else 0)
		_store_string_name(file, bridge.catalog_id)
		file.store_float(bridge.deck_z)
		file.store_float(bridge.axis.x)
		file.store_float(bridge.axis.y)
		file.store_float(bridge.center_xz.x)
		file.store_float(bridge.center_xz.y)
		file.store_float(bridge.gap_half)
		file.store_float(bridge.abutment_s)
		file.store_float(bridge.ramp_length)
		file.store_float(bridge.plateau_length)
		file.store_float(bridge.grade_half_width)

	file.store_32(paths.roads.size())
	for road_variant in paths.roads:
		var road: RoadEdge = road_variant
		file.store_32(road.id)
		file.store_8(int(road.tier))
		_store_v3_array(file, road.points)
		file.store_float(road.half_width)
		file.store_32(road.from_node)
		file.store_32(road.to_node)
		file.store_8(1 if road.is_trunk else 0)
		file.store_32(road.feature_id)
		file.store_32(road.crossings.size())
		for crossing_variant in road.crossings:
			var crossing: BridgeSite = crossing_variant
			file.store_32(crossing.id)

	file.store_32(sector.houses.size())
	for house_variant in sector.houses:
		var house: HouseSite = house_variant
		_store_string_name(file, house.catalog_id)
		file.store_float(house.world_x)
		file.store_float(house.world_z)
		file.store_float(house.yaw)
		file.store_float(house.footprint)
		file.store_float(house.seat_sink)


static func _read_sector_body(
	file: FileAccess, context: WorldContext, sector_coord: Vector2i
) -> WorldSector:
	var sector: WorldSector = WorldSector.new()
	sector.context = context
	sector.config = context.config
	sector.sector = sector_coord
	sector.core_min = Vector2i(file.get_32(), file.get_32())
	sector.core_max = Vector2i(file.get_32(), file.get_32())

	var terrain: MacroTerrain = MacroTerrain.new()
	terrain.config = context.config
	terrain.origin_cell = Vector2i(file.get_32(), file.get_32())
	terrain.cells = file.get_32()
	terrain.cell_size = file.get_float()
	terrain.min_elevation = file.get_float()
	terrain.max_elevation = file.get_float()
	terrain.elevation = _get_f32_array(file)
	terrain.relief_amp = _get_f32_array(file)
	terrain.moisture = _get_f32_array(file)
	terrain.temperature = _get_f32_array(file)
	var cell_count: int = terrain.cells * terrain.cells
	if (
		terrain.elevation.size() != cell_count
		or terrain.relief_amp.size() != cell_count
		or terrain.moisture.size() != cell_count
		or terrain.temperature.size() != cell_count
	):
		return null
	sector.terrain = terrain

	var hydro: Hydrology = Hydrology.new()
	hydro.config = context.config
	hydro.terrain = terrain
	hydro.continental = null
	hydro.corridors = context.corridors
	hydro.core_min = Vector2i(file.get_32(), file.get_32())
	hydro.core_max = Vector2i(file.get_32(), file.get_32())
	hydro.local_min = Vector2i(file.get_32(), file.get_32())
	hydro.local_max = Vector2i(file.get_32(), file.get_32())
	hydro.filled = _get_f32_array(file)
	hydro.lake_id = _get_i32_array(file)
	hydro.accumulation = _get_f32_array(file)
	hydro.is_channel = _get_i32_array(file)
	hydro.trunk = _get_bytes(file)
	hydro.atlas_water = _get_bytes(file)
	hydro.lake_distance = _get_f32_array(file)
	hydro.lake_surface_near = _get_f32_array(file)
	if (
		hydro.filled.size() != cell_count
		or hydro.lake_id.size() != cell_count
		or hydro.accumulation.size() != cell_count
		or hydro.is_channel.size() != cell_count
		or hydro.trunk.size() != cell_count
		or hydro.atlas_water.size() != cell_count
		or hydro.lake_distance.size() != cell_count
		or hydro.lake_surface_near.size() != cell_count
	):
		return null

	var lake_count: int = file.get_32()
	hydro.lakes.clear()
	for _i in lake_count:
		var lake: LakeData = LakeData.new()
		lake.id = file.get_32()
		lake.surface_z = file.get_float()
		lake.outlet_cell = file.get_32()
		lake.max_depth = file.get_float()
		lake.bounds = Rect2(
			file.get_float(), file.get_float(),
			file.get_float(), file.get_float()
		)
		lake.cells = _get_i32_array(file)
		hydro.lakes.append(lake)

	var river_count: int = file.get_32()
	hydro.rivers.clear()
	for _i in river_count:
		var reach: RiverPolyline = RiverPolyline.new()
		reach.id = file.get_32()
		reach.points = _get_v3_array(file)
		reach.half_width = _get_f32_array(file)
		reach.order = file.get_32()
		reach.depth = file.get_float()
		reach.valley = file.get_float()
		reach.downstream_id = file.get_32()
		reach.ends_in_lake = file.get_32()
		reach.is_trunk = file.get_8() != 0
		reach.is_shared = file.get_8() != 0
		reach.feature_id = file.get_32()
		reach.compute_bounds()
		hydro.rivers.append(reach)
	hydro.rebuild_spatial_index()
	sector.hydro = hydro

	var claims: ClaimMask = ClaimMask.new()
	var claim_count: int = file.get_32()
	for _i in claim_count:
		var claim: ClaimMask.Claim = ClaimMask.Claim.new()
		claim.id = file.get_32()
		claim.kind = _get_string_name(file)
		claim.center = Vector2(file.get_float(), file.get_float())
		claim.radius = file.get_float()
		claim.ground_z = file.get_float()
		claim.built_radius = file.get_float()
		claims.claims.append(claim)
	claims.rebuild_spatial_index()
	sector.claims = claims

	var paths: PathNetwork = PathNetwork.new()
	paths.config = context.config
	paths.terrain = terrain
	paths.hydro = hydro
	paths.claims = claims
	paths.corridors = context.corridors
	paths.core_min = Vector2i(file.get_32(), file.get_32())
	paths.core_max = Vector2i(file.get_32(), file.get_32())
	paths.local_min = Vector2i(file.get_32(), file.get_32())
	paths.local_max = Vector2i(file.get_32(), file.get_32())

	var bridge_count: int = file.get_32()
	paths.bridges.clear()
	var bridges_by_id: Dictionary = {}
	for _i in bridge_count:
		var bridge: BridgeSite = BridgeSite.new()
		bridge.id = file.get_32()
		bridge.road_id = file.get_32()
		bridge.anchor_a = _get_vector3(file)
		bridge.anchor_b = _get_vector3(file)
		bridge.water_z = file.get_float()
		bridge.river_order = file.get_32()
		bridge.deck_width = file.get_float()
		bridge.is_ford = file.get_8() != 0
		bridge.catalog_id = _get_string_name(file)
		bridge.deck_z = file.get_float()
		bridge.axis = Vector2(file.get_float(), file.get_float())
		bridge.center_xz = Vector2(file.get_float(), file.get_float())
		bridge.gap_half = file.get_float()
		bridge.abutment_s = file.get_float()
		bridge.ramp_length = file.get_float()
		bridge.plateau_length = file.get_float()
		bridge.grade_half_width = file.get_float()
		paths.bridges.append(bridge)
		bridges_by_id[bridge.id] = bridge

	var road_count: int = file.get_32()
	paths.roads.clear()
	for _i in road_count:
		var road: RoadEdge = RoadEdge.new()
		road.id = file.get_32()
		road.tier = file.get_8() as RoadEdge.Tier
		road.points = _get_v3_array(file)
		road.half_width = file.get_float()
		road.from_node = file.get_32()
		road.to_node = file.get_32()
		road.is_trunk = file.get_8() != 0
		road.feature_id = file.get_32()
		var crossing_count: int = file.get_32()
		for _j in crossing_count:
			var bridge_id: int = file.get_32()
			if not bridges_by_id.has(bridge_id):
				push_error("BakeCache: road crossing bridge id %d missing" % bridge_id)
				return null
			road.crossings.append(bridges_by_id[bridge_id])
		road.compute_bounds()
		paths.roads.append(road)
	paths.rebuild_spatial_index()
	sector.paths = paths

	var house_count: int = file.get_32()
	sector.houses.clear()
	for _i in house_count:
		var house: HouseSite = HouseSite.new()
		house.catalog_id = _get_string_name(file)
		house.world_x = file.get_float()
		house.world_z = file.get_float()
		house.yaw = file.get_float()
		house.footprint = file.get_float()
		house.seat_sink = file.get_float()
		sector.houses.append(house)

	if file.get_error() != OK and file.get_position() < file.get_length():
		return null
	return sector


# --- LOD0 chunk body -----------------------------------------------------------

static func try_load_chunk(
	context: WorldContext,
	sector: WorldSector,
	region: RegionData,
	chunk: Vector2i,
	lod: int
) -> ChunkJob:
	if lod != 0:
		return null
	var key: int = chunk_key(context)
	var path: String = chunk_path(key, chunk)
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("BakeCache: cannot open chunk cache %s (%s)" % [
			path, FileAccess.get_open_error()
		])
		return null
	var magic: int = file.get_32()
	var version: int = file.get_32()
	if magic != MAGIC_CHUNK or version != CHUNK_FORMAT_VERSION:
		push_warning(
			"BakeCache: chunk cache header mismatch (magic=0x%X ver=%d); regenerating" % [
				magic, version
			]
		)
		return null
	var stored_key: int = file.get_64()
	var cx: int = file.get_32()
	var cz: int = file.get_32()
	var stored_lod: int = file.get_32()
	if stored_key != key or cx != chunk.x or cz != chunk.y or stored_lod != 0:
		push_warning("BakeCache: chunk cache key/coord mismatch; regenerating")
		return null
	var job: ChunkJob = _read_chunk_body(file, context, sector, region, chunk)
	if job == null:
		push_error("BakeCache: truncated or corrupt chunk cache at %s" % path)
		return null
	if file.get_position() != file.get_length():
		push_error(
			"BakeCache: chunk cache has trailing bytes at %s (%d leftover)" % [
				path, file.get_length() - file.get_position()
			]
		)
		return null
	return job


static func save_chunk(context: WorldContext, job: ChunkJob) -> void:
	assert(job != null, "BakeCache.save_chunk: job is null")
	assert(job.lod == 0, "BakeCache.save_chunk: only LOD0 is cached")
	assert(job.mesh_data != null, "BakeCache.save_chunk: mesh_data is null")
	var key: int = chunk_key(context)
	var path: String = chunk_path(key, job.chunk)
	_ensure_parent_dir(path)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "BakeCache: cannot write chunk cache %s (%s)" % [
		path, FileAccess.get_open_error()
	])
	file.store_32(MAGIC_CHUNK)
	file.store_32(CHUNK_FORMAT_VERSION)
	file.store_64(key)
	file.store_32(job.chunk.x)
	file.store_32(job.chunk.y)
	file.store_32(job.lod)
	_write_chunk_body(file, job)
	print("BakeCache: wrote chunk %s (%.2f MB)" % [
		path, float(file.get_position()) / (1024.0 * 1024.0)
	])


static func _write_chunk_body(file: FileAccess, job: ChunkJob) -> void:
	file.store_float(job.max_contract_error)
	_write_mesh_data(file, job.mesh_data)
	_write_water_data(file, job.water_data)
	_write_props(file, job.props)
	file.store_32(job.bridges.size())
	for site in job.bridges:
		file.store_32(site.id)


static func _read_chunk_body(
	file: FileAccess,
	context: WorldContext,
	sector: WorldSector,
	region: RegionData,
	chunk: Vector2i
) -> ChunkJob:
	var job: ChunkJob = ChunkJob.new()
	job.config = context.config
	job.context = context
	job.sector = sector
	job.region = region
	job.chunk = chunk
	job.lod = 0
	job.want_collision = true
	job.want_props = true
	job.want_clutter = true
	job.max_contract_error = file.get_float()
	job.mesh_data = _read_mesh_data(file)
	job.water_data = _read_water_data(file)
	if job.mesh_data == null or job.water_data == null:
		return null
	job.props = _read_props(file)
	var bridge_count: int = file.get_32()
	job.bridges.clear()
	job.bridge_builds.clear()
	var chunk_origin: Vector2 = WorldCoords.chunk_origin(context.config, chunk)
	for _i in bridge_count:
		var bridge_id: int = file.get_32()
		var site: BridgeSite = _find_bridge(sector, region, bridge_id)
		if site == null:
			push_error("BakeCache: chunk bridge id %d missing" % bridge_id)
			return null
		job.bridges.append(site)
		job.bridge_builds.append(BridgeBuilder.build(site, chunk_origin, true))
	if file.get_error() != OK and file.get_position() < file.get_length():
		return null
	return job


static func _find_bridge(
	sector: WorldSector, region: RegionData, bridge_id: int
) -> BridgeSite:
	for site in region.bridges:
		if site.id == bridge_id:
			return site
	for site in sector.paths.bridges:
		if site.id == bridge_id:
			return site
	return null


static func _write_mesh_data(file: FileAccess, data: MeshExtract.MeshData) -> void:
	_store_v3_array(file, data.vertices)
	_store_v3_array(file, data.normals)
	_store_color_array(file, data.colors)
	_store_v2_array(file, data.uvs)
	_store_i32_array(file, data.indices)
	_store_v3_array(file, data.collision_faces)
	file.store_32(data.surface_triangles)
	_store_vector3(file, data.aabb.position)
	_store_vector3(file, data.aabb.size)


static func _read_mesh_data(file: FileAccess) -> MeshExtract.MeshData:
	var data: MeshExtract.MeshData = MeshExtract.MeshData.new()
	data.vertices = _get_v3_array(file)
	data.normals = _get_v3_array(file)
	data.colors = _get_color_array(file)
	data.uvs = _get_v2_array(file)
	data.indices = _get_i32_array(file)
	data.collision_faces = _get_v3_array(file)
	data.surface_triangles = file.get_32()
	data.aabb = AABB(_get_vector3(file), _get_vector3(file))
	return data


static func _write_water_data(file: FileAccess, data: WaterSurface.WaterData) -> void:
	if data == null:
		data = WaterSurface.WaterData.new()
	_store_v3_array(file, data.vertices)
	_store_v3_array(file, data.normals)
	_store_v2_array(file, data.uvs)
	_store_i32_array(file, data.indices)


static func _read_water_data(file: FileAccess) -> WaterSurface.WaterData:
	var data: WaterSurface.WaterData = WaterSurface.WaterData.new()
	data.vertices = _get_v3_array(file)
	data.normals = _get_v3_array(file)
	data.uvs = _get_v2_array(file)
	data.indices = _get_i32_array(file)
	return data


static func _write_props(file: FileAccess, props: Dictionary) -> void:
	file.store_32(props.size())
	for catalog_id in props.keys():
		_store_string_name(file, catalog_id as StringName)
		var transforms: Array = props[catalog_id]
		file.store_32(transforms.size())
		# 12 float32s per Transform3D — one buffer, not 12 FileAccess calls each.
		var floats: PackedFloat32Array = PackedFloat32Array()
		floats.resize(transforms.size() * 12)
		var o: int = 0
		for xf_variant in transforms:
			var xf: Transform3D = xf_variant
			floats[o] = xf.basis.x.x
			floats[o + 1] = xf.basis.x.y
			floats[o + 2] = xf.basis.x.z
			floats[o + 3] = xf.basis.y.x
			floats[o + 4] = xf.basis.y.y
			floats[o + 5] = xf.basis.y.z
			floats[o + 6] = xf.basis.z.x
			floats[o + 7] = xf.basis.z.y
			floats[o + 8] = xf.basis.z.z
			floats[o + 9] = xf.origin.x
			floats[o + 10] = xf.origin.y
			floats[o + 11] = xf.origin.z
			o += 12
		if floats.size() > 0:
			file.store_buffer(floats.to_byte_array())


static func _read_props(file: FileAccess) -> Dictionary:
	var out: Dictionary = {}
	var entry_count: int = file.get_32()
	for _i in entry_count:
		var catalog_id: StringName = _get_string_name(file)
		var count: int = file.get_32()
		var transforms: Array[Transform3D] = []
		transforms.resize(count)
		if count > 0:
			var bytes: PackedByteArray = file.get_buffer(count * 48)
			if bytes.size() != count * 48:
				push_error("BakeCache: truncated prop transforms")
				return {}
			var floats: PackedFloat32Array = bytes.to_float32_array()
			for j in count:
				var o: int = j * 12
				transforms[j] = Transform3D(
					Basis(
						Vector3(floats[o], floats[o + 1], floats[o + 2]),
						Vector3(floats[o + 3], floats[o + 4], floats[o + 5]),
						Vector3(floats[o + 6], floats[o + 7], floats[o + 8])
					),
					Vector3(floats[o + 9], floats[o + 10], floats[o + 11])
				)
		out[catalog_id] = transforms
	return out


# --- Primitives ----------------------------------------------------------------

static func _ensure_parent_dir(path: String) -> void:
	var dir_path: String = path.get_base_dir()
	var abs_path: String = ProjectSettings.globalize_path(dir_path)
	var err: Error = DirAccess.make_dir_recursive_absolute(abs_path)
	assert(err == OK, "BakeCache: mkdir %s failed (%s)" % [abs_path, error_string(err)])


static func _store_i32_array(file: FileAccess, values: PackedInt32Array) -> void:
	file.store_32(values.size())
	if values.size() > 0:
		file.store_buffer(values.to_byte_array())


static func _get_i32_array(file: FileAccess) -> PackedInt32Array:
	var count: int = file.get_32()
	if count == 0:
		return PackedInt32Array()
	var bytes: PackedByteArray = file.get_buffer(count * 4)
	if bytes.size() != count * 4:
		push_error("BakeCache: truncated int32 array")
		return PackedInt32Array()
	return bytes.to_int32_array()


static func _store_f32_array(file: FileAccess, values: PackedFloat32Array) -> void:
	file.store_32(values.size())
	if values.size() > 0:
		file.store_buffer(values.to_byte_array())


static func _get_f32_array(file: FileAccess) -> PackedFloat32Array:
	var count: int = file.get_32()
	if count == 0:
		return PackedFloat32Array()
	var bytes: PackedByteArray = file.get_buffer(count * 4)
	if bytes.size() != count * 4:
		push_error("BakeCache: truncated float32 array")
		return PackedFloat32Array()
	return bytes.to_float32_array()


static func _store_bytes(file: FileAccess, values: PackedByteArray) -> void:
	file.store_32(values.size())
	if values.size() > 0:
		file.store_buffer(values)


static func _get_bytes(file: FileAccess) -> PackedByteArray:
	var count: int = file.get_32()
	if count == 0:
		return PackedByteArray()
	var bytes: PackedByteArray = file.get_buffer(count)
	if bytes.size() != count:
		push_error("BakeCache: truncated byte array")
		return PackedByteArray()
	return bytes


static func _store_v3_array(file: FileAccess, values: PackedVector3Array) -> void:
	file.store_32(values.size())
	if values.size() > 0:
		file.store_buffer(values.to_byte_array())


static func _get_v3_array(file: FileAccess) -> PackedVector3Array:
	var count: int = file.get_32()
	if count == 0:
		return PackedVector3Array()
	var bytes: PackedByteArray = file.get_buffer(count * 12)
	if bytes.size() != count * 12:
		push_error("BakeCache: truncated Vector3 array")
		return PackedVector3Array()
	return bytes.to_vector3_array()


static func _store_v2_array(file: FileAccess, values: PackedVector2Array) -> void:
	file.store_32(values.size())
	if values.size() > 0:
		file.store_buffer(values.to_byte_array())


static func _get_v2_array(file: FileAccess) -> PackedVector2Array:
	var count: int = file.get_32()
	if count == 0:
		return PackedVector2Array()
	var bytes: PackedByteArray = file.get_buffer(count * 8)
	if bytes.size() != count * 8:
		push_error("BakeCache: truncated Vector2 array")
		return PackedVector2Array()
	return bytes.to_vector2_array()


static func _store_color_array(file: FileAccess, values: PackedColorArray) -> void:
	file.store_32(values.size())
	if values.size() > 0:
		file.store_buffer(values.to_byte_array())


static func _get_color_array(file: FileAccess) -> PackedColorArray:
	var count: int = file.get_32()
	if count == 0:
		return PackedColorArray()
	var bytes: PackedByteArray = file.get_buffer(count * 16)
	if bytes.size() != count * 16:
		push_error("BakeCache: truncated Color array")
		return PackedColorArray()
	return bytes.to_color_array()


static func _store_vector3(file: FileAccess, value: Vector3) -> void:
	file.store_float(value.x)
	file.store_float(value.y)
	file.store_float(value.z)


static func _get_vector3(file: FileAccess) -> Vector3:
	return Vector3(file.get_float(), file.get_float(), file.get_float())


static func _store_string_name(file: FileAccess, value: StringName) -> void:
	file.store_pascal_string(String(value))


static func _get_string_name(file: FileAccess) -> StringName:
	return StringName(file.get_pascal_string())
