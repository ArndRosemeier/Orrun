class_name WorldContext
extends RefCounted
## Everything the world generator needs that is the same for every sector.
##
## Immutable once built. Sector and chunk jobs hold a reference to it and only
## read, which is what makes generation reentrant: a sector is a pure function
## of (this context, its sector coordinate), and nothing else.
##
## The atlas is the authority; [AtlasFields] is that authority unpacked into
## interpolatable grids, and [AtlasCorridors] is the continental river and road
## network reconstructed once so no sector has to guess at it.

var config: WorldConfig
var atlas: ContinentAtlas
var fields: AtlasFields
var corridors: AtlasCorridors
## Settlement detail-damp masks: [cx, cz, radius]… (no target height).
var settlement_pads: PackedFloat32Array = PackedFloat32Array()

## Timings of the one-off continental build, for the loading screen and HUD.
var build_timings: Dictionary = {}


static func create(cfg: WorldConfig, continent: ContinentAtlas) -> WorldContext:
	var context: WorldContext = WorldContext.new()
	context.config = cfg
	context.atlas = continent

	var t0: int = Time.get_ticks_msec()
	context.fields = AtlasFields.build(continent)
	var t1: int = Time.get_ticks_msec()
	context.corridors = AtlasCorridors.build(cfg, continent)
	var t2: int = Time.get_ticks_msec()
	context.settlement_pads = ContinentalTerrain.build_settlement_pads(continent)
	var t3: int = Time.get_ticks_msec()

	context.build_timings = {
		"atlas_ms": continent.generate_ms,
		"fields_ms": t1 - t0,
		"corridors_ms": t2 - t1,
		"settlement_pads_ms": t3 - t2,
	}
	return context


## A fresh continental sampler for the calling thread.
##
## Never share one: it owns a [NoiseSet], and FastNoiseLite is not safe to read
## from two threads at once. Building one is cheap.
func sampler() -> ContinentalTerrain:
	return ContinentalTerrain.create(config, fields, corridors, settlement_pads)


## Key that any derived, cached artifact must be stored under. Changing the
## atlas, its schema, the config, or the edge contract version invalidates it.
func content_key() -> int:
	var h: int = config.content_hash()
	h = (h ^ hash(atlas.content_hash)) * 1099511628211
	h = (h ^ hash(atlas.schema_version)) * 1099511628211
	return h & 0x7FFFFFFFFFFFFFFF


## True when the sector lies inside the atlas. Beyond it there is no authority
## for climate or coast, so there is no world either.
func sector_in_atlas(sector: Vector2i) -> bool:
	var span: float = config.continent_metres()
	var rect: Rect2 = WorldCoords.sector_rect(sector)
	return (
		rect.position.x >= 0.0 and rect.position.y >= 0.0
		and rect.position.x + rect.size.x <= span
		and rect.position.y + rect.size.y <= span
	)
