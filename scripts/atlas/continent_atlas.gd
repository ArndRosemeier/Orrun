class_name ContinentAtlas
extends RefCounted
## Layer 0: continental climate + major river/road continuity.
##
## See docs/CONTINENT_ATLAS.md. Immutable after generate().

const SIZE: int = 1000
const CELL_METRES: float = 1000.0
const SCHEMA_VERSION: int = 4
const SEA_SURFACE_Z: int = 0
const OCEAN_COLLAR_FULL: int = 48
const RIVER_ACCUM_THRESHOLD: float = 180.0
const MAX_RIVER_PORTS: int = 2
const MAX_ROAD_PORTS: int = 2
const LAKE_MIN_DEPTH_CODE: int = 3
const LAKE_MIN_CELLS: int = 6
const LAKE_MAX_CELLS_FULL: int = 450
const PRIMARY_NODE_TARGET: int = 72
## Occupancy is sparse: land below this score stays at population 0.
const POPULATION_THRESHOLD: float = 0.66
const POPULATION_SCORE_SPAN: float = 1.0
## Cells this far from a river mouth still get a share of the port bonus.
const POPULATION_MOUTH_RADIUS: int = 2
## Population at or above this promotes a node to SETTLEMENT.
const SETTLEMENT_MIN_POP: int = 7
## Reference |∇h| (rise/run) for flatness fitness — ~2% / 1.1°.
const SETTLEMENT_SLOPE_REF: float = 0.02
## Hard cliff reject: steeper than this cannot host a SETTLEMENT.
const SETTLEMENT_SLOPE_CLIFF: float = 0.12
## Minimum flatness fitness for a townable peak.
const SETTLEMENT_FLATNESS_FLOOR: float = 0.35

static var NEIGHBOR_DX: PackedInt32Array = PackedInt32Array([1, 1, 0, -1, -1, -1, 0, 1])
static var NEIGHBOR_DZ: PackedInt32Array = PackedInt32Array([0, 1, 1, 1, 0, -1, -1, -1])

var schema_version: int = SCHEMA_VERSION
var world_seed: int = 0
var size: int = SIZE
var content_hash: int = 0
var sea_surface_z: int = SEA_SURFACE_Z

var cells: PackedInt32Array = PackedInt32Array()
var landmass_id: PackedInt32Array = PackedInt32Array()
var lake_id: PackedInt32Array = PackedInt32Array()

var lakes: Array[AtlasLake] = []
var nodes: Array[AtlasGraphNode] = []
var crossings: Array[AtlasCrossing] = []
## Primary road MST edges as pairs of node ids (for backbone validation).
var primary_road_edges: Array[Vector2i] = []

## edge_key -> Array[AtlasPort]
var river_ports: Dictionary = {}
var road_ports: Dictionary = {}
## cell index -> Array[AtlasLink]
var river_links: Dictionary = {}
var road_links: Dictionary = {}
## Land cell -> downhill receiver cell index (-1 when flowing into ocean/lake).
var river_receiver: PackedInt32Array = PackedInt32Array()
## Ring distance to nearest river mouth (0 on mouth, -1 outside hinterland).
## Filled during [_seed_population]; used by village tier classification.
var mouth_distance: PackedInt32Array = PackedInt32Array()

var generate_ms: int = 0
## Scratch while [_build_roads] runs; not part of the published atlas.
var _road_channel_mask: PackedByteArray = PackedByteArray()
var _road_native: RefCounted = null


static func generate(p_world_seed: int, p_size: int = SIZE) -> ContinentAtlas:
	var atlas: ContinentAtlas = ContinentAtlas.new()
	atlas.world_seed = p_world_seed
	atlas.size = p_size
	var t0: int = Time.get_ticks_msec()
	atlas._build()
	atlas.generate_ms = Time.get_ticks_msec() - t0
	atlas.content_hash = atlas._compute_hash()
	return atlas


func index_of(ax: int, az: int) -> int:
	return az * size + ax


func in_bounds(ax: int, az: int) -> bool:
	return ax >= 0 and az >= 0 and ax < size and az < size


func cell_at(ax: int, az: int) -> int:
	return cells[index_of(ax, az)]


func is_ocean(ax: int, az: int) -> bool:
	return AtlasPack.biome(cell_at(ax, az)) == AtlasBiomes.Id.OCEAN


func is_lake(ax: int, az: int) -> bool:
	return AtlasPack.biome(cell_at(ax, az)) == AtlasBiomes.Id.LAKE


func ports_on_edge(ax: int, az: int, dir: int, kind: int) -> Array:
	var key: int = AtlasFeatures.edge_key(ax, az, dir, size)
	var store: Dictionary = river_ports if kind == AtlasFeatures.Kind.RIVER else road_ports
	if not store.has(key):
		return []
	return store[key]


func links_in_cell(ax: int, az: int, kind: int) -> Array:
	var idx: int = index_of(ax, az)
	var store: Dictionary = river_links if kind == AtlasFeatures.Kind.RIVER else road_links
	if not store.has(idx):
		return []
	return store[idx]


func continental_centre(ax: int, az: int) -> Vector2:
	return Vector2((float(ax) + 0.5) * CELL_METRES, (float(az) + 0.5) * CELL_METRES)


func port_continental_pos(ax: int, az: int, dir: int, t: float) -> Vector2:
	var x0: float = float(ax) * CELL_METRES
	var z0: float = float(az) * CELL_METRES
	var tt: float = clampf(t, 0.15, 0.85)
	match dir:
		AtlasFeatures.Dir.EAST:
			return Vector2(x0 + CELL_METRES, z0 + tt * CELL_METRES)
		AtlasFeatures.Dir.WEST:
			return Vector2(x0, z0 + tt * CELL_METRES)
		AtlasFeatures.Dir.SOUTH:
			return Vector2(x0 + tt * CELL_METRES, z0 + CELL_METRES)
		AtlasFeatures.Dir.NORTH:
			return Vector2(x0 + tt * CELL_METRES, z0)
	return continental_centre(ax, az)


## Empty array means all invariants hold.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if schema_version != SCHEMA_VERSION:
		errors.append("schema_version mismatch")
	if cells.size() != size * size:
		errors.append("cells size wrong")
		return errors

	var ocean_border: int = 0
	var border_total: int = 0
	var land_count: int = 0
	var collar: int = _collar_cells()
	for az in size:
		for ax in size:
			var biome: int = AtlasPack.biome(cell_at(ax, az))
			if AtlasBiomes.is_land(biome) or biome == AtlasBiomes.Id.LAKE:
				land_count += 1
			var on_border: bool = (
				ax < collar or az < collar
				or ax >= size - collar or az >= size - collar
			)
			if on_border:
				border_total += 1
				if biome == AtlasBiomes.Id.OCEAN:
					ocean_border += 1

	if land_count < size * size / 20:
		errors.append("too little land (%d cells)" % land_count)
	if border_total > 0 and float(ocean_border) / float(border_total) < 0.7:
		errors.append(
			"ocean collar weak (%.0f%% ocean on border)" % [
				100.0 * float(ocean_border) / float(border_total)
			]
		)
	if lakes.is_empty():
		errors.append("no atlas lakes")

	for lake in lakes:
		if lake.spill_cell < 0:
			errors.append("lake %d has no spill" % lake.id)
		if not _lake_is_connected(lake):
			errors.append("lake %d is not contiguous" % lake.id)
		if _lake_touches_ocean(lake):
			errors.append("lake %d touches ocean instead of being ocean" % lake.id)

	errors.append_array(_validate_edge_agreement(AtlasFeatures.Kind.RIVER, river_ports))
	errors.append_array(_validate_edge_agreement(AtlasFeatures.Kind.ROAD, road_ports))
	errors.append_array(_validate_river_termination())
	errors.append_array(_validate_river_monotonicity())
	errors.append_array(_validate_road_backbone())
	errors.append_array(_validate_population())
	return errors


func _validate_population() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var land: int = 0
	var occupied: int = 0
	var water_occupied: int = 0
	for i in cells.size():
		var pop: int = AtlasPack.population(cells[i])
		if AtlasBiomes.is_land(AtlasPack.biome(cells[i])):
			land += 1
			if pop > 0:
				occupied += 1
		elif pop > 0:
			water_occupied += 1

	if water_occupied > 0:
		errors.append("population on %d water cells" % water_occupied)
	if land == 0:
		return errors
	if occupied == 0:
		errors.append("no populated land cells")
	# Occupancy is meant to be sparse peaks, not a field painted over the map.
	if float(occupied) / float(land) > 0.5:
		errors.append(
			"population not sparse (%.0f%% of land occupied)" % [
				100.0 * float(occupied) / float(land)
			]
		)
	return errors


