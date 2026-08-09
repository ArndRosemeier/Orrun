class_name WorldCoords
extends RefCounted
## Coordinate contract shared by every layer.
##
## World axes: +X east, +Z south, +Y up. There is no finite map any more: every
## persistent position is **continental metres** on an unbounded signed plane,
## and the atlas alone decides what part of that plane is land.
##
## Four grids sit on the plane and every one of them is aligned to the others,
## which is what lets a feature be owned by exactly one generator:
##
##   atlas cell   1000 m   continental authority (climate, coast, trunks)
##   sector       8000 m   unit of lower-layer generation (8 atlas cells)
##   region       1000 m   feature page inside a sector (8 x 8 per sector)
##   chunk          64 m   unit of meshing and streaming (125 per sector)
##
## Sector-local cell indices exist only inside one bake and never leave it.
## Anything that crosses a sector boundary - ports, ids, saved positions - is
## expressed in continental metres or in global (signed) cell coordinates.

const ATLAS_CELL_SIZE: float = 1000.0
const SECTOR_SIZE: float = 8000.0
## Feature page. Divides the sector exactly, so a page never straddles two
## sectors and a chunk never needs features from two pages at once.
const REGION_SIZE: float = 1000.0


# --- Atlas --------------------------------------------------------------------

static func atlas_cell_of(world_x: float, world_z: float) -> Vector2i:
	return Vector2i(floori(world_x / ATLAS_CELL_SIZE), floori(world_z / ATLAS_CELL_SIZE))


static func atlas_cell_origin(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x), float(cell.y)) * ATLAS_CELL_SIZE


# --- Sectors ------------------------------------------------------------------

static func sector_of(world_x: float, world_z: float) -> Vector2i:
	return Vector2i(floori(world_x / SECTOR_SIZE), floori(world_z / SECTOR_SIZE))


static func sector_origin(sector: Vector2i) -> Vector2:
	return Vector2(float(sector.x), float(sector.y)) * SECTOR_SIZE


static func sector_rect(sector: Vector2i) -> Rect2:
	return Rect2(sector_origin(sector), Vector2.ONE * SECTOR_SIZE)


## Owning sector of a chunk. Exact because 8000 m is exactly 125 chunks: no
## chunk is ever shared, so no chunk is ever generated twice from two bakes.
static func sector_of_chunk(config: WorldConfig, chunk: Vector2i) -> Vector2i:
	var per: int = config.chunks_per_sector()
	return Vector2i(floordiv(chunk.x, per), floordiv(chunk.y, per))


static func sector_key(sector: Vector2i) -> int:
	return ((sector.x + 65536) << 18) | (sector.y + 65536)


# --- Chunks -------------------------------------------------------------------

static func chunk_of(config: WorldConfig, world_x: float, world_z: float) -> Vector2i:
	return Vector2i(
		floori(world_x / config.chunk_size),
		floori(world_z / config.chunk_size)
	)


static func chunk_origin(config: WorldConfig, chunk: Vector2i) -> Vector2:
	return Vector2(float(chunk.x), float(chunk.y)) * config.chunk_size


static func chunk_center(config: WorldConfig, chunk: Vector2i) -> Vector2:
	return chunk_origin(config, chunk) + Vector2.ONE * (config.chunk_size * 0.5)


## Stable key for a chunk column. Signed range +-32768 chunks is +-2097 km,
## comfortably past the largest atlas the generator will build.
static func chunk_key(chunk: Vector2i) -> int:
	return ((chunk.x + 32768) << 18) | (chunk.y + 32768)


# --- Regions ------------------------------------------------------------------

static func region_of(world_x: float, world_z: float) -> Vector2i:
	return Vector2i(floori(world_x / REGION_SIZE), floori(world_z / REGION_SIZE))


static func region_of_chunk(config: WorldConfig, chunk: Vector2i) -> Vector2i:
	var origin: Vector2 = chunk_origin(config, chunk)
	return region_of(origin.x, origin.y)


static func region_origin(region: Vector2i) -> Vector2:
	return Vector2(float(region.x), float(region.y)) * REGION_SIZE


static func region_key(region: Vector2i) -> int:
	return ((region.x + 65536) << 18) | (region.y + 65536)


# --- Macro cells ----------------------------------------------------------------

## Global macro cell of a continental position. Signed and unclamped: the cell
## index is a property of the plane, not of whichever sector happens to be
## looking at it. Two sectors that bake the same cell therefore agree on both
## its index and the position it is sampled at.
static func macro_cell_of(config: WorldConfig, world_x: float, world_z: float) -> Vector2i:
	return Vector2i(
		floori(world_x / config.macro_cell_size),
		floori(world_z / config.macro_cell_size)
	)


static func macro_cell_center(config: WorldConfig, cell: Vector2i) -> Vector2:
	return (Vector2(float(cell.x), float(cell.y)) + Vector2.ONE * 0.5) * config.macro_cell_size


## Global macro cell of a sector's lower-left core corner.
static func sector_macro_origin(config: WorldConfig, sector: Vector2i) -> Vector2i:
	var per: int = config.macro_cells_per_sector()
	return Vector2i(sector.x * per, sector.y * per)


# --- Helpers ----------------------------------------------------------------------

## Floor division that keeps working for negative numerators, which integer
## division in GDScript does not: -1 / 125 is 0, and that would hand chunk -1 to
## sector 0 while chunk -125 goes to sector -1.
static func floordiv(value: int, divisor: int) -> int:
	var q: int = value / divisor
	if (value % divisor) != 0 and ((value < 0) != (divisor < 0)):
		q -= 1
	return q
