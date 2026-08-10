extends SceneTree
## Headless village tier / decorator checks.
##
##   godot --headless --path <project> --script res://tools/tests/village_tests.gd

const HamletLabBridgeT := preload("res://scripts/world/hamlet_lab_bridge.gd")
const ATLAS_SIZE: int = 64

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	print("=== Orrun village tests ===")
	VillageCatalog.load_catalog()
	FarmCatalog.load_catalog()
	_check("catalog has 44 entries", VillageCatalog.all_specs().size() == 44, "")
	_check(
		"mesh_scale in gameplay band",
		VillageCatalog.mesh_scale() > 4.0 and VillageCatalog.mesh_scale() < 4.5,
		str(VillageCatalog.mesh_scale())
	)
	_check("House_1 is dwelling", VillageCatalog.spec_for(&"House_1").is_dwelling(), "")
	_check("Blacksmith is civic", VillageCatalog.spec_for(&"Blacksmith").is_civic(), "")
	_check("Blacksmith min_tier town", VillageCatalog.spec_for(&"Blacksmith").min_tier == 2, "")
	_check("Bell_Tower min_tier port", VillageCatalog.spec_for(&"Bell_Tower").min_tier == 3, "")

	_check(
		"hamlet classify",
		VillageTier.classify(7, -1) == VillageTier.Tier.HAMLET,
		str(VillageTier.classify(7, -1))
	)
	_check(
		"village classify",
		VillageTier.classify(9, -1) == VillageTier.Tier.VILLAGE,
		str(VillageTier.classify(9, -1))
	)
	_check(
		"town by pop",
		VillageTier.classify(12, -1) == VillageTier.Tier.TOWN,
		str(VillageTier.classify(12, -1))
	)
	_check(
		"port by mouth+pop",
		VillageTier.classify(11, 0) == VillageTier.Tier.PORT,
		str(VillageTier.classify(11, 0))
	)
	_check(
		"port claim largest",
		VillageTier.claim_radius(VillageTier.Tier.PORT)
		> VillageTier.claim_radius(VillageTier.Tier.TOWN),
		""
	)

	var config: WorldConfig = WorldConfig.new()
	config.atlas_size = ATLAS_SIZE
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var settlement: AtlasGraphNode = _first_settlement(atlas)
	_check("atlas has a settlement", settlement != null, "")
	if settlement == null:
		_finish()
		return

	var centre: Vector2 = atlas.continental_centre(settlement.ax, settlement.az)
	var sector_coord: Vector2i = WorldCoords.sector_of(centre.x, centre.y)
	var sector: WorldSector = WorldSector.generate(context, sector_coord)
	_check("sector placed house sites", sector.houses.size() > 0, str(sector.houses.size()))
	var settlement_trails: int = 0
	for road in sector.paths.roads:
		if not road.is_trunk and road.tier == RoadEdge.Tier.TRAIL:
			settlement_trails += 1
	_check("sector has settlement trail lanes", settlement_trails > 0, str(settlement_trails))
	_check(
		"sector building OBBs clear",
		_buildings_obb_clear(sector.houses),
		""
	)

	# Synthetic packs use a dry stand in the sector core when the node centre is wet.
	var pack_centre: Vector2 = _dry_stand(sector, centre)
	_check("found dry stand for decorator", pack_centre != Vector2.ZERO, "")

	# Synthetic hamlet recipe must never include smith / tower.
	var hamlet_area: VillageDecorator.Area = VillageDecorator.Area.new()
	hamlet_area.centre = pack_centre
	hamlet_area.tier = VillageTier.Tier.HAMLET
	hamlet_area.settlement_id = 900001
	hamlet_area.claim_radius = VillageTier.claim_radius(VillageTier.Tier.HAMLET)
	hamlet_area.lab_dwelling_min = 8
	hamlet_area.lab_dwelling_max = 8
	var hamlet_sites: Array[HouseSite] = VillageDecorator.decorate(
		hamlet_area, sector.terrain, sector.hydro
	)
	_check("hamlet places something", not hamlet_sites.is_empty(), "")
	_check(
		"hamlet excludes Blacksmith",
		not _has_id(hamlet_sites, &"Blacksmith"),
		_ids(hamlet_sites)
	)
	_check(
		"hamlet excludes Bell_Tower",
		not _has_id(hamlet_sites, &"Bell_Tower"),
		_ids(hamlet_sites)
	)
	_check(
		"built core smaller than claim",
		VillageTier.built_radius(VillageTier.Tier.HAMLET)
		< VillageTier.claim_radius(VillageTier.Tier.HAMLET),
		""
	)
	var hamlet_dwellings: Array[HouseSite] = _dwellings_only(hamlet_sites)
	_check("hamlet has lab dwellings", hamlet_dwellings.size() >= 5, str(hamlet_dwellings.size()))
	_check("hamlet has Well", _has_id(hamlet_sites, &"Well"), _ids(hamlet_sites))
	_check("hamlet OBB clear", _buildings_obb_clear(hamlet_sites), "")
	if not hamlet_dwellings.is_empty():
		var n_near: int = 0
		for site in hamlet_dwellings:
			var d: float = Vector2(site.world_x, site.world_z).distance_to(pack_centre)
			if d < VillageTier.claim_radius(VillageTier.Tier.HAMLET) * 0.85:
				n_near += 1
		_check(
			"hamlet dwellings inside claim",
			n_near == hamlet_dwellings.size(),
			"%d / %d" % [n_near, hamlet_dwellings.size()]
		)

	# Port plans are heavy (500–2000 dwellings); pin a small lab-sized want via seed
	# by using a dedicated settlement id and checking civics + determinism on a town.
	var town_area: VillageDecorator.Area = VillageDecorator.Area.new()
	town_area.centre = pack_centre
	town_area.tier = VillageTier.Tier.TOWN
	town_area.settlement_id = 900002
	town_area.claim_radius = VillageTier.claim_radius(VillageTier.Tier.TOWN)
	town_area.lab_dwelling_min = 24
	town_area.lab_dwelling_max = 24
	var town_a: Array[HouseSite] = VillageDecorator.decorate(
		town_area, sector.terrain, sector.hydro
	)
	var town_b: Array[HouseSite] = VillageDecorator.decorate(
		town_area, sector.terrain, sector.hydro
	)
	_check("town decorator deterministic count", town_a.size() == town_b.size(), "%d vs %d" % [
		town_a.size(), town_b.size()
	])
	if town_a.size() == town_b.size():
		var same: bool = true
		for i in town_a.size():
			if (
				town_a[i].catalog_id != town_b[i].catalog_id
				or absf(town_a[i].world_x - town_b[i].world_x) > 0.01
				or absf(town_a[i].world_z - town_b[i].world_z) > 0.01
			):
				same = false
				break
		_check("town decorator deterministic sites", same, "")
	_check("town has Inn", _has_id(town_a, &"Inn"), _ids(town_a))
	_check("town excludes Bell_Tower", not _has_id(town_a, &"Bell_Tower"), _ids(town_a))

	_check(
		"port claim largest radius",
		VillageTier.claim_radius(VillageTier.Tier.PORT) >= 320.0,
		str(VillageTier.claim_radius(VillageTier.Tier.PORT))
	)

	_finish()


