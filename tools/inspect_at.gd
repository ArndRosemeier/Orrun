extends SceneTree
## Headless site inspector for a continental XZ (optional yaw).
##
##   inspect.bat 173495 39048
##   inspect.bat 173495 39048 --yaw 1.20
##   start.bat --headless --script res://tools/inspect_at.gd -- 173495 39048
##
## Builds the owning sector + LOD0 density field, then reports terrace / road /
## house geometry around the point so agents can debug what the player saw.


## Default: trench screenshot (continental XZ from HUD).
const DEFAULT_X: float = 173495.0
const DEFAULT_Z: float = 39048.0
const OUT_PATH: String = "res://logs/inspect_at.txt"


var _log: FileAccess
var _at: Vector2 = Vector2(DEFAULT_X, DEFAULT_Z)
var _yaw: float = NAN


func _initialize() -> void:
	_parse_args()
	_log = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	_line("=== Orrun inspect_at ===")
	_line("at continental xz=%.1f, %.1f" % [_at.x, _at.y])
	if not is_nan(_yaw):
		_line("yaw=%.4f rad (%.1f deg)  forward=(%.3f, %.3f)" % [
			_yaw, rad_to_deg(_yaw), sin(_yaw), cos(_yaw)
		])
	else:
		_line("yaw=unknown (HUD did not show it; pass --yaw <rad>)")

	VillageCatalog.load_catalog()
	FarmCatalog.load_catalog()

	var config: WorldConfig = WorldConfig.new()
	var atlas: ContinentAtlas = ContinentAtlas.generate(config.seed, config.atlas_size)
	var context: WorldContext = WorldContext.create(config, atlas)
	var continental: ContinentalTerrain = context.sampler()
	var sector_coord: Vector2i = WorldCoords.sector_of(_at.x, _at.y)
	_line("sector %s  chunk %s" % [
		sector_coord, WorldCoords.chunk_of(config, _at.x, _at.y)
	])

	var t0: int = Time.get_ticks_msec()
	var sector: WorldSector = WorldSector.generate(context, sector_coord)
	_line("sector bake %d ms  houses=%d  roads=%d  timings=%s" % [
		Time.get_ticks_msec() - t0,
		sector.houses.size(),
		sector.paths.roads.size(),
		str(sector.bake_timings),
	])

	var info: Dictionary = sector.describe_at(_at.x, _at.y)
	_line("describe: %s" % str(info))
	_line("macro=%.3f  drainage=%.3f  shore_d=%.1f  water_plane=%.3f" % [
		continental.height_at(_at.x, _at.y),
		sector.hydro.drainage_at(_at.x, _at.y),
		continental.shore_distance(_at.x, _at.y),
		continental.water_plane_at(_at.x, _at.y),
	])

	_report_claims(sector)
	_report_roads(sector)
	_report_houses(sector)
	_suggest_orientation(sector)

	var chunk: Vector2i = WorldCoords.chunk_of(config, _at.x, _at.y)
	t0 = Time.get_ticks_msec()
	var noise: NoiseSet = NoiseSet.create(config)
	var field: DensityField.Field = DensityField.build(
		config, sector, continental, noise, chunk, 0
	)
	_line("density field %d ms  deficit=%.3f  wet_fail=%d/%d" % [
		Time.get_ticks_msec() - t0,
		field.max_contract_error,
		field.wet_columns_failing_clearance,
		field.wet_columns,
	])

	_sample_column(field, _at.x, _at.y, "AT")
	_cross_section(field, sector)
	_line("wrote %s" % OUT_PATH)
	if _log != null:
		_log.close()
	quit(0)


func _parse_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	var nums: Array[float] = []
	while i < args.size():
		var a: String = args[i]
		if a == "--yaw" and i + 1 < args.size():
			_yaw = float(args[i + 1])
			i += 2
			continue
		if a.begins_with("--yaw="):
			_yaw = float(a.substr(6))
			i += 1
			continue
		if a.is_valid_float():
			nums.append(float(a))
		i += 1
	if nums.size() >= 2:
		_at = Vector2(nums[0], nums[1])
	elif nums.size() == 1:
		push_error("inspect_at: need X and Z (got one number)")
		assert(false)


func _line(msg: String) -> void:
	print(msg)
	if _log != null:
		_log.store_line(msg)
		_log.flush()


