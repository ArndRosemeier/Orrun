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
var _body: StaticBody3D


func apply(job: ChunkJob, terrain_material: Material, water_material: Material) -> void:
	chunk = job.chunk
	lod = job.lod
	max_contract_error = job.max_contract_error
	var origin: Vector2 = WorldCoords.chunk_origin(job.config, job.chunk)
	world_origin = Vector3(origin.x, 0.0, origin.y)
	name = "Chunk_%d_%d" % [chunk.x, chunk.y]

	_build_terrain(job, terrain_material)
	_build_water(job, water_material)
	_build_bridges(job, terrain_material, origin)
	_build_props(job)
	refresh_transform()


func refresh_transform() -> void:
	position = WorldOrigin.to_scene(world_origin)


## Hiding water is how the terrain underneath gets inspected; a shallow sheet
## and pale ground are hard to tell apart in a screenshot otherwise.
func set_water_visible(visible_state: bool) -> void:
	if _water != null:
		_water.visible = visible_state


func _build_terrain(job: ChunkJob, material: Material) -> void:
	var data: MeshExtract.MeshData = job.mesh_data
	if data.is_empty():
		return
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

	if not data.collision_faces.is_empty():
		var shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
		shape.set_faces(data.collision_faces)
		var collider: CollisionShape3D = CollisionShape3D.new()
		collider.shape = shape
		_body = StaticBody3D.new()
		_body.add_child(collider)
		add_child(_body)


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


func _build_bridges(job: ChunkJob, material: Material, origin: Vector2) -> void:
	for site in job.bridges:
		var mesh: ArrayMesh = BridgeBuilder.build(site, origin)
		mesh.surface_set_material(0, material)
		var instance: MeshInstance3D = MeshInstance3D.new()
		instance.mesh = mesh
		add_child(instance)

		if job.want_collision:
			var shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
			shape.set_faces(mesh.get_faces())
			var collider: CollisionShape3D = CollisionShape3D.new()
			collider.shape = shape
			var body: StaticBody3D = StaticBody3D.new()
			body.add_child(collider)
			add_child(body)


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
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(instance)
