class_name ContinentalTerrain
extends RefCounted
## The one continuous land surface, as a pure function of continental metres.
##
## Nothing in this class knows what a sector is, and that is the point. Two
## sectors that sample the same square metre call the same function with the
## same arguments and get bit-identical answers, so their shared edge cannot
## disagree about height, coast, climate or valley shape - there is no seam to
## get wrong.
##
## The surface is assembled in a fixed order:
##
##   1. atlas elevation, read with a smooth kernel     (continental authority)
##   2. warped detail noise, scaled by atlas relief    (what a kilometre hides)
##   3. trunk valleys along atlas river corridors      (so the land drains)
##   4. shoreline authority against the water plane    (so coasts are coasts)
##
## Step 4 is the global signed shoreline function. Land and water meet exactly
## where [method shore_signed] crosses zero, and both the depth below and the
## freeboard above fade to zero there, so the waterline is continuous rather
## than a step. Because that function depends only on the atlas and continental
## coordinates, every sector draws the same coast.
##
## One instance per thread: it owns a [NoiseSet], which is not shareable.

## Signed-shore band, in field units, over which the coast profile develops.
const SHORE_OUTER: float = 0.26
## How much the coast detail noise may push the waterline inside a coastal
## cell. Below 0.5 by construction, so it can never dry an ocean cell or flood
## an inland one: the atlas keeps its authority over which cells are wet.
const COAST_WOBBLE: float = 0.20
## Metres of shelf the sea bed drops through across the shore band...
const SHELF_DEPTH: float = 70.0
## ...and metres the land climbs through it.
const FREEBOARD_SPAN: float = 26.0
## Rough metres per unit of [method shore_signed]. Only used to tell the
## corridor mask how near a coast a column is, so an approximation is honest:
## the waterline itself is the exact zero of the signed function, not this.
const SHORE_METRES_PER_UNIT: float = 500.0
## Horizontal bins used when a whole window is filled at once. Only an
## optimisation: a bin holds every corridor that could reach any cell in it, and
## corridors that turn out to be too far away are skipped per cell, so the
## number of bins cannot change the surface.
const BIN_DIVISIONS: int = 16

var config: WorldConfig
var fields: AtlasFields
var corridors: AtlasCorridors
var noise: NoiseSet

var _continent_span: float = 1.0


static func create(
	cfg: WorldConfig, atlas_fields: AtlasFields, atlas_corridors: AtlasCorridors
) -> ContinentalTerrain:
	var terrain: ContinentalTerrain = ContinentalTerrain.new()
	terrain.config = cfg
	terrain.fields = atlas_fields
	terrain.corridors = atlas_corridors
	terrain.noise = NoiseSet.create(cfg)
	terrain._continent_span = maxf(cfg.continent_metres(), 1.0)
	return terrain


# --- Single-sample reads --------------------------------------------------------

func height_at(world_x: float, world_z: float) -> float:
	var radius: float = corridors.max_valley_radius
	var rect: Rect2 = Rect2(
		world_x - radius, world_z - radius, radius * 2.0, radius * 2.0
	)
	var height: float = _base_height(world_x, world_z)
	height = _carve_valleys(
		height, world_x, world_z, corridors.rivers_in_rect(rect)
	)
	return _shore_authority(height, world_x, world_z)


func relief_amp_at(world_x: float, world_z: float) -> float:
	return _relief_amp(fields.sample_smooth(fields.relief01, world_x, world_z))


func moisture_at(world_x: float, world_z: float) -> float:
	return _moisture(world_x, world_z)


func temperature_at(world_x: float, world_z: float) -> float:
	return temperature_for(world_x, world_z, height_at(world_x, world_z))