func _validate_edge_agreement(kind: int, store: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	# Every stored east/south edge is canonical; walk cells and compare lookups
	# from both sides via ports_on_edge.
	for az in size:
		for ax in range(size - 1):
			var a: Array = ports_on_edge(ax, az, AtlasFeatures.Dir.EAST, kind)
			var b: Array = ports_on_edge(ax + 1, az, AtlasFeatures.Dir.WEST, kind)
			if a.size() != b.size():
				errors.append(
					"%s east ports disagree at %d,%d (%d vs %d)" % [
						"river" if kind == AtlasFeatures.Kind.RIVER else "road",
						ax, az, a.size(), b.size()
					]
				)
				if errors.size() > 12:
					return errors
				continue
			for i in a.size():
				var pa: AtlasPort = a[i]
				var pb: AtlasPort = b[i]
				if absf(pa.t - pb.t) > 0.001 or pa.feature_class != pb.feature_class:
					errors.append("port payload mismatch at %d,%d east #%d" % [ax, az, i])
	for az in range(size - 1):
		for ax in size:
			var a: Array = ports_on_edge(ax, az, AtlasFeatures.Dir.SOUTH, kind)
			var b: Array = ports_on_edge(ax, az + 1, AtlasFeatures.Dir.NORTH, kind)
			if a.size() != b.size():
				errors.append(
					"%s south ports disagree at %d,%d (%d vs %d)" % [
						"river" if kind == AtlasFeatures.Kind.RIVER else "road",
						ax, az, a.size(), b.size()
					]
				)
				if errors.size() > 12:
					return errors
	return errors


func _validate_river_termination() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var port_used: Dictionary = {}
	var cells_with_sink_link: Dictionary = {}
	for cell_idx in river_links:
		for link_variant in river_links[cell_idx]:
			var link: AtlasLink = link_variant
			_mark_endpoint(port_used, link.a)
			_mark_endpoint(port_used, link.b)
			if (
				link.b.kind == AtlasFeatures.EndpointKind.OCEAN
				or link.b.kind == AtlasFeatures.EndpointKind.LAKE
			):
				cells_with_sink_link[int(cell_idx)] = true
			if (
				link.a.kind != AtlasFeatures.EndpointKind.OCEAN
				and link.a.kind != AtlasFeatures.EndpointKind.LAKE
				and link.b.kind != AtlasFeatures.EndpointKind.OCEAN
				and link.b.kind != AtlasFeatures.EndpointKind.LAKE
				and link.a.kind != AtlasFeatures.EndpointKind.EDGE_PORT
				and link.b.kind != AtlasFeatures.EndpointKind.EDGE_PORT
				and link.a.kind != AtlasFeatures.EndpointKind.NODE
			):
				errors.append("river link without edge/terminal in cell %d" % cell_idx)

	for key in river_ports:
		var ports: Array = river_ports[key]
		for port_variant in ports:
			var port: AtlasPort = port_variant
			var mark: String = "%d:%d" % [key, port.id]
			if not port_used.has(mark):
				errors.append("dangling river port %s" % mark)
				if errors.size() > 20:
					return errors

	# Every cell that participates in the river graph must drain to ocean/lake
	# along river_receiver without vanishing on dry land.
	if river_receiver.size() == cells.size():
		for cell_idx in river_links:
			var idx: int = int(cell_idx)
			var guard: int = 0
			var walk: int = idx
			var seen: Dictionary = {}
			var reached: bool = false
			while walk >= 0 and guard < size * size:
				guard += 1
				if seen.has(walk):
					break
				seen[walk] = true
				var biome: int = AtlasPack.biome(cells[walk])
				if biome == AtlasBiomes.Id.OCEAN or biome == AtlasBiomes.Id.LAKE:
					reached = true
					break
				if cells_with_sink_link.has(walk):
					reached = true
					break
				var nxt: int = river_receiver[walk]
				if nxt < 0:
					var nb_biome: int = _receiver_sink_biome(walk)
					reached = (
						nb_biome == AtlasBiomes.Id.OCEAN
						or nb_biome == AtlasBiomes.Id.LAKE
					)
					break
				var nxt_biome: int = AtlasPack.biome(cells[nxt])
				if (
					nxt_biome == AtlasBiomes.Id.OCEAN
					or nxt_biome == AtlasBiomes.Id.LAKE
				):
					reached = true
					break
				walk = nxt
			if not reached:
				errors.append("river vanishes at cell %d,%d" % [idx % size, idx / size])
				if errors.size() > 20:
					return errors
	return errors


func _receiver_sink_biome(cell: int) -> int:
	var ax: int = cell % size
	var az: int = cell / size
	for k in 4:
		var nx: int = ax + NEIGHBOR_DX[k * 2]
		var nz: int = az + NEIGHBOR_DZ[k * 2]
		if not in_bounds(nx, nz):
			continue
		var biome: int = AtlasPack.biome(cells[index_of(nx, nz)])
		if biome == AtlasBiomes.Id.OCEAN or biome == AtlasBiomes.Id.LAKE:
			return biome
	return AtlasBiomes.Id.PLAINS


func _validate_river_monotonicity() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if river_receiver.size() != cells.size():
		return errors
	for idx in cells.size():
		var biome: int = AtlasPack.biome(cells[idx])
		if not AtlasBiomes.is_land(biome):
			continue
		if not river_links.has(idx):
			continue
		var down: int = river_receiver[idx]
		if down < 0:
			continue
		var e0: int = AtlasPack.elevation(cells[idx])
		var down_biome: int = AtlasPack.biome(cells[down])
		if down_biome == AtlasBiomes.Id.OCEAN or down_biome == AtlasBiomes.Id.LAKE:
			continue
		var e1: int = AtlasPack.elevation(cells[down])
		if e1 > e0:
			errors.append(
				"river climbs %d,%d (%d) -> %d,%d (%d)" % [
					idx % size, idx / size, e0, down % size, down / size, e1
				]
			)
			if errors.size() > 20:
				return errors
	return errors


func _mark_endpoint(used: Dictionary, endpoint: AtlasEndpoint) -> void:
	if endpoint.kind == AtlasFeatures.EndpointKind.EDGE_PORT:
		used["%d:%d" % [endpoint.ref_id, endpoint.port_id]] = true


func _validate_road_backbone() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if nodes.is_empty():
		errors.append("no road nodes")
		return errors

	var by_mass: Dictionary = {}
	for node in nodes:
		if not by_mass.has(node.landmass):
			by_mass[node.landmass] = []
		by_mass[node.landmass].append(node.id)

	for mass in by_mass:
		var ids: Array = by_mass[mass]
		if ids.size() < 2:
			continue
		var parent: Dictionary = {}
		for id_variant in ids:
			parent[int(id_variant)] = int(id_variant)
		for edge in primary_road_edges:
			if parent.has(edge.x) and parent.has(edge.y):
				_uf_union(parent, edge.x, edge.y)
		var root: int = _uf_find(parent, int(ids[0]))
		var connected: int = 0
		for id_variant in ids:
			if _uf_find(parent, int(id_variant)) == root:
				connected += 1
		if connected < ids.size():
			errors.append(
				"landmass %d primary roads not connected (%d of %d)" % [
					mass, connected, ids.size()
				]
			)

	# Coverage floors so the backbone cannot silently starve to a couple of stubs.
	var min_nodes: int = maxi(8, size / 20)
	if nodes.size() < min_nodes:
		errors.append("too few road nodes (%d < %d)" % [nodes.size(), min_nodes])
	var expected_primary_edges: int = 0
	for mass in by_mass:
		var mass_n: int = (by_mass[mass] as Array).size()
		if mass_n >= 2:
			expected_primary_edges += mass_n - 1
	if primary_road_edges.size() < expected_primary_edges:
		errors.append(
			"primary road edges starved (%d edges, need %d)" % [
				primary_road_edges.size(), expected_primary_edges
			]
		)
	var min_road_cells: int = maxi(24, nodes.size() * 4)
	if road_links.size() < min_road_cells:
		errors.append(
			"road cell coverage starved (%d cells < %d)" % [
				road_links.size(), min_road_cells
			]
		)
	var through_cells: int = 0
	for cell_idx in road_links:
		for link_variant in road_links[cell_idx]:
			var link: AtlasLink = link_variant
			if (
				link.a.kind == AtlasFeatures.EndpointKind.EDGE_PORT
				and link.b.kind == AtlasFeatures.EndpointKind.EDGE_PORT
				and link.a.ref_id != link.b.ref_id
			):
				through_cells += 1
				break
	if through_cells < maxi(8, min_road_cells / 2):
		errors.append(
			"road through-links starved (%d cells with distinct edge ports)" % through_cells
		)
	return errors


func _uf_find(parent: Dictionary, x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]
		x = parent[x]
	return x


func _uf_union(parent: Dictionary, a: int, b: int) -> void:
	if not parent.has(a) or not parent.has(b):
		return
	var ra: int = _uf_find(parent, a)
	var rb: int = _uf_find(parent, b)
	if ra != rb:
		parent[rb] = ra


# --- Generation ---------------------------------------------------------------

func _build() -> void:
	var count: int = size * size
	cells.resize(count)
	landmass_id.resize(count)
	lake_id.resize(count)
	for i in count:
		lake_id[i] = -1
		landmass_id[i] = -1

	var elev_code: PackedByteArray = PackedByteArray()
	elev_code.resize(count)
	var humidity: PackedByteArray = PackedByteArray()
	humidity.resize(count)
	var relief: PackedByteArray = PackedByteArray()
	relief.resize(count)
	var land: PackedByteArray = PackedByteArray()
	land.resize(count)

	_build_landmask_elevation(land, elev_code, humidity, relief)
	# Continental mountain belts (Alps-scale orogens). Landmask noise alone almost
	# never reaches mountain codes; these arcs force a readable high spine with
	# foothills and passes before lakes/rivers solve drainage.
	_apply_orogens(land, elev_code, humidity, relief)
	_build_lakes(land, elev_code)
	_merge_coastal_lakes_into_ocean(land, elev_code)
	_label_landmasses(land)
	_classify_and_pack(land, elev_code, humidity, relief)
	# Rivers first: mouths are the strongest settlement signal, and nodes should
	# be placed once population is known so roads serve towns, not random dots.
	_build_rivers(elev_code)
	_seed_population()
	_seed_nodes()
	_build_roads(elev_code)
	_find_crossings()


func _layer_seed(name: String) -> int:
	return int(hash(str(world_seed) + ":" + name))


func _make_noise(seed_name: String, frequency: float, fractal: int, octaves: int) -> FastNoiseLite:
	var n: FastNoiseLite = FastNoiseLite.new()
	n.seed = _layer_seed(seed_name)
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = fractal
	n.fractal_octaves = octaves
	n.frequency = frequency
	return n


func _build_landmask_elevation(
	land: PackedByteArray,
	elev_code: PackedByteArray,
	humidity: PackedByteArray,
	relief: PackedByteArray
) -> void:
	assert(
		ClassDB.class_exists("OrrunGen"),
		"OrrunGen is required for ContinentAtlas.atlas_landmask"
	)
	var native: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
	var params: Dictionary = {
		"size": size,
		"seed_continent": _layer_seed("atlas_continent"),
		"seed_coast_cut": _layer_seed("atlas_coast_cut"),
		"seed_peninsula": _layer_seed("atlas_peninsula"),
		"seed_mountain": _layer_seed("atlas_mountain"),
		"seed_moist": _layer_seed("atlas_moist"),
		"seed_relief": _layer_seed("atlas_relief"),
		"seed_warp": _layer_seed("atlas_warp"),
		"seed_warp2": _layer_seed("atlas_warp2"),
	}
	var result: Variant = native.call("atlas_landmask", params)
	assert(
		typeof(result) == TYPE_DICTIONARY,
		"OrrunGen.atlas_landmask failed: %s" % [result]
	)
	var dict: Dictionary = result
	var land_src: PackedByteArray = dict["land"]
	var elev_src: PackedByteArray = dict["elev_code"]
	var hum_src: PackedByteArray = dict["humidity"]
	var rel_src: PackedByteArray = dict["relief"]
	var count: int = size * size
	assert(
		land_src.size() == count
		and elev_src.size() == count
		and hum_src.size() == count
		and rel_src.size() == count,
		"OrrunGen.atlas_landmask size mismatch: got %d want %d"
		% [land_src.size(), count]
	)
	for i in count:
		land[i] = land_src[i]
		elev_code[i] = elev_src[i]
		humidity[i] = hum_src[i]
		relief[i] = rel_src[i]


func _collar_cells() -> int:
	return maxi(6, OCEAN_COLLAR_FULL * size / SIZE)


## Raise land along 1–2 crescent mountain belts. Distances are in atlas cells
## (1 km). Widths scale with [member size] so a 256 km preview still gets one
## clear range, and a 1000 km continent gets Alps-like breadth.
func _apply_orogens(
	land: PackedByteArray,
	elev_code: PackedByteArray,
	humidity: PackedByteArray,
	relief: PackedByteArray
) -> void:
	var count: int = size * size
	var dist: PackedFloat32Array = PackedFloat32Array()
	dist.resize(count)
	var pass_field: PackedFloat32Array = PackedFloat32Array()
	pass_field.resize(count)
	for i in count:
		dist[i] = INF
		pass_field[i] = 0.0

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _layer_seed("atlas_orogens")
	var belt_count: int = 1 if size < 500 else 2
	for belt in belt_count:
		_stamp_orogen_arc(dist, pass_field, rng, belt)

	# Narrow high core, tighter foothills — steeper flanks over fewer kilometres.
	var core_r: float = maxf(6.0, float(size) * 0.024)
	var near_r: float = maxf(12.0, float(size) * 0.045)
	var foot_r: float = maxf(22.0, float(size) * 0.085)
	# Kilometre massifs / valleys / needles. Distance loft alone leaves a flat
	# plateau; mountains must register as neighbouring atlas cells with large
	# elevation swings or the 3D world has nothing steep to interpret.
	var massif_n: FastNoiseLite = _make_noise(
		"atlas_orogen_massif", 0.085, FastNoiseLite.FRACTAL_RIDGED, 4
	)
	var valley_n: FastNoiseLite = _make_noise(
		"atlas_orogen_valley", 0.05, FastNoiseLite.FRACTAL_FBM, 3
	)
	var peak_n: FastNoiseLite = _make_noise(
		"atlas_orogen_crest", 0.16, FastNoiseLite.FRACTAL_RIDGED, 3
	)

	for i in count:
		if land[i] == 0:
			continue
		var d: float = dist[i]
		if d >= foot_r:
			continue
		var pass_u: float = clampf(pass_field[i], 0.0, 1.0)
		# Passes pull the target down toward foothills so rivers can cross.
		var loft: float = 0.0
		if d < core_r:
			loft = lerpf(0.78, 1.0, 1.0 - d / core_r)
		elif d < near_r:
			loft = lerpf(
				0.48, 0.78,
				1.0 - (d - core_r) / maxf(near_r - core_r, 0.001)
			)
		else:
			loft = lerpf(
				0.10, 0.48,
				1.0 - (d - near_r) / maxf(foot_r - near_r, 0.001)
			)

		loft = lerpf(loft, loft * 0.28, pass_u)

		var cx: float = float(i % size)
		var cz: float = float(i / size)
		var massif: float = massif_n.get_noise_2d(cx, cz) * 0.5 + 0.5
		massif = pow(massif, 1.28)
		var dissect: float = valley_n.get_noise_2d(cz * 1.15, cx * 0.92)
		var needle: float = peak_n.get_noise_2d(cx * 1.35, cz * 1.35) * 0.5 + 0.5
		needle = pow(needle, 1.65)

		# Along-range relief: ridges up, dissected valleys down. Stronger toward
		# the core so foothills stay coherent for drainage.
		var belt_w: float = smoothstep(0.08, 0.55, loft)
		var undulation: float = (massif - 0.48) * 0.50 + dissect * 0.20
		var loft_h: float = clampf(loft + undulation * belt_w, 0.05, 1.25)

		# Map loft → elevation codes with a wide mountain band so neighbouring
		# cells can differ by hundreds of metres.
		var code_f: float = lerpf(118.0, 168.0, clampf(loft_h / 0.45, 0.0, 1.0))
		if loft_h > 0.45:
			code_f = lerpf(168.0, 208.0, clampf((loft_h - 0.45) / 0.28, 0.0, 1.0))
		if loft_h > 0.70:
			var peak_t: float = (
				clampf((loft_h - 0.70) / 0.40, 0.0, 1.0) * needle * lerpf(0.55, 1.0, massif)
			)
			code_f = lerpf(208.0, 252.0, peak_t)

		# Extra incision where valley noise is low and we are off the massif crest.
		if loft > 0.35:
			var incision: float = (
				(1.0 - massif)
				* smoothstep(0.10, -0.45, dissect)
				* lerpf(6.0, 48.0, loft)
			)
			code_f -= incision

		var target: int = clampi(int(code_f), 33, 255)
		if target > int(elev_code[i]):
			elev_code[i] = target

		var variance: float = absf(undulation) * belt_w + needle * loft
		var rel_boost: int = clampi(
			int(
				lerpf(12.0, 58.0, loft) * (1.0 - pass_u * 0.55)
				+ variance * 18.0
			),
			0, 63
		)
		relief[i] = maxi(int(relief[i]), rel_boost)
		var dry: float = lerpf(1.0, 0.55, loft * (1.0 - pass_u * 0.45))
		humidity[i] = clampi(int(float(humidity[i]) * dry), 0, 255)


func _stamp_orogen_arc(
	dist: PackedFloat32Array,
	pass_field: PackedFloat32Array,
	rng: RandomNumberGenerator,
	belt: int
) -> void:
	var collar: float = float(_collar_cells()) + 4.0
	var cx: float = lerpf(float(size) * 0.38, float(size) * 0.62, rng.randf())
	var cz: float = lerpf(float(size) * 0.38, float(size) * 0.62, rng.randf())
	# Second belt offsets so belts don't sit on top of each other.
	if belt > 0:
		cx = clampf(cx + float(size) * lerpf(-0.18, 0.18, rng.randf()), collar, float(size) - collar)
		cz = clampf(cz + float(size) * lerpf(-0.18, 0.18, rng.randf()), collar, float(size) - collar)
	var radius: float = float(size) * lerpf(0.32, 0.44, rng.randf())
	var angle0: float = rng.randf() * TAU
	var span: float = lerpf(PI * 0.70, PI * 1.05, rng.randf())
	var steps: int = maxi(32, int(radius * span * 1.15))
	var foot_r: float = maxf(22.0, float(size) * 0.085)
	var pass_n: FastNoiseLite = _make_noise(
		"atlas_orogen_pass_%d" % belt, 0.11, FastNoiseLite.FRACTAL_FBM, 2
	)
	var warp_n: FastNoiseLite = _make_noise(
		"atlas_orogen_warp_%d" % belt, 0.03, FastNoiseLite.FRACTAL_FBM, 3
	)

	var prev: Vector2 = Vector2.INF
	for s in range(steps + 1):
		var u: float = float(s) / float(steps)
		var ang: float = angle0 + span * u
		var rad: float = radius * (
			1.0 + warp_n.get_noise_2d(ang * 3.0, float(belt) * 7.0) * 0.08
		)
		var px: float = cx + cos(ang) * rad
		var pz: float = cz + sin(ang) * rad
		px = clampf(px, collar, float(size) - 1.0 - collar)
		pz = clampf(pz, collar, float(size) - 1.0 - collar)
		var p: Vector2 = Vector2(px, pz)
		# Sparse high passes along the crest (not a solid wall).
		var pass_amt: float = 0.0
		var pn: float = pass_n.get_noise_2d(u * 40.0, float(belt) * 11.0)
		if pn > 0.28:
			pass_amt = smoothstep(0.28, 0.72, pn)
		if prev != Vector2.INF:
			_stamp_orogen_segment(dist, pass_field, prev, p, foot_r, pass_amt)
		prev = p


func _stamp_orogen_segment(
	dist: PackedFloat32Array,
	pass_field: PackedFloat32Array,
	a: Vector2,
	b: Vector2,
	foot_r: float,
	pass_amt: float
) -> void:
	var pad: float = foot_r + 2.0
	var min_x: int = clampi(floori(minf(a.x, b.x) - pad), 0, size - 1)
	var max_x: int = clampi(ceili(maxf(a.x, b.x) + pad), 0, size - 1)
	var min_z: int = clampi(floori(minf(a.y, b.y) - pad), 0, size - 1)
	var max_z: int = clampi(ceili(maxf(a.y, b.y) + pad), 0, size - 1)
	var ab: Vector2 = b - a
	var ab_len_sq: float = ab.length_squared()
	for az in range(min_z, max_z + 1):
		for ax in range(min_x, max_x + 1):
			var p: Vector2 = Vector2(float(ax) + 0.5, float(az) + 0.5)
			var t: float = 0.0
			if ab_len_sq > 0.0001:
				t = clampf((p - a).dot(ab) / ab_len_sq, 0.0, 1.0)
			var closest: Vector2 = a + ab * t
			var d: float = p.distance_to(closest)
			if d > foot_r + 1.0:
				continue
			var idx: int = index_of(ax, az)
			if d < dist[idx]:
				dist[idx] = d
			if pass_amt > 0.0:
				# Pass influence is strongest on the crest and fades with distance.
				var crest_w: float = 1.0 - clampf(d / maxf(foot_r * 0.45, 1.0), 0.0, 1.0)
				pass_field[idx] = maxf(pass_field[idx], pass_amt * crest_w)


func _lake_max_cells() -> int:
	# Scale with map area; keep room for both ponds and inland seas on previews.
	return clampi(size * size / 90, 48, LAKE_MAX_CELLS_FULL)


## Place atlas lakes as irregular basins with real spill rims. A sloping
## continent with only a priority flood often has no closed depressions left,
## so we carve varied bowls and wire their outlets into the drainage.
func _build_lakes(land: PackedByteArray, elev_code: PackedByteArray) -> void:
	var want: int = maxi(4, 22 * size / SIZE)
	var collar: int = _collar_cells() + 4
	if collar >= size / 2:
		collar = maxi(2, size / 8)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _layer_seed("atlas_lake_seeds")
	var step: int = maxi(10, size / maxi(want, 1))
	var ax: int = collar + step / 2
	while ax < size - collar and lakes.size() < want:
		var az: int = collar + step / 2
		while az < size - collar and lakes.size() < want:
			var jx: int = clampi(ax + rng.randi_range(-step / 3, step / 3), collar, size - collar - 1)
			var jz: int = clampi(az + rng.randi_range(-step / 3, step / 3), collar, size - collar - 1)
			_try_place_lake(jx, jz, land, elev_code, rng)
			az += step
		ax += step
	if lakes.size() < want:
		var scans: int = 0
		while lakes.size() < want and scans < size * 4:
			scans += 1
			_try_place_lake(
				rng.randi_range(collar, size - collar - 1),
				rng.randi_range(collar, size - collar - 1),
				land, elev_code, rng
			)


func _try_place_lake(
	ax: int,
	az: int,
	land: PackedByteArray,
	elev_code: PackedByteArray,
	rng: RandomNumberGenerator
) -> void:
	if not in_bounds(ax, az):
		return
	var idx: int = index_of(ax, az)
	if land[idx] == 0 or lake_id[idx] >= 0:
		return
	# Prefer local lows so basins sit in natural hollows.
	if not _is_local_low(ax, az, elev_code, land):
		if rng.randf() > 0.35:
			return

	var max_cells: int = _lake_max_cells()
	# Log-ish mix: many small ponds, occasional large inland lakes.
	var t: float = pow(rng.randf(), 2.2)
	var lo: int = LAKE_MIN_CELLS
	var hi: int = max_cells
	var target: int = clampi(int(lerpf(float(lo), float(hi), t)), lo, hi)
	var scale: float = float(maxi(size, 64)) / 96.0
	var rx: float = rng.randf_range(1.2, 7.5) * scale * lerpf(0.55, 1.4, t)
	var rz: float = rng.randf_range(1.2, 7.5) * scale * lerpf(0.55, 1.4, t)
	# Large lakes must not become near-circular inland discs. Always stretch the
	# upper size range; smaller lakes vary between round ponds and long basins.
	if t > 0.30 or rng.randf() < 0.4:
		if rng.randf() < 0.5:
			rx *= rng.randf_range(1.8, 3.2)
			rz *= rng.randf_range(0.30, 0.65)
		else:
			rz *= rng.randf_range(1.8, 3.2)
			rx *= rng.randf_range(0.30, 0.65)
	var rot: float = rng.randf() * TAU
	var cos_r: float = cos(rot)
	var sin_r: float = sin(rot)
	var noise: FastNoiseLite = _make_noise(
		"atlas_lake_shape_%d_%d" % [ax, az], 0.35, FastNoiseLite.FRACTAL_NONE, 1
	)
	var depth_carve: int = rng.randi_range(3, 14)

	var basin: PackedInt32Array = PackedInt32Array()
	var span: int = int(ceili(maxi(rx, rz) * 1.6)) + 2
	for dz in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var nx: int = ax + dx
			var nz: int = az + dz
			if not in_bounds(nx, nz):
				continue
			var nb: int = index_of(nx, nz)
			if land[nb] == 0 or lake_id[nb] >= 0:
				continue
			var lx: float = float(dx) * cos_r + float(dz) * sin_r
			var lz: float = float(-dx) * sin_r + float(dz) * cos_r
			var ellipse: float = (lx * lx) / (rx * rx) + (lz * lz) / (rz * rz)
			ellipse += noise.get_noise_2d(float(nx), float(nz)) * 0.45
			if ellipse <= 1.0:
				basin.append(nb)

	# Grow/shrink toward the target with a cheap elevation-biased flood so lakes
	# are not identical stamped ellipses.
	if basin.size() < target:
		_grow_lake_basin(basin, target, land, elev_code, int(elev_code[idx]) + depth_carve)
	elif basin.size() > target:
		basin = _trim_lake_basin(
			basin, target, ax, az, rx, rz, cos_r, sin_r, noise
		)
		if basin.size() < target:
			_grow_lake_basin(
				basin, target, land, elev_code, int(elev_code[idx]) + depth_carve
			)

	if basin.size() < LAKE_MIN_CELLS or basin.size() > max_cells:
		return

	var spill_cell: int = -1
	var spill_out: int = -1
	var rim_min: int = 999
	for cell in basin:
		var cx: int = cell % size
		var cz: int = cell / size
		for k in 4:
			var nx: int = cx + NEIGHBOR_DX[k * 2]
			var nz: int = cz + NEIGHBOR_DZ[k * 2]
			if not in_bounds(nx, nz):
				continue
			var nb: int = index_of(nx, nz)
			if land[nb] == 0:
				# Ocean-touching basin: spill straight to sea.
				if int(elev_code[nb]) < rim_min:
					rim_min = int(elev_code[nb])
					spill_cell = cell
					spill_out = nb
				continue
			if lake_id[nb] >= 0:
				continue
			var in_basin: bool = false
			for b in basin:
				if b == nb:
					in_basin = true
					break
			if in_basin:
				continue
			var ne: int = int(elev_code[nb])
			if ne < rim_min:
				rim_min = ne
				spill_cell = cell
				spill_out = nb

	if spill_cell < 0:
		spill_cell = basin[0]
		rim_min = int(elev_code[idx]) + 6
	var surface_code: int = clampi(rim_min - 1, 34, 250)
	var lake: AtlasLake = AtlasLake.new()
	lake.id = lakes.size()
	lake.cells = basin
	lake.spill_cell = spill_cell
	lake.surface_code = surface_code
	lake.surface_z = AtlasPack.elevation_to_metres(surface_code)
	lakes.append(lake)
	for cell in basin:
		lake_id[cell] = lake.id
		# Flat lake bed below the spill; deepest near the seed.
		var cx: int = cell % size
		var cz: int = cell / size
		var dist: float = sqrt(float((cx - ax) * (cx - ax) + (cz - az) * (cz - az)))
		var bed: int = surface_code - 2 - clampi(int(depth_carve - dist), 0, depth_carve)
		elev_code[cell] = clampi(bed, 33, surface_code - 1)
	# Notch the spill outlet slightly so drainage prefers the lake mouth.
	if spill_out >= 0 and land[spill_out] != 0 and lake_id[spill_out] < 0:
		elev_code[spill_out] = clampi(
			mini(int(elev_code[spill_out]), surface_code + 1), 33, 255
		)


func _is_local_low(
	ax: int, az: int, elev_code: PackedByteArray, land: PackedByteArray
) -> bool:
	var e: int = int(elev_code[index_of(ax, az)])
	var lower_or_eq: int = 0
	for k in 8:
		var nx: int = ax + NEIGHBOR_DX[k]
		var nz: int = az + NEIGHBOR_DZ[k]
		if not in_bounds(nx, nz):
			continue
		var nb: int = index_of(nx, nz)
		if land[nb] == 0:
			continue
		if int(elev_code[nb]) <= e:
			lower_or_eq += 1
	return lower_or_eq <= 2


func _grow_lake_basin(
	basin: PackedInt32Array,
	target: int,
	land: PackedByteArray,
	elev_code: PackedByteArray,
	max_elev: int
) -> void:
	var in_basin: Dictionary = {}
	for cell in basin:
		in_basin[cell] = true
	var guard: int = 0
	while basin.size() < target and guard < target * 8:
		guard += 1
		var best: int = -1
		var best_e: int = 999
		for cell in basin:
			var cx: int = cell % size
			var cz: int = cell / size
			for k in 4:
				var nx: int = cx + NEIGHBOR_DX[k * 2]
				var nz: int = cz + NEIGHBOR_DZ[k * 2]
				if not in_bounds(nx, nz):
					continue
				var nb: int = index_of(nx, nz)
				if in_basin.has(nb) or land[nb] == 0 or lake_id[nb] >= 0:
					continue
				var ne: int = int(elev_code[nb])
				if ne > max_elev:
					continue
				if ne < best_e:
					best_e = ne
					best = nb
		if best < 0:
			break
		basin.append(best)
		in_basin[best] = true


func _trim_lake_basin(
	basin: PackedInt32Array,
	target: int,
	ax: int,
	az: int,
	rx: float,
	rz: float,
	cos_r: float,
	sin_r: float,
	noise: FastNoiseLite
) -> PackedInt32Array:
	var allowed: PackedByteArray = PackedByteArray()
	allowed.resize(size * size)
	var state: PackedByteArray = PackedByteArray()
	state.resize(size * size)
	for cell in basin:
		allowed[cell] = 1

	var start: int = index_of(ax, az)
	if allowed[start] == 0:
		var nearest_d2: int = 0x7fffffff
		for cell in basin:
			var cx: int = cell % size
			var cz: int = cell / size
			var d2: int = (cx - ax) * (cx - ax) + (cz - az) * (cz - az)
			if d2 < nearest_d2:
				nearest_d2 = d2
				start = cell

	var frontier: PackedInt32Array = PackedInt32Array([start])
	state[start] = 1
	var kept: PackedInt32Array = PackedInt32Array()
	var phase: float = float(posmod(int(hash("%d:%d" % [ax, az])), 1000)) / 1000.0 * TAU
	while not frontier.is_empty() and kept.size() < target:
		var best_frontier_i: int = 0
		var best_score: float = 1.0e12
		for i in frontier.size():
			var candidate: int = frontier[i]
			var score: float = _lake_trim_score(
				candidate, ax, az, rx, rz, cos_r, sin_r, noise, phase
			)
			if score < best_score:
				best_score = score
				best_frontier_i = i
		var cell: int = frontier[best_frontier_i]
		frontier.remove_at(best_frontier_i)
		state[cell] = 2
		kept.append(cell)
		var cx: int = cell % size
		var cz: int = cell / size
		for k in 4:
			var nx: int = cx + NEIGHBOR_DX[k * 2]
			var nz: int = cz + NEIGHBOR_DZ[k * 2]
			if not in_bounds(nx, nz):
				continue
			var nb: int = index_of(nx, nz)
			if allowed[nb] == 0 or state[nb] != 0:
				continue
			state[nb] = 1
			frontier.append(nb)
	return kept


func _lake_trim_score(
	cell: int,
	ax: int,
	az: int,
	rx: float,
	rz: float,
	cos_r: float,
	sin_r: float,
	noise: FastNoiseLite,
	phase: float
) -> float:
	var cx: int = cell % size
	var cz: int = cell / size
	var dx: float = float(cx - ax)
	var dz: float = float(cz - az)
	var lx: float = dx * cos_r + dz * sin_r
	var lz: float = -dx * sin_r + dz * cos_r
	var ellipse: float = (lx * lx) / (rx * rx) + (lz * lz) / (rz * rz)
	var shore_noise: float = noise.get_noise_2d(float(cx), float(cz)) * 0.48
	var lobes: float = sin(atan2(lz, lx) * 3.0 + phase) * 0.16
	return ellipse + shore_noise + lobes


func _lake_is_connected(lake: AtlasLake) -> bool:
	if lake.cells.is_empty():
		return false
	var membership: PackedByteArray = PackedByteArray()
	membership.resize(size * size)
	for cell in lake.cells:
		membership[cell] = 1
	var queue: PackedInt32Array = PackedInt32Array([lake.cells[0]])
	membership[lake.cells[0]] = 2
	var head: int = 0
	while head < queue.size():
		var cell: int = queue[head]
		head += 1
		var ax: int = cell % size
		var az: int = cell / size
		for k in 4:
			var nx: int = ax + NEIGHBOR_DX[k * 2]
			var nz: int = az + NEIGHBOR_DZ[k * 2]
			if not in_bounds(nx, nz):
				continue
			var nb: int = index_of(nx, nz)
			if membership[nb] != 1:
				continue
			membership[nb] = 2
			queue.append(nb)
	return queue.size() == lake.cells.size()


func _lake_touches_ocean(lake: AtlasLake) -> bool:
	for cell in lake.cells:
		var ax: int = cell % size
		var az: int = cell / size
		for k in 4:
			var nx: int = ax + NEIGHBOR_DX[k * 2]
			var nz: int = az + NEIGHBOR_DZ[k * 2]
			if not in_bounds(nx, nz):
				return true
			if AtlasPack.biome(cells[index_of(nx, nz)]) == AtlasBiomes.Id.OCEAN:
				return true
	return false


## Any lake connected to open sea is an inlet/loch and therefore part of the
## ocean datum. This runs before packing and graph generation, so no stale lake
## IDs or river terminals survive the conversion.
func _merge_coastal_lakes_into_ocean(
	land: PackedByteArray, elev_code: PackedByteArray
) -> void:
	if lakes.is_empty():
		return
	var coastal: PackedByteArray = PackedByteArray()
	coastal.resize(lakes.size())

	# Seed basins that directly touch existing ocean.
	for lake in lakes:
		for cell in lake.cells:
			var ax: int = cell % size
			var az: int = cell / size
			for k in 4:
				var nx: int = ax + NEIGHBOR_DX[k * 2]
				var nz: int = az + NEIGHBOR_DZ[k * 2]
				if not in_bounds(nx, nz):
					coastal[lake.id] = 1
					break
				var nb: int = index_of(nx, nz)
				if land[nb] == 0 and lake_id[nb] < 0:
					coastal[lake.id] = 1
					break
			if coastal[lake.id] != 0:
				break

	# Propagate through adjacent basins so all sea-connected water shares the
	# ocean classification, even if two generated basins happen to touch.
	var changed: bool = true
	while changed:
		changed = false
		for lake in lakes:
			if coastal[lake.id] != 0:
				continue
			for cell in lake.cells:
				var ax: int = cell % size
				var az: int = cell / size
				for k in 4:
					var nx: int = ax + NEIGHBOR_DX[k * 2]
					var nz: int = az + NEIGHBOR_DZ[k * 2]
					if not in_bounds(nx, nz):
						continue
					var other_id: int = lake_id[index_of(nx, nz)]
					if other_id >= 0 and other_id != lake.id and coastal[other_id] != 0:
						coastal[lake.id] = 1
						changed = true
						break
				if coastal[lake.id] != 0:
					break

	var kept: Array[AtlasLake] = []
	for lake in lakes:
		if coastal[lake.id] != 0:
			for cell in lake.cells:
				land[cell] = 0
				lake_id[cell] = -1
				elev_code[cell] = mini(int(elev_code[cell]), 32)
			continue
		lake.id = kept.size()
		for cell in lake.cells:
			lake_id[cell] = lake.id
		kept.append(lake)
	lakes = kept


func _label_landmasses(land: PackedByteArray) -> void:
	var count: int = size * size
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(count)
	var stack: PackedInt32Array = PackedInt32Array()
	var mass: int = 0
	for start in count:
		if land[start] == 0 or lake_id[start] >= 0 or seen[start] != 0:
			continue
		stack.clear()
		stack.append(start)
		seen[start] = 1
		var cells_in_mass: int = 0
		while not stack.is_empty():
			var cell: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			landmass_id[cell] = mass
			cells_in_mass += 1
			var cx: int = cell % size
			var cz: int = cell / size
			for k in 4:
				var nx: int = cx + NEIGHBOR_DX[k * 2]
				var nz: int = cz + NEIGHBOR_DZ[k * 2]
				if not in_bounds(nx, nz):
					continue
				var nb: int = index_of(nx, nz)
				if seen[nb] != 0 or land[nb] == 0 or lake_id[nb] >= 0:
					continue
				seen[nb] = 1
				stack.append(nb)
		if cells_in_mass > 0:
			mass += 1


func _classify_and_pack(
	land: PackedByteArray,
	elev_code: PackedByteArray,
	humidity: PackedByteArray,
	relief: PackedByteArray
) -> void:
	var temp_n: FastNoiseLite = _make_noise(
		"atlas_temp", 0.0025, FastNoiseLite.FRACTAL_FBM, 2
	)
	for az in size:
		for ax in size:
			var idx: int = index_of(ax, az)
			var biome: int = AtlasBiomes.Id.OCEAN
			if lake_id[idx] >= 0:
				biome = AtlasBiomes.Id.LAKE
				humidity[idx] = 255
				relief[idx] = 0
			elif land[idx] != 0:
				biome = _classify_land(
					ax, az, int(elev_code[idx]), int(humidity[idx]), int(relief[idx]), temp_n
				)
				if _touches_ocean(ax, az, land):
					biome = AtlasBiomes.Id.COAST
			else:
				humidity[idx] = 255
				relief[idx] = 0
			cells[idx] = AtlasPack.pack(
				int(elev_code[idx]), int(humidity[idx]), biome, int(relief[idx]), 0
			)


func _touches_ocean(ax: int, az: int, land: PackedByteArray) -> bool:
	for k in 4:
		var nx: int = ax + NEIGHBOR_DX[k * 2]
		var nz: int = az + NEIGHBOR_DZ[k * 2]
		if not in_bounds(nx, nz):
			return true
		if land[index_of(nx, nz)] == 0 and lake_id[index_of(nx, nz)] < 0:
			return true
	return false


func _classify_land(
	ax: int, az: int, elev: int, hum: int, rel: int, temp_n: FastNoiseLite
) -> int:
	var temp: float = temp_n.get_noise_2d(float(ax), float(az)) * 0.5 + 0.5
	temp = lerpf(temp, 0.15, float(az) / float(maxi(size - 1, 1)) * 0.35)
	if elev >= 181 or (elev >= 160 and rel > 28):
		return AtlasBiomes.Id.ALPINE
	if temp < 0.28 and elev > 60:
		return AtlasBiomes.Id.TUNDRA
	if hum < 90 and rel > 10:
		return AtlasBiomes.Id.ARID
	if hum > 170 and elev < 100:
		return AtlasBiomes.Id.WETLAND
	if hum > 130 and rel > 8:
		return AtlasBiomes.Id.FOREST
	return AtlasBiomes.Id.PLAINS


## Sparse land occupancy, seeded after rivers. Humidity decides whether land is
## habitable at all, river corridors concentrate it, and mouths into ocean/lake
## anchor the densest cores. Most land stays at 0.
func _seed_population() -> void:
	var count: int = size * size
	mouth_distance = _river_mouth_distances()
	var grain: FastNoiseLite = _make_noise(
		"atlas_population", 0.045, FastNoiseLite.FRACTAL_FBM, 3
	)
	var region: FastNoiseLite = _make_noise(
		"atlas_pop_region", 0.007, FastNoiseLite.FRACTAL_FBM, 3
	)

	for az in size:
		for ax in size:
			var idx: int = index_of(ax, az)
			var packed: int = cells[idx]
			var biome: int = AtlasPack.biome(packed)
			var pop: int = 0
			if AtlasBiomes.is_land(biome):
				var score: float = _population_score(
					ax, az, idx, packed, biome, mouth_distance[idx], grain, region
				)
				if score > POPULATION_THRESHOLD:
					var t: float = (score - POPULATION_THRESHOLD) / POPULATION_SCORE_SPAN
					pop = clampi(1 + int(t * 15.0), 1, 15)
			cells[idx] = AtlasPack.pack(
				AtlasPack.elevation(packed),
				AtlasPack.humidity(packed),
				biome,
				AtlasPack.relief(packed),
				pop
			)


## Mouth hinterland ring distance for a cell, or -1 when outside it.
func mouth_distance_at(ax: int, az: int) -> int:
	if not in_bounds(ax, az) or mouth_distance.is_empty():
		return -1
	return mouth_distance[index_of(ax, az)]


## Ring distance from each land cell to the nearest river mouth, capped at
## POPULATION_MOUTH_RADIUS. -1 means "outside the port hinterland".
func _river_mouth_distances() -> PackedInt32Array:
	var count: int = size * size
	var dist: PackedInt32Array = PackedInt32Array()
	dist.resize(count)
	for i in count:
		dist[i] = -1

	var frontier: PackedInt32Array = PackedInt32Array()
	for cell_variant in river_links:
		var cell: int = int(cell_variant)
		if not _cell_is_river_mouth(cell):
			continue
		dist[cell] = 0
		frontier.append(cell)

	var ring: int = 0
	while ring < POPULATION_MOUTH_RADIUS and frontier.size() > 0:
		var next: PackedInt32Array = PackedInt32Array()
		for cell in frontier:
			var cx: int = cell % size
			var cz: int = cell / size
			for k in 8:
				var nx: int = cx + NEIGHBOR_DX[k]
				var nz: int = cz + NEIGHBOR_DZ[k]
				if not in_bounds(nx, nz):
					continue
				var nb: int = index_of(nx, nz)
				if dist[nb] >= 0 or not AtlasBiomes.is_land(AtlasPack.biome(cells[nb])):
					continue
				dist[nb] = ring + 1
				next.append(nb)
		frontier = next
		ring += 1
	return dist


func _cell_is_river_mouth(cell: int) -> bool:
	for link_variant in river_links[cell]:
		var link: AtlasLink = link_variant
		if (
			link.b.kind == AtlasFeatures.EndpointKind.OCEAN
			or link.b.kind == AtlasFeatures.EndpointKind.LAKE
		):
			return true
	return false


func _population_score(
	ax: int,
	az: int,
	idx: int,
	packed: int,
	biome: int,
	mouth_dist: int,
	grain: FastNoiseLite,
	region: FastNoiseLite
) -> float:
	var humidity: float = float(AtlasPack.humidity(packed)) / 255.0
	var relief: float = float(AtlasPack.relief(packed)) / 63.0
	var elevation: int = AtlasPack.elevation(packed)
	var flatness: float = _flatness_fitness(ax, az)
	var slope: float = _local_slope(ax, az)

	var score: float = smoothstep(0.28, 0.78, humidity) * 0.5
	score -= relief * 0.65
	if elevation > 190:
		score -= 0.55
	elif elevation > 150:
		score -= 0.22

	match biome:
		AtlasBiomes.Id.ARID:
			score -= 0.4
		AtlasBiomes.Id.ALPINE:
			score -= 0.6
		AtlasBiomes.Id.TUNDRA:
			score -= 0.35
		AtlasBiomes.Id.WETLAND:
			score -= 0.1
		AtlasBiomes.Id.COAST:
			score += 0.14

	if river_links.has(idx):
		score += 0.38
	elif _touches_river(ax, az):
		score += 0.14

	if mouth_dist == 0:
		score += 0.9
	elif mouth_dist > 0:
		score += lerpf(0.55, 0.12, float(mouth_dist - 1) / float(POPULATION_MOUTH_RADIUS))

	# Regional bias keeps occupancy clustered; grain breaks ties inside a region.
	score += region.get_noise_2d(float(ax), float(az)) * 0.22
	score += grain.get_noise_2d(float(ax), float(az)) * 0.14
	# |∇h| fitness multiplies last so mouth/river bonuses cannot crown a steep bank
	# when a flatter neighbour scores higher.
	score *= lerpf(0.05, 1.0, flatness)
	if slope > SETTLEMENT_SLOPE_CLIFF:
		score *= 0.05
	return score


## Land elevation in metres, or NAN when out of bounds / not land.
func _land_elev_m(ax: int, az: int) -> float:
	if not in_bounds(ax, az):
		return NAN
	var packed: int = cells[index_of(ax, az)]
	if not AtlasBiomes.is_land(AtlasPack.biome(packed)):
		return NAN
	return float(AtlasPack.elevation_to_metres(AtlasPack.elevation(packed)))


## First-derivative magnitude |∇h| (rise/run) from atlas neighbour metres.
func _local_slope(ax: int, az: int) -> float:
	var h0: float = _land_elev_m(ax, az)
	if is_nan(h0):
		return SETTLEMENT_SLOPE_CLIFF + 1.0
	var hx_lo: float = _land_elev_m(ax - 1, az)
	var hx_hi: float = _land_elev_m(ax + 1, az)
	var hz_lo: float = _land_elev_m(ax, az - 1)
	var hz_hi: float = _land_elev_m(ax, az + 1)
	var gx: float = 0.0
	var gz: float = 0.0
	if not is_nan(hx_lo) and not is_nan(hx_hi):
		gx = (hx_hi - hx_lo) / (2.0 * CELL_METRES)
	elif not is_nan(hx_hi):
		gx = (hx_hi - h0) / CELL_METRES
	elif not is_nan(hx_lo):
		gx = (h0 - hx_lo) / CELL_METRES
	if not is_nan(hz_lo) and not is_nan(hz_hi):
		gz = (hz_hi - hz_lo) / (2.0 * CELL_METRES)
	elif not is_nan(hz_hi):
		gz = (hz_hi - h0) / CELL_METRES
	elif not is_nan(hz_lo):
		gz = (h0 - hz_lo) / CELL_METRES
	return sqrt(gx * gx + gz * gz)


## Continuous flatness: 1 / (1 + (s/s0)²). Best sites rank highest.
func _flatness_fitness(ax: int, az: int) -> float:
	var s: float = _local_slope(ax, az)
	var t: float = s / SETTLEMENT_SLOPE_REF
	return 1.0 / (1.0 + t * t)


func _cell_is_settlement_flat(ax: int, az: int) -> bool:
	return (
		_local_slope(ax, az) <= SETTLEMENT_SLOPE_CLIFF
		and _flatness_fitness(ax, az) >= SETTLEMENT_FLATNESS_FLOOR
	)


func _touches_river(ax: int, az: int) -> bool:
	for k in 8:
		var nx: int = ax + NEIGHBOR_DX[k]
		var nz: int = az + NEIGHBOR_DZ[k]
		if in_bounds(nx, nz) and river_links.has(index_of(nx, nz)):
			return true
	return false


func _seed_nodes() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _layer_seed("atlas_nodes")
	var target: int = clampi(maxi(PRIMARY_NODE_TARGET * size / SIZE, size / 10), 12, 96)
	var attempts: int = target * 120
	var occupied: Dictionary = {}
	var collar: int = _collar_cells() + 2
	if collar >= size / 2:
		collar = maxi(2, size / 8)
	var spacing: int = maxi(3, size / 36)

	# Towns claim the spacing budget before wilderness sampling, so the road
	# backbone is built around occupancy instead of random landmarks.
	_seed_settlement_nodes(clampi(target * 6 / 10, 2, target), occupied, spacing, rng)

	for _i in attempts:
		if nodes.size() >= target:
			break
		var ax: int = rng.randi_range(collar, size - collar - 1)
		var az: int = rng.randi_range(collar, size - collar - 1)
		_try_add_node(ax, az, occupied, spacing, rng)

	# Fill shortfalls with a lattice pass so maps are never node-starved.
	if nodes.size() < target:
		var step: int = maxi(spacing, 4)
		var ax: int = collar + step / 2
		while ax < size - collar and nodes.size() < target:
			var az: int = collar + step / 2
			while az < size - collar and nodes.size() < target:
				_try_add_node(ax, az, occupied, spacing, rng)
				az += step
			ax += step

	# Guarantee a backbone even if random sampling was unlucky on small maps.
	if nodes.size() < 2:
		for az in size:
			for ax in size:
				if nodes.size() >= maxi(target, 4):
					break
				_try_add_node(ax, az, occupied, maxi(2, spacing / 2), rng)
			if nodes.size() >= maxi(target, 4):
				break


func _seed_settlement_nodes(
	budget: int, occupied: Dictionary, spacing: int, rng: RandomNumberGenerator
) -> void:
	var peaks: Array[Vector2i] = _population_peaks()
	for peak in peaks:
		if nodes.size() >= budget:
			break
		_try_add_node(peak.y % size, peak.y / size, occupied, spacing, rng)

	# Any landmass that carries flat, townable occupancy needs a hub, even if
	# the budget was spent on a denser neighbour. Prefer densest then flattest.
	var hosted: Dictionary = {}
	for node in nodes:
		if node.kind == AtlasFeatures.NodeKind.SETTLEMENT:
			hosted[node.landmass] = true
	var best_flat: Dictionary = {}
	for az in size:
		for ax in size:
			var idx: int = index_of(ax, az)
			var pop: int = AtlasPack.population(cells[idx])
			if pop < SETTLEMENT_MIN_POP:
				continue
			if not _cell_is_settlement_flat(ax, az):
				continue
			var mass: int = landmass_id[idx]
			if mass < 0 or hosted.has(mass):
				continue
			var fitness: float = _flatness_fitness(ax, az)
			var prev: Variant = best_flat.get(mass, null)
			var take: bool = prev == null
			if not take:
				var prev_d: Dictionary = prev
				take = (
					pop > int(prev_d["pop"])
					or (
						pop == int(prev_d["pop"])
						and (
							fitness > float(prev_d["fitness"])
							or (
								is_equal_approx(fitness, float(prev_d["fitness"]))
								and idx < int(prev_d["idx"])
							)
						)
					)
				)
			if take:
				best_flat[mass] = {"pop": pop, "fitness": fitness, "idx": idx}
	for mass in best_flat.keys():
		if hosted.has(mass):
			continue
		var pick: Dictionary = best_flat[mass]
		var pick_idx: int = int(pick["idx"])
		var before: int = nodes.size()
		_try_add_node(pick_idx % size, pick_idx / size, occupied, maxi(2, spacing / 2), rng)
		if nodes.size() > before:
			hosted[mass] = true


## Local population maxima as (population, cell index), densest first, then
## flattest (|∇h| fitness). Steep neighbourhoods are excluded.
func _population_peaks() -> Array[Vector2i]:
	var peaks: Array[Vector2i] = []
	var radius: int = 2
	for az in size:
		for ax in size:
			var idx: int = index_of(ax, az)
			var pop: int = AtlasPack.population(cells[idx])
			if pop < SETTLEMENT_MIN_POP:
				continue
			if not _cell_is_settlement_flat(ax, az):
				continue
			var is_peak: bool = true
			for dz in range(-radius, radius + 1):
				for dx in range(-radius, radius + 1):
					if dx == 0 and dz == 0:
						continue
					var nx: int = ax + dx
					var nz: int = az + dz
					if not in_bounds(nx, nz):
						continue
					var nb: int = index_of(nx, nz)
					var npop: int = AtlasPack.population(cells[nb])
					if npop > pop or (npop == pop and nb < idx):
						is_peak = false
						break
				if not is_peak:
					break
			if is_peak:
				peaks.append(Vector2i(pop, idx))
	peaks.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			if a.x != b.x:
				return a.x > b.x
			var fa: float = _flatness_fitness(a.y % size, a.y / size)
			var fb: float = _flatness_fitness(b.y % size, b.y / size)
			if not is_equal_approx(fa, fb):
				return fa > fb
			return a.y < b.y
	)
	return peaks


