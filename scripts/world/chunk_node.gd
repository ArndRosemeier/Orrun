class_name ChunkNode
extends Node3D
## Scene-side half of a chunk. Built entirely on the main thread from the plain
## arrays a [ChunkJob] produced.

var chunk: Vector2i
var lod: int = 0
var world_origin: Vector3 = Vector3.ZERO
var max_contract_error: float = 0.0
var triangle_count: int = 0

var _terrain: MeshInstance3D
var _water: MeshInstance3D
## Terrain + bridge collision soups deferred to a later frame.
var _deferred_collision_faces: Array[PackedVector3Array] = []


## Builds scene nodes. Returns phase timings in milliseconds for hitch logging.
## When [param defer_collision] is true, concave collision is staged for
## [method install_deferred_collision] so mesh can appear without a hitch.
func apply(
	job: ChunkJob,
	terrain_material: Material,
	water_material: Material,
	defer_collision: bool = false
) -> Dictionary:
	chunk = job.chunk
	lod = job.lod
	max_contract_error = job.max_contract_error
	var origin: Vector2 = WorldCoords.chunk_origin(job.config, job.chunk)
	world_origin = Vector3(origin.x, 0.0, origin.y)
	name = "Chunk_%d_%d" % [chunk.x, chunk.y]
	_deferred_collision_faces.clear()

	var t0: int = Time.get_ticks_usec()
	var collision_faces: int = _build_terrain(job, terrain_material, defer_collision)
	var terrain_ms: float = (Time.get_ticks_usec() - t0) * 0.001

	t0 = Time.get_ticks_usec()
	_build_water(job, water_material)
	var water_ms: float = (Time.get_ticks_usec() - t0) * 0.001

	t0 = Time.get_ticks_usec()
	_build_bridges(job, terrain_material, defer_collision)
	var bridges_ms: float = (Time.get_ticks_usec() - t0) * 0.001

	t0 = Time.get_ticks_usec()
	_build_props(job)
	var props_ms: float = (Time.get_ticks_usec() - t0) * 0.001

	refresh_transform()
	return {
		"terrain_ms": terrain_ms,
		"water_ms": water_ms,
		"bridges_ms": bridges_ms,
		"props_ms": props_ms,
		"collision_faces": collision_faces,
		"deferred_collision": defer_collision and not _deferred_collision_faces.is_empty(),
		"want_collision": job.want_collision,
		"lod": job.lod,
		"chunk": job.chunk,
	}


func has_deferred_collision() -> bool:
	return not _deferred_collision_faces.is_empty()


## Installs one deferred concave shape. Returns milliseconds spent.
func install_deferred_collision() -> float:
	if _deferred_collision_faces.is_empty():
		return 0.0
	var t0: int = Time.get_ticks_usec()
	var faces: PackedVector3Array = _deferred_collision_faces.pop_front()
	_add_faces_collision(faces)
	return (Time.get_ticks_usec() - t0) * 0.001


func refresh_transform() -> void:
	position = WorldOrigin.to_scene(world_origin)


## Hiding water is how the terrain underneath gets inspected; a shallow sheet
## and pale ground are hard to tell apart in a screenshot otherwise.
func set_water_visible(visible_state: bool) -> void:
	if _water != null:
		_water.visible = visible_state


## Returns the number of terrain collision face vertices (installed or deferred).
func _build_terrain(job: ChunkJob, material: Material, defer_collision: bool) -> int:
	var data: MeshExtract.MeshData = job.mesh_data
	if data.is_empty():
		return 0
	triangle_count = data.indices.size() / 3

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data.vertices
	arrays[Mesh.ARRAY_NORMAL] = data.normals
	arrays[Mesh.ARRAY_COLOR] = data.colors
	arrays[Mesh.ARRAY_TEX_UV] = data.uvs
	arrays[Mesh.ARRAY_INDEX] = data.indices

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)

	_terrain = MeshInstance3D.new()
	_terrain.mesh = mesh
	_terrain.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if job.lod == 0
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(_terrain)

	if data.collision_faces.is_empty():
		return 0
	if defer_collision:
		_deferred_collision_faces.append(data.collision_faces)
	else:
		_add_faces_collision(data.collision_faces)
	return data.collision_faces.size()


