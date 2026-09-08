@tool
extends SkeletonModifier3D
class_name DGDWeaponModifier
const ASSETS = preload("res://addons/dgd_weapon/assets.gd")
const SOLVER = preload("res://addons/dgd_weapon/arm_solver.gd")
var profile: DGDWeaponProfile
var state := 0
var equipped := true
var allow_ik := true
var weapon_root: Node3D
var model: Node3D
var muzzle: Marker3D
var final_frames: Dictionary = {}
var targets: Dictionary = {}
var reference_hand := Transform3D.IDENTITY
var right_error := 0.0
var left_error := 0.0
var validation_error := ""
var _right := PackedInt32Array()
var _left := PackedInt32Array()
var _back := -1
var _weight := 0.0
var _pose_transform := Transform3D.IDENTITY
var _profile_ref: DGDWeaponProfile
var _bone_version := -1
var _right_weight := 1.0
var _left_weight := 1.0

func _ready() -> void:
	weapon_root = Node3D.new()
	weapon_root.name = "WeaponRoot"
	get_skeleton().add_child(weapon_root)
	muzzle = Marker3D.new()
	muzzle.name = "Muzzle"
	weapon_root.add_child(muzzle)
	modification_processed.connect(_capture_final)

func _exit_tree() -> void:
	if is_instance_valid(weapon_root): weapon_root.queue_free()

func rebuild() -> void:
	if not is_instance_valid(weapon_root): return
	if is_instance_valid(model):
		weapon_root.remove_child(model)
		model.queue_free()
	model = ASSETS.instantiate_weapon(profile)
	weapon_root.add_child(model)
	_profile_ref = profile
	_weight = 0.0
	_pose_transform = Transform3D.IDENTITY
	_bone_version = -1
	resolve_bones()

func resolve_bones() -> void:
	var s := get_skeleton()
	if not s or not profile: return
	_right = PackedInt32Array([s.find_bone(profile.right_upper), s.find_bone(profile.right_lower), s.find_bone(profile.right_hand)])
	_left = PackedInt32Array([s.find_bone(profile.left_upper), s.find_bone(profile.left_lower), s.find_bone(profile.left_hand)])
	_back = s.find_bone(profile.back_bone)
	validation_error = ""
	for chain in [_right, _left]:
		if -1 in chain:
			validation_error = "Не найдены кости рук. Проверьте профиль скелета."
		elif s.get_bone_parent(chain[1]) != chain[0] or s.get_bone_parent(chain[2]) != chain[1]:
			validation_error = "Кости руки должны образовывать цепь плечо → предплечье → кисть."
	_bone_version = s.get_version()

func _process_modification_with_delta(delta: float) -> void:
	var s := get_skeleton()
	if not profile or not weapon_root: return
	if profile != _profile_ref: rebuild()
	if _bone_version != s.get_version(): resolve_bones()
	if not validation_error.is_empty(): return
	var pose := profile.pose_at(state)
	var blend := 1.0 - exp(-maxf(delta, 0.0) * clampf(profile.blend_speed, 1, 30))
	_pose_transform = _pose_transform.interpolate_with(profile.transform_at(pose.position, pose.rotation_degrees), blend)
	_right_weight = lerpf(_right_weight, pose.right_weight, blend)
	_left_weight = lerpf(_left_weight, pose.left_weight, blend)
	_weight = lerpf(_weight, 1.0 if equipped and allow_ik else 0.0, blend)
	var animated_hand := s.get_bone_global_pose(_right[2])
	reference_hand = animated_hand
	# Read the unmodified animation once. Never parent the weapon to a solved hand.
	var mount := animated_hand * profile.transform_at(profile.mount_position, profile.mount_rotation) * _pose_transform
	if not equipped and _back >= 0:
		mount = s.get_bone_global_pose(_back) * profile.transform_at(profile.holster_position, profile.holster_rotation)
	weapon_root.transform = mount
	muzzle.transform = profile.transform_at(profile.muzzle_position, profile.muzzle_rotation)
	var right_goal := mount * profile.transform_at(profile.right_position, profile.right_rotation)
	var left_goal := mount * profile.transform_at(profile.left_position, profile.left_rotation)
	var right_pole := s.get_bone_global_pose(_right[1]).origin + profile.right_pole
	var left_pole := s.get_bone_global_pose(_left[1]).origin + profile.left_pole
	targets = {"right": right_goal, "left": left_goal, "right_pole": right_pole, "left_pole": left_pole}
	right_error = SOLVER.solve(s, _right, right_goal, right_pole, _weight * _right_weight)
	left_error = SOLVER.solve(s, _left, left_goal, left_pole, _weight * _left_weight)

func _capture_final() -> void:
	var s := get_skeleton()
	final_frames.clear()
	# Cache in skeleton space: world movement/teleports remain current between ticks.
	for i in s.get_bone_count(): final_frames[i] = s.get_bone_global_pose(i)
