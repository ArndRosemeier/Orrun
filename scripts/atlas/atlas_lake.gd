class_name AtlasLake
extends RefCounted
## Inland lake basin with spill surface.


var id: int = 0
var cells: PackedInt32Array = PackedInt32Array()
var spill_cell: int = -1
var surface_code: int = 0
var surface_z: int = 0