## Positive on land, negative under water, zero exactly on the waterline.
##
## This is the global shoreline function. Every ocean edge and every atlas lake
## edge in the world is its zero set, which is why neighbouring sectors never
## have to agree on a coastline - they cannot disagree about one.
func shore_signed(world_x: float, world_z: float) -> float:
	var wet: float = fields.sample_smooth(fields.water_flag, world_x, world_z)
	var wobble: float = noise.coast.get_noise_2d(world_x, world_z) * COAST_WOBBLE
	return 0.5 - wet + wobble


## Rough metres from the waterline, positive on land. Used only to tell the
## corridor mask that a column is on a beach; the exact waterline is the zero
## of [method shore_signed], which this deliberately does not try to restate.
func shore_distance(world_x: float, world_z: float) -> float:
	return shore_signed(world_x, world_z) * SHORE_METRES_PER_UNIT


## Surface height of the water body nearest this point. Meaningful inside the
## shore band; far inland it is only the sea, and nothing reads it there.
func water_plane_at(world_x: float, world_z: float) -> float:
	return fields.sample_linear(fields.water_plane, world_x, world_z)


## True where the atlas itself says the cell is ocean or lake, ignoring the
## coast detail. Used where authority matters more than the exact waterline.
func atlas_is_water(world_x: float, world_z: float) -> bool:
	var cell: Vector2i = WorldCoords.atlas_cell_of(world_x, world_z)
	return fields.water_flag[fields.index_of(cell.x, cell.y)] > 0.5


# --- Bulk window fill --------------------------------------------------------------

## Fills one sector's macro window. Identical to calling the single-sample
## readers cell by cell - the only difference is that corridor segments are
## gathered once for the whole window instead of once per cell.
func fill_window(
	origin_cell: Vector2i,
	cells: int,
	elevation: PackedFloat32Array,
	relief_amp: PackedFloat32Array,
	moisture: PackedFloat32Array,
	temperature: PackedFloat32Array
) -> void:
	var cs: float = config.macro_cell_size
	var origin: Vector2 = Vector2(
		float(origin_cell.x) * cs, float(origin_cell.y) * cs
	)
	var span: float = float(cells) * cs
	var radius: float = corridors.max_valley_radius
	var window: Rect2 = Rect2(
		origin.x - radius, origin.y - radius, span + radius * 2.0, span + radius * 2.0
	)
	var river_bases: PackedInt32Array = corridors.rivers_in_rect(window)

	if ClassDB.class_exists("OrrunGen"):
		var native: RefCounted = ClassDB.instantiate("OrrunGen") as RefCounted
		var params: Dictionary = {
			"origin_x": origin_cell.x,
			"origin_z": origin_cell.y,
			"cells": cells,
			"macro_cell_size": cs,
			"atlas_size": fields.size,
			"continent_span": _continent_span,
			"max_valley_radius": radius,
			"trunk_valley_radius": config.trunk_valley_radius,
			"trunk_valley_per_class": config.trunk_valley_per_class,
			"trunk_bank_rise": config.trunk_bank_rise,
			"swell_height": config.swell_height,
			"mountain_detail": config.mountain_detail,
			"mountain_octaves": config.mountain_octaves,
			"mountain_gain": config.mountain_gain,
			"mountain_sharpness": config.mountain_sharpness,
			"mountain_macro_contrast": config.mountain_macro_contrast,
			"warp_strength": config.warp_strength,
			"ocean_floor_margin": config.ocean_floor_margin,
			"inland_freeboard": config.inland_freeboard,
			"relief_amp_plains": config.relief_amp_plains,
			"relief_amp_hills": config.relief_amp_hills,
			"relief_amp_mountains": config.relief_amp_mountains,
			"seed_swell": config.layer_seed("swell"),
			"seed_mountain": config.layer_seed("mountain"),
			"seed_warp_a": config.layer_seed("warp_a"),
			"seed_warp_b": config.layer_seed("warp_b"),
			"seed_moisture": config.layer_seed("moisture"),
			"seed_temperature": config.layer_seed("temperature"),
			"seed_coast": config.layer_seed("coast"),
			"swell_scale": config.swell_scale,
			"mountain_noise_scale": config.mountain_noise_scale,
			"warp_scale": config.warp_scale,
		}
		var result: Variant = native.call(
			"fill_window",
			fields.elevation_m,
			fields.humidity01,
			fields.relief01,
			fields.water_flag,
			fields.water_plane,
			corridors.rivers,
			river_bases,
			params
		)
		if typeof(result) == TYPE_DICTIONARY:
			var dict: Dictionary = result
			var elev_src: PackedFloat32Array = dict["elevation"]
			var rel_src: PackedFloat32Array = dict["relief_amp"]
			var moist_src: PackedFloat32Array = dict["moisture"]
			var temp_src: PackedFloat32Array = dict["temperature"]
			var count: int = cells * cells
			for i in count:
				elevation[i] = elev_src[i]
				relief_amp[i] = rel_src[i]
				moisture[i] = moist_src[i]
				temperature[i] = temp_src[i]
			return
		push_error("OrrunGen.fill_window failed: %s" % [result])

	var bins: Array[PackedInt32Array] = _bin_rivers(river_bases, origin, span, radius)

	for cz in cells:
		var wz: float = (float(origin_cell.y + cz) + 0.5) * cs
		var bz: int = clampi(int((wz - origin.y) / span * float(BIN_DIVISIONS)), 0, BIN_DIVISIONS - 1)
		for cx in cells:
			var wx: float = (float(origin_cell.x + cx) + 0.5) * cs
			var bx: int = clampi(
				int((wx - origin.x) / span * float(BIN_DIVISIONS)), 0, BIN_DIVISIONS - 1
			)
			var index: int = cz * cells + cx

			var height: float = _base_height(wx, wz)
			height = _carve_valleys(height, wx, wz, bins[bz * BIN_DIVISIONS + bx])
			height = _shore_authority(height, wx, wz)

			elevation[index] = height
			relief_amp[index] = _relief_amp(
				fields.sample_smooth(fields.relief01, wx, wz)
			)
			moisture[index] = _moisture(wx, wz)
			temperature[index] = temperature_for(wx, wz, height)


