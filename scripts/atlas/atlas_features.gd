class_name AtlasFeatures
extends RefCounted
## Continuity enums and helpers for the continent atlas.


enum Kind { RIVER = 0, ROAD = 1 }

enum Dir { EAST = 0, SOUTH = 1, WEST = 2, NORTH = 3 }

enum EndpointKind { EDGE_PORT = 0, OCEAN = 1, LAKE = 2, NODE = 3 }

enum NodeKind {
	COASTAL_GATE = 0,
	LAKE_SHORE = 1,
	PASS = 2,
	LANDMARK = 3,
	SETTLEMENT = 4,
	CLAIM_RESERVED = 5,
}

enum RoadClass { PRIMARY = 0, SECONDARY = 1, TRAIL = 2 }


static func opposite_dir(dir: int) -> int:
	match dir:
		Dir.EAST:
			return Dir.WEST
		Dir.WEST:
			return Dir.EAST
		Dir.SOUTH:
			return Dir.NORTH
		Dir.NORTH:
			return Dir.SOUTH
	return dir


static func dir_delta(dir: int) -> Vector2i:
	match dir:
		Dir.EAST:
			return Vector2i(1, 0)
		Dir.WEST:
			return Vector2i(-1, 0)
		Dir.SOUTH:
			return Vector2i(0, 1)
		Dir.NORTH:
			return Vector2i(0, -1)
	return Vector2i.ZERO


## Canonical edge key owned by the west cell (EAST) or north cell (SOUTH).
static func edge_key(ax: int, az: int, dir: int, size: int) -> int:
	var oax: int = ax
	var oaz: int = az
	var odir: int = dir
	if dir == Dir.WEST:
		oax = ax - 1
		odir = Dir.EAST
	elif dir == Dir.NORTH:
		oaz = az - 1
		odir = Dir.SOUTH
	assert(oax >= 0 and oaz >= 0 and oax < size and oaz < size)
	assert(odir == Dir.EAST or odir == Dir.SOUTH)
	return oax | (oaz << 12) | (odir << 24)


static func edge_owner(key: int) -> Vector3i:
	return Vector3i(key & 0xFFF, (key >> 12) & 0xFFF, (key >> 24) & 0xF)


static func node_kind_name(kind: int) -> String:
	match kind:
		NodeKind.COASTAL_GATE:
			return "gate"
		NodeKind.LAKE_SHORE:
			return "lake"
		NodeKind.PASS:
			return "pass"
		NodeKind.LANDMARK:
			return "mark"
		NodeKind.SETTLEMENT:
			return "town"
		NodeKind.CLAIM_RESERVED:
			return "claim"
	return "?"
