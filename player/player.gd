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

## For a peer that neither owns a given Player nor is master for it, that node's
## global_position only moves on the physics ticks a Fusion network snapshot
## actually lands on -- every tick in between reads as zero apparent velocity
## even mid-stride. Without this grace window, _update_animation() flickered
## straight back to the frozen idle pose on every such tick, which is what
## looked like "no animation, just sliding" with a hard snap on the tick a
## snapshot did land. Locally-simulated players (owner, or master-simulated
## remotes) update every tick anyway, so this adds no perceptible lag there.
const ANIM_STOP_GRACE_SEC: float = 0.2

## Extra margin the OTHER axis must clear before axis-dominance flips between
## forward/backward and left/right in _update_animation(). Holding an exact
## diagonal (e.g. W+A) puts abs(along) ~= abs(lateral), and without this
## margin floating-point noise flipped the dominant axis every physics tick --
## each flip restarts the clip via play(), which looked like the animation
## stuttering/lagging specifically while moving diagonally.
const DIAGONAL_AXIS_HYSTERESIS: float = 0.2

## Non-lethal hit feedback: a quick procedural jerk instead of a clip --
## "Hit Reaction.fbx" turned out to be a crouch, not a flinch (see
## REVIEW_NOTES.md). Rotates the whole skeleton node by a small random amount
## and springs it back via a Tween; layered on top of whatever locomotion/aim
## animation is already driving the bone poses rather than interrupting it,
## so it works regardless of what _current_clip is at the moment of the hit.
const HIT_JERK_ROTATION: float = deg_to_rad(12.0)
const HIT_JERK_RECOVER_SEC: float = 0.12

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

## Stance system. Values double as STANCE_TRANSITION_CLIP key digits below, so
## don't reorder without updating that table.
enum Stance { STAND, CROUCH, PRONE }
const CROUCH_SPEED: float = 3.0
const PRONE_SPEED: float = 1.1
const SPRINT_SPEED: float = 6.5
## Playback rate for the stand<->crouch transition clip (both directions --
## see rpc_set_stance()/_play_action_reversed()). >1 = faster than the
## recorded motion; the default 1x looked sluggish.
const CROUCH_TRANSITION_SPEED_SCALE: float = 1.6
## Forward-pace clip is picked from *observed* speed (see _forward_pace_clip()),
## not an input flag -- keeps it correct for a peer that only ever sees this
## Player's replicated position (same reasoning as ANIM_STOP_GRACE_SEC above).
const RUN_ANIM_SPEED_MIN: float = 3.0
const SPRINT_ANIM_SPEED_MIN: float = 5.5

const JUMP_VELOCITY: float = 4.6

## Procedural "knees up" jump pose instead of a clip -- see LegTuckModifier
## near _build_spine_modifier(). The downloaded Jump/Running Jump/Falling
## Idle/Landing/Hard Landing set turned out to be built for falling from a
## big height (see REVIEW_NOTES.md), wrong for this game's small hop, and hit
## a double-fire bug on top of that (vertical speed crossing zero at the apex
## looked like a landing). A continuous procedural blend sidesteps both: no
## discrete clip state to mis-trigger, and no asset to be the wrong one.
const JUMP_TUCK_AIR_THRESHOLD: float = 0.6  # vertical apparent-speed, m/s
const JUMP_TUCK_BLEND_SPEED: float = 6.0  # tuck units/sec (move_toward)
const JUMP_TUCK_THIGH_ANGLE: float = deg_to_rad(45.0)
const JUMP_TUCK_SHIN_ANGLE: float = deg_to_rad(70.0)
const LEG_TUCK_THIGH_BONES: Array[String] = ["mixamorig_LeftUpLeg", "mixamorig_RightUpLeg"]
const LEG_TUCK_SHIN_BONES: Array[String] = ["mixamorig_LeftLeg", "mixamorig_RightLeg"]

