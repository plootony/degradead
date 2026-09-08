@tool
extends SubViewportContainer
const RIG = preload("res://addons/dgd_camera/rig.gd")
var profile: DGDCameraProfile
var first_person := false
var walking := false
var stance_height := 1.6
var rig: DGDCameraRig
var _avatar: Node3D
var _viewport: SubViewport

func _ready() -> void:
	custom_minimum_size = Vector2(280, 210)
	stretch = true
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(320, 210)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(_viewport)
	var scene := Node3D.new()
	_viewport.add_child(scene)
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("273b50")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.65
	world.environment = env
	scene.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -25, 0)
	scene.add_child(light)
	_box(scene, Vector3(0, -0.08, -5), Vector3(16, 0.1, 22), Color("46505a"))
	for x in range(-6, 7):
		_box(scene, Vector3(x, -0.02, -5), Vector3(0.015, 0.01, 20), Color("687884"))
	for z in range(-14, 5):
		_box(scene, Vector3(0, -0.02, z), Vector3(14, 0.01, 0.015), Color("687884"))
	for pos in [Vector3(-2, 0.9, -6), Vector3(0, 0.9, -9), Vector3(2, 0.9, -6)]:
		_box(scene, pos, Vector3(0.6, 1.8, 0.3), Color("dd8b59"))
	_avatar = Node3D.new()
	scene.add_child(_avatar)
	_box(_avatar, Vector3(0, 1.1, 0), Vector3(0.44, 0.65, 0.24), Color("65b7bd"))
	_box(_avatar, Vector3(0, 1.63, 0), Vector3(0.27, 0.32, 0.27), Color("adcfd1"))
	for x in [-0.13, 0.13]:
		_box(_avatar, Vector3(x, 0.38, 0), Vector3(0.16, 0.76, 0.2), Color("417c87"))
	_box(_avatar, Vector3(0.32, 1.23, -0.25), Vector3(0.12, 0.12, 0.65), Color("232c36"))
	rig = RIG.new()
	scene.add_child(rig)
	rig.camera.current = true

func _box(parent: Node, position: Vector3, size: Vector3, color: Color) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material_override = material
	parent.add_child(mesh)
	mesh.position = position

func _process(delta: float) -> void:
	if not profile or not rig or not is_visible_in_tree():
		return
	_avatar.visible = not first_person
	_avatar.scale.y = stance_height / 1.6
	rig.configure(profile, stance_height, minf(delta, 0.1), 4.5 if walking else 0.0, true)
	rig.set_pose(Vector3.ZERO, 0.0, 0.0)
	# SpringArm does not run its internal physics in the editor. This preview
	# has no occluders; position the camera at its configured unobstructed end.
	rig.camera.position = Vector3(0, 0, rig.spring_arm.spring_length)

func fire() -> void:
	if rig and profile: rig.motion.fire(profile)

func hit() -> void:
	if rig and profile: rig.motion.hit(profile)
