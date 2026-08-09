class_name ContinentAtlas
extends RefCounted
## Layer 0: continental climate + major river/road continuity.
##
## See docs/CONTINENT_ATLAS.md. Immutable after generate().

const SIZE: int = 1000
const CELL_METRES: float = 1000.0
const SCHEMA_VERSION: int = 1
const SEA_SURFACE_Z: int = 0
const OCEAN_COLLAR_FULL: int = 48
const RIVER_ACCUM_THRESHOLD: float = 180.0
const MAX_RIVER_PORTS: int = 2
const MAX_ROAD_PORTS: int = 2
const LAKE_MIN_DEPTH_CODE: int = 3
const LAKE_MIN_CELLS: int = 6
const LAKE_MAX_CELLS_FULL: int = 450
const PRIMARY_NODE_TARGET: int = 48

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

var generate_ms: int = 0


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
	_build_lakes(land, elev_code)
	_merge_coastal_lakes_into_ocean(land, elev_code)
	_label_landmasses(land)
	_classify_and_pack(land, elev_code, humidity, relief)
	_seed_nodes()
	_build_rivers(elev_code)
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
	var continent: FastNoiseLite = _make_noise(
		"atlas_continent", 0.0024, FastNoiseLite.FRACTAL_FBM, 6
	)
	var coast_cut: FastNoiseLite = _make_noise(
		"atlas_coast_cut", 0.011, FastNoiseLite.FRACTAL_RIDGED, 4
	)
	var peninsula: FastNoiseLite = _make_noise(
		"atlas_peninsula", 0.0065, FastNoiseLite.FRACTAL_FBM, 4
	)
	var mountain: FastNoiseLite = _make_noise(
		"atlas_mountain", 0.0045, FastNoiseLite.FRACTAL_RIDGED, 4
	)
	var moist: FastNoiseLite = _make_noise(
		"atlas_moist", 0.0035, FastNoiseLite.FRACTAL_FBM, 3
	)
	var relief_n: FastNoiseLite = _make_noise(
		"atlas_relief", 0.008, FastNoiseLite.FRACTAL_FBM, 3
	)
	var warp: FastNoiseLite = _make_noise(
		"atlas_warp", 0.0035, FastNoiseLite.FRACTAL_FBM, 4
	)
	var warp2: FastNoiseLite = _make_noise(
		"atlas_warp2", 0.0016, FastNoiseLite.FRACTAL_FBM, 3
	)

	var half: float = float(size) * 0.5
	var collar_cells: int = _collar_cells()
	# Keep a narrow soft sea belt inside the hard collar. The radial mass still
	# prevents a square continent, but most of the atlas remains usable land.
	var soft_margin: float = float(collar_cells) + float(size) * 0.02
	for az in size:
		for ax in size:
			var idx: int = index_of(ax, az)
			var edge_d: int = mini(
				mini(ax, size - 1 - ax),
				mini(az, size - 1 - az)
			)
			var hard_sea: bool = edge_d < collar_cells
			var dxn: float = (float(ax) - half) / half
			var dzn: float = (float(az) - half) / half
			var radial: float = sqrt(dxn * dxn + dzn * dzn)
			var wx: float = (
				float(ax)
				+ warp.get_noise_2d(float(ax), float(az)) * float(size) * 0.08
				+ warp2.get_noise_2d(float(az), float(ax)) * float(size) * 0.05
			)
			var wz: float = (
				float(az)
				+ warp.get_noise_2d(float(ax) + 40.0, float(az) - 17.0) * float(size) * 0.08
				+ warp2.get_noise_2d(float(ax) - 11.0, float(az) + 27.0) * float(size) * 0.05
			)
			var cont: float = continent.get_noise_2d(wx, wz)
			var pen: float = peninsula.get_noise_2d(wx * 0.7, wz * 0.7)
			var cut: float = coast_cut.get_noise_2d(wx, wz) * 0.5 + 0.5
			# Mild oval bias (not a filled square): keeps one main landmass but
			# lets noise chew deep bays and peninsulas into the shoreline.
			var mass: float = 1.0 - clampf(radial * 0.88, 0.0, 1.20)
			mass = smoothstep(-0.08, 0.82, mass)
			var landness: float = cont * 0.66 + pen * 0.22 + mass * 0.56
			# Ridged cuts carve gulfs; stronger near the outer third.
			landness -= cut * lerpf(0.06, 0.30, clampf(radial, 0.0, 1.0))
			# Keep a soft sea belt inside the hard collar so coasts are free-form.
			var rim: float = smoothstep(
				soft_margin, soft_margin + float(size) * 0.06, float(edge_d)
			)
			landness *= lerpf(0.34, 1.0, rim)
			var is_land: bool = (not hard_sea) and landness > 0.08
			land[idx] = 1 if is_land else 0

			if not is_land:
				var depth: float = clampf(0.55 - landness, 0.0, 1.0) * 32.0
				elev_code[idx] = clampi(int(depth), 0, 32)
				humidity[idx] = 255
				relief[idx] = 0
				continue

			var ridge: float = mountain.get_noise_2d(wx * 0.9, wz * 0.9) * 0.5 + 0.5
			var alpine: float = pow(ridge, 1.35) * smoothstep(0.2, 0.7, landness)
			var code_f: float = 48.0 + landness * 70.0 + alpine * 130.0
			code_f += relief_n.get_noise_2d(wx, wz) * 10.0
			elev_code[idx] = clampi(int(code_f), 33, 255)
			relief[idx] = clampi(int(alpine * 50.0 + relief_n.get_noise_2d(wz, wx) * 8.0 + 4.0), 0, 63)

			var h: float = moist.get_noise_2d(wx, wz) * 0.5 + 0.5
			h = lerpf(h, 0.85, clampf(radial, 0.0, 1.0) * 0.35) * 0.35 + h * 0.65
			h -= alpine * 0.25
			humidity[idx] = clampi(int(h * 255.0), 0, 255)