func _try_add_node(
	ax: int, az: int, occupied: Dictionary, spacing: int, rng: RandomNumberGenerator
) -> void:
	if not in_bounds(ax, az):
		return
	var idx: int = index_of(ax, az)
	var biome: int = AtlasPack.biome(cells[idx])
	if not AtlasBiomes.is_land(biome):
		return
	if occupied.has(idx):
		return
	var mass: int = landmass_id[idx]
	if mass < 0:
		# Coast/plains should be labelled; if not, assign a synthetic mass.
		mass = 0
		landmass_id[idx] = 0
	var kind: int = AtlasFeatures.NodeKind.LANDMARK
	if (
		AtlasPack.population(cells[idx]) >= SETTLEMENT_MIN_POP
		and _cell_is_settlement_flat(ax, az)
	):
		# Occupied + locally flat → town. Steep high-pop cells stay landmarks.
		kind = AtlasFeatures.NodeKind.SETTLEMENT
	elif biome == AtlasBiomes.Id.COAST:
		kind = AtlasFeatures.NodeKind.COASTAL_GATE
	elif _near_lake(ax, az):
		kind = AtlasFeatures.NodeKind.LAKE_SHORE
	elif AtlasPack.relief(cells[idx]) > 24 and AtlasPack.elevation(cells[idx]) > 140:
		kind = AtlasFeatures.NodeKind.PASS
	elif rng.randf() < 0.08:
		kind = AtlasFeatures.NodeKind.CLAIM_RESERVED

	for node in nodes:
		if absi(node.ax - ax) + absi(node.az - az) < spacing:
			return

	var created: AtlasGraphNode = AtlasGraphNode.new()
	created.id = int(hash("%d:node:%d:%d:%d" % [world_seed, ax, az, kind])) & 0x7fffffff
	created.kind = kind
	created.cell = idx
	created.ax = ax
	created.az = az
	created.landmass = mass
	nodes.append(created)
	occupied[idx] = true


