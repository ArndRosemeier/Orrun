class_name BridgeSite
extends RefCounted
## Where a road meets water.
##
## Small channels become fords (walk through the shallows); anything wider gets
## a structure. [member deck_z] is the single walking height: density hard-sets
## abutments to it after settlement terracing, and the kit deck sits on the same
## number.

## Inland grade length past the hard apron (metres).
const RAMP_LENGTH: float = 28.0
## Hard deck_z apron inland of each abutment before the ramp starts.
const PLATEAU_LENGTH: float = 6.0
## Extra metres past half deck width for the lateral grade corridor.
const GRADE_HALF_EXTRA: float = 4.0

var id: int = -1
var road_id: int = -1
## Bank anchor points in world space; Y equals [member deck_z].
var anchor_a: Vector3 = Vector3.ZERO
var anchor_b: Vector3 = Vector3.ZERO
## Water surface height under the crossing (never a global level).
var water_z: float = 0.0
var river_order: int = 1
var deck_width: float = 6.0
var is_ford: bool = false

## Kit id from assets/catalog/bridges.json (`timber` / `stone`), or `ford`.
## BridgeBuilder falls back to the box placeholder if the kit mesh is missing.
var catalog_id: StringName = &"timber"

## Authoritative walking height for both abutments and the kit deck.
var deck_z: float = 0.0
## Unit span direction (road heading across water), XZ.
var axis: Vector2 = Vector2.RIGHT
var center_xz: Vector2 = Vector2.ZERO
## Along-axis half-width of the water gap (no fill).
var gap_half: float = 0.0
## Along-axis distance from centre to abutment contact.
var abutment_s: float = 0.0
## Inland ramp length past the hard apron.
var ramp_length: float = RAMP_LENGTH
## Hard deck_z length inland of the abutment before ramping.
var plateau_length: float = PLATEAU_LENGTH
## Lateral half-width of the grade corridor.
var grade_half_width: float = 5.0


func center() -> Vector3:
	return (anchor_a + anchor_b) * 0.5


func span_length() -> float:
	return Vector2(anchor_a.x - anchor_b.x, anchor_a.z - anchor_b.z).length()


func direction() -> Vector2:
	if axis.length_squared() > 0.0001:
		return axis
	var d: Vector2 = Vector2(anchor_b.x - anchor_a.x, anchor_b.z - anchor_a.z)
	return d.normalized() if d.length_squared() > 0.0001 else Vector2.RIGHT


func deck_height() -> float:
	return deck_z


func abutment_a_xz() -> Vector2:
	return center_xz - axis * abutment_s


func abutment_b_xz() -> Vector2:
	return center_xz + axis * abutment_s
