class_name VillageTier
extends RefCounted
## Settlement size class derived from atlas population and river-mouth proximity.

enum Tier { HAMLET = 0, VILLAGE = 1, TOWN = 2, PORT = 3 }

## Wilderness keep-out / influence — sized for HamletLab max_settle envelopes.
static var CLAIM_RADIUS: PackedFloat32Array = PackedFloat32Array([140.0, 200.0, 400.0, 720.0])
## Soft growth hint; bake uses Plan.built_envelope from the lab when available.
static var BUILT_RADIUS: PackedFloat32Array = PackedFloat32Array([100.0, 170.0, 360.0, 680.0])
static var PLAZA_RADIUS: PackedFloat32Array = PackedFloat32Array([10.0, 14.0, 20.0, 30.0])
static var NAME: PackedStringArray = PackedStringArray(["hamlet", "village", "town", "port"])


static func classify(population: int, mouth_dist: int) -> int:
	# Mouth cells with strong occupancy become ports; other mouth hinterland
	# and dense inland peaks become towns; the rest taper to hamlet.
	if mouth_dist == 0 and population >= 10:
		return Tier.PORT
	if mouth_dist == 0 or population >= 11:
		return Tier.TOWN
	if population >= 9 or mouth_dist > 0:
		return Tier.VILLAGE
	return Tier.HAMLET


static func from_atlas_node(atlas: ContinentAtlas, node: AtlasGraphNode) -> int:
	var pop: int = AtlasPack.population(atlas.cell_at(node.ax, node.az))
	var mouth: int = atlas.mouth_distance_at(node.ax, node.az)
	return classify(pop, mouth)


static func claim_radius(tier: int) -> float:
	return CLAIM_RADIUS[clampi(tier, 0, Tier.PORT)]


static func built_radius(tier: int) -> float:
	return BUILT_RADIUS[clampi(tier, 0, Tier.PORT)]


static func plaza_radius(tier: int) -> float:
	return PLAZA_RADIUS[clampi(tier, 0, Tier.PORT)]


static func name_of(tier: int) -> String:
	return NAME[clampi(tier, 0, Tier.PORT)]
