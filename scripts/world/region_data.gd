class_name RegionData
extends RefCounted
## Layer boundary between the baked world and chunk generation.
##
## A region is built before any chunk inside it. It carries the hydrology, roads
## and claims that overlap it, so a chunk job never has to search the whole map
## and - more importantly - never invents features of its own. Two neighbouring
## chunks reading the same region see the same river, which is why they agree
## across the border.

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


static func build(map: WorldMap, region_coord: Vector2i) -> RegionData:
	var data: RegionData = RegionData.new()
	data.region = region_coord
	var origin: Vector2 = WorldCoords.region_origin(region_coord)
	data.rect = Rect2(origin, Vector2.ONE * WorldCoords.REGION_SIZE)
	var padded: Rect2 = data.rect.grow(160.0)

	var seen_reaches: Dictionary = {}
	for encoded in map.hydro.river_index.query_rect(padded):
		var reach_id: int = encoded >> 16
		if seen_reaches.has(reach_id):
			continue
		seen_reaches[reach_id] = true
		data.rivers.append(map.hydro.rivers[reach_id])

	var seen_roads: Dictionary = {}
	for encoded in map.paths.road_index.query_rect(padded):
		var road_id: int = encoded >> 16
		if seen_roads.has(road_id):
			continue
		seen_roads[road_id] = true
		data.roads.append(map.paths.roads[road_id])

	data.lakes = map.lakes_in_rect(padded)
	data.bridges = map.bridges_in_rect(padded)
	data.claims = map.claims.claims_in_rect(padded)

	var lowest: float = INF
	var highest: float = -INF
	var config: WorldConfig = map.config
	var step: float = config.macro_cell_size
	var x: float = origin.x
	while x <= origin.x + WorldCoords.REGION_SIZE:
		var z: float = origin.y
		while z <= origin.y + WorldCoords.REGION_SIZE:
			var h: float = map.terrain.height_at(x, z)
			lowest = minf(lowest, h)
			highest = maxf(highest, h)
			z += step
		x += step
	data.min_height = lowest
	data.max_height = highest
	return data