func _collar_cells() -> int:
	return maxi(6, OCEAN_COLLAR_FULL * size / SIZE)


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


func _seed_nodes() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _layer_seed("atlas_nodes")
	var target: int = maxi(8, PRIMARY_NODE_TARGET * size / SIZE)
	var attempts: int = target * 80
	var occupied: Dictionary = {}
	var collar: int = _collar_cells() + 2
	if collar >= size / 2:
		collar = maxi(2, size / 8)
	var spacing: int = maxi(3, 18 * size / SIZE)

	for _i in attempts:
		if nodes.size() >= target:
			break
		var ax: int = rng.randi_range(collar, size - collar - 1)
		var az: int = rng.randi_range(collar, size - collar - 1)
		_try_add_node(ax, az, occupied, spacing, rng)

	# Guarantee a backbone even if random sampling was unlucky on small maps.
	if nodes.size() < 2:
		for az in size:
			for ax in size:
				if nodes.size() >= maxi(target, 4):
					break
				_try_add_node(ax, az, occupied, spacing, rng)
			if nodes.size() >= maxi(target, 4):
				break


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
	if biome == AtlasBiomes.Id.COAST:
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
	if ports.size() >= MAX_RIVER_PORTS:
		var best: AtlasPort = ports[0]
		for p in ports:
			var port: AtlasPort = p
			if port.feature_class < feature_class:
				port.feature_class = feature_class
			if port.feature_class >= best.feature_class:
				best = port
		return best

	var owner: Vector3i = AtlasFeatures.edge_owner(key)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _layer_seed("edge_r_%d_%d_%d_%d" % [owner.x, owner.y, owner.z, ports.size()])
	var port: AtlasPort = AtlasPort.new()
	port.id = ports.size()
	port.t = lerpf(0.2, 0.8, rng.randf())
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
		# Prim MST on Euclidean cell distance.
		var n: int = group.size()
		var in_tree: PackedByteArray = PackedByteArray()
		in_tree.resize(n)
		in_tree[0] = 1
		var edges: Array[Vector2i] = []
		for _k in range(n - 1):
			var best_i: int = -1
			var best_j: int = -1
			var best_d: int = 1 << 30
			for i in n:
				if in_tree[i] == 0:
					continue
				var ni: AtlasGraphNode = group[i]
				for j in n:
					if in_tree[j] != 0:
						continue
					var nj: AtlasGraphNode = group[j]
					var d: int = absi(ni.ax - nj.ax) + absi(ni.az - nj.az)
					if d < best_d:
						best_d = d
						best_i = i
						best_j = j
			if best_j < 0:
				break
			in_tree[best_j] = 1
			edges.append(Vector2i(best_i, best_j))

		for edge in edges:
			var a: AtlasGraphNode = group[edge.x]
			var b: AtlasGraphNode = group[edge.y]
			var path: PackedInt32Array = _road_astar(a.cell, b.cell, elev_code)
			if path.size() < 2:
				path = _road_bresenham(a.ax, a.az, b.ax, b.az)
			if path.size() < 2:
				continue
			primary_road_edges.append(Vector2i(a.id, b.id))
			_stamp_road_path(path, AtlasFeatures.RoadClass.PRIMARY, a.id, b.id, road_serial)
			road_serial += 1