## Movement collider per stance: (height, radius, center_y), same CapsuleShape3D
## node resized on stance change -- see _apply_stance_collision(). Rough numbers,
## no real crouch/prone silhouette reference; same class of approximation as
## HITBOX_BONES below.
const STANCE_COLLISION: Dictionary = {
	Stance.STAND: {"height": 1.8, "radius": 0.35, "center_y": 0.9},
	Stance.CROUCH: {"height": 1.1, "radius": 0.35, "center_y": 0.55},
	Stance.PRONE: {"height": 0.5, "radius": 0.4, "center_y": 0.25},
}
## Camera pivot height per stance (see _update_camera()).
const STANCE_PIVOT_Y: Dictionary = {Stance.STAND: 1.6, Stance.CROUCH: 1.05, Stance.PRONE: 0.35}

## Clips that must finish playing before _update_animation() picks a new
## locomotion state -- see the guard near the top of that function.
const ACTION_CLIPS: Array[String] = [
	"fire", "crouch_fire", "reload", "melee",
	"stand_to_crouch", "prone_to_crouch", "stand_up",
	"rifle_pull_out", "rifle_put_away",
]

## Per-stance locomotion clip names, keyed by movement direction relative to
## facing (see _update_animation()). Forward pace (walk/run/sprint) is resolved
## separately in _forward_pace_clip(); the other directions have exactly one
## pace each. Missing directions fall back to the forward clip for that stance
## -- the downloaded Mixamo set doesn't cover every combination (no mirrored
## crouch-strafe-right, no continuous prone strafe/backward crawl loop).
const LOCOMOTION_CLIPS: Dictionary = {
	Stance.STAND: {
		"idle": "idle", "aim_idle": "aim_idle",
		"backward": "walk_backward", "left": "strafe_left", "right": "strafe_right",
	},
	Stance.CROUCH: {
		"idle": "crouch_idle", "aim_idle": "crouch_aim_idle", "forward": "crouch_walk_forward",
		"backward": "crouch_walk_backward", "left": "crouch_strafe_left", "right": "crouch_walk_forward",
	},
	Stance.PRONE: {
		"idle": "prone_idle", "aim_idle": "prone_idle", "forward": "prone_forward",
		"backward": "prone_backward", "left": "prone_forward", "right": "prone_forward",
	},
}
## from_stance*10 + to_stance -> one-shot transition clip (Stance: STAND=0
## CROUCH=1 PRONE=2). Pairs missing here (STAND<->PRONE directly) have no
## dedicated clip in this asset set, so that transition just snaps.
const STANCE_TRANSITION_CLIP: Dictionary = {
	1: "stand_to_crouch",    # STAND -> CROUCH
	10: "crouch_to_stand",   # CROUCH -> STAND (see rpc_set_stance -- played as "stand_to_crouch" in reverse)
	21: "prone_to_crouch",   # PRONE -> CROUCH
	20: "stand_up",          # PRONE -> STAND (user-provided "Stand Up.fbx")
}

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
@export var dying_clip: PackedScene = preload("res://Dying.fbx")

## Standing locomotion.
@export var rifle_idle_clip: PackedScene = preload("res://Rifle Idle.fbx")
@export var rifle_aim_idle_clip: PackedScene = preload("res://Rifle Aiming Idle.fbx")
@export var rifle_walk_clip: PackedScene = preload("res://Rifle Walk.fbx")
@export var rifle_run_clip: PackedScene = preload("res://Rifle Run.fbx")
@export var walk_backward_clip: PackedScene = preload("res://Walk Backward.fbx")
@export var sprint_clip: PackedScene = preload("res://Sprint.fbx")
@export var strafe_left_clip: PackedScene = preload("res://Left Strafe.fbx")
@export var strafe_right_clip: PackedScene = preload("res://Right Strafe.fbx")

## Crouch.
@export var crouch_idle_clip: PackedScene = preload("res://Crouch Idle.fbx")
@export var crouch_aim_idle_clip: PackedScene = preload("res://Idle Crouching Aiming.fbx")
@export var crouch_walk_clip: PackedScene = preload("res://Crouched Walking.fbx")
@export var crouch_walk_backward_clip: PackedScene = preload("res://Crouch Walk Backwards Stop.fbx")
@export var crouch_strafe_clip: PackedScene = preload("res://Crouch Walk Strafe Left.fbx")
@export var crouch_fire_clip: PackedScene = preload("res://Crouch Rapid Fire.fbx")
## No separate crouch_to_stand_clip -- "Crouch To Stand.fbx" turned out to be
## the wrong animation (see REVIEW_NOTES.md); rpc_set_stance() plays this same
## clip backwards instead so going down and coming up match exactly.
@export var stand_to_crouch_clip: PackedScene = preload("res://Stand To Crouch.fbx")