func _report_claims(sector: WorldSector) -> void:
	_line("--- claims ---")
	var hit: ClaimMask.Claim = sector.claims.claim_at(_at.x, _at.y)
	if hit == null:
		_line("  none at AT")
	else:
		_line(
			"  at: kind=%s centre=%.1f,%.1f r=%.1f built=%.1f ground_z=%.3f d=%.1f"
			% [
				hit.kind, hit.center.x, hit.center.y, hit.radius, hit.built_radius,
				hit.ground_z, _at.distance_to(hit.center),
			]
		)
	for claim in sector.claims.claims:
		if claim.kind != &"settlement":
			continue
		var d: float = _at.distance_to(claim.center)
		if d > claim.radius + 80.0:
			continue
		_line(
			"  settlement centre=%.1f,%.1f r=%.1f built=%.1f ground_z=%.3f d=%.1f"
			% [
				claim.center.x, claim.center.y, claim.radius, claim.built_radius,
				claim.ground_z, d,
			]
		)


func _report_roads(sector: WorldSector) -> void:
	_line("--- nearest roads ---")
	var scored: Array[Dictionary] = []
	for road in sector.paths.roads:
		var best_d: float = INF
		var best_p: Vector3 = Vector3.ZERO
		var best_t: float = 0.0
		for i in range(road.points.size() - 1):
			var a: Vector3 = road.points[i]
			var b: Vector3 = road.points[i + 1]
			var t: float = _seg_param(_at, Vector2(a.x, a.z), Vector2(b.x, b.z))
			var p: Vector3 = a.lerp(b, t)
			var d: float = _at.distance_to(Vector2(p.x, p.z))
			if d < best_d:
				best_d = d
				best_p = p
				best_t = t
		if best_d > 80.0:
			continue
		scored.append({
			"d": best_d,
			"road": road,
			"p": best_p,
			"edge": best_d - road.half_width,
		})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["d"]) < float(b["d"]))
	for i in mini(scored.size(), 8):
		var s: Dictionary = scored[i]
		var road: RoadEdge = s["road"]
		var p: Vector3 = s["p"]
		_line(
			"  d=%.2f edge=%.2f tier=%d trunk=%s half=%.2f y=%.3f at=%.1f,%.1f id=%d"
			% [
				s["d"], s["edge"], road.tier, str(road.is_trunk), road.half_width,
				p.y, p.x, p.z, road.id,
			]
		)


func _report_houses(sector: WorldSector) -> void:
	_line("--- nearest houses ---")
	var scored: Array[Dictionary] = []
	for site in sector.houses:
		if not VillageCatalog.has_id(site.catalog_id):
			continue
		var role: StringName = VillageCatalog.spec_for(site.catalog_id).role
		if role != &"dwelling" and role != &"civic":
			continue
		var d: float = _at.distance_to(Vector2(site.world_x, site.world_z))
		if d > 60.0:
			continue
		scored.append({"d": d, "site": site})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["d"]) < float(b["d"]))
	for i in mini(scored.size(), 12):
		var site: HouseSite = scored[i]["site"]
		var spec: VillageCatalog.Spec = VillageCatalog.spec_for(site.catalog_id)
		var col: Vector2 = SettlementLayout.collision_xz_of(site.catalog_id) * 0.78
		_line(
			"  d=%.1f %s yaw=%.3f size=%.2fx%.2f col=%.2fx%.2f at=%.1f,%.1f"
			% [
				scored[i]["d"], site.catalog_id, site.yaw,
				spec.size_x, spec.size_z, col.x, col.y,
				site.world_x, site.world_z,
			]
		)


func _suggest_orientation(sector: WorldSector) -> void:
	_line("--- orientation hints (from geometry, not screenshot EXIF) ---")
	var claim: ClaimMask.Claim = sector.claims.claim_at(_at.x, _at.y)
	if claim != null and claim.kind == &"settlement":
		var to_plaza: Vector2 = claim.center - _at
		if to_plaza.length_squared() > 1e-4:
			var toward: float = atan2(to_plaza.x, to_plaza.y)
			_line("  face plaza: yaw=%.4f (%.1f deg)" % [toward, rad_to_deg(toward)])
			_line("  back to plaza: yaw=%.4f" % [toward + PI])
	var best_lane_yaw: float = NAN
	var best_d: float = INF
	for road in sector.paths.roads:
		if road.is_trunk:
			continue
		for i in range(road.points.size() - 1):
			var a: Vector2 = Vector2(road.points[i].x, road.points[i].z)
			var b: Vector2 = Vector2(road.points[i + 1].x, road.points[i + 1].z)
			var t: float = _seg_param(_at, a, b)
			var p: Vector2 = a.lerp(b, t)
			var d: float = _at.distance_to(p)
			if d >= best_d or d > 12.0:
				continue
			best_d = d
			var dir: Vector2 = (b - a).normalized()
			best_lane_yaw = atan2(dir.x, dir.y)
	if not is_nan(best_lane_yaw):
		_line(
			"  nearest trail tangent d=%.2f: yaw=%.4f or %.4f (along street)"
			% [best_d, best_lane_yaw, best_lane_yaw + PI]
		)
	if not is_nan(_yaw):
		_line("  supplied yaw matches trail±0.25? %s" % str(
			not is_nan(best_lane_yaw) and (
				absf(angle_difference(_yaw, best_lane_yaw)) < 0.25
				or absf(angle_difference(_yaw, best_lane_yaw + PI)) < 0.25
			)
		))