func _build_water(job: ChunkJob, material: Material) -> void:
	var data: WaterSurface.WaterData = job.water_data
	if data.is_empty():
		return

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data.vertices
	arrays[Mesh.ARRAY_NORMAL] = data.normals
	arrays[Mesh.ARRAY_TEX_UV] = data.uvs
	arrays[Mesh.ARRAY_INDEX] = data.indices

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)

	_water = MeshInstance3D.new()
	_water.mesh = mesh
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_water)


func _build_bridges(job: ChunkJob, material: Material, defer_collision: bool) -> void:
	for built in job.bridge_builds:
		if built.uses_kit:
			_add_bridge_multimesh(built.mid_mesh, built.mid_transforms)
			_add_bridge_multimesh(built.end_mesh, built.end_transforms)

		if built.has_procedural_mesh():
			var mesh: ArrayMesh = ArrayMesh.new()
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = built.procedural_vertices
			arrays[Mesh.ARRAY_NORMAL] = built.procedural_normals
			arrays[Mesh.ARRAY_COLOR] = built.procedural_colors
			arrays[Mesh.ARRAY_INDEX] = built.procedural_indices
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(0, material)
			var instance: MeshInstance3D = MeshInstance3D.new()
			instance.mesh = mesh
			add_child(instance)

		if built.collision_faces.is_empty():
			continue
		if defer_collision:
			_deferred_collision_faces.append(built.collision_faces)
		else:
			_add_faces_collision(built.collision_faces)


func _add_faces_collision(faces: PackedVector3Array) -> void:
	var shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var collider: CollisionShape3D = CollisionShape3D.new()
	collider.shape = shape
	var body: StaticBody3D = StaticBody3D.new()
	body.add_child(collider)
	add_child(body)


func _add_bridge_multimesh(mesh: Mesh, transforms: Array[Transform3D]) -> void:
	if mesh == null or transforms.is_empty():
		return
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	var kit_instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
	kit_instance.multimesh = multimesh
	kit_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(kit_instance)


func _build_props(job: ChunkJob) -> void:
	for id_variant in job.props:
		var prop_id: StringName = id_variant
		var transforms: Array = job.props[prop_id]
		if transforms.is_empty():
			continue
		var mesh: Mesh = PropLibrary.mesh_for(prop_id)
		if mesh == null:
			continue

		var multimesh: MultiMesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = transforms.size()
		for i in transforms.size():
			multimesh.set_instance_transform(i, transforms[i])

		var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
		instance.multimesh = multimesh
		# Tufts are dense; shadows cost more than they read.
		instance.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if String(prop_id).begins_with("grass_tuft")
			else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		)
		add_child(instance)

		if job.want_collision and SettlementLayout.is_house(prop_id):
			_add_house_collision(prop_id, transforms)


func _add_house_collision(catalog_id: StringName, transforms: Array) -> void:
	## Oriented box from catalog size_x/size_z (yawed with the instance).
	## Mesh AABBs include eaves/beams; lab packs flush to that AABB, so a full-size
	## collider walls off alleys. Shrink to the masonry body.
	const BODY_SCALE: float = 0.78
	var xz: Vector2 = SettlementLayout.collision_xz_of(catalog_id)
	var height: float = SettlementLayout.height_of(catalog_id)
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(xz.x * BODY_SCALE, height, xz.y * BODY_SCALE)
	for xform_variant in transforms:
		var xform: Transform3D = xform_variant
		var body: StaticBody3D = StaticBody3D.new()
		var collider: CollisionShape3D = CollisionShape3D.new()
		collider.shape = box
		# Box is centred; lift so the bottom sits on the slab.
		collider.position = Vector3(0.0, height * 0.5, 0.0)
		body.transform = xform
		body.add_child(collider)
		add_child(body)
