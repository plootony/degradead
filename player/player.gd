extends CharacterBody3D
class_name Player
## Player avatar: WASD movement + mouse look (Шаг 2), Idle/Run/Fire/Death animation
## (Шаг 3), Fusion client-server prediction + hitscan shooting (Шаг 4a/4b).
##
## The scene file (player.tscn) is intentionally a bare shell (this script + the
## FusionServerReplicator). Everything that depends on the Mixamo import's internal
## node layout is built at runtime in _ready() by searching the instanced model for
## a Skeleton3D/AnimationPlayer by type, instead of hardcoding a guessed NodePath.

signal hp_changed(hp: int)

const MOVE_SPEED: float = 4.5
const GRAVITY: float = 9.8
const MOUSE_SENSITIVITY: float = 0.0035
const PITCH_MIN: float = deg_to_rad(-80.0)
const PITCH_MAX: float = deg_to_rad(80.0)

## Bone the weapon is rigidly attached to (no IK, per ТЗ scope -- visual mismatch
## expected). Godot's importer replaces ":" with "_" in bone names (confirmed
## against the actual imported Tony.fbx skeleton -- Mixamo's raw FBX uses
## "mixamorig:RightHand", but that colon isn't a legal Godot node-name character).
const WEAPON_HAND_BONE: String = "mixamorig_RightHand"
const WEAPON_BACK_BONE: String = "mixamorig_Spine2"
const HEAD_BONE: String = "mixamorig_Head"
const HIPS_BONE: String = "mixamorig_Hips"
## Torso bones that get a share of the look pitch so the rifle (and the
## first-person body) follow the vertical aim instead of staying level.
const SPINE_PITCH_BONES: Array[String] = ["mixamorig_Spine", "mixamorig_Spine1", "mixamorig_Spine2"]
const SPINE_PITCH_SHARE: float = 0.8  # fraction of the camera pitch that goes into the torso

## Camera presets (DayZ-like): third person is over the right shoulder with the
## character low-centre; aiming pulls in tight over the shoulder and narrows the
## FOV; first person sits at the eyes with the body and rifle still rendered.
enum View { THIRD_PERSON, FIRST_PERSON }
const TPP_ARM_LENGTH: float = 3.0
const TPP_ARM_OFFSET: Vector3 = Vector3(0.45, 0.0, 0.0)
const TPP_FOV: float = 75.0
const TPP_AIM_ARM_LENGTH: float = 1.3
const TPP_AIM_ARM_OFFSET: Vector3 = Vector3(0.6, 0.1, 0.0)
const TPP_AIM_FOV: float = 50.0
const FPP_FOV: float = 80.0
const FPP_AIM_FOV: float = 55.0
## Eye point relative to the head bone, in body space (body forward is -Z).
const FPP_EYE_OFFSET: Vector3 = Vector3(0.0, 0.08, -0.12)
const CAMERA_BLEND_SPEED: float = 12.0

enum WeaponSlot { RIFLE, HANDS }
const WEAPON_SLOT_NAMES: Array[String] = ["AKS-74", "Hands"]

## Bone -> (hitbox key, local radius) used for the Шаг 4b modular hitboxes.
## Rough single-sphere-per-region approximation; adjust radii in the editor after
## seeing the actual model scale.
const HITBOX_BONES: Dictionary = {
	"mixamorig_Head": {"key": "head", "radius": 0.16},
	"mixamorig_Spine1": {"key": "torso", "radius": 0.28},
	"mixamorig_LeftForeArm": {"key": "left_arm", "radius": 0.11},
	"mixamorig_RightForeArm": {"key": "right_arm", "radius": 0.11},
	"mixamorig_Hips": {"key": "legs", "radius": 0.22},
}

@export var model_scene: PackedScene = preload("res://Tony.fbx")
@export var weapon_scene: PackedScene = preload("res://aks-74.fbx")
@export var run_forward_clip: PackedScene = preload("res://Run Forward.fbx")
@export var run_backward_clip: PackedScene = preload("res://Run Backward.fbx")
@export var reload_clip: PackedScene = preload("res://Reloading.fbx")
@export var dying_clip: PackedScene = preload("res://Dying.fbx")

## Single Шаг-4a capsule (movement collider is separate; this is hitbox-layer only).
@export var body_capsule_height: float = 1.7
@export var body_capsule_radius: float = 0.32
@export var body_capsule_center_y: float = 0.95

var _replicator: Node
var _skeleton: Skeleton3D
var _anim_player: AnimationPlayer
var _camera: Camera3D
var _camera_pivot: Node3D
var _hitbox_single: Area3D
var _hitbox_areas: Array[Area3D] = []
var _hitbox_history: HitboxHistory
var _weapon_attachment: Node3D
var _weapon_back_attachment: Node3D
var _weapon: Node3D
var _head_attachment: Node3D
var _spring_arm: SpringArm3D
var _view: View = View.THIRD_PERSON
var _aiming: bool = false
var _weapon_slot: int = WeaponSlot.RIFLE
var _idle_clip_name: String = ""
var _idle_is_static_pose: bool = false
var _current_clip: String = ""

