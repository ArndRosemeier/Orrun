class_name ClaimMask
extends RefCounted
## Reservation layer. Nothing in slice 1 builds towns or dungeons, but the land
## they will need is already spoken for, so later content does not have to fight
## roads, props and terrain detail that were placed as if the map were empty.
##
## A claim is a circle with a kind. Generators consult it before dressing or
## carving: props stay out, and roads pay a cost to cross non-settlement claims.

class Claim extends RefCounted:
	var id: int = -1
	var kind: StringName = &""
	var center: Vector2 = Vector2.ZERO
	var radius: float = 0.0
	var ground_z: float = 0.0
	## Built envelope for settlements (houses/crofts); meadow starts outside this.
	var built_radius: float = 0.0

	func contains(x: float, z: float) -> bool:
		return Vector2(x, z).distance_squared_to(center) <= radius * radius


var claims: Array[Claim] = []
var _index: SpatialIndex2D = SpatialIndex2D.new(256.0)


func add(
	kind: StringName,
	center: Vector2,
	radius: float,
	ground_z: float,
	built_radius: float = 0.0
) -> Claim:
	var claim: Claim = Claim.new()
	claim.id = claims.size()
	claim.kind = kind
	claim.center = center
	claim.radius = radius
	claim.ground_z = ground_z
	claim.built_radius = built_radius
	claims.append(claim)
	_index.insert_segment(
		center.x - radius, center.y - radius,
		center.x + radius, center.y + radius,
		claim.id
	)
	return claim


func claims_in_rect(rect: Rect2) -> Array[Claim]:
	var out: Array[Claim] = []
	for id in _index.query_rect(rect):
		out.append(claims[id])
	return out


## Kind of the claim covering this point, or empty when the land is free.
func kind_at(x: float, z: float) -> StringName:
	var claim: Claim = claim_at(x, z)
	return claim.kind if claim != null else &""


## First claim covering this point, or null when free.
func claim_at(x: float, z: float) -> Claim:
	var rect: Rect2 = Rect2(x - 1.0, z - 1.0, 2.0, 2.0)
	for id in _index.query_rect(rect):
		var claim: Claim = claims[id]
		if claim.contains(x, z):
			return claim
	return null


func is_reserved(x: float, z: float) -> bool:
	return kind_at(x, z) != &""


## How far inside a claim this point lies, as 0 at the boundary rising to 1 at
## the centre. Scatterers use it instead of [method is_reserved] so a reservation
## thins its surroundings rather than stamping a circle into them: a hard radius
## test leaves a bare disc ringed by trees, which is the most obvious tell a
## procedural world can produce.
func reservation_depth(x: float, z: float) -> float:
	var rect: Rect2 = Rect2(x - 1.0, z - 1.0, 2.0, 2.0)
	var deepest: float = 0.0
	for id in _index.query_rect(rect):
		var claim: Claim = claims[id]
		if claim.radius <= 0.0:
			continue
		var d: float = Vector2(x, z).distance_to(claim.center) / claim.radius
		deepest = maxf(deepest, 1.0 - clampf(d, 0.0, 1.0))
	return deepest
