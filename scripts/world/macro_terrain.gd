class_name MacroTerrain
extends RefCounted
## Layer 1: the drainage-scale 2D landscape.
##
## This grid is what hydrology and roads reason about. It is deliberately smooth
## and coarse: cliffs, overhangs and caves are added later by the 3D density
## field, which is only allowed to deviate from this surface away from water and
## roads (see the corridor mask in [DensityField]).

var config: WorldConfig
var cells: int
var cell_size: float

## Land surface height in metres, one value per macro cell.
var elevation: PackedFloat32Array
## How many metres of 3D relief detail the density field may add here.
var relief_amp: PackedFloat32Array
var moisture: PackedFloat32Array
var temperature: PackedFloat32Array

var min_elevation: float = 0.0
var max_elevation: float = 0.0


static func bake(cfg: WorldConfig, noise: NoiseSet) -> MacroTerrain:
	var terrain: MacroTerrain = MacroTerrain.new()
	terrain.config = cfg
	terrain.cells = cfg.macro_cells
	terrain.cell_size = cfg.macro_cell_size

	var n: int = cfg.macro_cells
	var count: int = n * n
	terrain.elevation = PackedFloat32Array()
	terrain.elevation.resize(count)
	terrain.relief_amp = PackedFloat32Array()
	terrain.relief_amp.resize(count)
	terrain.moisture = PackedFloat32Array()
	terrain.moisture.resize(count)
	terrain.temperature = PackedFloat32Array()
	terrain.temperature.resize(count)

	var cs: float = cfg.macro_cell_size
	var world_size: float = cfg.world_size()
	var lowest: float = INF
	var highest: float = -INF

	for cz in n:
		var wz: float = (float(cz) + 0.5) * cs
		for cx in n:
			var wx: float = (float(cx) + 0.5) * cs

			var warp_x: float = noise.warp_a.get_noise_2d(wx, wz) * cfg.warp_strength
			var warp_z: float = noise.warp_b.get_noise_2d(wx, wz) * cfg.warp_strength
			var px: float = wx + warp_x
			var pz: float = wz + warp_z

			var cont: float = noise.continent.get_noise_2d(px, pz)
			var ridge01: float = noise.mountain.get_noise_2d(px * 0.9, pz * 0.9) * 0.5 + 0.5

			var land: float = smoothstep(-0.45, 0.35, cont)
			var belt: float = smoothstep(0.05, 0.60, cont)
			var alpine: float = belt * belt * pow(ridge01, 1.4)

			var elev: float = cfg.elevation_sea_base
			elev += land * cfg.elevation_land_scale
			elev += alpine * cfg.mountain_height

			# Rolling ground, strongest on the flats. A smoothstep of continental
			# noise is almost level over kilometres, and a level kilometre has no
			# valleys: the flood fills it edge to edge and the map turns to lake.
			elev += (
				noise.swell.get_noise_2d(px, pz) * cfg.swell_height
				* lerpf(1.0, 0.35, alpine)
			)

			# A very gentle dome over the whole map. Without it, large enclosed
			# basins form and the priority flood turns them into inland seas;
			# with it, most water finds its way to the rim and lakes stay lakes.
			elev += _dome_bias(wx, wz, world_size, cfg.drainage_dome)

			# Map rim drops away so drainage has somewhere to leave the map.
			var edge: float = _edge_falloff(wx, wz, world_size)
			elev = lerpf(-14.0, elev, edge)

			var amp: float = lerpf(cfg.relief_amp_plains, cfg.relief_amp_hills, land)
			amp = lerpf(amp, cfg.relief_amp_mountains, clampf(alpine * 1.6, 0.0, 1.0))

			var index: int = cz * n + cx
			terrain.elevation[index] = elev
			terrain.relief_amp[index] = amp
			terrain.moisture[index] = clampf(
				noise.moisture.get_noise_2d(wx, wz) * 0.5 + 0.5 + (0.25 - alpine * 0.2),
				0.0, 1.0
			)
			terrain.temperature[index] = clampf(
				0.5 + noise.temperature.get_noise_2d(wx, wz) * 0.28
				+ (0.5 - wz / world_size) * 0.35
				- alpine * 0.45,
				0.0, 1.0
			)

			lowest = minf(lowest, elev)
			highest = maxf(highest, elev)

	terrain.min_elevation = lowest
	terrain.max_elevation = highest
	return terrain


static func _dome_bias(wx: float, wz: float, world_size: float, strength: float) -> float:
	var half: float = world_size * 0.5
	var dx: float = (wx - half) / half
	var dz: float = (wz - half) / half
	return (1.0 - clampf((dx * dx + dz * dz) * 0.5, 0.0, 1.0)) * strength


static func _edge_falloff(wx: float, wz: float, world_size: float) -> float:
	var margin: float = world_size * 0.07
	var dx: float = minf(wx, world_size - wx)
	var dz: float = minf(wz, world_size - wz)
	var d: float = minf(dx, dz)
	return smoothstep(0.0, margin, d)


func index_of(cx: int, cz: int) -> int:
	return cz * cells + cx


func clamped_index(cx: int, cz: int) -> int:
	var last: int = cells - 1
	return clampi(cz, 0, last) * cells + clampi(cx, 0, last)


## Smooth (Catmull-Rom) elevation lookup in world metres.
## Bilinear would leave visible 32 m creases across every plain.
func height_at(world_x: float, world_z: float) -> float:
	return _sample_smooth(elevation, world_x, world_z)


func relief_amp_at(world_x: float, world_z: float) -> float:
	return _sample_smooth(relief_amp, world_x, world_z)


func moisture_at(world_x: float, world_z: float) -> float:
	return _sample_smooth(moisture, world_x, world_z)


func temperature_at(world_x: float, world_z: float) -> float:
	return _sample_smooth(temperature, world_x, world_z)


## Catmull-Rom lookup into any field laid out on this grid. Public so the
## hydrology can sample its own per-cell arrays the same smooth way the terrain
## is sampled: mixing a smooth height with a cell-quantised water level is what
## produces stair-stepped shorelines.
func sample_field(field: PackedFloat32Array, world_x: float, world_z: float) -> float:
	return _sample_smooth(field, world_x, world_z)


func _sample_smooth(field: PackedFloat32Array, world_x: float, world_z: float) -> float:
	var u: float = world_x / cell_size - 0.5
	var v: float = world_z / cell_size - 0.5
	var ix: int = floori(u)
	var iz: int = floori(v)
	var tx: float = u - float(ix)
	var tz: float = v - float(iz)

	# Called for every sample column of every chunk, so this stays allocation
	# free: four stack floats instead of a temporary array.
	var r0: float = _row(field, ix, iz - 1, tx)
	var r1: float = _row(field, ix, iz, tx)
	var r2: float = _row(field, ix, iz + 1, tx)
	var r3: float = _row(field, ix, iz + 2, tx)
	return _catmull(r0, r1, r2, r3, tz)


func _row(field: PackedFloat32Array, ix: int, cz: int, tx: float) -> float:
	var last: int = cells - 1
	var row: int = clampi(cz, 0, last) * cells
	return _catmull(
		field[row + clampi(ix - 1, 0, last)],
		field[row + clampi(ix, 0, last)],
		field[row + clampi(ix + 1, 0, last)],
		field[row + clampi(ix + 2, 0, last)],
		tx
	)


static func _catmull(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * (
		2.0 * p1
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)
