class_name RiverPolyline
extends RefCounted
## One reach of a river: a run of channel with constant Strahler order.
##
## Point.y is the WATER SURFACE elevation at that station, taken from the
## depression-filled drainage surface. It never rises downstream. There is no
## global water level anywhere in this project; this per-station height is the
## only thing that decides where river water sits.

var id: int = -1
## World-space stations. x/z are horizontal, y is the water surface height.
var points: PackedVector3Array = PackedVector3Array()
## Channel half-width in metres at each station.
var half_width: PackedFloat32Array = PackedFloat32Array()
var order: int = 1
## Bed depth below the water surface.
var depth: float = 1.0
## Distance from the channel edge over which the bank ramps back to terrain.
var valley: float = 24.0
## Reach this one flows into, or -1 when it leaves the map.
var downstream_id: int = -1
## Lake this reach flows into, or -1.
var ends_in_lake: int = -1

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


func max_half_width() -> float:
	var w: float = 0.0
	for v in half_width:
		w = maxf(w, v)
	return w