func _road_astar(start: int, goal: int, elev_code: PackedByteArray) -> PackedInt32Array:
	# Coarse A* stepping by 1 cell; capped expansions for GDScript budgets.
	var open: Array[int] = [start]
	var came: Dictionary = {}
	var gscore: Dictionary = {start: 0.0}
	var goal_ax: int = goal % size
	var goal_az: int = goal / size
	var expansions: int = 0
	var closed: Dictionary = {}

	while not open.is_empty() and expansions < 20000:
		expansions += 1
		var best_i: int = 0
		var best_f: float = INF
		for i in open.size():
			var c: int = open[i]
			var ax: int = c % size
			var az: int = c / size
			var f: float = float(gscore[c]) + float(absi(ax - goal_ax) + absi(az - goal_az))
			if f < best_f:
				best_f = f
				best_i = i
		var current: int = open[best_i]
		open.remove_at(best_i)
		if current == goal:
			return _reconstruct(came, current)
		if closed.has(current):
			continue
		closed[current] = true
		var cx: int = current % size
		var cz: int = current / size
		for k in 4:
			var nx: int = cx + NEIGHBOR_DX[k * 2]
			var nz: int = cz + NEIGHBOR_DZ[k * 2]
			if not in_bounds(nx, nz):
				continue
			var nb: int = index_of(nx, nz)
			var biome: int = AtlasPack.biome(cells[nb])
			if biome == AtlasBiomes.Id.OCEAN or biome == AtlasBiomes.Id.LAKE:
				continue
			var step: float = 1.0 + float(AtlasPack.relief(cells[nb])) * 0.04
			step += float(absi(int(elev_code[nb]) - int(elev_code[current]))) * 0.08
			if river_links.has(nb):
				step += 0.35
			var tentative: float = float(gscore[current]) + step
			if gscore.has(nb) and tentative >= float(gscore[nb]):
				continue
			came[nb] = current
			gscore[nb] = tentative
			open.append(nb)
	return PackedInt32Array()


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
	for i in range(path.size() - 1):
		var a: int = path[i]
		var b: int = path[i + 1]
		var ax: int = a % size
		var az: int = a / size
		var bx: int = b % size
		var bz: int = b / size
		var dir: int = _dir_from_delta(bx - ax, bz - az)
		if dir < 0:
			continue
		var surface_z: int = AtlasPack.elevation_to_metres(AtlasPack.elevation(cells[a]))
		var port: AtlasPort = _ensure_road_port(ax, az, dir, road_class, surface_z)
		var ea: AtlasEndpoint = AtlasEndpoint.new()
		var eb: AtlasEndpoint = AtlasEndpoint.new()
		if i == 0:
			ea.kind = AtlasFeatures.EndpointKind.NODE
			ea.ref_id = node_a
		else:
			ea.kind = AtlasFeatures.EndpointKind.EDGE_PORT
			ea.ref_id = AtlasFeatures.edge_key(ax, az, dir, size)
			ea.port_id = port.id
		if i + 1 == path.size() - 1:
			eb.kind = AtlasFeatures.EndpointKind.NODE
			eb.ref_id = node_b
		else:
			eb.kind = AtlasFeatures.EndpointKind.EDGE_PORT
			eb.ref_id = AtlasFeatures.edge_key(ax, az, dir, size)
			eb.port_id = port.id
		var link: AtlasLink = AtlasLink.new()
		link.a = ea
		link.b = eb
		link.kind = AtlasFeatures.Kind.ROAD
		link.feature_class = road_class
		link.feature_id = feature_id
		if not road_links.has(a):
			road_links[a] = []
		road_links[a].append(link)


func _ensure_road_port(
	ax: int, az: int, dir: int, road_class: int, surface_z: int
) -> AtlasPort:
	var key: int = AtlasFeatures.edge_key(ax, az, dir, size)
	if not road_ports.has(key):
		road_ports[key] = []
	var ports: Array = road_ports[key]
	if ports.size() >= MAX_ROAD_PORTS:
		return ports[0]
	var owner: Vector3i = AtlasFeatures.edge_owner(key)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _layer_seed("edge_p_%d_%d_%d_%d" % [owner.x, owner.y, owner.z, ports.size()])
	var port: AtlasPort = AtlasPort.new()
	port.id = ports.size()
	port.t = lerpf(0.25, 0.75, rng.randf())
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
