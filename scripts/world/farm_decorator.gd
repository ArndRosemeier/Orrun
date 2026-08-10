class_name FarmDecorator
extends RefCounted
## Retired scatter path — farmland is planned inside [SettlementPlanner].
##
## Kept as a named type so older call sites and docs resolve; decorate() returns
## farm catalog sites from a full settlement plan.

static func decorate(
	area: VillageDecorator.Area, terrain: MacroTerrain, hydro: Hydrology
) -> Array[HouseSite]:
	var plan_area: SettlementPlanner.Area = SettlementPlanner.Area.new()
	plan_area.centre = area.centre
	plan_area.tier = area.tier
	plan_area.settlement_id = area.settlement_id
	plan_area.claim_radius = area.claim_radius
	var empty_paths: PathNetwork = PathNetwork.new()
	empty_paths.terrain = terrain
	empty_paths.hydro = hydro
	empty_paths.config = WorldConfig.new()
	empty_paths.roads = []
	empty_paths.road_index = SpatialIndex2D.new(160.0)
	var planned: SettlementPlanner.Plan = SettlementPlanner.plan(
		plan_area, terrain, hydro, empty_paths
	)
	var farm_only: Array[HouseSite] = []
	for site in planned.sites:
		if FarmCatalog.has_id(site.catalog_id):
			farm_only.append(site)
	return farm_only
