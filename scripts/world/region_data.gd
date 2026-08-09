class_name RegionData
extends RefCounted
## Feature page inside one sector: the layer boundary between a baked sector
## and the chunks meshed from it.
##
## A page is built before any chunk inside it. It carries the hydrology, roads
## and claims that overlap it, so a chunk job never has to search the whole
## sector and - more importantly - never invents features of its own. Two
## neighbouring chunks reading the same page see the same river, which is why
## they agree across the border.
##
## A page is 1000 m and a sector is 8000 m, so a page never straddles two
## sectors and always has exactly one owner.

var region: Vector2i
var rect: Rect2
var rivers: Array[RiverPolyline] = []
var lakes: Array[LakeData] = []
var roads: Array[RoadEdge] = []
var bridges: Array[BridgeSite] = []
var claims: Array[ClaimMask.Claim] = []

## Elevation span, used by the streamer to size vertical work.
var min_height: float = 0.0
var max_height: float = 0.0


static func build(sector: WorldSector, region_coord: Vector2i) -> RegionData:
	var data: RegionData = RegionData.new()
	data.region = region_coord
	var origin: Vector2 = WorldCoords.region_origin(region_coord)
	data.rect = Rect2(origin, Vector2.ONE * WorldCoords.REGION_SIZE)
	# Grown so a chunk on the page boundary still finds every feature that can
	# reach it, including the ones whose valley starts on the next page.
	var padded: Rect2 = data.rect.grow(160.0)

	var seen_reaches: Dictionary = {}
	for encoded in sector.hydro.river_index.query_rect(padded):
		var reach_id: int = encoded >> 16
		if seen_reaches.has(reach_id):
			continue
		seen_reaches[reach_id] = true
		data.rivers.append(sector.hydro.rivers[reach_id])

	var seen_roads: Dictionary = {}
	for encoded in sector.paths.road_index.query_rect(padded):
		var road_id: int = encoded >> 16
		if seen_roads.has(road_id):
			continue
		seen_roads[road_id] = true
		data.roads.append(sector.paths.roads[road_id])

	data.lakes = sector.lakes_in_rect(padded)
	data.bridges = sector.bridges_in_rect(padded)
	data.claims = sector.claims.claims_in_rect(padded)

	var lowest: float = INF
	var highest: float = -INF
	var step: float = sector.config.macro_cell_size
	var x: float = origin.x
	while x <= origin.x + WorldCoords.REGION_SIZE:
		var z: float = origin.y
		while z <= origin.y + WorldCoords.REGION_SIZE:
			var h: float = sector.terrain.height_at(x, z)
			lowest = minf(lowest, h)
			highest = maxf(highest, h)
			z += step
		x += step
	data.min_height = lowest
	data.max_height = highest
	return data
