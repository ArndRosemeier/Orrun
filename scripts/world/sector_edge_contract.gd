class_name SectorEdgeContract
extends RefCounted
## What crosses one shared sector boundary, described once for both sides.
##
## The contract is keyed by the *edge*, never by a sector, and every value in it
## is a pure function of the atlas and the continental terrain along that edge.
## Two neighbours that build it independently therefore build the same object,
## which is what lets each of them bake in isolation and still meet.
##
## Matching a position is not enough. A river that arrives at the right metre
## with the wrong heading, the wrong fall, or a bed two metres shallower than
## the far side still reads as a kink or a step in the water, so a port carries
## the full profile: position, tangent, grade, surface height, width, bed depth,
## valley radius and the length over which a sector must have blended into all
## of them.

enum Kind { RIVER = 0, ROAD = 1, DRAIN = 2 }
enum Side { EAST = 0, SOUTH = 1, WEST = 2, NORTH = 3 }

## Metres either side of the boundary line searched for a crossing corridor.
const CROSSING_BAND: float = 24.0
## Macro cells of blend a sector gets to reach a port's prescribed profile.
const RIVER_TRANSITION_CELLS: float = 6.0
const DRAIN_TRANSITION_CELLS: float = 3.0
## A local drainage port only exists where the land really does fall across the
## boundary, over this baseline in metres. Measuring over a single macro cell
## instead finds grid noise, and every one of those becomes a channel on both
## sides: a comb of ditches along every sector edge.
const DRAIN_BASELINE: float = 128.0
## Metres the land must fall across that baseline.
const DRAIN_MIN_FALL: float = 3.0
## Macro cells the point must be the lowest of, along the boundary. A valley is
## a minimum over a few hundred metres, not over one cell.
const DRAIN_MIN_WIDTH: int = 4
## Minimum spacing between local drainage ports, in macro cells.
const DRAIN_MIN_SPACING: int = 16


class Port extends RefCounted:
	## Stable across runs and identical on both sides of the boundary.
	var id: int = 0
	var kind: int = Kind.DRAIN
	## Continental metres, exactly on the boundary line.
	var position: Vector2 = Vector2.ZERO
	## Unit heading, pointing the way the feature travels across the boundary.
	## For a river that is downstream; for a road it is arbitrary but shared.
	var tangent: Vector2 = Vector2.ZERO
	## Water surface for a river, running surface for a road, ground for a drain.
	var surface_z: float = 0.0
	## Fall per metre along [member tangent]. Negative means descending.
	var grade: float = 0.0
	var half_width: float = 1.0
	var depth: float = 0.0
	var valley: float = 0.0
	## Metres over which each side must have blended into this profile.
	var transition: float = 96.0
	var feature_class: int = 1
	## Atlas feature this port belongs to, or 0 for a local drainage port.
	var feature_id: int = 0
	## Sector the feature is entering. The other one is where it comes from.
	var into_sector: Vector2i = Vector2i.ZERO

	func fingerprint() -> String:
		return "%d|%.3f,%.3f|%.4f,%.4f|%.3f|%.5f|%.3f|%.3f|%.3f|%.3f|%d|%d" % [
			kind, position.x, position.y, tangent.x, tangent.y,
			surface_z, grade, half_width, depth, valley, transition,
			feature_class, feature_id
		]


## Owner is the lower sector of the pair; axis 0 is its east face, 1 its south.
var owner: Vector2i = Vector2i.ZERO
var axis: int = 0
var ports: Array[Port] = []


# --- Identity --------------------------------------------------------------------

## The pair of sectors this edge separates, owner first.
static func neighbours(owner_sector: Vector2i, edge_axis: int) -> Array[Vector2i]:
	var delta: Vector2i = Vector2i(1, 0) if edge_axis == 0 else Vector2i(0, 1)
	return [owner_sector, owner_sector + delta]


## Canonical (owner, axis) for a sector and one of its four sides.
static func canonical(sector: Vector2i, side: int) -> Array:
	match side:
		Side.EAST:
			return [sector, 0]
		Side.SOUTH:
			return [sector, 1]
		Side.WEST:
			return [sector - Vector2i(1, 0), 0]
		Side.NORTH:
			return [sector - Vector2i(0, 1), 1]
	return [sector, 0]


static func key_of(owner_sector: Vector2i, edge_axis: int) -> int:
	return (WorldCoords.sector_key(owner_sector) << 1) | edge_axis


func key() -> int:
	return key_of(owner, axis)