## Prone.
@export var prone_idle_clip: PackedScene = preload("res://Prone Idle.fbx")
@export var prone_forward_clip: PackedScene = preload("res://Prone Forward.fbx")
@export var prone_backward_clip: PackedScene = preload("res://Prone Backwards Stop.fbx")
@export var prone_to_crouch_clip: PackedScene = preload("res://Prone To Crouch Transition.fbx")
@export var stand_up_clip: PackedScene = preload("res://Stand Up.fbx")

## Weapon handling / combat.
@export var firing_rifle_clip: PackedScene = preload("res://Firing Rifle.fbx")
@export var reload_clip: PackedScene = preload("res://Reload.fbx")
@export var rifle_pull_out_clip: PackedScene = preload("res://Rifle Pull Out.fbx")
@export var rifle_put_away_clip: PackedScene = preload("res://Rifle Put Away.fbx")
@export var rifle_punch_clip: PackedScene = preload("res://Rifle Punch.fbx")

## Reactions / death. Non-lethal hits get a procedural jerk instead of a clip
## -- see _play_hit_jerk() -- "Hit Reaction.fbx" turned out to play a crouch,
## not a flinch.
@export var death_headshot_clip: PackedScene = preload("res://Death From Front Headshot.fbx")
@export var death_alt_clip: PackedScene = preload("res://Death From Right.fbx")

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
var _current_clip: String = ""
var _stance: int = Stance.STAND
## Last non-idle movement direction key ("forward"/"backward"/"left"/"right")
## actually observed, and when -- see ANIM_STOP_GRACE_SEC.
var _last_move_dir: String = ""
var _last_move_time: float = -1000.0
## Current blend amount (0..1) of the procedural jump pose -- see
## LegTuckModifier / JUMP_TUCK_BLEND_SPEED.
var _leg_tuck_amount: float = 0.0

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
	_build_leg_tuck_modifier()
	_build_camera_rig()
	_build_single_hitbox()
	_build_replicator()
	_merge_animation_clips()

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
	var col := CollisionShape3D.new()
	col.name = "MovementCollision"
	col.shape = CapsuleShape3D.new()
	add_child(col)
	_apply_stance_collision()  # sizes it from STANCE_COLLISION[Stance.STAND]
	# Movement collider sees the environment AND other players' bodies (so two
	# avatars can't walk through each other); kept off the dedicated hitbox
	# layer so it never interferes with shot raycasts.
	collision_layer = NetConfig.player_body_mask()
	collision_mask = NetConfig.environment_mask() | NetConfig.player_body_mask()


## Resizes MovementCollision for the current _stance. Same node throughout --
## no real crouch/prone silhouette reference, see STANCE_COLLISION.
func _apply_stance_collision() -> void:
	var col := get_node_or_null("MovementCollision") as CollisionShape3D
	if not col or not (col.shape is CapsuleShape3D):
		return
	var cfg: Dictionary = STANCE_COLLISION[_stance]
	var shape := col.shape as CapsuleShape3D
	shape.height = cfg["height"]
	shape.radius = cfg["radius"]
	col.position.y = cfg["center_y"]


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
	# T-pose (that's the Mixamo base download), so it is deliberately never
	# merged in anywhere -- "Rifle Idle.fbx" (see _clip_table()) is the real
	# idle now.
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
	var target_pivot: Vector3 = Vector3(0.0, STANCE_PIVOT_Y.get(_stance, 1.6), 0.0)
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
var _hit_jerk_tween: Tween


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