func _near_lake(ax: int, az: int) -> bool:
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var nx: int = ax + dx
			var nz: int = az + dz
			if in_bounds(nx, nz) and lake_id[index_of(nx, nz)] >= 0:
				return true
	return false


func _build_rivers(elev_code: PackedByteArray) -> void:
	var count: int = size * size
	river_receiver.resize(count)
	var accum: PackedFloat32Array = PackedFloat32Array()
	accum.resize(count)
	for i in count:
		river_receiver[i] = -1
		accum[i] = 1.0

	# Priority flood both resolves depressions and records the terrain-derived
	# drainage tree. This follows basin shape rather than Manhattan sink distance.
	var flood_order: PackedInt32Array = _priority_flood_fill(elev_code)
	_rewrite_cell_elevations(elev_code)

	# Parents are popped before children by the flood. Reverse that order to
	# accumulate every tributary exactly once, including broad flat basins.
	for order_i in range(flood_order.size() - 1, -1, -1):
		var idx: int = flood_order[order_i]
		var down: int = river_receiver[idx]
		if down >= 0 and AtlasBiomes.is_land(AtlasPack.biome(cells[down])):
			accum[down] += accum[idx]

	# Scale accumulation cutoff with map size; floor avoids coastal herringbone
	# stubs without starving the continent of trunks.
	var threshold: float = maxf(12.0, RIVER_ACCUM_THRESHOLD * float(size) / float(SIZE))
	var channel: PackedByteArray = PackedByteArray()
	channel.resize(count)
	for i in count:
		if AtlasBiomes.is_land(AtlasPack.biome(cells[i])) and accum[i] >= threshold:
			channel[i] = 1

	# Extend every channel all the way to ocean/lake so trunks cannot vanish.
	for i in count:
		if channel[i] == 0:
			continue
		var walk: int = i
		var guard: int = 0
		while walk >= 0 and guard < count:
			guard += 1
			channel[walk] = 1
			var down: int = river_receiver[walk]
			if down < 0:
				break
			var down_biome: int = AtlasPack.biome(cells[down])
			if down_biome == AtlasBiomes.Id.OCEAN or down_biome == AtlasBiomes.Id.LAKE:
				break
			walk = down

	var river_serial: int = 0
	for az in size:
		for ax in size:
			var idx: int = index_of(ax, az)
			if channel[idx] == 0:
				continue
			var down: int = river_receiver[idx]
			if down < 0:
				continue
			var dx: int = (down % size) - ax
			var dz: int = (down / size) - az
			# Must be a single cardinal step after the 4-neighbour routing.
			if absi(dx) + absi(dz) != 1:
				continue
			var dir: int = _dir_from_delta(dx, dz)
			if dir < 0:
				continue

			var down_biome: int = AtlasPack.biome(cells[down])
			var out_endpoint: AtlasEndpoint = AtlasEndpoint.new()
			var feature_class: int = clampi(int(log(maxi(accum[idx], 2.0)) / log(3.0)), 1, 4)
			var surface_z: int = AtlasPack.elevation_to_metres(int(elev_code[idx]))

			if down_biome == AtlasBiomes.Id.OCEAN:
				out_endpoint.kind = AtlasFeatures.EndpointKind.OCEAN
				out_endpoint.ref_id = 0
			elif down_biome == AtlasBiomes.Id.LAKE:
				out_endpoint.kind = AtlasFeatures.EndpointKind.LAKE
				out_endpoint.ref_id = maxi(lake_id[down], 0)
				surface_z = lakes[out_endpoint.ref_id].surface_z
			else:
				if channel[down] == 0:
					continue
				var port: AtlasPort = _ensure_river_port(
					ax, az, dir, feature_class, surface_z, river_serial
				)
				out_endpoint.kind = AtlasFeatures.EndpointKind.EDGE_PORT
				out_endpoint.ref_id = AtlasFeatures.edge_key(ax, az, dir, size)
				out_endpoint.port_id = port.id
				river_serial += 1

			var inflows: int = 0
			for k in 4:
				var nx: int = ax + NEIGHBOR_DX[k * 2]
				var nz: int = az + NEIGHBOR_DZ[k * 2]
				if not in_bounds(nx, nz):
					continue
				var nb: int = index_of(nx, nz)
				if channel[nb] == 0 or river_receiver[nb] != idx:
					continue
				var idir: int = _dir_from_delta(ax - nx, az - nz)
				if idir < 0:
					continue
				var in_port: AtlasPort = _ensure_river_port(
					nx, nz, idir, feature_class, surface_z, river_serial
				)
				river_serial += 1
				var in_endpoint: AtlasEndpoint = AtlasEndpoint.new()
				in_endpoint.kind = AtlasFeatures.EndpointKind.EDGE_PORT
				in_endpoint.ref_id = AtlasFeatures.edge_key(nx, nz, idir, size)
				in_endpoint.port_id = in_port.id
				_add_river_link(idx, in_endpoint, out_endpoint, feature_class)
				inflows += 1

			if inflows == 0:
				var source: AtlasEndpoint = AtlasEndpoint.new()
				source.kind = AtlasFeatures.EndpointKind.NODE
				source.ref_id = -1 - idx
				_add_river_link(idx, source, out_endpoint, feature_class)


