class_name AtlasBiomes
extends RefCounted
## Landcover ids packed into ContinentAtlas climate cells.

enum Id {
	OCEAN = 0,
	COAST = 1,
	PLAINS = 2,
	FOREST = 3,
	WETLAND = 4,
	ARID = 5,
	ALPINE = 6,
	TUNDRA = 7,
	LAKE = 8,
}

static var NAMES: PackedStringArray = PackedStringArray([
	"ocean", "coast", "plains", "forest", "wetland", "arid", "alpine", "tundra", "lake"
])


static func name_of(biome: int) -> String:
	if biome < 0 or biome >= NAMES.size():
		return "biome_%d" % biome
	return NAMES[biome]


static func color_of(biome: int) -> Color:
	match biome:
		Id.OCEAN:
			return Color(0.10, 0.22, 0.40)
		Id.COAST:
			return Color(0.72, 0.66, 0.42)
		Id.PLAINS:
			return Color(0.42, 0.58, 0.28)
		Id.FOREST:
			return Color(0.18, 0.40, 0.20)
		Id.WETLAND:
			return Color(0.28, 0.48, 0.36)
		Id.ARID:
			return Color(0.62, 0.52, 0.32)
		Id.ALPINE:
			return Color(0.55, 0.56, 0.52)
		Id.TUNDRA:
			return Color(0.48, 0.52, 0.44)
		Id.LAKE:
			return Color(0.16, 0.38, 0.58)
		_:
			return Color(1.0, 0.0, 1.0)


static func is_water(biome: int) -> bool:
	return biome == Id.OCEAN or biome == Id.LAKE


static func is_land(biome: int) -> bool:
	return not is_water(biome)