## The boundary line in continental metres: fixed coordinate, and the span the
## edge covers on the other axis.
func line_constant() -> float:
	return (
		float(owner.x + 1) * WorldCoords.SECTOR_SIZE if axis == 0
		else float(owner.y + 1) * WorldCoords.SECTOR_SIZE
	)


func line_start() -> float:
	return (
		float(owner.y) * WorldCoords.SECTOR_SIZE if axis == 0
		else float(owner.x) * WorldCoords.SECTOR_SIZE
	)


func point_on_line(along: float) -> Vector2:
	return (
		Vector2(line_constant(), along) if axis == 0
		else Vector2(along, line_constant())
	)


# --- Construction -------------------------------------------------------------------

static func build(
	config: WorldConfig,
	corridors: AtlasCorridors,
	continental: ContinentalTerrain,
	owner_sector: Vector2i,
	edge_axis: int
) -> SectorEdgeContract:
	var contract: SectorEdgeContract = SectorEdgeContract.new()
	contract.owner = owner_sector
	contract.axis = edge_axis
	contract._collect_corridor_ports(config, corridors, Kind.RIVER)
	contract._collect_corridor_ports(config, corridors, Kind.ROAD)
	contract._collect_drain_ports(config, continental)
	# Ordered along the boundary so both sides iterate the same sequence.
	contract.ports.sort_custom(_before)
	return contract


static func _before(a: Port, b: Port) -> bool:
	var pa: float = a.position.y if a.position.x == b.position.x else a.position.x
	var pb: float = b.position.y if a.position.x == b.position.x else b.position.x
	if absf(pa - pb) > 0.0001:
		return pa < pb
	if a.kind != b.kind:
		return a.kind < b.kind
	return a.id < b.id


func _band_rect() -> Rect2:
	var span: float = WorldCoords.SECTOR_SIZE
	var start: float = line_start()
	var line: float = line_constant()
	if axis == 0:
		return Rect2(line - CROSSING_BAND, start, CROSSING_BAND * 2.0, span)
	return Rect2(start, line - CROSSING_BAND, span, CROSSING_BAND * 2.0)


func _collect_corridor_ports(
	config: WorldConfig, corridors: AtlasCorridors, kind: int
) -> void:
	var rect: Rect2 = _band_rect()
	var line: float = line_constant()
	var data: PackedFloat32Array = corridors.rivers if kind == Kind.RIVER else corridors.roads
	var stride: int = (
		AtlasCorridors.RIVER_STRIDE if kind == Kind.RIVER else AtlasCorridors.ROAD_STRIDE
	)
	var ids: PackedInt32Array = (
		corridors.river_feature_ids if kind == Kind.RIVER else corridors.road_feature_ids
	)
	var bases: PackedInt32Array = (
		corridors.rivers_in_rect(rect) if kind == Kind.RIVER
		else corridors.roads_in_rect(rect)
	)

	for base in bases:
		var a: Vector3 = Vector3(data[base], data[base + 1], data[base + 2])
		var b: Vector3 = Vector3(data[base + 3], data[base + 4], data[base + 5])
		var pa: float = a.x if axis == 0 else a.z
		var pb: float = b.x if axis == 0 else b.z
		if (pa - line) * (pb - line) > 0.0:
			continue
		if absf(pb - pa) < 0.000001:
			continue
		var t: float = (line - pa) / (pb - pa)
		if t < 0.0 or t > 1.0:
			continue

		var crossing: Vector3 = a.lerp(b, t)
		var along: float = crossing.z if axis == 0 else crossing.x
		if along < line_start() or along > line_start() + WorldCoords.SECTOR_SIZE:
			continue

		var flat: Vector2 = Vector2(b.x - a.x, b.z - a.z)
		if flat.length_squared() < 0.000001:
			continue
		var run: float = flat.length()
		var port: Port = Port.new()
		port.kind = kind
		port.position = Vector2(crossing.x, crossing.z)
		port.tangent = flat / run
		port.surface_z = crossing.y
		port.grade = (b.y - a.y) / run
		port.feature_class = int(data[base + stride - 1])
		port.feature_id = ids[base / stride]
		port.into_sector = WorldCoords.sector_of(
			port.position.x + port.tangent.x * 1.0,
			port.position.y + port.tangent.y * 1.0
		)

		if kind == Kind.RIVER:
			var order: int = corridors.trunk_order(port.feature_class)
			port.half_width = corridors.river_half_width(port.feature_class)
			port.depth = (
				config.river_depth_base + float(order - 1) * config.river_depth_per_order
			)
			port.valley = (
				config.river_valley_base + float(order - 1) * config.river_valley_per_order
			)
			port.transition = RIVER_TRANSITION_CELLS * config.macro_cell_size
		else:
			port.half_width = corridors.road_half_width(port.feature_class)
			port.depth = 0.0
			port.valley = port.half_width + 14.0
			port.transition = RIVER_TRANSITION_CELLS * config.macro_cell_size

		port.id = _port_id(config, port)
		ports.append(port)