func _rewrite_cell_elevations(elev_code: PackedByteArray) -> void:
	for i in cells.size():
		var packed: int = cells[i]
		cells[i] = AtlasPack.pack(
			int(elev_code[i]),
			AtlasPack.humidity(packed),
			AtlasPack.biome(packed),
			AtlasPack.relief(packed),
			AtlasPack.population(packed)
		)


## Raise closed depressions and assign each land cell to the terrain cell that
## flooded it. The returned pop order is sink-to-ridge topological order.
func _priority_flood_fill(elev_code: PackedByteArray) -> PackedInt32Array:
	var count: int = size * size
	var closed: PackedByteArray = PackedByteArray()
	closed.resize(count)
	var flood_order: PackedInt32Array = PackedInt32Array()
	# Min-heap via sorted bucket list: elevation code is 0..255.
	var buckets: Array = []
	buckets.resize(256)
	for i in 256:
		buckets[i] = PackedInt32Array()

	var open_min: int = 256
	for i in count:
		var biome: int = AtlasPack.biome(cells[i])
		if biome == AtlasBiomes.Id.OCEAN or biome == AtlasBiomes.Id.LAKE:
			var e: int = clampi(int(elev_code[i]), 0, 255)
			if biome == AtlasBiomes.Id.LAKE and lake_id[i] >= 0:
				e = lakes[lake_id[i]].surface_code
				elev_code[i] = e
			buckets[e].append(i)
			closed[i] = 1
			open_min = mini(open_min, e)

	while open_min < 256:
		while open_min < 256 and buckets[open_min].is_empty():
			open_min += 1
		if open_min >= 256:
			break
		var cell: int = buckets[open_min][buckets[open_min].size() - 1]
		buckets[open_min].remove_at(buckets[open_min].size() - 1)
		var ax: int = cell % size
		var az: int = cell / size
		var ce: int = int(elev_code[cell])
		if AtlasBiomes.is_land(AtlasPack.biome(cells[cell])):
			flood_order.append(cell)
		# Rotate cardinal expansion per cell. On broad flats this avoids a global
		# axis preference while remaining deterministic for the world seed.
		var first_dir: int = posmod(
			int(hash("%d:flood:%d:%d" % [world_seed, ax, az])), 4
		)
		for step in 4:
			var k: int = (first_dir + step) % 4
			var nx: int = ax + NEIGHBOR_DX[k * 2]
			var nz: int = az + NEIGHBOR_DZ[k * 2]
			if not in_bounds(nx, nz):
				continue
			var nb: int = index_of(nx, nz)
			if closed[nb] != 0:
				continue
			var biome: int = AtlasPack.biome(cells[nb])
			if biome == AtlasBiomes.Id.OCEAN or biome == AtlasBiomes.Id.LAKE:
				closed[nb] = 1
				continue
			var ne: int = maxi(int(elev_code[nb]), ce)
			elev_code[nb] = ne
			river_receiver[nb] = cell
			closed[nb] = 1
			buckets[ne].append(nb)
			open_min = mini(open_min, ne)
	return flood_order


