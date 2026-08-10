class_name HamletLabBridge
extends RefCounted
## Bridge: [HamletLabPlanner] Plan2D → world [HouseSite]s for sector bake.
##
## Lab coordinates are local XZ as Vector2(x, z) with plaza at origin.
## World sites are offset by the resolved continental plaza.


static func config_for(tier: int, settlement_id: int) -> HamletLabConfig:
	var cfg: HamletLabConfig = HamletLabConfig.new()
	cfg.apply_tier_defaults(tier)
	cfg.seed = int(hash("hamlet_lab:%d" % settlement_id)) & 0x7fffffff
	return cfg


static func to_house_sites(
	plan: HamletLabPlanner.Plan2D, plaza_world: Vector2
) -> Array[HouseSite]:
	var out: Array[HouseSite] = []
	for shape in plan.shapes:
		if shape.kind != HamletLabPlanner.Shape.Kind.HOUSE:
			continue
		assert(
			VillageCatalog.has_id(shape.catalog_id),
			"lab shape missing catalog id"
		)
		var site: HouseSite = HouseSite.new()
		site.catalog_id = shape.catalog_id
		site.world_x = plaza_world.x + shape.center.x
		site.world_z = plaza_world.y + shape.center.y
		site.yaw = shape.yaw
		site.footprint = VillageCatalog.footprint_of(shape.catalog_id)
		site.seat_sink = 0.2
		out.append(site)
	return out


static func market_lanes(
	plan: HamletLabPlanner.Plan2D, plaza_world: Vector2
) -> Array[PackedVector2Array]:
	## Hollow-way rings around each market polygon (closed polylines).
	var out: Array[PackedVector2Array] = []
	for poly in plan.markets:
		if poly.size() < 3:
			continue
		var lane: PackedVector2Array = PackedVector2Array()
		lane.resize(poly.size() + 1)
		for i in poly.size():
			lane[i] = plaza_world + poly[i]
		lane[poly.size()] = lane[0]
		out.append(lane)
	return out


static func add_oriented_site(
	occ: SettlementOccupancy, site: HouseSite, margin: float
) -> void:
	var spec: VillageCatalog.Spec = VillageCatalog.spec_for(site.catalog_id)
	occ.add_rect(
		Vector2(site.world_x, site.world_z),
		spec.half_x(),
		spec.half_z(),
		site.yaw,
		margin
	)


static func fits_oriented_site(
	occ: SettlementOccupancy, site: HouseSite, margin: float
) -> bool:
	var spec: VillageCatalog.Spec = VillageCatalog.spec_for(site.catalog_id)
	return occ.fits_rect(
		Vector2(site.world_x, site.world_z),
		spec.half_x(),
		spec.half_z(),
		site.yaw,
		margin,
		true
	)