func _bin_rivers(
	bases: PackedInt32Array, origin: Vector2, span: float, radius: float
) -> Array[PackedInt32Array]:
	var bins: Array[PackedInt32Array] = []
	bins.resize(BIN_DIVISIONS * BIN_DIVISIONS)
	for i in bins.size():
		bins[i] = PackedInt32Array()
	var bin_span: float = span / float(BIN_DIVISIONS)

	for base in bases:
		var reach: float = radius
		var min_x: float = minf(corridors.rivers[base], corridors.rivers[base + 3]) - reach
		var max_x: float = maxf(corridors.rivers[base], corridors.rivers[base + 3]) + reach
		var min_z: float = minf(corridors.rivers[base + 2], corridors.rivers[base + 5]) - reach
		var max_z: float = maxf(corridors.rivers[base + 2], corridors.rivers[base + 5]) + reach
		var x0: int = clampi(floori((min_x - origin.x) / bin_span), 0, BIN_DIVISIONS - 1)
		var x1: int = clampi(floori((max_x - origin.x) / bin_span), 0, BIN_DIVISIONS - 1)
		var z0: int = clampi(floori((min_z - origin.y) / bin_span), 0, BIN_DIVISIONS - 1)
		var z1: int = clampi(floori((max_z - origin.y) / bin_span), 0, BIN_DIVISIONS - 1)
		if max_x < origin.x or max_z < origin.y:
			continue
		for bz in range(z0, z1 + 1):
			for bx in range(x0, x1 + 1):
				bins[bz * BIN_DIVISIONS + bx].append(base)
	return bins


# --- Shape ---------------------------------------------------------------------------

