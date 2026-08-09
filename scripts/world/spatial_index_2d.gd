class_name SpatialIndex2D
extends RefCounted
## Uniform bucket grid over the finite map, used to find the polyline segments
## near a chunk without scanning every river or road in the world.
##
## Buckets store opaque integer ids; the owner decides what they mean.

var bucket_size: float = 128.0
var buckets: Dictionary = {}


func _init(size: float = 128.0) -> void:
	bucket_size = size


func _key(bx: int, bz: int) -> int:
	return ((bx + 65536) << 18) | (bz + 65536)


func insert_segment(ax: float, az: float, bx: float, bz: float, id: int) -> void:
	var min_bx: int = floori(minf(ax, bx) / bucket_size)
	var max_bx: int = floori(maxf(ax, bx) / bucket_size)
	var min_bz: int = floori(minf(az, bz) / bucket_size)
	var max_bz: int = floori(maxf(az, bz) / bucket_size)
	for cell_z in range(min_bz, max_bz + 1):
		for cell_x in range(min_bx, max_bx + 1):
			var key: int = _key(cell_x, cell_z)
			var list: PackedInt32Array = buckets.get(key, PackedInt32Array())
			list.append(id)
			buckets[key] = list


## Every id stored in buckets overlapping the rect, de-duplicated.
func query_rect(rect: Rect2) -> PackedInt32Array:
	var min_bx: int = floori(rect.position.x / bucket_size)
	var max_bx: int = floori((rect.position.x + rect.size.x) / bucket_size)
	var min_bz: int = floori(rect.position.y / bucket_size)
	var max_bz: int = floori((rect.position.y + rect.size.y) / bucket_size)
	var seen: Dictionary = {}
	var out: PackedInt32Array = PackedInt32Array()
	for cell_z in range(min_bz, max_bz + 1):
		for cell_x in range(min_bx, max_bx + 1):
			var list: PackedInt32Array = buckets.get(_key(cell_x, cell_z), PackedInt32Array())
			for id in list:
				if not seen.has(id):
					seen[id] = true
					out.append(id)
	return out