var _hp: int = NetConfig.MAX_HP
var _dead: bool = false

## Headless-test hook only (see `--automove` in _physics_process).
var _automove: bool = "--automove" in OS.get_cmdline_user_args()
var _autofire: bool = "--autofire" in OS.get_cmdline_user_args()
var _autoaim: bool = "--autoaim" in OS.get_cmdline_user_args()
var _autofire_accum: float = 0.0

var _yaw: float = 0.0
var _pitch: float = 0.0
var _prev_global_position: Vector3


func _ready() -> void:
	add_to_group("players")
	_prev_global_position = global_position
	_build_movement_collision()
	_build_model_and_skeleton()
	_build_spine_modifier()
	_build_camera_rig()
	_build_single_hitbox()
	_build_replicator()
	_merge_animation_clips()

	# There is no Idle clip anywhere in this asset set (only Run Forward/Backward,
	# Reloading, Dying), and Tony.fbx's own "mixamo_com" clip is the T-pose, so
	# hold run_forward's first frame as a stand-in standing pose instead.
	if _anim_player and _anim_player.has_animation("run_forward"):
		_idle_clip_name = "run_forward"
		_idle_is_static_pose = true

	_hitbox_history = HitboxHistory.new()
	_hitbox_history.name = "HitboxHistory"
	add_child(_hitbox_history)
	_build_modular_hitboxes()

	if MatchServer:
		MatchServer.register_player(self)


func _exit_tree() -> void:
	if MatchServer:
		MatchServer.unregister_player(self)


# ---------------------------------------------------------------------------
# Scene construction (runtime, see file-level comment for why).
# ---------------------------------------------------------------------------

func _build_movement_collision() -> void:
	var shape := CapsuleShape3D.new()
	shape.height = 1.8
	shape.radius = 0.35
	var col := CollisionShape3D.new()
	col.name = "MovementCollision"
	col.shape = shape
	col.position.y = 0.9
	add_child(col)
	# Movement collider sees the environment AND other players' bodies (so two
	# avatars can't walk through each other); kept off the dedicated hitbox
	# layer so it never interferes with shot raycasts.
	collision_layer = NetConfig.player_body_mask()
	collision_mask = NetConfig.environment_mask() | NetConfig.player_body_mask()


func _build_model_and_skeleton() -> void:
	var visual := Node3D.new()
	visual.name = "Visual"
	# Mixamo characters face +Z in their own space, Godot treats -Z as forward,
	# so without this the character runs backwards (you see his face while the
	# third-person camera is behind him).
	visual.rotation.y = PI
	add_child(visual)
	var model := model_scene.instantiate()
	visual.add_child(model)
	_skeleton = _find_child_of_type(model, Skeleton3D) as Skeleton3D
	_anim_player = _find_child_of_type(model, AnimationPlayer) as AnimationPlayer
	# NOTE: Tony.fbx's own baked clip imports as "mixamo_com" and is just the
	# T-pose (that's the Mixamo base download), so it is deliberately NOT used
	# as an idle -- doing so was exactly what left the character T-posing.
	# The idle is picked in _ready() after the run clips have been merged in.
	if _skeleton:
		_attach_weapon()
	else:
		push_warning("Player: no Skeleton3D found inside Tony.fbx -- weapon/hitboxes skipped.")


func _attach_weapon() -> void:
	var bone_idx := _skeleton.find_bone(WEAPON_HAND_BONE)
	if bone_idx == -1:
		push_warning("Player: bone '%s' not found on skeleton -- weapon not attached." % WEAPON_HAND_BONE)
		return
	var attachment := BoneAttachment3D.new()
	attachment.name = "WeaponAttachment"
	attachment.bone_name = WEAPON_HAND_BONE
	_skeleton.add_child(attachment)
	var weapon := weapon_scene.instantiate() as Node3D
	_strip_weapon_extras(weapon)
	_normalize_weapon_scale(weapon)
	# Orient the rifle in the hand-bone frame. Mixamo hand bones: +Y runs
	# wrist -> knuckles, +Z is the palm normal, +X the thumb-side axis. The rifle
	# mesh points its barrel down +X with +Y up (grip at WEAPON_GRIP_LOCAL), so
	# barrel := along the fingers, up := thumb axis, rifle-left := into the palm.
	_weapon = weapon
	_weapon_attachment = attachment
	# Holster slot: rifle slung diagonally across the back (Spine2 bone).
	var back := BoneAttachment3D.new()
	back.name = "WeaponBackAttachment"
	back.bone_name = WEAPON_BACK_BONE
	_skeleton.add_child(back)
	_weapon_back_attachment = back
	_apply_weapon_slot()