func _finish() -> void:
	print("=== %d checks, %d failures ===" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _dry_stand(sector: WorldSector, hint: Vector2) -> Vector2:
	if VillageDecorator._point_dry(
		hint.x, hint.y, 6.0, sector.terrain, sector.hydro, 64.0
	):
		return hint
	var origin: Vector2 = WorldCoords.sector_origin(sector.sector)
	var step: float = sector.config.macro_cell_size * 2.0
	for z in range(8, 40):
		for x in range(8, 40):
			var p: Vector2 = origin + Vector2((float(x) + 0.5) * step, (float(z) + 0.5) * step)
			if VillageDecorator._point_dry(
				p.x, p.y, 6.0, sector.terrain, sector.hydro, 64.0
			):
				return p
	return Vector2.ZERO


func _first_settlement(atlas: ContinentAtlas) -> AtlasGraphNode:
	for node_variant in atlas.nodes:
		var node: AtlasGraphNode = node_variant
		if node.kind == AtlasFeatures.NodeKind.SETTLEMENT:
			return node
	return null


func _has_id(sites: Array[HouseSite], id: StringName) -> bool:
	for site in sites:
		if site.catalog_id == id:
			return true
	return false


func _dwellings_only(sites: Array[HouseSite]) -> Array[HouseSite]:
	var out: Array[HouseSite] = []
	for site in sites:
		if VillageCatalog.spec_for(site.catalog_id).is_dwelling():
			out.append(site)
	return out


func _sites_centroid(sites: Array[HouseSite]) -> Vector2:
	var acc := Vector2.ZERO
	for site in sites:
		acc += Vector2(site.world_x, site.world_z)
	return acc / float(sites.size())


func _median_nearest_gap(sites: Array[HouseSite]) -> float:
	var gaps: Array[float] = []
	for i in sites.size():
		var best: float = INF
		var a := Vector2(sites[i].world_x, sites[i].world_z)
		for j in sites.size():
			if i == j:
				continue
			var d: float = a.distance_to(Vector2(sites[j].world_x, sites[j].world_z))
			best = minf(best, d)
		if best < INF:
			gaps.append(best)
	if gaps.is_empty():
		return INF
	gaps.sort()
	return gaps[gaps.size() / 2]


func _median_footprint(sites: Array[HouseSite]) -> float:
	var fps: Array[float] = []
	for site in sites:
		fps.append(site.footprint)
	fps.sort()
	return fps[fps.size() / 2]


func _ids(sites: Array[HouseSite]) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for site in sites:
		parts.append(String(site.catalog_id))
	return ", ".join(parts)


func _principal_axis(sites: Array[HouseSite]) -> Vector2:
	var c: Vector2 = _sites_centroid(sites)
	var best: Vector2 = Vector2.RIGHT
	var best_var: float = INF
	for i in 16:
		var axis: Vector2 = Vector2.RIGHT.rotated(TAU * float(i) / 16.0)
		var acc: float = 0.0
		for site in sites:
			var d: Vector2 = Vector2(site.world_x, site.world_z) - c
			var cross: float = d.x * (-axis.y) + d.y * axis.x
			acc += cross * cross
		if acc < best_var:
			best_var = acc
			best = axis
	return best


func _cross_track_rms(sites: Array[HouseSite], axis: Vector2) -> float:
	var c: Vector2 = _sites_centroid(sites)
	var across: Vector2 = Vector2(-axis.y, axis.x)
	var acc: float = 0.0
	for site in sites:
		var d: Vector2 = Vector2(site.world_x, site.world_z) - c
		var cross: float = d.dot(across)
		acc += cross * cross
	return sqrt(acc / float(sites.size()))


func _buildings_obb_clear(sites: Array[HouseSite]) -> bool:
	var occ: SettlementOccupancy = SettlementOccupancy.new()
	for site in sites:
		if not VillageCatalog.has_id(site.catalog_id):
			continue
		var role: StringName = VillageCatalog.spec_for(site.catalog_id).role
		if role != &"dwelling" and role != &"civic":
			continue
		if not HamletLabBridgeT.fits_oriented_site(occ, site, SettlementPlanner.LAB_BUILDING_MARGIN):
			return false
		HamletLabBridgeT.add_oriented_site(occ, site, SettlementPlanner.LAB_BUILDING_MARGIN)
	return true


func _check(label: String, ok: bool, detail: String) -> void:
	checks += 1
	if ok:
		print("  PASS  %s" % label)
	else:
		failures += 1
		if detail.is_empty():
			print("  FAIL  %s" % label)
		else:
			print("  FAIL  %s — %s" % [label, detail])