## Procedural "knees up" jump pose -- same SkeletonModifier3D technique as
## SpinePitchModifier above, so it blends on top of whatever locomotion clip
## is already animating the legs instead of replacing it. See
## JUMP_TUCK_AIR_THRESHOLD for why this replaced a downloaded clip set.
class LegTuckModifier extends SkeletonModifier3D:
	var tuck: float = 0.0  # 0..1, blended in Player._update_animation()
	var thigh_indices: Array[int] = []
	var shin_indices: Array[int] = []

	func _process_modification_with_delta(_delta: float) -> void:
		var skeleton := get_skeleton()
		if not skeleton or tuck <= 0.0:
			return
		# Bone-local +X is the same left-right axis SpinePitchModifier bends
		# the torso around. Thighs rotate up-and-forward, shins fold the knee
		# back the other way to bring the heel toward the seat -- signs are a
		# best guess (not visually confirmed, no editor in this environment):
		# flip either sign if a leg bends the wrong way or looks stiff.
		var thigh_extra := Quaternion(Vector3.RIGHT, -JUMP_TUCK_THIGH_ANGLE * tuck)
		for idx in thigh_indices:
			skeleton.set_bone_pose_rotation(idx, skeleton.get_bone_pose_rotation(idx) * thigh_extra)
		var shin_extra := Quaternion(Vector3.RIGHT, JUMP_TUCK_SHIN_ANGLE * tuck)
		for idx in shin_indices:
			skeleton.set_bone_pose_rotation(idx, skeleton.get_bone_pose_rotation(idx) * shin_extra)


var _leg_tuck_modifier: LegTuckModifier


func _build_leg_tuck_modifier() -> void:
	if not _skeleton:
		return
	_leg_tuck_modifier = LegTuckModifier.new()
	_leg_tuck_modifier.name = "LegTuck"
	for bone_name in LEG_TUCK_THIGH_BONES:
		var idx := _skeleton.find_bone(bone_name)
		if idx != -1:
			_leg_tuck_modifier.thigh_indices.append(idx)
	for bone_name in LEG_TUCK_SHIN_BONES:
		var idx := _skeleton.find_bone(bone_name)
		if idx != -1:
			_leg_tuck_modifier.shin_indices.append(idx)
	_skeleton.add_child(_leg_tuck_modifier)


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
	# TODO(revert-me): player.tscn's FusionServerReplicator temporarily has NO
	# object_interpolation_time set (removed for testing, was 0.1 = 100ms proxy
	# smoothing buffer). Without it, a peer that is neither owner nor master for
	# a given Player shows its position exactly as Fusion's root_interpolation_mode
	# delivers it, unsmoothed -- put the 0.1 back once that raw behaviour has been
	# compared against it. See REVIEW_NOTES.md.


## name -> [source scene, looping]. One entry per merged clip name used
## throughout this script (LOCOMOTION_CLIPS, ACTION_CLIPS, STANCE_TRANSITION_CLIP,
## _die(), _play_fire_clip(), ...). Getting Up.fbx is deliberately not in this
## table -- no knockdown/stagger state exists in this prototype to trigger it.
## Left Turn.fbx and Strafe Right.fbx are also unused (Right Strafe already
## covers the strafe role; there is no turn-in-place feature -- see
## REVIEW_NOTES.md, "Standing Turn 90 Left/Right" turned out to be a
## look-around idle, not an actual turn, and was removed).
func _clip_table() -> Dictionary:
	return {
		"idle": [rifle_idle_clip, true],
		"aim_idle": [rifle_aim_idle_clip, true],
		"walk_forward": [rifle_walk_clip, true],
		"run_forward": [rifle_run_clip, true],
		"sprint_forward": [sprint_clip, true],
		"walk_backward": [walk_backward_clip, true],
		"strafe_left": [strafe_left_clip, true],
		"strafe_right": [strafe_right_clip, true],
		"crouch_idle": [crouch_idle_clip, true],
		"crouch_aim_idle": [crouch_aim_idle_clip, true],
		"crouch_walk_forward": [crouch_walk_clip, true],
		"crouch_walk_backward": [crouch_walk_backward_clip, true],
		"crouch_strafe_left": [crouch_strafe_clip, true],
		"crouch_fire": [crouch_fire_clip, false],
		"stand_to_crouch": [stand_to_crouch_clip, false],
		"prone_idle": [prone_idle_clip, true],
		"prone_forward": [prone_forward_clip, true],
		"prone_backward": [prone_backward_clip, true],
		"prone_to_crouch": [prone_to_crouch_clip, false],
		"stand_up": [stand_up_clip, false],
		"fire": [firing_rifle_clip, false],
		"reload": [reload_clip, false],
		"rifle_pull_out": [rifle_pull_out_clip, false],
		"rifle_put_away": [rifle_put_away_clip, false],
		"melee": [rifle_punch_clip, false],
		"dying": [dying_clip, false],
		"death_headshot": [death_headshot_clip, false],
		"death_alt": [death_alt_clip, false],
	}


