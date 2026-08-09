class_name MacroTerrain
extends RefCounted
## Layer 1 as one sector sees it: a window onto the continental surface.
##
## The array is sector-local, but the *values* are not. Cell (cx, cz) of this
## window is global macro cell [member origin_cell] + (cx, cz), sampled at that
## cell's continental centre by [ContinentalTerrain]. Two sectors whose windows
## overlap therefore hold identical numbers in the overlap, and a chunk that
## reads across a sector boundary cannot see a step.
##
## Nothing ever writes to [member elevation] after the bake. The old generator
## breached depressions by rewriting the grid, which is exactly the kind of
## local mutation that cannot be made seamless: the drainage gutters now come
## from the atlas corridors instead, and they are a pure function.
##
## This grid is deliberately smooth and coarse: cliffs, overhangs and caves are
## added later by the 3D density field, which is only allowed to deviate from
## this surface away from water and roads (see the corridor mask in
## [DensityField]).

var config: WorldConfig
## Side length of the baked window, core plus halo on both sides.
var cells: int
var cell_size: float
## Global macro cell that local (0, 0) stands for.
var origin_cell: Vector2i = Vector2i.ZERO

## Land surface height in metres, one value per macro cell.
var elevation: PackedFloat32Array
## How many metres of 3D relief detail the density field may add here.
var relief_amp: PackedFloat32Array
var moisture: PackedFloat32Array
var temperature: PackedFloat32Array

var min_elevation: float = 0.0
var max_elevation: float = 0.0


static func bake_window(
	cfg: WorldConfig,
	origin_cell: Vector2i,
	cells: int,
	continental: ContinentalTerrain
) -> MacroTerrain:
	var terrain: MacroTerrain = MacroTerrain.new()
	terrain.config = cfg
	terrain.cells = cells
	terrain.cell_size = cfg.macro_cell_size
	terrain.origin_cell = origin_cell

	var count: int = cells * cells
	terrain.elevation = PackedFloat32Array()
	terrain.elevation.resize(count)
	terrain.relief_amp = PackedFloat32Array()
	terrain.relief_amp.resize(count)
	terrain.moisture = PackedFloat32Array()
	terrain.moisture.resize(count)
	terrain.temperature = PackedFloat32Array()
	terrain.temperature.resize(count)

	continental.fill_window(
		origin_cell, cells,
		terrain.elevation, terrain.relief_amp, terrain.moisture, terrain.temperature
	)

	var lowest: float = INF
	var highest: float = -INF
	for value in terrain.elevation:
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
	terrain.min_elevation = lowest
	terrain.max_elevation = highest
	return terrain


# --- Indexing -------------------------------------------------------------------

func index_of(cx: int, cz: int) -> int:
	return cz * cells + cx


func clamped_index(cx: int, cz: int) -> int:
	var last: int = cells - 1
	return clampi(cz, 0, last) * cells + clampi(cx, 0, last)


func contains_local(cx: int, cz: int) -> bool:
	return cx >= 0 and cz >= 0 and cx < cells and cz < cells


## Local cell for a continental position, unclamped: negative or oversized
## results mean the point is outside this window, and the caller must say so
## rather than silently reading the nearest edge.
func local_cell_of(world_x: float, world_z: float) -> Vector2i:
	return WorldCoords.macro_cell_of(config, world_x, world_z) - origin_cell


## Continental centre of a local cell.
func cell_center(cx: int, cz: int) -> Vector2:
	return WorldCoords.macro_cell_center(config, origin_cell + Vector2i(cx, cz))


func window_rect() -> Rect2:
	var origin: Vector2 = Vector2(
		float(origin_cell.x) * cell_size, float(origin_cell.y) * cell_size
	)
	return Rect2(origin, Vector2.ONE * (float(cells) * cell_size))


# --- Sampling ---------------------------------------------------------------------

## Smooth (Catmull-Rom) elevation lookup in continental metres.
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
	var u: float = world_x / cell_size - 0.5 - float(origin_cell.x)
	var v: float = world_z / cell_size - 0.5 - float(origin_cell.y)
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
