class_name WorldCoords
extends RefCounted
## Coordinate contract shared by every layer.
##
## World axes: +X east, +Z south, +Y up. The map occupies [0, world_size) on X
## and Z. Chunks are columns identified by a Vector2i; their vertical extent is
## derived per chunk from the terrain that actually occupies them.

const REGION_SIZE: float = 1024.0


static func chunk_of(config: WorldConfig, world_x: float, world_z: float) -> Vector2i:
	return Vector2i(
		floori(world_x / config.chunk_size),
		floori(world_z / config.chunk_size)
	)


static func chunk_origin(config: WorldConfig, chunk: Vector2i) -> Vector2:
	return Vector2(float(chunk.x), float(chunk.y)) * config.chunk_size


static func chunk_center(config: WorldConfig, chunk: Vector2i) -> Vector2:
	return chunk_origin(config, chunk) + Vector2.ONE * (config.chunk_size * 0.5)


static func region_of(world_x: float, world_z: float) -> Vector2i:
	return Vector2i(floori(world_x / REGION_SIZE), floori(world_z / REGION_SIZE))


static func region_of_chunk(config: WorldConfig, chunk: Vector2i) -> Vector2i:
	var origin: Vector2 = chunk_origin(config, chunk)
	return region_of(origin.x, origin.y)


static func region_origin(region: Vector2i) -> Vector2:
	return Vector2(float(region.x), float(region.y)) * REGION_SIZE


## Macro cell containing a world position, clamped to the finite map.
static func macro_cell_of(config: WorldConfig, world_x: float, world_z: float) -> Vector2i:
	var last: int = config.macro_cells - 1
	return Vector2i(
		clampi(floori(world_x / config.macro_cell_size), 0, last),
		clampi(floori(world_z / config.macro_cell_size), 0, last)
	)


static func macro_cell_center(config: WorldConfig, cell: Vector2i) -> Vector2:
	return (Vector2(float(cell.x), float(cell.y)) + Vector2.ONE * 0.5) * config.macro_cell_size


static func macro_index(config: WorldConfig, cx: int, cz: int) -> int:
	return cz * config.macro_cells + cx


static func in_bounds(config: WorldConfig, world_x: float, world_z: float) -> bool:
	var size: float = config.world_size()
	return world_x >= 0.0 and world_z >= 0.0 and world_x < size and world_z < size


static func world_center(config: WorldConfig) -> Vector2:
	var half: float = config.world_size() * 0.5
	return Vector2(half, half)


## Stable 32-bit key for a chunk column, for dictionaries and job ids.
static func chunk_key(chunk: Vector2i) -> int:
	return ((chunk.x + 32768) << 16) | (chunk.y + 32768)
