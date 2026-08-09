class_name RoadEdge
extends RefCounted
## One road between two landmarks. Point.y is the finished road surface height,
## which the density field benches the terrain to.

enum Tier { PRIMARY = 0, SECONDARY = 1, TRAIL = 2 }

static var TIER_NAMES: PackedStringArray = PackedStringArray(["primary", "secondary", "trail"])


static func tier_name(tier: Tier) -> String:
	return TIER_NAMES[clampi(int(tier), 0, TIER_NAMES.size() - 1)]

var id: int = -1
var tier: Tier = Tier.SECONDARY
var points: PackedVector3Array = PackedVector3Array()
var half_width: float = 3.0
var from_node: int = -1
var to_node: int = -1
var crossings: Array[BridgeSite] = []
var bounds: Rect2 = Rect2()


func compute_bounds() -> void:
	if points.is_empty():
		bounds = Rect2()
		return
	var min_x: float = INF
	var min_z: float = INF
	var max_x: float = -INF
	var max_z: float = -INF
	for p in points:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)
	bounds = Rect2(min_x, min_z, max_x - min_x, max_z - min_z)