func _base_height(world_x: float, world_z: float) -> float:
	var warp_x: float = noise.warp_a.get_noise_2d(world_x, world_z) * config.warp_strength
	var warp_z: float = noise.warp_b.get_noise_2d(world_x, world_z) * config.warp_strength
	var px: float = world_x + warp_x
	var pz: float = world_z + warp_z

	var relief: float = fields.sample_smooth(fields.relief01, world_x, world_z)
	var base: float = _atlas_base_steepened(world_x, world_z, relief)
	var wet: float = clampf(fields.sample_smooth(fields.water_flag, world_x, world_z), 0.0, 1.0)
	# The sea bed keeps a little detail so it is not a plate, but not enough to
	# rise through the shelf and invent islands the atlas never placed.
	var dryness: float = lerpf(0.18, 1.0, 1.0 - wet)

	var swell: float = (
		noise.swell.get_noise_2d(px, pz) * config.swell_height
		* lerpf(1.0, 0.4, relief)
	)
	var ridge01: float = noise.mountain.get_noise_2d(px * 0.9, pz * 0.9) * 0.5 + 0.5
	var shaped: float = pow(clampf(ridge01, 0.0, 1.0), maxf(config.mountain_sharpness, 0.5))
	# Linear relief (not squared): squared made Peak height feel broken in alpine.
	var ridge: float = (shaped - 0.35) * config.mountain_detail * lerpf(0.35, 1.0, relief)

	return base + (swell + ridge) * dryness


## Amplifies atlas elevation against a local neighbourhood so orogen flanks
## get real slope. Without this, Peak height only adds gentle rolls on a
## kilometre-smooth loft — which is what shallow distant hills look like.
func _atlas_base_steepened(world_x: float, world_z: float, relief: float) -> float:
	var e0: float = fields.sample_smooth(fields.elevation_m, world_x, world_z)
	var contrast: float = config.mountain_macro_contrast
	if contrast <= 1.001 or relief < 0.04:
		return e0
	var r: float = 1400.0
	var e_avg: float = (
		fields.sample_smooth(fields.elevation_m, world_x - r, world_z)
		+ fields.sample_smooth(fields.elevation_m, world_x + r, world_z)
		+ fields.sample_smooth(fields.elevation_m, world_x, world_z - r)
		+ fields.sample_smooth(fields.elevation_m, world_x, world_z + r)
	) * 0.25
	var amount: float = lerpf(1.0, contrast, clampf(relief, 0.0, 1.0))
	return e_avg + (e0 - e_avg) * amount


## Pulls the land down into a valley along every atlas trunk it is near.
##
## Without this the atlas gives a drainage tree with no gutter to run in: the
## detail noise dams the valley floor every few hundred metres and the sector
## flood turns the lowland into a chain of lakes. The trench is a pure function
## of the atlas corridor, so it crosses sector boundaries unchanged.
##
## Every candidate is measured against the *uncarved* height and the lowest one
## wins. Chaining them instead - each carve deepening the result of the last -
## would make the answer depend on the order the segments came back in, and two
## sectors query the corridor index with different rectangles.
func _carve_valleys(
	height: float, world_x: float, world_z: float, bases: PackedInt32Array
) -> float:
	var out: float = height
	for base in bases:
		var ax: float = corridors.rivers[base]
		var ay: float = corridors.rivers[base + 1]
		var az: float = corridors.rivers[base + 2]
		var bx: float = corridors.rivers[base + 3]
		var by: float = corridors.rivers[base + 4]
		var bz: float = corridors.rivers[base + 5]
		var feature_class: int = int(corridors.rivers[base + 8])
		var radius: float = corridors.river_valley_radius(feature_class)

		var t: float = _segment_param(world_x, world_z, ax, az, bx, bz)
		var px: float = ax + (bx - ax) * t
		var pz: float = az + (bz - az) * t
		var d: float = sqrt((world_x - px) * (world_x - px) + (world_z - pz) * (world_z - pz))
		if d >= radius:
			continue
		# Atlas water is a kilometre-scale hint. Detail (ridge × relief²) can
		# dam a valley that only digs trunk_bank_rise metres — common on orogen
		# flanks — so require a gutter deep enough to beat that amplitude.
		var relief01: float = fields.sample_smooth(fields.relief01, world_x, world_z)
		var detail_amp: float = (
			config.mountain_detail * lerpf(0.35, 1.0, relief01) * 0.65
			+ config.swell_height * lerpf(1.0, 0.4, relief01) * 0.35
			+ maxf(config.mountain_macro_contrast - 1.0, 0.0) * 40.0 * relief01
		)
		var min_gutter: float = config.trunk_bank_rise + detail_amp
		var atlas_floor: float = ay + (by - ay) * t + config.trunk_bank_rise
		var floor_z: float = minf(atlas_floor, height - min_gutter)
		floor_z = minf(floor_z, height)
		var ramp: float = smoothstep(0.0, radius, d)
		out = minf(out, lerpf(floor_z, height, ramp))
	return out


