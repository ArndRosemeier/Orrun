extends Node
## Floating origin. Autoloaded as `WorldOrigin`.
##
## World space is absolute and can reach tens of kilometres, which is past the
## precision float32 vertices and physics can carry. Scene space is world space
## minus [member offset], kept near zero by rebasing as the player travels.
##
## Rules:
##   - Generation, hydrology and queries always speak *world* coordinates.
##   - Anything placed in the SceneTree is positioned in *scene* coordinates.
##   - Convert at the boundary with [method to_scene] / [method to_world].

signal rebased(delta: Vector3)

## World-space position that currently sits at scene-space zero.
var offset: Vector3 = Vector3.ZERO

var _shifted_roots: Array[Node3D] = []


func to_scene(world_pos: Vector3) -> Vector3:
	return world_pos - offset


func to_world(scene_pos: Vector3) -> Vector3:
	return scene_pos + offset


func to_scene_xz(world_x: float, world_z: float) -> Vector2:
	return Vector2(world_x - offset.x, world_z - offset.z)


## Nodes registered here are moved whenever the origin shifts.
func register_root(root: Node3D) -> void:
	if not _shifted_roots.has(root):
		_shifted_roots.append(root)


func unregister_root(root: Node3D) -> void:
	_shifted_roots.erase(root)


## Move the origin so that `new_offset` becomes scene zero, shifting everything
## registered by the inverse delta so nothing appears to move.
func rebase_to(new_offset: Vector3) -> void:
	var delta: Vector3 = new_offset - offset
	if delta == Vector3.ZERO:
		return
	offset = new_offset
	for root in _shifted_roots:
		root.global_position -= delta
	rebased.emit(delta)