func _dir_from_delta(dx: int, dz: int) -> int:
	# Prefer cardinal for ports; diagonals snap to the larger step.
	if dx == 0 and dz == 0:
		return -1
	if absi(dx) >= absi(dz):
		return AtlasFeatures.Dir.EAST if dx > 0 else AtlasFeatures.Dir.WEST
	return AtlasFeatures.Dir.SOUTH if dz > 0 else AtlasFeatures.Dir.NORTH


func _ensure_river_port(
	ax: int, az: int, dir: int, feature_class: int, surface_z: int, serial: int
) -> AtlasPort:
	var key: int = AtlasFeatures.edge_key(ax, az, dir, size)
	if not river_ports.has(key):
		river_ports[key] = []
	var ports: Array = river_ports[key]
	# One shared crossing per edge for the drainage tree. Creating a fresh port
	# on every call made upstream/downstream cells disagree on `t`, which showed
	# up as broken river segments when zoomed in.
	if not ports.is_empty():
		var best: AtlasPort = ports[0]
		for p in ports:
			var existing: AtlasPort = p
			if existing.feature_class < feature_class:
				existing.feature_class = feature_class
			if existing.surface_z == 0:
				existing.surface_z = surface_z
			if existing.feature_class >= best.feature_class:
				best = existing
		return best

	var owner: Vector3i = AtlasFeatures.edge_owner(key)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _layer_seed("edge_r_%d_%d_%d_%d" % [owner.x, owner.y, owner.z, serial])
	var port: AtlasPort = AtlasPort.new()
	port.id = 0
	port.t = lerpf(0.28, 0.72, rng.randf())
	port.kind = AtlasFeatures.Kind.RIVER
	port.feature_class = feature_class
	port.flow_sign = 1
	port.surface_z = surface_z
	port.feature_id = int(hash("%d:river:%d:%d" % [world_seed, key, port.id])) & 0x7fffffff
	ports.append(port)
	river_ports[key] = ports
	return port