## Forces the surface to respect the atlas coastline, and makes the waterline
## itself continuous: depth below and freeboard above both vanish at the zero
## of [method shore_signed], so land does not step into water.
func _shore_authority(height: float, world_x: float, world_z: float) -> float:
	var signed_shore: float = shore_signed(world_x, world_z)
	var plane: float = water_plane_at(world_x, world_z)

	if signed_shore <= 0.0:
		var wetness: float = smoothstep(0.0, SHORE_OUTER, -signed_shore)
		var depth: float = (config.ocean_floor_margin + SHELF_DEPTH * wetness) * wetness
		return minf(height, plane - depth)

	# Inland the plane belongs to whichever body is nearest, which stops being
	# a meaningful statement a few hundred metres from the shore. The lift is
	# therefore confined to the band where it is still true.
	var band: float = 1.0 - smoothstep(0.0, SHORE_OUTER, signed_shore)
	if band <= 0.0:
		return height
	var dryness: float = smoothstep(0.0, SHORE_OUTER, signed_shore)
	var freeboard: float = (config.inland_freeboard + FREEBOARD_SPAN * dryness) * dryness
	return lerpf(height, maxf(height, plane + freeboard), band)


func _relief_amp(relief01: float) -> float:
	var amp: float = lerpf(
		config.relief_amp_plains, config.relief_amp_hills,
		smoothstep(0.12, 0.55, relief01)
	)
	return lerpf(amp, config.relief_amp_mountains, smoothstep(0.55, 0.92, relief01))


func _moisture(world_x: float, world_z: float) -> float:
	var atlas_humidity: float = fields.sample_smooth(fields.humidity01, world_x, world_z)
	var local: float = noise.moisture.get_noise_2d(world_x, world_z) * 0.5 + 0.5
	return clampf(atlas_humidity * 0.75 + local * 0.25, 0.0, 1.0)


## Continental latitude, not window position: the north of the atlas is cold
## wherever you stand in it, and crossing a sector boundary changes nothing.
func temperature_for(world_x: float, world_z: float, height: float) -> float:
	var latitude: float = clampf(world_z / _continent_span, 0.0, 1.0)
	var alpine: float = smoothstep(420.0, 900.0, height)
	return clampf(
		0.28 + latitude * 0.46
		+ noise.temperature.get_noise_2d(world_x, world_z) * 0.16
		- alpine * 0.42,
		0.0, 1.0
	)


static func _segment_param(
	px: float, pz: float, ax: float, az: float, bx: float, bz: float
) -> float:
	var dx: float = bx - ax
	var dz: float = bz - az
	var len_sq: float = dx * dx + dz * dz
	if len_sq < 0.000001:
		return 0.0
	return clampf(((px - ax) * dx + (pz - az) * dz) / len_sq, 0.0, 1.0)
