class_name HouseSite
extends RefCounted
## One settlement site (building or prop) from [SettlementPlanner].
##
## World XZ and yaw are fixed at sector bake; height is the lowest density-field
## footprint corner when the chunk meshes, so no corner hangs above the grade.

var catalog_id: StringName = &""
var world_x: float = 0.0
var world_z: float = 0.0
var yaw: float = 0.0
## Clearance used when packing around the settlement centre.
var footprint: float = 6.0
## How far to bury the mesh into the grade when seating (metres).
var seat_sink: float = 0.2