func _add_river_link(
	cell: int, a: AtlasEndpoint, b: AtlasEndpoint, feature_class: int
) -> void:
	var link: AtlasLink = AtlasLink.new()
	link.a = a
	link.b = b
	link.kind = AtlasFeatures.Kind.RIVER
	link.feature_class = feature_class
	link.feature_id = int(hash("%d:rlink:%d:%d:%d" % [
		world_seed, cell, a.ref_id, b.ref_id
	])) & 0x7fffffff
	if not river_links.has(cell):
		river_links[cell] = []
	river_links[cell].append(link)


func _build_roads(elev_code: PackedByteArray) -> void:
	if nodes.size() < 2:
		return

	var river_adjacent: PackedByteArray = _river_adjacency_mask()
	_road_channel_mask = PackedByteArray()
	_road_channel_mask.resize(size * size)
	for cell_variant in river_links:
		_road_channel_mask[int(cell_variant)] = 1
	assert(
		ClassDB.class_exists("OrrunGen"),
		"OrrunGen is required for ContinentAtlas roads"
	)
	_road_native = ClassDB.instantiate("OrrunGen") as RefCounted

	# Group by landmass and connect with a simple nearest-neighbour chain + star
	# to the mass centroid node, then A* each segment on a coarse step.
	var by_mass: Dictionary = {}
	for node in nodes:
		if not by_mass.has(node.landmass):
			by_mass[node.landmass] = []
		by_mass[node.landmass].append(node)

	var road_serial: int = 0
	for mass in by_mass:
		var group: Array = by_mass[mass]
		if group.size() < 2:
			continue
		group.sort_custom(func(a: AtlasGraphNode, b: AtlasGraphNode) -> bool:
			return a.id < b.id
		)
		# Prim MST on population-weighted cell distance, so the trunk grows
		# between towns before it reaches out to wilderness landmarks.
		var n: int = group.size()
		var in_tree: PackedByteArray = PackedByteArray()
		in_tree.resize(n)
		in_tree[_densest_node_index(group)] = 1
		var edges: Array[Vector2i] = []
		for _k in range(n - 1):
			var best_i: int = -1
			var best_j: int = -1
			var best_w: float = INF
			for i in n:
				if in_tree[i] == 0:
					continue
				var ni: AtlasGraphNode = group[i]
				for j in n:
					if in_tree[j] != 0:
						continue
					var w: float = _road_pair_weight(ni, group[j])
					if w < best_w:
						best_w = w
						best_i = i
						best_j = j
			if best_j < 0:
				break
			in_tree[best_j] = 1
			edges.append(Vector2i(best_i, best_j))

		var linked: Dictionary = {}
		for edge in edges:
			var a: AtlasGraphNode = group[edge.x]
			var b: AtlasGraphNode = group[edge.y]
			if _route_and_stamp_road(
				a, b, AtlasFeatures.RoadClass.PRIMARY, elev_code, river_adjacent, road_serial
			):
				primary_road_edges.append(Vector2i(a.id, b.id))
				linked["%d:%d" % [mini(a.id, b.id), maxi(a.id, b.id)]] = true
				road_serial += 1

		# Secondary spurs: each node also reaches its second-nearest neighbour so
		# the network is denser than a bare MST.
		for i in n:
			var ni: AtlasGraphNode = group[i]
			var best: Array[Vector2] = []
			for j in n:
				if i == j:
					continue
				best.append(Vector2(_road_pair_weight(ni, group[j]), float(j)))
			best.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
			# Towns get one extra spur so occupied regions end up denser.
			var spur_budget: int = (
				3 if ni.kind == AtlasFeatures.NodeKind.SETTLEMENT else 2
			)
			var added: int = 0
			for cand in best:
				if added >= spur_budget:
					break
				var nj2: AtlasGraphNode = group[int(cand.y)]
				var key: String = "%d:%d" % [mini(ni.id, nj2.id), maxi(ni.id, nj2.id)]
				if linked.has(key):
					continue
				if _route_and_stamp_road(
					ni, nj2, AtlasFeatures.RoadClass.SECONDARY, elev_code, river_adjacent,
					road_serial
				):
					linked[key] = true
					road_serial += 1
					added += 1
	_road_channel_mask = PackedByteArray()
	_road_native = null