func _merge_animation_clips() -> void:
	if not _anim_player:
		return
	var lib: AnimationLibrary = _anim_player.get_animation_library("")
	if not lib:
		lib = AnimationLibrary.new()
		_anim_player.add_animation_library("", lib)
	for clip_name: String in _clip_table():
		var entry: Array = _clip_table()[clip_name]
		_merge_clip_into(lib, entry[0], clip_name, entry[1])


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
				# Applied unconditionally, not just to loops: a one-shot with
				# baked-in hip travel (a turn, Stand Up, a jump...) would drag
				# the mesh away from the physics-driven capsule for the clip's
				# duration too -- same class of bug this was written to fix for
				# the run cycles in the first place.
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
	elif event.is_action_pressed("crouch"):
		_request_stance(Stance.STAND if _stance == Stance.CROUCH else Stance.CROUCH)
	elif event.is_action_pressed("prone"):
		_request_stance(Stance.STAND if _stance == Stance.PRONE else Stance.PRONE)
	elif event.is_action_pressed("melee"):
		_request_melee()


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
	var drawing_rifle := slot == WeaponSlot.RIFLE and _weapon_slot != WeaponSlot.RIFLE
	var stowing_rifle := slot == WeaponSlot.HANDS and _weapon_slot != WeaponSlot.HANDS
	_weapon_slot = slot
	_apply_weapon_slot()
	_emit_local_status()
	# Cosmetic overlay only -- the re-parent above is still instant, so this
	# doesn't gate anything; it just plays alongside it.
	if drawing_rifle:
		_play_action("rifle_pull_out")
	elif stowing_rifle:
		_play_action("rifle_put_away")


## Local input -> broadcast so every peer sees the same stance change.
func _request_stance(new_stance: int) -> void:
	if new_stance == _stance or _dead:
		return
	Fusion.rpc(rpc_set_stance, new_stance)


@rpc("any_peer", "call_local")
func rpc_set_stance(new_stance: int) -> void:
	var clip: String = STANCE_TRANSITION_CLIP.get(_stance * 10 + new_stance, "")
	_stance = new_stance
	_apply_stance_collision()
	if clip == "crouch_to_stand":
		# "Crouch To Stand.fbx" was the wrong animation -- reuse "Stand To
		# Crouch" played backwards instead, so going down and coming up match.
		_play_action_reversed("stand_to_crouch", CROUCH_TRANSITION_SPEED_SCALE)
	elif clip == "stand_to_crouch":
		_play_action(clip, CROUCH_TRANSITION_SPEED_SCALE)
	elif clip != "":
		_play_action(clip)
	_last_move_dir = ""
	_emit_local_status()


## Visual only -- no melee hit detection/damage yet, see REVIEW_NOTES.md.
func _request_melee() -> void:
	if _dead or _weapon_slot != WeaponSlot.RIFLE:
		return
	Fusion.rpc(rpc_play_melee)


@rpc("any_peer", "call_local")
func rpc_play_melee() -> void:
	_play_action("melee")


## Plays a one-shot "action" clip (fire/reload/melee/hit reaction/turn/jump/
## landing/stance transition/draw/holster) that should finish uninterrupted
## before _update_animation() resumes picking a locomotion clip -- see
## ACTION_CLIPS.
func _play_action(clip_name: String, speed_scale: float = 1.0) -> void:
	if _anim_player and _anim_player.has_animation(clip_name):
		_anim_player.play(clip_name, -1.0, speed_scale)
		_current_clip = clip_name


