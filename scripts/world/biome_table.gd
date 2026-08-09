class_name BiomeTable
extends RefCounted
## Biomes are weights, not separate generators: they retint the ground, change
## how much relief the density field is allowed to add, and pick prop tables.

enum Biome { PLAINS = 0, FOREST_HILLS = 1, ROCKY_BADLANDS = 2, ALPINE = 3 }

static var BIOME_NAMES: PackedStringArray = PackedStringArray([
	"Plains", "Forest Hills", "Rocky Badlands", "Alpine"
])

const GRASS_PLAINS: Color = Color(0.36, 0.47, 0.22)
const GRASS_FOREST: Color = Color(0.24, 0.38, 0.19)
const DRY_BADLANDS: Color = Color(0.49, 0.40, 0.25)
const ALPINE_TUNDRA: Color = Color(0.42, 0.44, 0.36)
const ROCK: Color = Color(0.35, 0.34, 0.33)
const SNOW: Color = Color(0.86, 0.88, 0.92)
const RIVER_MUD: Color = Color(0.34, 0.29, 0.21)
const ROAD_DIRT: Color = Color(0.47, 0.37, 0.24)
## Water seen from far enough away that no sheet is drawn for it.
const DISTANT_WATER: Color = Color(0.16, 0.26, 0.34)


static func classify(moisture: float, temperature: float, elevation: float, relief: float) -> int:
	# Thresholds are in metres of this world's own range (roughly 0-820 m). Set
	# the alpine line too low and every rolling hill turns into bare tundra,
	# which reads as one grey landmass from any distance.
	if elevation > 520.0 or temperature < 0.16:
		return Biome.ALPINE
	if moisture < 0.36 and relief > 16.0:
		return Biome.ROCKY_BADLANDS
	if moisture > 0.5 and relief > 7.0:
		return Biome.FOREST_HILLS
	return Biome.PLAINS


static func base_color(biome: int) -> Color:
	match biome:
		Biome.FOREST_HILLS:
			return GRASS_FOREST
		Biome.ROCKY_BADLANDS:
			return DRY_BADLANDS
		Biome.ALPINE:
			return ALPINE_TUNDRA
		_:
			return GRASS_PLAINS


## The ground tint before slope, snow and mud are applied.
##
## Deliberately not [method base_color] of [method classify]: a hard switch on
## the same thresholds draws a visible contour line across every hillside where
## one biome takes over from the next. The classification still decides props
## and relief; only the colour is continuous.
static func ground_color(
	moisture: float, temperature: float, elevation: float, relief: float
) -> Color:
	var forest: float = (
		smoothstep(0.42, 0.60, moisture) * smoothstep(4.0, 12.0, relief)
	)
	var badlands: float = (
		(1.0 - smoothstep(0.28, 0.44, moisture)) * smoothstep(10.0, 22.0, relief)
	)
	var alpine: float = maxf(
		smoothstep(380.0, 560.0, elevation),
		1.0 - smoothstep(0.12, 0.32, temperature)
	)

	var color: Color = GRASS_PLAINS.lerp(GRASS_FOREST, forest)
	color = color.lerp(DRY_BADLANDS, badlands)
	return color.lerp(ALPINE_TUNDRA, alpine)


## Final colour for one vertex. Slope exposes rock, height brings snow, and
## proximity to a channel or shore turns the ground to mud.
static func surface_color(
	ground: Color,
	slope01: float,
	height: float,
	wetness: float,
	snow_line: float,
	roadness: float
) -> Color:
	var rock_mix: float = smoothstep(0.42, 0.78, slope01)
	var color: Color = ground.lerp(ROCK, rock_mix)
	if height > snow_line:
		var snow_mix: float = smoothstep(snow_line, snow_line + 130.0, height) * (1.0 - rock_mix * 0.6)
		color = color.lerp(SNOW, snow_mix)
	# Worn earth last but one: a road crosses biomes and snowfields and still
	# reads as the same road, which is the point of a road.
	if roadness > 0.0:
		color = color.lerp(ROAD_DIRT, clampf(roadness, 0.0, 1.0))
	if wetness > 0.0:
		color = color.lerp(RIVER_MUD, clampf(wetness, 0.0, 1.0) * 0.85)
	return color


## How much of the configured relief amplitude this biome actually uses.
static func relief_scale(biome: int) -> float:
	match biome:
		Biome.PLAINS:
			return 0.55
		Biome.FOREST_HILLS:
			return 0.9
		Biome.ROCKY_BADLANDS:
			return 1.25
		Biome.ALPINE:
			return 1.15
		_:
			return 1.0


static func name_of(biome: int) -> String:
	return BIOME_NAMES[clampi(biome, 0, BIOME_NAMES.size() - 1)]
