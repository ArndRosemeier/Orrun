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
		var built: BridgeBuilder.BuildResult = BridgeBuilder.build(site, origin)

		if built.uses_kit:
			_add_bridge_multimesh(built.mid_mesh, built.mid_transforms)
			_add_bridge_multimesh(built.end_mesh, built.end_transforms)
			if job.want_collision:
				_add_bridge_kit_collision(built)

		if built.procedural_mesh != null:
			built.procedural_mesh.surface_set_material(0, material)
			var instance: MeshInstance3D = MeshInstance3D.new()
			instance.mesh = built.procedural_mesh
			add_child(instance)
			if job.want_collision:
				_add_mesh_collision(built.procedural_mesh)


func _add_mesh_collision(mesh: ArrayMesh) -> void:
	var shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
	shape.set_faces(mesh.get_faces())
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


func _add_bridge_kit_collision(built: BridgeBuilder.BuildResult) -> void:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_bridge_collision(st, built.mid_mesh, built.mid_transforms)
	_append_bridge_collision(st, built.end_mesh, built.end_transforms)
	var baked: ArrayMesh = st.commit()
	if baked.get_surface_count() == 0:
		return
	_add_mesh_collision(baked)


func _append_bridge_collision(
	st: SurfaceTool, mesh: Mesh, transforms: Array[Transform3D]
) -> void:
	if mesh == null:
		return
	for xform in transforms:
		for surface_i in mesh.get_surface_count():
			st.append_from(mesh, surface_i, xform)


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
	var footprint: float = SettlementLayout.footprint_of(catalog_id)
	var height: float = SettlementLayout.height_of(catalog_id)
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(footprint * 0.85, height, footprint * 0.85)
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
