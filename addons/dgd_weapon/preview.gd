@tool
extends SubViewportContainer
signal dragged(target: int, value: Vector3)
signal target_selected(target: int)
const ASSETS = preload("res://addons/dgd_weapon/assets.gd")
const MODIFIER = preload("res://addons/dgd_weapon/modifier.gd")
const CLIPS: Array[String] = ["idle", "aim_idle", "run_forward", "sprint_forward", "walk_forward", "walk_backward", "fire", "reload", "crouch_idle", "crouch_aim_idle", "crouch_walk_forward", "prone_idle", "prone_forward", "melee", "rifle_pull_out", "rifle_put_away", "dying"]
const TARGETS: Array[String] = ["Оружие — поправка позы", "Правая кисть", "Левая кисть", "Правый локоть", "Левый локоть", "Дуло", "Оружие — базовая опора"]
var profile: DGDWeaponProfile
var pose_index := 0
var selected := 2
var playing := true
var clip := "idle"
var speed := 1.0
var modifier: DGDWeaponModifier
var skeleton: Skeleton3D
var animator: AnimationPlayer
var camera: Camera3D
var _viewport: SubViewport
var _markers: Array[MeshInstance3D] = []
var _yaw := 2.6
var _pitch := 0.18
var _distance := 2.4
var _orbit := false
var _drag := false
var _drag_point := Vector3.ZERO
var _resume := false

func _ready() -> void:
	stretch = true
	custom_minimum_size = Vector2(400, 320)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(800, 600)
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(_viewport)
	var scene := Node3D.new()
	_viewport.add_child(scene)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202e3e")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.65
	scene.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -35, 0)
	scene.add_child(light)
	var floor := MeshInstance3D.new()
	floor.mesh = PlaneMesh.new()
	floor.mesh.size = Vector2(8, 8)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("405264")
	floor.material_override = mat
	scene.add_child(floor)
	var avatar := load("res://player/model/tony.fbx").instantiate() as Node3D
	scene.add_child(avatar)
	avatar.rotation.y = PI
	skeleton = ASSETS.find_type(avatar, Skeleton3D)
	animator = ASSETS.find_type(avatar, AnimationPlayer)
	animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	modifier = MODIFIER.new()
	skeleton.add_child(modifier)
	modifier.profile = profile
	if profile: modifier.rebuild()
	camera = Camera3D.new()
	scene.add_child(camera)
	camera.current = true
	camera.near = 0.03
	camera.fov = 45.0
	for i in TARGETS.size():
		var marker := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.016
		sphere.height = 0.032
		marker.mesh = sphere
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		marker.material_override = material
		scene.add_child(marker)
		_markers.append(marker)
	set_clip(clip)

func set_profile(value: DGDWeaponProfile) -> void:
	profile = value
	if modifier:
		modifier.profile = value
		modifier.rebuild()

func set_clip(value: String) -> void:
	clip = value
	if not animator: return
	var library := animator.get_animation_library("")
	if not library:
		library = AnimationLibrary.new()
		animator.add_animation_library("", library)
	var path := "res://player/animations/%s.fbx" % clip
	if ResourceLoader.exists(path):
		ASSETS.merge_clip(library, load(path), clip, true)
		animator.play(clip)
		animator.seek(0, true)

func seek(time: float) -> void:
	if animator: animator.seek(time, true)

func _process(delta: float) -> void:
	if not is_visible_in_tree() or not modifier or not profile: return
	modifier.profile = profile
	modifier.state = pose_index
	modifier.allow_ik = clip not in ["reload", "melee", "rifle_pull_out", "rifle_put_away", "dying"]
	if playing: animator.advance(minf(delta, 0.1) * speed)
	skeleton.advance(minf(delta, 0.1))
	var center := Vector3(0, 1.05 if pose_index < 4 else 0.4, 0)
	camera.position = center + Vector3(sin(_yaw)*cos(_pitch), sin(_pitch), cos(_yaw)*cos(_pitch)) * _distance
	camera.look_at(center)
	for i in _markers.size():
		_markers[i].position = point_for(i)
		_markers[i].scale = Vector3.ONE * (1.5 if i == selected else 1.0)
		_markers[i].material_override.albedo_color = Color.YELLOW if i == selected else (Color("f27770") if i in [1,3] else Color("68dbcf"))

func point_for(target: int) -> Vector3:
	if not profile or not modifier or modifier.targets.is_empty(): return Vector3.ZERO
	var mount := modifier.weapon_root.global_transform
	match target:
		0: return mount.origin
		1: return mount * profile.right_position
		2: return mount * profile.left_position
		3: return skeleton.global_transform * Vector3(modifier.targets.right_pole)
		4: return skeleton.global_transform * Vector3(modifier.targets.left_pole)
		5: return mount * profile.muzzle_position
		6: return (skeleton.global_transform * modifier.reference_hand * profile.transform_at(profile.mount_position, profile.mount_rotation)).origin
	return Vector3.ZERO

func value_from_world(target: int, world: Vector3) -> Vector3:
	var local := skeleton.global_transform.affine_inverse() * world
	match target:
		0: return (modifier.reference_hand * profile.transform_at(profile.mount_position, profile.mount_rotation)).affine_inverse() * local
		1,2,5: return modifier.weapon_root.global_transform.affine_inverse() * world
		3: return local - (Vector3(modifier.targets.right_pole) - profile.right_pole)
		4: return local - (Vector3(modifier.targets.left_pole) - profile.left_pole)
		6: return modifier.reference_hand.affine_inverse() * local
	return Vector3.ZERO

func _gui_input(event: InputEvent) -> void:
	if not camera: return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbit = event.pressed
			accept_event()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_distance = clampf(_distance * (0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1), 0.4, 8.0)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if not event.pressed and _drag:
				_drag = false
				playing = _resume
			elif event.pressed:
				var mouse: Vector2 = event.position * Vector2(_viewport.size) / size
				var best := 22.0
				var found := -1
				for i in _markers.size():
					if camera.is_position_behind(point_for(i)): continue
					var d := camera.unproject_position(point_for(i)).distance_to(mouse)
					if d < best: best = d; found = i
				if found >= 0:
					selected = found
					target_selected.emit(found)
					_drag = true
					_drag_point = point_for(found)
					_resume = playing
					playing = false
					accept_event()
	elif event is InputEventMouseMotion:
		if _orbit:
			_yaw -= event.relative.x * 0.008
			_pitch = clampf(_pitch + event.relative.y * 0.008, -1.2, 1.2)
			accept_event()
		elif _drag:
			var mouse: Vector2 = event.position * Vector2(_viewport.size) / size
			var origin := camera.project_ray_origin(mouse)
			var ray := camera.project_ray_normal(mouse)
			var normal := camera.global_basis.z
			var denominator := ray.dot(normal)
			if absf(denominator) > 0.0001:
				var point := origin + ray * ((_drag_point-origin).dot(normal)/denominator)
				dragged.emit(selected, value_from_world(selected, point))
			accept_event()
