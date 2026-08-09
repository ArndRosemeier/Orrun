extends Node3D
## Renders a row of spheres under one sun so a material can be judged on its
## own, without a 30 second world bake in front of every iteration.
##
##   godot --path <project> --resolution 900x300 res://tools/tests/shader_probe.tscn
##
## The leftmost sphere always carries a stock material. It is the control: if it
## is lit and the others are not, the fault is in the shader under test.

const OUTPUT: String = "res://docs/shots/shader_probe.png"
const SHADERS: Array[String] = [
	"res://shaders/terrain.gdshader",
]
## A material that swallows all light photographs exactly like one that is
## simply dark, so the control sphere sets the floor for what "lit" looks like.
const MIN_LIT: float = 0.05

var _frames: int = 0


func _ready() -> void:
	var env: Environment = Environment.new()
	var sky: Sky = Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	var world_env: WorldEnvironment = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	add_child(sun)

	var count: int = SHADERS.size() + 1
	var camera: Camera3D = Camera3D.new()
	camera.position = Vector3(0.0, 0.0, float(count) * 2.4)
	camera.current = true
	add_child(camera)

	var stock: StandardMaterial3D = StandardMaterial3D.new()
	stock.albedo_color = Color(0.8, 0.8, 0.8)
	_add_sphere(_slot(0, count), stock)

	for i in SHADERS.size():
		var material: ShaderMaterial = ShaderMaterial.new()
		material.shader = load(SHADERS[i])
		_add_sphere(_slot(i + 1, count), material)


func _slot(index: int, count: int) -> float:
	return (float(index) - float(count - 1) * 0.5) * 3.0


func _add_sphere(x: float, material: Material) -> void:
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 1.2
	sphere.height = 2.4
	sphere.material = material
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.mesh = sphere
	instance.position = Vector3(x, 0.0, 0.0)
	add_child(instance)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < 10:
		return
	set_process(false)
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png(OUTPUT)
	var count: int = SHADERS.size() + 1
	var failures: int = 0
	for i in count:
		var color: Color = _sample(image, i, count)
		var lit: bool = maxf(color.r, maxf(color.g, color.b)) >= MIN_LIT
		var label: String = "stock" if i == 0 else SHADERS[i - 1].get_file()
		print("  %-24s (%.3f %.3f %.3f)  %s" % [
			label, color.r, color.g, color.b, "lit" if lit else "UNLIT"
		])
		if not lit:
			failures += 1
	print("wrote %s" % OUTPUT)
	get_tree().quit(1 if failures > 0 else 0)


func _sample(image: Image, index: int, count: int) -> Color:
	var camera: Camera3D = get_viewport().get_camera_3d()
	var point: Vector2 = camera.unproject_position(Vector3(_slot(index, count), 0.0, 0.0))
	return image.get_pixel(
		clampi(int(point.x), 0, image.get_width() - 1),
		clampi(int(point.y), 0, image.get_height() - 1)
	)
