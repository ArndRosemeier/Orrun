class_name NoiseSet
extends RefCounted
## Every noise field the world uses, built from one config.
##
## FastNoiseLite objects are cheap to build and are NOT shared between threads:
## each worker job constructs its own NoiseSet so generation stays reentrant and
## deterministic regardless of scheduling.

var continent: FastNoiseLite
## Rolling ground between the continental shape and the 3D relief. Without it
## the lowlands are a table, and a priority flood turns a table into an inland
## sea.
var swell: FastNoiseLite
var mountain: FastNoiseLite
var warp_a: FastNoiseLite
var warp_b: FastNoiseLite
var moisture: FastNoiseLite
var temperature: FastNoiseLite
var relief: FastNoiseLite
var relief_fine: FastNoiseLite
var overhang: FastNoiseLite
var cave_a: FastNoiseLite
var cave_b: FastNoiseLite
var meander: FastNoiseLite
var scatter: FastNoiseLite


static func create(config: WorldConfig) -> NoiseSet:
	var built: NoiseSet = NoiseSet.new()

	built.continent = _make(
		config.layer_seed("continent"), config.continent_noise_scale,
		FastNoiseLite.FRACTAL_FBM, 5, 0.5, 2.0
	)
	built.swell = _make(
		config.layer_seed("swell"), config.swell_scale,
		FastNoiseLite.FRACTAL_FBM, 4, 0.52, 2.1
	)
	built.mountain = _make(
		config.layer_seed("mountain"), config.mountain_noise_scale,
		FastNoiseLite.FRACTAL_RIDGED, 5, 0.5, 2.05
	)
	built.warp_a = _make(
		config.layer_seed("warp_a"), config.continent_noise_scale * 0.55,
		FastNoiseLite.FRACTAL_FBM, 3, 0.5, 2.0
	)
	built.warp_b = _make(
		config.layer_seed("warp_b"), config.continent_noise_scale * 0.55,
		FastNoiseLite.FRACTAL_FBM, 3, 0.5, 2.0
	)
	built.moisture = _make(
		config.layer_seed("moisture"), 2100.0, FastNoiseLite.FRACTAL_FBM, 3, 0.5, 2.0
	)
	built.temperature = _make(
		config.layer_seed("temperature"), 4200.0, FastNoiseLite.FRACTAL_FBM, 2, 0.5, 2.0
	)
	built.relief = _make(
		config.layer_seed("relief"), 190.0, FastNoiseLite.FRACTAL_RIDGED, 4, 0.55, 2.1
	)
	built.relief_fine = _make(
		config.layer_seed("relief_fine"), 41.0, FastNoiseLite.FRACTAL_FBM, 3, 0.5, 2.0
	)
	built.overhang = _make(
		config.layer_seed("overhang"), config.overhang_scale,
		FastNoiseLite.FRACTAL_FBM, 3, 0.55, 2.0
	)
	built.cave_a = _make(
		config.layer_seed("cave_a"), config.cave_scale, FastNoiseLite.FRACTAL_FBM, 2, 0.5, 2.0
	)
	built.cave_b = _make(
		config.layer_seed("cave_b"), config.cave_scale * 0.77,
		FastNoiseLite.FRACTAL_FBM, 2, 0.5, 2.0
	)
	built.meander = _make(
		config.layer_seed("meander"), config.meander_scale, FastNoiseLite.FRACTAL_FBM, 3, 0.5, 2.0
	)
	built.scatter = _make(
		config.layer_seed("scatter"), 120.0, FastNoiseLite.FRACTAL_FBM, 2, 0.5, 2.0
	)
	return built


static func _make(
	seed_value: int,
	period: float,
	fractal: FastNoiseLite.FractalType,
	octaves: int,
	gain: float,
	lacunarity: float
) -> FastNoiseLite:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed_value
	noise.frequency = 1.0 / period
	noise.fractal_type = fractal
	noise.fractal_octaves = octaves
	noise.fractal_gain = gain
	noise.fractal_lacunarity = lacunarity
	return noise