## Same as _play_action(), but plays clip_name backwards (from its last frame
## to its first) -- used to fake a matching "stand up" out of a "sit/go down"
## clip when no correct reverse animation exists (see rpc_set_stance()).
func _play_action_reversed(clip_name: String, speed_scale: float = 1.0) -> void:
	if _anim_player and _anim_player.has_animation(clip_name):
		_anim_player.play(clip_name, -1.0, -speed_scale, true)
		_current_clip = clip_name


func _current_move_speed(sprinting: bool) -> float:
	match _stance:
		Stance.CROUCH:
			return CROUCH_SPEED
		Stance.PRONE:
			return PRONE_SPEED
		_:
			return SPRINT_SPEED if sprinting else MOVE_SPEED


const STANCE_STATUS_SUFFIX: Dictionary = {Stance.CROUCH: "   CROUCH [C]", Stance.PRONE: "   PRONE [Z]"}


func _emit_local_status() -> void:
	if MatchServer and _has_input_authority():
		MatchServer.local_status_changed.emit("%s [Q]   %s [V]%s%s" % [
			WEAPON_SLOT_NAMES[_weapon_slot],
			"1st person" if _view == View.FIRST_PERSON else "3rd person",
			"   AIM" if _aiming else "",
			STANCE_STATUS_SUFFIX.get(_stance, ""),
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
		var sprint_held := Input.is_action_pressed("sprint")
		var jump_pressed := Input.is_action_just_pressed("jump") and _stance == Stance.STAND
		if _dead:
			move_input = Vector2.ZERO
			fire_pressed = false
			jump_pressed = false
		var payload := {
			"move": move_input,
			"yaw": _yaw,
			"pitch": _pitch,
			"fire": fire_pressed,
			"sprint": sprint_held,
			"jump": jump_pressed,
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

	# Procedural jump pose: blends continuously from vertical apparent velocity
	# (observer-safe, like the rest of this function) instead of triggering a
	# discrete clip -- see JUMP_TUCK_AIR_THRESHOLD.
	var airborne := absf(apparent_velocity.y) > JUMP_TUCK_AIR_THRESHOLD
	_leg_tuck_amount = move_toward(_leg_tuck_amount, 1.0 if airborne else 0.0, JUMP_TUCK_BLEND_SPEED * delta)
	if _leg_tuck_modifier:
		_leg_tuck_modifier.tuck = _leg_tuck_amount

	if _current_clip in ACTION_CLIPS and _anim_player.is_playing():
		return  # let a one-shot action (fire/reload/melee/stance change...) finish

	# Tracked as a *direction key*, not a clip name: forward pace (walk/run/
	# sprint) is resolved separately from instantaneous speed in
	# _forward_pace_clip(), so the same "forward" key can map to different clips
	# as speed changes without re-triggering the hysteresis below.
	if speed > 0.35:
		var forward := -transform.basis.z
		var right := transform.basis.x
		var along := Vector2(forward.x, forward.z).dot(horizontal) / speed  # -1..1
		var lateral := Vector2(right.x, right.z).dot(horizontal) / speed  # -1..1
		# Dead band + hysteresis on whichever axis dominates, same reasoning as the
		# old forward/backward-only version: a plain sign test at a near-zero axis
		# value flips every physics tick (each flip restarts the clip). The axis
		# CHOICE itself needs the same treatment (DIAGONAL_AXIS_HYSTERESIS) --
		# without it, an exact diagonal sits right where abs(along) ~= abs(lateral)
		# and flips between forward/strafe every tick instead.
		var was_longitudinal := _last_move_dir != "left" and _last_move_dir != "right"
		var longitudinal_wins: bool = (
			absf(along) >= absf(lateral) - DIAGONAL_AXIS_HYSTERESIS if was_longitudinal
			else absf(along) - DIAGONAL_AXIS_HYSTERESIS >= absf(lateral)
		)
		if longitudinal_wins:
			if _last_move_dir == "backward":
				_last_move_dir = "backward" if along < 0.35 else "forward"
			else:
				_last_move_dir = "backward" if along < -0.35 else "forward"
		else:
			if _last_move_dir == "left":
				_last_move_dir = "left" if lateral < 0.35 else "right"
			else:
				_last_move_dir = "right" if lateral > -0.35 else "left"
		_last_move_time = Time.get_ticks_msec() / 1000.0

	var still_moving := _last_move_dir != "" \
		and (Time.get_ticks_msec() / 1000.0) - _last_move_time < ANIM_STOP_GRACE_SEC
	var dirs: Dictionary = LOCOMOTION_CLIPS[_stance]
	var state: String
	if not still_moving:
		state = dirs["aim_idle"] if _aiming else dirs["idle"]
	elif _last_move_dir == "forward":
		state = _forward_pace_clip(speed)
	else:
		state = dirs.get(_last_move_dir, dirs.get("forward", dirs["idle"]))

	if state == _current_clip:
		return
	if _anim_player.has_animation(state):
		_anim_player.play(state)
		_current_clip = state


## Forward-direction locomotion clip for the current stance, picked from
## *observed* speed rather than the sprint input flag -- see SPRINT_ANIM_SPEED_MIN.
func _forward_pace_clip(speed: float) -> String:
	if _stance != Stance.STAND:
		return LOCOMOTION_CLIPS[_stance]["forward"]
	if speed >= SPRINT_ANIM_SPEED_MIN:
		return "sprint_forward"
	elif speed >= RUN_ANIM_SPEED_MIN:
		return "run_forward"
	else:
		return "walk_forward"


func _play_fire_clip() -> void:
	if _dead:
		return
	_play_action("crouch_fire" if _stance == Stance.CROUCH else "fire")


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
	_apply_movement(
		Vector2.ZERO if _dead else input.get("move", Vector2.ZERO), delta_time,
		input.get("sprint", false), input.get("jump", false)
	)

	# Only the visual here: the shot RPC itself is sent from the input sampling
	# path in _physics_process, because this callback does not run at all on a
	# non-master client and its shots would otherwise never be sent.
	if is_new and input.get("fire", false) and not _has_input_authority():
		_play_fire_clip()


func _apply_movement(move_input: Vector2, delta_time: float, sprinting: bool, jump_pressed: bool) -> void:
	var basis_fwd := -transform.basis.z
	var basis_right := transform.basis.x
	var dir := Vector3.ZERO
	if move_input.length() > 0.01:
		dir = (basis_right * move_input.x + basis_fwd * -move_input.y).normalized()
	var speed := _current_move_speed(sprinting)
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if is_on_floor():
		velocity.y = JUMP_VELOCITY if jump_pressed else 0.0
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
	_stance = Stance.STAND
	_apply_stance_collision()
	_last_move_dir = ""
	_leg_tuck_amount = 0.0
	_current_clip = ""
	if _anim_player:
		_anim_player.stop()
	_emit_hp()


# ---------------------------------------------------------------------------
# Health / death (mirrored on every peer from the master's hit report).
# ---------------------------------------------------------------------------

func apply_hit_result(hp_left: int, _position: Vector3, hit_bone: String = "") -> void:
	_hp = hp_left
	_emit_hp()
	if hp_left <= 0:
		if not _dead:
			_die(hit_bone)
	else:
		_play_hit_jerk()


func _die(hit_bone: String = "") -> void:
	_dead = true
	velocity = Vector3.ZERO
	_set_hitboxes_enabled(false)
	# Deterministic per-peer pick so every peer renders the same clip from only
	# data already in the broadcast hit report (no extra RPC field needed): a
	# headshot always uses the headshot clip, anything else alternates between
	# the two generic death clips by the target's own id.
	var clip := "death_headshot" if hit_bone == "head" else ("dying" if get_player_id() % 2 == 0 else "death_alt")
	if _anim_player and _anim_player.has_animation(clip):
		_anim_player.play(clip)  # LOOP_NONE: holds the final pose until respawn
		_current_clip = clip


## Procedural non-lethal-hit flinch -- see HIT_JERK_ROTATION comment above.
func _play_hit_jerk() -> void:
	if not _skeleton:
		return
	if _hit_jerk_tween and _hit_jerk_tween.is_valid():
		_hit_jerk_tween.kill()
	var axis := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized()
	_skeleton.rotation = axis * HIT_JERK_ROTATION
	_hit_jerk_tween = create_tween()
	_hit_jerk_tween.tween_property(_skeleton, "rotation", Vector3.ZERO, HIT_JERK_RECOVER_SEC)


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
