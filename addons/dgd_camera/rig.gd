@tool
extends Node3D
class_name DGDCameraRig
const MOTION = preload("res://addons/dgd_camera/motion.gd")
var spring_arm: SpringArm3D
var camera: Camera3D
var motion := MOTION.new()
var anchor_offset := Vector3(0.0, 1.6, 0.0)
var max_origin_distance := 3.8
var _distance := 0.0
var _stance_height := 1.6
var _tilt := 0.0
var _configured := false

func _ready() -> void:
	spring_arm = SpringArm3D.new()
	spring_arm.name = "SpringArm"
	spring_arm.margin = 0.15
	spring_arm.collision_mask = 1
	add_child(spring_arm)
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.near = 0.03
	spring_arm.add_child(camera)

func configure(profile: DGDCameraProfile, stance_height: float, delta: float, speed: float, grounded: bool, alive: bool = true) -> void:
	var blend := 1.0 if not _configured else 1.0 - exp(-profile.value("transition_speed") * maxf(delta, 0.0))
	_configured = true
	_stance_height = stance_height
	var height := stance_height + profile.value("height") - 1.6
	anchor_offset.y = lerpf(anchor_offset.y, height, blend)
	_tilt = lerpf(_tilt, deg_to_rad(profile.value("tilt")), blend)
	_distance = lerpf(_distance, profile.value("distance"), blend)
	spring_arm.spring_length = _distance
	spring_arm.position = spring_arm.position.lerp(Vector3(profile.value("shoulder"), 0.0, profile.value("forward_offset")), blend)
	camera.fov = lerpf(camera.fov, profile.value("fov"), blend)
	camera.rotation = motion.sample(delta, profile, speed, grounded, alive)

func set_pose(body_position: Vector3, yaw: float, pitch: float) -> void:
	# Mouse look is never smoothed. Only profile transitions and effects are blended.
	global_rotation = Vector3(clampf(pitch + _tilt, deg_to_rad(-89.0), deg_to_rad(89.0)), yaw, 0.0)
	global_position = body_position + Basis(Vector3.UP, yaw) * anchor_offset
	# At extreme pitch, a low/high pivot and a long arm can exceed the allowed
	# camera-origin radius. Solve the ray/sphere exit distance for this pose.
	var offset := global_position + global_basis * spring_arm.position - (body_position + Vector3.UP * _stance_height)
	var projection := offset.dot(global_basis.z)
	var remaining := maxf(0.0, projection * projection + max_origin_distance * max_origin_distance - offset.length_squared())
	spring_arm.spring_length = minf(_distance, maxf(0.0, -projection + sqrt(remaining)))

func reset() -> void:
	motion.reset()
	_configured = false
	if camera:
		camera.rotation = Vector3.ZERO
