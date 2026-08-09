class_name AtlasFields
extends RefCounted
## The atlas, unpacked once into float grids the 3D world can interpolate.
##
## The atlas stores quantised codes per 1 km cell. Sampling those codes per
## chunk would put a 1 km staircase through every hillside, so they are unpacked
## here into continuous fields and read with a Catmull-Rom kernel.
##
## [member water_plane] is the piece that makes shorelines work. Every cell -
## wet or dry - carries the surface height of the nearest water body, spread by
## a chamfer distance transform over the whole continent. A column near a shore
## therefore knows which body it is on the edge of and at what height, without
## guessing from bounding boxes and picking up a different lake across the
## valley.
##
## Immutable after [method build]; worker threads only read it.

const CHAMFER_STRAIGHT: float = 1.0
const CHAMFER_DIAGONAL: float = 1.41421356

var size: int = 0
var sea_surface_z: float = 0.0

## Land surface height per atlas cell, in metres.
var elevation_m: PackedFloat32Array = PackedFloat32Array()
## 0..1 humidity and relief, unpacked from their codes.
var humidity01: PackedFloat32Array = PackedFloat32Array()
var relief01: PackedFloat32Array = PackedFloat32Array()
## 1.0 where the atlas says the cell is ocean or lake, 0.0 on land.
var water_flag: PackedFloat32Array = PackedFloat32Array()
## Surface height of the nearest water body, in metres, everywhere.
var water_plane: PackedFloat32Array = PackedFloat32Array()
## Distance in atlas cells to the nearest water cell.
var water_distance: PackedFloat32Array = PackedFloat32Array()


static func build(atlas: ContinentAtlas) -> AtlasFields:
	var fields: AtlasFields = AtlasFields.new()
	fields.size = atlas.size
	fields.sea_surface_z = float(atlas.sea_surface_z)

	var count: int = atlas.size * atlas.size
	fields.elevation_m.resize(count)
	fields.humidity01.resize(count)
	fields.relief01.resize(count)
	fields.water_flag.resize(count)
	fields.water_plane.resize(count)
	fields.water_distance.resize(count)

	for i in count:
		var cell: int = atlas.cells[i]
		fields.elevation_m[i] = float(AtlasPack.elevation_to_metres(AtlasPack.elevation(cell)))
		fields.humidity01[i] = float(AtlasPack.humidity(cell)) / 255.0
		fields.relief01[i] = float(AtlasPack.relief(cell)) / 63.0

		var biome: int = AtlasPack.biome(cell)
		var wet: bool = biome == AtlasBiomes.Id.OCEAN or biome == AtlasBiomes.Id.LAKE
		fields.water_flag[i] = 1.0 if wet else 0.0
		if wet:
			fields.water_distance[i] = 0.0
			fields.water_plane[i] = fields._surface_of(atlas, i, biome)
		else:
			fields.water_distance[i] = INF
			fields.water_plane[i] = fields.sea_surface_z

	fields._spread_water_plane()
	return fields


func _surface_of(atlas: ContinentAtlas, index: int, biome: int) -> float:
	if biome == AtlasBiomes.Id.LAKE:
		var id: int = atlas.lake_id[index]
		if id >= 0 and id < atlas.lakes.size():
			return float(atlas.lakes[id].surface_z)
	return sea_surface_z


## Two-pass chamfer sweep. Cheap, deterministic, and good enough: the plane is
## only used inside a shore band, where the nearest body is unambiguous.
func _spread_water_plane() -> void:
	for z in size:
		for x in size:
			var i: int = z * size + x
			if x > 0:
				_relax(i, i - 1, CHAMFER_STRAIGHT)
			if z > 0:
				_relax(i, i - size, CHAMFER_STRAIGHT)
			if x > 0 and z > 0:
				_relax(i, i - size - 1, CHAMFER_DIAGONAL)
			if x < size - 1 and z > 0:
				_relax(i, i - size + 1, CHAMFER_DIAGONAL)
	for z in range(size - 1, -1, -1):
		for x in range(size - 1, -1, -1):
			var i: int = z * size + x
			if x < size - 1:
				_relax(i, i + 1, CHAMFER_STRAIGHT)
			if z < size - 1:
				_relax(i, i + size, CHAMFER_STRAIGHT)
			if x < size - 1 and z < size - 1:
				_relax(i, i + size + 1, CHAMFER_DIAGONAL)
			if x > 0 and z < size - 1:
				_relax(i, i + size - 1, CHAMFER_DIAGONAL)


func _relax(target: int, source: int, step: float) -> void:
	var candidate: float = water_distance[source] + step
	if candidate < water_distance[target]:
		water_distance[target] = candidate
		water_plane[target] = water_plane[source]


# --- Sampling -------------------------------------------------------------------

func index_of(ax: int, az: int) -> int:
	var last: int = size - 1
	return clampi(az, 0, last) * size + clampi(ax, 0, last)


## Catmull-Rom read of any per-cell field at continental metres. Smooth enough
## that the 1 km lattice never shows in a hillside.
func sample_smooth(field: PackedFloat32Array, world_x: float, world_z: float) -> float:
	var u: float = world_x / WorldCoords.ATLAS_CELL_SIZE - 0.5
	var v: float = world_z / WorldCoords.ATLAS_CELL_SIZE - 0.5
	var ix: int = floori(u)
	var iz: int = floori(v)
	var tx: float = u - float(ix)
	var tz: float = v - float(iz)
	return _catmull(
		_row(field, ix, iz - 1, tx),
		_row(field, ix, iz, tx),
		_row(field, ix, iz + 1, tx),
		_row(field, ix, iz + 2, tx),
		tz
	)


## Bilinear read, for fields where Catmull-Rom overshoot would invent a water
## height that belongs to no body.
func sample_linear(field: PackedFloat32Array, world_x: float, world_z: float) -> float:
	var u: float = world_x / WorldCoords.ATLAS_CELL_SIZE - 0.5
	var v: float = world_z / WorldCoords.ATLAS_CELL_SIZE - 0.5
	var ix: int = floori(u)
	var iz: int = floori(v)
	var tx: float = u - float(ix)
	var tz: float = v - float(iz)
	var a: float = lerpf(field[index_of(ix, iz)], field[index_of(ix + 1, iz)], tx)
	var b: float = lerpf(field[index_of(ix, iz + 1)], field[index_of(ix + 1, iz + 1)], tx)
	return lerpf(a, b, tz)


func _row(field: PackedFloat32Array, ix: int, az: int, tx: float) -> float:
	return _catmull(
		field[index_of(ix - 1, az)],
		field[index_of(ix, az)],
		field[index_of(ix + 1, az)],
		field[index_of(ix + 2, az)],
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
