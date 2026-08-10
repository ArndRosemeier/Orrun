class_name SettlementHolding
extends RefCounted
## One peasant tenement: house on the street front, croft strip behind.

var house: HouseSite = null
## Door / street face (toward commons or emergent lane).
var frontage: Vector2 = Vector2.ZERO
## Croft rectangle centre (outward from commons).
var croft_center: Vector2 = Vector2.ZERO
var croft_half_w: float = 3.0
var croft_half_l: float = 8.0
var croft_yaw: float = 0.0


func rear_midpoint() -> Vector2:
	var outward: Vector2 = Vector2(sin(croft_yaw), cos(croft_yaw))
	return croft_center + outward * croft_half_l
