class_name BridgeSite
extends RefCounted
## Where a road meets water.
##
## Small channels become fords (walk through the shallows); anything wider gets
## a structure. Both anchor to real bank samples so the deck lands on ground the
## density field actually produces.

var id: int = -1
var road_id: int = -1
## Bank anchor points in world space, at the height the deck meets the ground.
var anchor_a: Vector3 = Vector3.ZERO
var anchor_b: Vector3 = Vector3.ZERO
## Water surface height under the crossing (never a global level).
var water_z: float = 0.0
var river_order: int = 1
var deck_width: float = 6.0
var is_ford: bool = false

## Catalog id the placer resolves; procedural spans are built when this is
## `procedural_timber` / `procedural_stone` and no Asset Lab kit is installed.
var catalog_id: StringName = &"procedural_timber"


func center() -> Vector3:
	return (anchor_a + anchor_b) * 0.5


func span_length() -> float:
	return Vector2(anchor_a.x - anchor_b.x, anchor_a.z - anchor_b.z).length()


func direction() -> Vector2:
	var d: Vector2 = Vector2(anchor_b.x - anchor_a.x, anchor_b.z - anchor_a.z)
	return d.normalized() if d.length_squared() > 0.0001 else Vector2.RIGHT


func deck_height() -> float:
	return maxf(anchor_a.y, anchor_b.y)