## Land cells that border a river channel without being one. Roads follow these
## valley shoulders instead of sitting in the water.
func _river_adjacency_mask() -> PackedByteArray:
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(size * size)
	for cell_variant in river_links:
		var cell: int = int(cell_variant)
		var cx: int = cell % size
		var cz: int = cell / size
		for k in 8:
			var nx: int = cx + NEIGHBOR_DX[k]
			var nz: int = cz + NEIGHBOR_DZ[k]
			if not in_bounds(nx, nz):
				continue
			var nb: int = index_of(nx, nz)
			if not river_links.has(nb) and AtlasBiomes.is_land(AtlasPack.biome(cells[nb])):
				mask[nb] = 1
	return mask


func _densest_node_index(group: Array) -> int:
	var best: int = 0
	var best_pop: int = -1
	for i in group.size():
		var node: AtlasGraphNode = group[i]
		var pop: int = AtlasPack.population(cells[node.cell])
		if pop > best_pop:
			best_pop = pop
			best = i
	return best


## Distance discounted by the occupancy of both endpoints, so town-to-town links
## outrank equally long wilderness links.
func _road_pair_weight(a: AtlasGraphNode, b: AtlasGraphNode) -> float:
	var d: float = float(absi(a.ax - b.ax) + absi(a.az - b.az))
	return d * _road_node_factor(a) * _road_node_factor(b)


func _road_node_factor(node: AtlasGraphNode) -> float:
	var factor: float = lerpf(
		1.0, 0.72, float(AtlasPack.population(cells[node.cell])) / 15.0
	)
	if node.kind == AtlasFeatures.NodeKind.SETTLEMENT:
		factor *= 0.85
	return factor


func _route_and_stamp_road(
	a: AtlasGraphNode,
	b: AtlasGraphNode,
	road_class: int,
	elev_code: PackedByteArray,
	river_adjacent: PackedByteArray,
	serial: int
) -> bool:
	var path: PackedInt32Array = _road_astar(a.cell, b.cell, elev_code, river_adjacent)
	if path.size() < 2:
		path = _road_bresenham(a.ax, a.az, b.ax, b.az)
	if path.size() < 2:
		return false
	_stamp_road_path(path, road_class, a.id, b.id, serial)
	return true


func _road_astar(
	start: int, goal: int, elev_code: PackedByteArray, river_adjacent: PackedByteArray
) -> PackedInt32Array:
	assert(
		_road_native != null,
		"OrrunGen is required for ContinentAtlas.road_astar"
	)
	var path: Variant = _road_native.call(
		"road_astar",
		cells,
		elev_code,
		river_adjacent,
		_road_channel_mask,
		size,
		start,
		goal,
		AtlasBiomes.Id.OCEAN,
		AtlasBiomes.Id.LAKE,
		AtlasBiomes.Id.ALPINE
	)
	assert(
		typeof(path) == TYPE_PACKED_INT32_ARRAY,
		"OrrunGen.road_astar failed: %s" % [path]
	)
	return path

func _reconstruct(came: Dictionary, current: int) -> PackedInt32Array:
	var path: PackedInt32Array = PackedInt32Array()
	path.append(current)
	while came.has(current):
		current = came[current]
		path.append(current)
	path.reverse()
	return path


func _road_bresenham(ax0: int, az0: int, ax1: int, az1: int) -> PackedInt32Array:
	var path: PackedInt32Array = PackedInt32Array()
	var x: int = ax0
	var z: int = az0
	var dx: int = absi(ax1 - ax0)
	var dz: int = absi(az1 - az0)
	var sx: int = 1 if ax0 < ax1 else -1
	var sz: int = 1 if az0 < az1 else -1
	var err: int = dx - dz
	while true:
		if not in_bounds(x, z):
			return PackedInt32Array()
		var idx: int = index_of(x, z)
		var biome: int = AtlasPack.biome(cells[idx])
		if biome == AtlasBiomes.Id.OCEAN:
			return PackedInt32Array()
		path.append(idx)
		if x == ax1 and z == az1:
			break
		var e2: int = err * 2
		if e2 > -dz:
			err -= dz
			x += sx
		if e2 < dx:
			err += dx
			z += sz
	return path


func _stamp_road_path(
	path: PackedInt32Array, road_class: int, node_a: int, node_b: int, serial: int
) -> void:
	var feature_id: int = int(hash("%d:road:%d:%d:%d" % [
		world_seed, node_a, node_b, serial
	])) & 0x7fffffff
	# One link per path cell, from the entry edge/node to the exit edge/node.
	# The old segment stamp put both endpoints on the same outgoing edge, which
	# made roads render as tiny stubs instead of continuous corridors.
	for i in path.size():
		var cell: int = path[i]
		var ax: int = cell % size
		var az: int = cell / size
		var surface_z: int = AtlasPack.elevation_to_metres(AtlasPack.elevation(cells[cell]))
		var ea: AtlasEndpoint = AtlasEndpoint.new()
		var eb: AtlasEndpoint = AtlasEndpoint.new()
		if i == 0:
			ea.kind = AtlasFeatures.EndpointKind.NODE
			ea.ref_id = node_a
		else:
			var prev: int = path[i - 1]
			var back_dir: int = _dir_from_delta(
				(prev % size) - ax, (prev / size) - az
			)
			if back_dir < 0:
				continue
			var in_port: AtlasPort = _ensure_road_port(
				ax, az, back_dir, road_class, surface_z
			)
			ea.kind = AtlasFeatures.EndpointKind.EDGE_PORT
			ea.ref_id = AtlasFeatures.edge_key(ax, az, back_dir, size)
			ea.port_id = in_port.id
		if i == path.size() - 1:
			eb.kind = AtlasFeatures.EndpointKind.NODE
			eb.ref_id = node_b
		else:
			var next_cell: int = path[i + 1]
			var forward: int = _dir_from_delta(
				(next_cell % size) - ax, (next_cell / size) - az
			)
			if forward < 0:
				continue
			var out_port: AtlasPort = _ensure_road_port(
				ax, az, forward, road_class, surface_z
			)
			eb.kind = AtlasFeatures.EndpointKind.EDGE_PORT
			eb.ref_id = AtlasFeatures.edge_key(ax, az, forward, size)
			eb.port_id = out_port.id
		var link: AtlasLink = AtlasLink.new()
		link.a = ea
		link.b = eb
		link.kind = AtlasFeatures.Kind.ROAD
		link.feature_class = road_class
		link.feature_id = feature_id
		if not road_links.has(cell):
			road_links[cell] = []
		road_links[cell].append(link)


func _ensure_road_port(
	ax: int, az: int, dir: int, road_class: int, surface_z: int
) -> AtlasPort:
	var key: int = AtlasFeatures.edge_key(ax, az, dir, size)
	if not road_ports.has(key):
		road_ports[key] = []
	var ports: Array = road_ports[key]
	if not ports.is_empty():
		var best: AtlasPort = ports[0]
		for p in ports:
			var existing: AtlasPort = p
			if existing.feature_class > best.feature_class:
				best = existing
			# Prefer keeping the primary class visible when MST and spur share an edge.
			if road_class < existing.feature_class:
				existing.feature_class = road_class
		return best
	var owner: Vector3i = AtlasFeatures.edge_owner(key)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _layer_seed("edge_p_%d_%d_%d_%d" % [owner.x, owner.y, owner.z, 0])
	var port: AtlasPort = AtlasPort.new()
	port.id = 0
	port.t = lerpf(0.3, 0.7, rng.randf())
	port.kind = AtlasFeatures.Kind.ROAD
	port.feature_class = road_class
	port.flow_sign = 0
	port.surface_z = surface_z
	port.feature_id = int(hash("%d:rport:%d:%d" % [world_seed, key, port.id])) & 0x7fffffff
	ports.append(port)
	road_ports[key] = ports
	return port


func _find_crossings() -> void:
	for cell in road_links:
		if not river_links.has(cell):
			continue
		var road_list: Array = road_links[cell]
		var river_list: Array = river_links[cell]
		if road_list.is_empty() or river_list.is_empty():
			continue
		var road: AtlasLink = road_list[0]
		var river: AtlasLink = river_list[0]
		var crossing: AtlasCrossing = AtlasCrossing.new()
		crossing.id = crossings.size()
		crossing.cell = cell
		crossing.river_id = river.feature_id
		crossing.road_id = road.feature_id
		crossing.river_class = river.feature_class
		crossing.road_class = road.feature_class
		crossings.append(crossing)


func _compute_hash() -> int:
	var h: int = world_seed
	h = h * 31 + size
	h = h * 31 + schema_version
	h = h * 31 + lakes.size()
	h = h * 31 + nodes.size()
	h = h * 31 + river_ports.size()
	h = h * 31 + road_ports.size()
	h = h * 31 + crossings.size()
	# Sample a sparse set of cells so the hash stays cheap but content-sensitive.
	var step: int = maxi(size / 32, 1)
	for az in range(0, size, step):
		for ax in range(0, size, step):
			h = h * 31 + cells[index_of(ax, az)]
	return h