## Places the rifle on the hand or the back according to _weapon_slot.
func _apply_weapon_slot() -> void:
	if not _weapon:
		return
	var s: float = _weapon.scale.x  # uniform, set by _normalize_weapon_scale
	var target: Node3D = _weapon_attachment if _weapon_slot == WeaponSlot.RIFLE else _weapon_back_attachment
	if _weapon.get_parent() != target:
		if _weapon.get_parent():
			_weapon.get_parent().remove_child(_weapon)
		target.add_child(_weapon)
	if _weapon_slot == WeaponSlot.RIFLE:
		_weapon.basis = WEAPON_IN_HAND_BASIS * s
		_weapon.position = -(WEAPON_IN_HAND_BASIS * (WEAPON_GRIP_LOCAL * s)) + WEAPON_PALM_OFFSET
	else:
		_weapon.basis = WEAPON_ON_BACK_BASIS * s
		_weapon.position = WEAPON_ON_BACK_OFFSET


## Extra props that ship inside aks-74.fbx lying next to the rifle (a loose
## cartridge, its empty case and a spare magazine). They are not part of the
## weapon; the inserted "ak74 30rnd bakelite mag" stays.
const WEAPON_EXTRA_NODE_NAMES: Array[String] = ["54539", "54539 case", "ak74 30rnd empty bakelite mag"]
## Rifle-local (unscaled) point in the middle of the pistol grip.
const WEAPON_GRIP_LOCAL: Vector3 = Vector3(-0.93, -1.0, 0.0)
## Rifle axes expressed in hand-bone space: rifle +X (barrel) -> bone +Y,
## rifle +Y (up) -> bone +X, rifle +Z (right side) -> bone -Z.
const WEAPON_IN_HAND_BASIS: Basis = Basis(Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1))
## Bone-space nudge so the grip sits inside the closed fist rather than at the wrist.
const WEAPON_PALM_OFFSET: Vector3 = Vector3(0.0, 0.08, 0.03)
## Holstered pose in the Spine2 bone frame (+Y up the spine, +Z model-forward,
## i.e. out of the chest): barrel up-and-left across the back, behind the body.
## Rifle top faces the body (+Z) so the magazine sticks outward, not into the back.
const WEAPON_ON_BACK_BASIS: Basis = Basis(Vector3(0.454, 0.891, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(0.891, -0.454, 0.0))
const WEAPON_ON_BACK_OFFSET: Vector3 = Vector3(0.0, 0.0, -0.2)

func _strip_weapon_extras(weapon: Node) -> void:
	for child in weapon.get_children():
		if String(child.name) in WEAPON_EXTRA_NODE_NAMES:
			weapon.remove_child(child)
			child.queue_free()


## aks-74.fbx renders many meters long at scale 1.0 -- almost certainly a
## unit mismatch baked into that export (a common issue when an asset comes
## from a different pack than the character). Rather than guess a fixed
## divisor blindly, measure the model's actual longest dimension and scale it
## to a plausible real-world rifle length.
const WEAPON_TARGET_LENGTH: float = 0.9

func _normalize_weapon_scale(weapon: Node3D) -> void:
	var aabb := _local_aabb(weapon, Transform3D.IDENTITY)
	var longest: float = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	if longest <= 0.001:
		return
	var factor := WEAPON_TARGET_LENGTH / longest
	if absf(factor - 1.0) > 0.05:
		weapon.scale = Vector3.ONE * factor
		print("[Player diag] weapon longest dimension=%.3f at scale 1.0 -> auto-scaled by %.5f (target %.2fm)" % [longest, factor, WEAPON_TARGET_LENGTH])


## Accumulates the AABB of every VisualInstance3D under `node`, expressed in
## `node`'s own local space (composing local `transform`s down the subtree --
## works before the node is added to the tree, unlike global_transform).
static func _local_aabb(node: Node, xform: Transform3D) -> AABB:
	var result := AABB()
	var has_any := false
	if node is VisualInstance3D:
		var mesh_aabb: AABB = node.get_aabb()
		for i in range(8):
			var p := xform * mesh_aabb.get_endpoint(i)
			result = AABB(p, Vector3.ZERO) if not has_any else result.expand(p)
			has_any = true
	for child in node.get_children():
		if child is Node3D:
			var child_aabb := _local_aabb(child, xform * child.transform)
			if has_any:
				result = result.merge(child_aabb)
			else:
				result = child_aabb
			has_any = true
	return result


func _build_camera_rig() -> void:
	_camera_pivot = Node3D.new()
	_camera_pivot.name = "CameraPivot"
	_camera_pivot.position.y = 1.6
	add_child(_camera_pivot)

	_spring_arm = SpringArm3D.new()
	_spring_arm.name = "SpringArm"
	_spring_arm.spring_length = TPP_ARM_LENGTH
	_spring_arm.position = TPP_ARM_OFFSET
	_spring_arm.margin = 0.15
	_spring_arm.collision_mask = NetConfig.environment_mask()
	_spring_arm.add_excluded_object(get_rid())
	_camera_pivot.add_child(_spring_arm)

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.fov = TPP_FOV
	_camera.near = 0.03
	_spring_arm.add_child(_camera)

	# Eye anchor for first person: follows the animated head (natural bob).
	if _skeleton and _skeleton.find_bone(HEAD_BONE) != -1:
		_head_attachment = BoneAttachment3D.new()
		_head_attachment.name = "HeadAttachment"
		_head_attachment.bone_name = HEAD_BONE
		_skeleton.add_child(_head_attachment)


## Per-frame camera rig blend towards the preset for (view, aiming).
func _update_camera(delta: float) -> void:
	if not _camera or not _spring_arm:
		return
	var target_len: float
	var target_offset: Vector3
	var target_fov: float
	var target_pivot: Vector3 = Vector3(0.0, 1.6, 0.0)
	var k := clampf(delta * CAMERA_BLEND_SPEED, 0.0, 1.0)
	if _view == View.FIRST_PERSON:
		target_len = 0.0
		target_offset = Vector3.ZERO
		target_fov = FPP_AIM_FOV if _aiming else FPP_FOV
		if _head_attachment:
			target_pivot = to_local(_head_attachment.global_position) + FPP_EYE_OFFSET
			k = 1.0  # track the head exactly, no lag
	elif _aiming:
		target_len = TPP_AIM_ARM_LENGTH
		target_offset = TPP_AIM_ARM_OFFSET
		target_fov = TPP_AIM_FOV
	else:
		target_len = TPP_ARM_LENGTH
		target_offset = TPP_ARM_OFFSET
		target_fov = TPP_FOV
	var kk := clampf(delta * CAMERA_BLEND_SPEED, 0.0, 1.0)
	_spring_arm.spring_length = lerpf(_spring_arm.spring_length, target_len, kk)
	_spring_arm.position = _spring_arm.position.lerp(target_offset, kk)
	_camera.fov = lerpf(_camera.fov, target_fov, kk)
	_camera_pivot.position = _camera_pivot.position.lerp(target_pivot, k)


## Bends the torso with the look pitch. Implemented as a SkeletonModifier3D
## (child of the Skeleton3D) because the skeleton applies modifiers on top of
## the animation pose non-destructively every frame. Writing bone poses from
## _process instead accumulated the rotation whenever the AnimationPlayer was
## paused (the idle pose), folding the character in half within a second.
class SpinePitchModifier extends SkeletonModifier3D:
	var pitch: float = 0.0
	var bone_indices: Array[int] = []

	func _process_modification_with_delta(_delta: float) -> void:
		var skeleton := get_skeleton()
		if not skeleton or bone_indices.is_empty():
			return
		var share := pitch * SPINE_PITCH_SHARE / bone_indices.size()
		# Bone-local +X is the character's left-right axis; the sign was picked
		# from screenshots (look down = torso leans forward).
		var extra := Quaternion(Vector3.RIGHT, -share)
		for idx in bone_indices:
			skeleton.set_bone_pose_rotation(idx, skeleton.get_bone_pose_rotation(idx) * extra)


var _spine_modifier: SpinePitchModifier


func _build_spine_modifier() -> void:
	if not _skeleton:
		return
	_spine_modifier = SpinePitchModifier.new()
	_spine_modifier.name = "SpinePitch"
	for bone_name in SPINE_PITCH_BONES:
		var idx := _skeleton.find_bone(bone_name)
		if idx != -1:
			_spine_modifier.bone_indices.append(idx)
	_skeleton.add_child(_spine_modifier)


func _process(delta: float) -> void:
	_update_camera(delta)
	if _spine_modifier:
		_spine_modifier.pitch = 0.0 if _dead else _pitch


func _build_single_hitbox() -> void:
	_hitbox_single = Area3D.new()
	_hitbox_single.name = "Hitbox"
	_hitbox_single.collision_layer = NetConfig.hitbox_mask()
	_hitbox_single.collision_mask = 0
	_hitbox_single.monitorable = true
	_hitbox_single.monitoring = false
	_hitbox_single.set_meta("player", self)
	_hitbox_single.set_meta("hitbox_key", "body")
	var shape := CapsuleShape3D.new()
	shape.height = body_capsule_height
	shape.radius = body_capsule_radius
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = body_capsule_center_y
	_hitbox_single.add_child(col)
	add_child(_hitbox_single)
	_hitbox_areas.append(_hitbox_single)


func _build_modular_hitboxes() -> void:
	if not _skeleton:
		return
	for bone_name: String in HITBOX_BONES.keys():
		var bone_idx := _skeleton.find_bone(bone_name)
		if bone_idx == -1:
			continue
		var info: Dictionary = HITBOX_BONES[bone_name]
		var attachment := BoneAttachment3D.new()
		attachment.bone_name = bone_name
		_skeleton.add_child(attachment)
		var area := Area3D.new()
		# Per-bone areas are only sampled into HitboxHistory (modular mode); they
		# stay off the hitbox layer so the single-mode raycast never sees them.
		area.collision_layer = 0
		area.collision_mask = 0
		area.monitoring = false
		area.monitorable = false
		area.set_meta("player", self)
		area.set_meta("hitbox_key", info["key"])
		var shape := SphereShape3D.new()
		shape.radius = info["radius"]
		var col := CollisionShape3D.new()
		col.shape = shape
		area.add_child(col)
		attachment.add_child(area)
		_hitbox_history.register_hitbox(info["key"], area, info["radius"])


func _build_replicator() -> void:
	# Must exist as a real node authored in player.tscn (root_path/owner_mode
	# set there too), NOT created here in code: FusionSpawner.spawn() scans the
	# freshly-instantiated scene for a FusionReplicator synchronously, before
	# _ready() ever runs, and crashes (native FATAL, empty replicator array) if
	# it isn't already present at that point.
	_replicator = get_node("FusionServerReplicator")
	_replicator.connect("on_process_input", _on_process_input)


func _merge_animation_clips() -> void:
	if not _anim_player:
		return
	var lib: AnimationLibrary = _anim_player.get_animation_library("")
	if not lib:
		lib = AnimationLibrary.new()
		_anim_player.add_animation_library("", lib)
	_merge_clip_into(lib, run_forward_clip, "run_forward", true)
	_merge_clip_into(lib, run_backward_clip, "run_backward", true)
	_merge_clip_into(lib, reload_clip, "reload", false)
	_merge_clip_into(lib, dying_clip, "dying", false)


func _merge_clip_into(target_lib: AnimationLibrary, scene: PackedScene, new_name: String, looping: bool) -> void:
	if target_lib.has_animation(new_name) or not scene:
		return
	var temp := scene.instantiate()
	var src_player := _find_child_of_type(temp, AnimationPlayer) as AnimationPlayer
	if src_player:
		for lib_name in src_player.get_animation_library_list():
			var src_lib := src_player.get_animation_library(lib_name)
			for anim_name in src_lib.get_animation_list():
				# Duplicate: the imported resource is shared between all Player
				# instances and we are about to edit its tracks.
				var anim: Animation = src_lib.get_animation(anim_name).duplicate()
				# Mixamo exports come in with loop_mode = NONE, so a run cycle
				# played once (0.5 s) and then froze mid-stride.
				anim.loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE
				if looping:
					_bake_in_place(anim)
				target_lib.add_animation(new_name, anim)
				break  # each Mixamo "without skin" export has exactly one clip
			if target_lib.has_animation(new_name):
				break
	temp.free()


## Strips horizontal root motion from the hips position track. "Run Backward"
## was exported WITHOUT "In Place": its hips travel ~2.5 m per cycle, which
## dragged the mesh away from the collider/camera and snapped it back every
## loop -- the visible "camera breaks while running" bug.
func _bake_in_place(anim: Animation) -> void:
	for t in range(anim.get_track_count()):
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		if not String(anim.track_get_path(t)).ends_with(HIPS_BONE):
			continue
		var key_count := anim.track_get_key_count(t)
		if key_count == 0:
			continue
		var first: Vector3 = anim.track_get_key_value(t, 0)
		for k in range(key_count):
			var v: Vector3 = anim.track_get_key_value(t, k)
			anim.track_set_key_value(t, k, Vector3(first.x, v.y, first.z))


static func _find_child_of_type(root: Node, type) -> Node:
	if is_instance_of(root, type):
		return root
	for child in root.get_children():
		var found := _find_child_of_type(child, type)
		if found:
			return found
	return null


# ---------------------------------------------------------------------------
# Per-frame: input capture (local input-authority only) + animation (everyone).
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _has_input_authority():
		return
	if event is InputEventMouseMotion:
		_yaw -= event.relative.x * MOUSE_SENSITIVITY
		_pitch = clamp(_pitch - event.relative.y * MOUSE_SENSITIVITY, PITCH_MIN, PITCH_MAX)
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# Click-to-capture, like any standard FPS -- this is also what lets you
		# click into a *different* window when testing two instances side by
		# side: only a fresh click inside THIS window re-captures its mouse.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("toggle_view"):
		set_view(View.FIRST_PERSON if _view == View.THIRD_PERSON else View.THIRD_PERSON)
	elif event.is_action_pressed("switch_weapon"):
		_request_weapon_slot((_weapon_slot + 1) % WeaponSlot.size())
	elif event.is_action_pressed("weapon_slot_1"):
		_request_weapon_slot(WeaponSlot.RIFLE)
	elif event.is_action_pressed("weapon_slot_2"):
		_request_weapon_slot(WeaponSlot.HANDS)


func set_view(view: View) -> void:
	_view = view
	_emit_local_status()


func set_aiming(aiming: bool) -> void:
	if aiming == _aiming:
		return
	_aiming = aiming
	_emit_local_status()


## Local input -> broadcast so every peer re-parents the rifle the same way.
func _request_weapon_slot(slot: int) -> void:
	if slot == _weapon_slot or _dead:
		return
	Fusion.rpc(rpc_set_weapon_slot, slot)


@rpc("any_peer", "call_local")
func rpc_set_weapon_slot(slot: int) -> void:
	_weapon_slot = slot
	_apply_weapon_slot()
	_emit_local_status()


func _emit_local_status() -> void:
	if MatchServer and _has_input_authority():
		MatchServer.local_status_changed.emit("%s [Q]   %s [V]%s" % [
			WEAPON_SLOT_NAMES[_weapon_slot],
			"1st person" if _view == View.FIRST_PERSON else "3rd person",
			"   AIM" if _aiming else "",
		])


func _physics_process(delta: float) -> void:
	if _has_input_authority():
		# NOTE: mouse_mode is set only on click/Escape (see _unhandled_input)
		# -- forcing MOUSE_MODE_CAPTURED here every frame would undo Escape on
		# the very next tick and made it impossible to alt-tab/click the other
		# test window when running two instances side by side.
		if _camera:
			_camera.current = true
		var move_input := Vector2(
			Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
			Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
		)
		if _automove:
			# Headless test hook (`-- --automove`): drive constant forward input
			# so movement/replication can be verified without a human at the
			# keyboard. Never active in a normal run.
			move_input = Vector2(0.0, -1.0)
		if _autoaim:
			# Headless test hook (`-- --autoaim`): face the nearest other player
			# so `--autofire` shots actually exercise the hit/death/respawn path.
			_aim_at_nearest_player()
		var mouse_captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		set_aiming(mouse_captured and Input.is_action_pressed("aim"))
		var fire_pressed := Input.is_action_just_pressed("fire") and mouse_captured and _weapon_slot == WeaponSlot.RIFLE
		if _autofire:
			# Headless test hook (`-- --autofire`): pull the trigger on a timer
			# so the shot RPC -> server raycast -> broadcast path can be checked.
			_autofire_accum += delta
			if _autofire_accum >= 2.0:
				_autofire_accum = 0.0
				fire_pressed = true
		if _dead:
			move_input = Vector2.ZERO
			fire_pressed = false
		var payload := {
			"move": move_input,
			"yaw": _yaw,
			"pitch": _pitch,
			"fire": fire_pressed,
		}
		if _replicator:
			_replicator.call("queue_input", delta, var_to_bytes(payload))
			# On the master, queue_input() already runs on_process_input
			# synchronously (seen in a stack trace), so draining again here
			# would apply the same tick twice. A plain client gets no such
			# callback, so without this it has zero local prediction and its
			# movement only appears after a full server round-trip.
			if Engine.has_singleton("Fusion") and not Fusion.is_master_client():
				_replicator.call("process_input_queue", delta)
		# Firing is triggered here, on the input sampling path, rather than
		# inside _on_process_input: that callback never runs on a non-master
		# client, so shots from the joining player were silently never sent.
		if fire_pressed:
			_play_fire_clip()
			_send_fire_request()
	else:
		if _camera and _camera.current:
			# Other players' avatars each carry their own Camera3D; Godot makes
			# the first one added to the scene current automatically, which would
			# otherwise leave a client watching through someone else's head.
			_camera.current = false
		# The other half of the ТЗ's queue_input()/process_input_queue() pattern:
		# the simulation server must drain inputs that arrived over the network
		# for players it does NOT own, otherwise those avatars never move for
		# anybody -- this was the "no sync between windows" bug.
		if _replicator and Engine.has_singleton("Fusion") and Fusion.is_master_client():
			_replicator.call("process_input_queue", delta)

	_update_animation(delta)


func _has_input_authority() -> bool:
	return _replicator != null and bool(_replicator.call("has_input_authority"))


func _aim_at_nearest_player() -> void:
	var best: Node3D = null
	var best_dist := INF
	for other in get_tree().get_nodes_in_group("players"):
		if other == self or not other is Node3D:
			continue
		var d: float = global_position.distance_to(other.global_position)
		if d < best_dist:
			best_dist = d
			best = other
	if not best:
		return
	var to := best.global_position - global_position
	# Shots leave the camera, which sits to the right of the body by the spring
	# arm offset: yaw the body left by the angle that offset subtends so the
	# camera ray (not the body's forward line) passes through the target.
	var lateral: float = _spring_arm.position.x if _spring_arm else 0.0
	var dist := Vector2(to.x, to.z).length()
	_yaw = atan2(-to.x, -to.z) + (asin(clampf(lateral / dist, -1.0, 1.0)) if dist > 0.01 else 0.0)
	_pitch = 0.0


func _update_animation(delta: float) -> void:
	if delta <= 0.0:
		return
	var apparent_velocity := (global_position - _prev_global_position) / delta
	_prev_global_position = global_position
	if _dead or not _anim_player:
		return  # the death clip owns the skeleton until respawn
	var horizontal := Vector2(apparent_velocity.x, apparent_velocity.z)
	var speed := horizontal.length()

	# Tracked as a *state*, not just a clip name: "idle" and "run_forward" can
	# share the same underlying clip (idle is that clip frozen on frame 0), so
	# comparing clip names alone would leave the character frozen while running.
	var state := "idle"
	if speed > 0.35:
		var forward := -transform.basis.z
		var along := Vector2(forward.x, forward.z).dot(horizontal) / speed  # -1..1
		# Only two locomotion clips exist, so strafing has to pick one. Pure
		# sideways motion has `along` ~ 0 and a plain sign test flipped between
		# forward/backward every physics tick (each flip restarts the clip).
		# Stick with the current clip inside a wide dead band instead.
		if _current_clip == "run_backward":
			state = "run_backward" if along < 0.35 else "run_forward"
		else:
			state = "run_backward" if along < -0.35 else "run_forward"

	if state == _current_clip:
		return
	# Don't cut the fire one-shot short while standing still; movement wins.
	if _current_clip == "reload" and _anim_player.is_playing() and state == "idle":
		return

	if state == "idle":
		if _idle_clip_name == "" or not _anim_player.has_animation(_idle_clip_name):
			return
		_anim_player.play(_idle_clip_name)
		if _idle_is_static_pose:
			_anim_player.seek(0.0, true)
			_anim_player.pause()
		_current_clip = state
	elif _anim_player.has_animation(state):
		_anim_player.play(state)
		_current_clip = state


func _play_fire_clip() -> void:
	if _dead:
		return
	if _anim_player and _anim_player.has_animation("reload"):
		_anim_player.play("reload")
		_current_clip = "reload"


# ---------------------------------------------------------------------------
# Fusion: authoritative movement tick (Шаг 4a) + shot request (Шаг 4a/4b).
# ---------------------------------------------------------------------------

func _on_process_input(_tick: int, delta_time: float, payload: PackedByteArray, is_new: bool) -> void:
	if payload.is_empty():
		return
	# Defensive re-registration: input_authority may not be fully replicated yet
	# at _ready() time on remote peers, so make sure MatchServer's id -> Player
	# lookup is correct by the time shots actually need resolving against it.
	if MatchServer:
		MatchServer.register_player(self)
	var input: Dictionary = bytes_to_var(payload)
	_yaw = input.get("yaw", _yaw)
	_pitch = input.get("pitch", _pitch)
	rotation.y = _yaw
	if _camera_pivot:
		_camera_pivot.rotation.x = _pitch
	_apply_movement(Vector2.ZERO if _dead else input.get("move", Vector2.ZERO), delta_time)

	# Only the visual here: the shot RPC itself is sent from the input sampling
	# path in _physics_process, because this callback does not run at all on a
	# non-master client and its shots would otherwise never be sent.
	if is_new and input.get("fire", false) and not _has_input_authority():
		_play_fire_clip()


func _apply_movement(move_input: Vector2, delta_time: float) -> void:
	var basis_fwd := -transform.basis.z
	var basis_right := transform.basis.x
	var dir := Vector3.ZERO
	if move_input.length() > 0.01:
		dir = (basis_right * move_input.x + basis_fwd * -move_input.y).normalized()
	velocity.x = dir.x * MOVE_SPEED
	velocity.z = dir.z * MOVE_SPEED
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta_time
	move_and_slide()


func _send_fire_request() -> void:
	if not _camera:
		return
	var origin := _camera.global_position
	var direction := -_camera.global_transform.basis.z
	# The RPC target must be a *networked* node (one carrying a replicator), so
	# it is routed through the shooter's own Player object. Addressing the
	# MatchServer autoload directly failed with "No FusionReplicator found for
	# object 'Node'" -- register_broadcast_receiver() alone is not enough.
	Fusion.rpc_to(NetConfig.RPC_TARGET_MASTER, rpc_request_fire, get_player_id(), origin, direction)


## RPC entry point, executed on the master/simulation-server peer only.
## claimed_shooter_id is sent explicitly because Fusion.get_rpc_sender() came
## back as 0 here in testing, which made every shot get attributed to player 1.
## The server still prefers its own sender info whenever that is available.
@rpc("any_peer")
func rpc_request_fire(claimed_shooter_id: int, origin: Vector3, direction: Vector3) -> void:
	if not Fusion.is_master_client():
		return
	var shooter_id: int = Fusion.get_rpc_sender()
	if shooter_id <= 0:
		shooter_id = claimed_shooter_id
	var shooter := MatchServer.get_player(shooter_id)
	if shooter and (shooter.call("is_dead") or shooter.call("get_weapon_slot") != WeaponSlot.RIFLE):
		return
	var result: Dictionary = MatchServer.resolve_shot(shooter_id, origin, direction)
	Fusion.rpc(rpc_report_hit, shooter_id, result["target_id"], result["hit_bone"], result["position"], result["hp_left"])


## RPC entry point, broadcast to every peer so both clients show the same result.
@rpc("any_peer", "call_local")
func rpc_report_hit(shooter_id: int, target_id: int, hit_bone: String, position: Vector3, hp_left: int) -> void:
	MatchServer.report_hit(shooter_id, target_id, hit_bone, position, hp_left)


## Master -> everyone: this player comes back to life at spawn_pos.
func broadcast_respawn(spawn_pos: Vector3) -> void:
	Fusion.rpc(rpc_respawn, spawn_pos)


@rpc("any_peer", "call_local")
func rpc_respawn(spawn_pos: Vector3) -> void:
	_dead = false
	_hp = NetConfig.MAX_HP
	velocity = Vector3.ZERO
	global_position = spawn_pos
	_prev_global_position = spawn_pos
	_set_hitboxes_enabled(true)
	# Snap remote copies instead of lerping across the map. The SDK only accepts
	# teleport() from the authority peer (logs an error elsewhere), so gate it.
	if _replicator and _replicator.has_method("teleport") and bool(_replicator.call("has_authority")):
		_replicator.call("teleport")
	_current_clip = ""
	if _anim_player:
		_anim_player.stop()
	_emit_hp()


# ---------------------------------------------------------------------------
# Health / death (mirrored on every peer from the master's hit report).
# ---------------------------------------------------------------------------

func apply_hit_result(hp_left: int, _position: Vector3) -> void:
	_hp = hp_left
	_emit_hp()
	if hp_left <= 0 and not _dead:
		_die()


func _die() -> void:
	_dead = true
	velocity = Vector3.ZERO
	_set_hitboxes_enabled(false)
	if _anim_player and _anim_player.has_animation("dying"):
		_anim_player.play("dying")  # LOOP_NONE: holds the final pose until respawn
		_current_clip = "dying"


func _set_hitboxes_enabled(enabled: bool) -> void:
	for area in _hitbox_areas:
		area.collision_layer = NetConfig.hitbox_mask() if enabled else 0


func _emit_hp() -> void:
	hp_changed.emit(_hp)
	if MatchServer and _has_input_authority():
		MatchServer.local_hp_changed.emit(_hp)


# ---------------------------------------------------------------------------
# Visual feedback.
# ---------------------------------------------------------------------------

## Short-lived line from the muzzle to the impact point, drawn on every peer.
func show_tracer(to: Vector3) -> void:
	var from: Vector3 = _weapon_attachment.global_position if _weapon_attachment else global_position + Vector3(0, 1.4, 0)
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	inst.material_override = mat
	get_tree().current_scene.add_child(inst)
	var tween := inst.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.15)
	tween.tween_callback(inst.queue_free)


# ---------------------------------------------------------------------------
# Accessors used by net/match_server.gd
# ---------------------------------------------------------------------------

func get_replicator() -> Node:
	return _replicator


func get_player_id() -> int:
	return _replicator.call("get_input_authority") if _replicator else -1


func get_hp() -> int:
	return _hp


func is_dead() -> bool:
	return _dead


func get_weapon_slot() -> int:
	return _weapon_slot


func get_hitbox_history() -> HitboxHistory:
	return _hitbox_history


func get_single_hitbox_node() -> Area3D:
	return _hitbox_single


## RIDs of this player's own colliders, so a third-person shot fired from behind
## the character's head doesn't stop on the shooter's own capsule.
func get_hitbox_rids() -> Array[RID]:
	var rids: Array[RID] = [get_rid()]
	for area in _hitbox_areas:
		rids.append(area.get_rid())
	return rids