func _sample_column(field: DensityField.Field, wx: float, wz: float, label: String) -> void:
	var col: Dictionary = _field_at(field, wx, wz)
	if col.is_empty():
		_line("%s: outside field" % label)
		return
	_line(
		"%s: surface=%.3f roadness=%.3f wet=%.3f water_top=%s mask=%.3f biome=%d"
		% [
			label,
			col["surface"],
			col["roadness"],
			col["wetness"],
			"dry" if float(col["water_top"]) == -INF else "%.3f" % float(col["water_top"]),
			col["mask"],
			int(col["biome"]),
		]
	)


func _cross_section(field: DensityField.Field, sector: WorldSector) -> void:
	## Profile ±16 m along view-right (or world +X) and view-forward (or world +Z).
	var forward: Vector2
	var right: Vector2
	if not is_nan(_yaw):
		forward = Vector2(sin(_yaw), cos(_yaw))
		right = Vector2(cos(_yaw), -sin(_yaw))
	else:
		var claim: ClaimMask.Claim = sector.claims.claim_at(_at.x, _at.y)
		if claim != null and claim.kind == &"settlement":
			var radial: Vector2 = (_at - claim.center).normalized()
			if radial.length_squared() < 1e-6:
				radial = Vector2.RIGHT
			forward = Vector2(-radial.y, radial.x) # tangential to plaza
			right = radial
			_line("cross-section axes: forward=lane-tangent  right=away-from-plaza")
		else:
			forward = Vector2(0.0, 1.0)
			right = Vector2(1.0, 0.0)
			_line("cross-section axes: world +Z forward, +X right")

	_line("--- surface cross-section (metres from AT) ---")
	_line("across street (right):")
	var row: String = ""
	for step in range(-16, 17, 2):
		var p: Vector2 = _at + right * float(step)
		var col: Dictionary = _field_at(field, p.x, p.y)
		if col.is_empty():
			row += "  %+.0f:?" % step
		else:
			row += "  %+.0f:%.2f/r%.2f" % [step, col["surface"], col["roadness"]]
	_line(row)
	_line("along street (forward):")
	row = ""
	for step in range(-16, 17, 2):
		var p2: Vector2 = _at + forward * float(step)
		var col2: Dictionary = _field_at(field, p2.x, p2.y)
		if col2.is_empty():
			row += "  %+.0f:?" % step
		else:
			row += "  %+.0f:%.2f/r%.2f" % [step, col2["surface"], col2["roadness"]]
	_line(row)

	# Trench detector: local min vs neighbours on the across axis.
	var centre: Dictionary = _field_at(field, _at.x, _at.y)
	var left: Dictionary = _field_at(field, (_at + right * 4.0).x, (_at + right * 4.0).y)
	var rite: Dictionary = _field_at(field, (_at - right * 4.0).x, (_at - right * 4.0).y)
	if not centre.is_empty() and not left.is_empty() and not rite.is_empty():
		var shoulder: float = minf(float(left["surface"]), float(rite["surface"]))
		var drop: float = shoulder - float(centre["surface"])
		_line(
			"trench metric: centre=%.3f  ±4m shoulder_min=%.3f  drop=%.3f m%s"
			% [
				centre["surface"], shoulder, drop,
				"  <-- TRENCH" if drop > 0.75 else "",
			]
		)


func _field_at(field: DensityField.Field, wx: float, wz: float) -> Dictionary:
	var local_x: float = (wx - field.origin.x) / field.voxel
	var local_z: float = (wz - field.origin.z) / field.voxel
	var ix: int = int(floor(local_x))
	var iz: int = int(floor(local_z))
	if ix < 0 or iz < 0 or ix >= field.dims.x or iz >= field.dims.z:
		return {}
	var idx: int = iz * field.dims.x + ix
	return {
		"surface": field.surface_z[idx],
		"roadness": field.roadness[idx],
		"wetness": field.wetness[idx],
		"water_top": field.water_top[idx],
		"mask": field.corridor_mask[idx],
		"biome": field.biome[idx],
	}


func _seg_param(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq < 1e-8:
		return 0.0
	return clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