## Local drainage crossings, invented by neither sector.
##
## Sampled from the continental terrain along the boundary line alone, so both
## neighbours find the same minima at the same metres, with the same fall. This
## is what lets a brook cross a sector boundary without either side having to
## guess where the other one will put its endpoint.
func _collect_drain_ports(config: WorldConfig, continental: ContinentalTerrain) -> void:
	var cs: float = config.macro_cell_size
	var steps: int = int(WorldCoords.SECTOR_SIZE / cs)
	var start: float = line_start()
	var line: float = line_constant()

	var normal: Vector2 = Vector2(1.0, 0.0) if axis == 0 else Vector2(0.0, 1.0)
	var profile: PackedFloat32Array = PackedFloat32Array()
	profile.resize(steps + 1)
	var fall: PackedFloat32Array = PackedFloat32Array()
	fall.resize(steps + 1)
	for i in steps + 1:
		var along: float = start + float(i) * cs
		var here: Vector2 = point_on_line(along)
		profile[i] = continental.height_at(here.x, here.y)
		var before: float = continental.height_at(
			here.x - normal.x * DRAIN_BASELINE, here.y - normal.y * DRAIN_BASELINE
		)
		var after: float = continental.height_at(
			here.x + normal.x * DRAIN_BASELINE, here.y + normal.y * DRAIN_BASELINE
		)
		fall[i] = before - after

	var last_index: int = -DRAIN_MIN_SPACING * 2
	for i in range(DRAIN_MIN_WIDTH, steps - DRAIN_MIN_WIDTH + 1):
		if absf(fall[i]) < DRAIN_MIN_FALL:
			continue
		var lowest: bool = true
		for k in range(1, DRAIN_MIN_WIDTH + 1):
			if profile[i] > profile[i - k] or profile[i] > profile[i + k]:
				lowest = false
				break
		if not lowest:
			continue
		if i - last_index < DRAIN_MIN_SPACING:
			continue
		last_index = i

		var along: float = start + float(i) * cs
		var here: Vector2 = point_on_line(along)
		var downhill: Vector2 = normal if fall[i] > 0.0 else -normal

		var port: Port = Port.new()
		port.kind = Kind.DRAIN
		port.position = here
		port.tangent = downhill
		port.surface_z = profile[i]
		port.grade = -absf(fall[i]) / (DRAIN_BASELINE * 2.0)
		port.half_width = config.river_width_base
		port.depth = config.river_depth_base
		port.valley = config.river_valley_base
		port.transition = DRAIN_TRANSITION_CELLS * cs
		port.feature_class = 0
		port.feature_id = 0
		port.into_sector = WorldCoords.sector_of(
			here.x + downhill.x * 1.0, here.y + downhill.y * 1.0
		)
		port.id = _port_id(config, port)
		ports.append(port)


## Derived from the seed and the canonical edge position, never from a sector.
func _port_id(config: WorldConfig, port: Port) -> int:
	return int(hash("%d:port:%d:%d:%d:%d" % [
		config.seed, key(), port.kind,
		int(round(port.position.x * 100.0)), int(round(port.position.y * 100.0))
	])) & 0x7FFFFFFF


# --- Queries -------------------------------------------------------------------------

func ports_of_kind(kind: int) -> Array[Port]:
	var out: Array[Port] = []
	for port in ports:
		if port.kind == kind:
			out.append(port)
	return out


## Ports whose flow enters this sector, i.e. sources it must accept.
func inflow_for(sector: Vector2i) -> Array[Port]:
	var out: Array[Port] = []
	for port in ports:
		if port.kind != Kind.ROAD and port.into_sector == sector:
			out.append(port)
	return out


## Ports whose flow leaves this sector, i.e. sinks it must drain into.
func outflow_for(sector: Vector2i) -> Array[Port]:
	var out: Array[Port] = []
	for port in ports:
		if port.kind != Kind.ROAD and port.into_sector != sector:
			out.append(port)
	return out


func fingerprint() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for port in ports:
		parts.append(port.fingerprint())
	return "|".join(parts)
