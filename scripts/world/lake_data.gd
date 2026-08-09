class_name LakeData
extends RefCounted
## A filled depression holding water at its own spill elevation.
##
## Every lake carries its own [member surface_z]. A tarn high in the mountains
## and a lowland lake are the same object at different heights; nothing in the
## world assumes a shared water table.

var id: int = -1
## Water surface height in metres for this basin only.
var surface_z: float = 0.0
## Macro cell indices covered by the lake.
var cells: PackedInt32Array = PackedInt32Array()
## Macro cell where the basin spills into its outflow river.
var outlet_cell: int = -1
var max_depth: float = 0.0
var bounds: Rect2 = Rect2()
