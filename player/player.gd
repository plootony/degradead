extends CharacterBody3D
class_name Player
## Player avatar: WASD movement + mouse look (Шаг 2), Idle/Run/Fire/Death animation
## (Шаг 3), Fusion client-server prediction + lag-compensated hitscan (Шаг 4a/4b).
##
## The scene file (player.tscn) is intentionally a bare shell (this script + the
## FusionServerReplicator). Everything that depends on the Mixamo import's internal
## node layout is built at runtime in _ready() by searching the instanced model for
## a Skeleton3D/AnimationPlayer by type, instead of hardcoding a guessed NodePath.

signal hp_changed(hp: int)
signal visual_pose_updated
## Owner-only, local presentation: the inventory panel (ui/inventory_panel.gd)
## listens to this to show/hide itself.
signal inventory_visibility_changed(open: bool)

const MOVE_SPEED: float = 4.5
const GRAVITY: float = 9.8
const MOUSE_SENSITIVITY: float = 0.0035
const PITCH_MIN: float = deg_to_rad(-80.0)
const PITCH_MAX: float = deg_to_rad(80.0)

## Animation reads CharacterBody3D.velocity: local prediction / master simulation
## writes it, and Fusion REPLICATION_AUTO keeps it on observers between snapshots.
## Position deltas include packet batching, interpolation and rollback corrections;
## differentiating them would repeatedly switch and restart locomotion clips.

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
## against the actual imported tony.fbx skeleton -- Mixamo's raw FBX uses
## "mixamorig:RightHand", but that colon isn't a legal Godot node-name character).
const WEAPON_HAND_BONE: String = "mixamorig_RightHand"
const WEAPON_BACK_BONE: String = "mixamorig_Spine2"
const HEAD_BONE: String = "mixamorig_Head"
const HIPS_BONE: String = "mixamorig_Hips"
## Torso bones that get a share of the look pitch so the rifle (and the
## first-person body) follow the vertical aim instead of staying level.
const SPINE_PITCH_BONES: Array[String] = ["mixamorig_Spine", "mixamorig_Spine1", "mixamorig_Spine2"]
const SPINE_PITCH_SHARE: float = 0.8  # fraction of the camera pitch that goes into the torso

## Profiles are edited with the DGD Camera editor plugin.
enum View { THIRD_PERSON, FIRST_PERSON }
@export var camera_settings: DGDCameraSettings = preload("res://addons/dgd_camera/camera_settings.tres")
const CAMERA_RIG = preload("res://addons/dgd_camera/rig.gd")
var _camera_rig: DGDCameraRig

## Widened from the old {RIFLE, HANDS} for the modular inventory (ТЗ §1):
## three independently-equippable weapon slots plus bare hands. Index order
## matches inventory/inventory.gd's DGDInventory.SlotKind (MAIN/SECONDARY/
## PISTOL) for the first three values -- UNARMED has no inventory slot index.
enum WeaponSlot { MAIN, SECONDARY, PISTOL, UNARMED }
const WEAPON_SLOT_NAMES: Array[String] = ["Main", "Secondary", "Pistol", "Unarmed"]

## Stance system. Values double as STANCE_TRANSITION key digits below, so
## don't reorder without updating that table.
enum Stance { STAND, CROUCH, PRONE }
const CROUCH_SPEED: float = 3.0
const PRONE_SPEED: float = 1.1
const SPRINT_SPEED: float = 6.5
## Playback rate for the stand<->crouch transition clip (both directions --
## see _sync_presentation()/_play_action_reversed()). >1 = faster than the
## recorded motion; the default 1x looked sluggish.
const CROUCH_TRANSITION_SPEED_SCALE: float = 1.6
## Forward pace follows simulated / replicated velocity (see _forward_pace_clip()).
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
const JUMP_TUCK_AIR_THRESHOLD: float = 0.6  # vertical simulation velocity, m/s
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
	Stance.PRONE: {"height": 0.5, "radius": 0.25, "center_y": 0.25},
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
## from_stance*10 + to_stance -> one-shot transition {clip, reversed?, speed?}
## (Stance: STAND=0 CROUCH=1 PRONE=2). Pairs missing here (STAND<->PRONE
## directly) have no dedicated clip in this asset set, so that transition just
## snaps. CROUCH -> STAND plays the going-down clip backwards: "Crouch To
## Stand.fbx" turned out to be the wrong animation (see REVIEW_NOTES.md).
const STANCE_TRANSITION: Dictionary = {
	1: {"clip": "stand_to_crouch", "speed": CROUCH_TRANSITION_SPEED_SCALE},  # STAND -> CROUCH
	10: {"clip": "stand_to_crouch", "speed": CROUCH_TRANSITION_SPEED_SCALE, "reversed": true},  # CROUCH -> STAND
	21: {"clip": "prone_to_crouch"},  # PRONE -> CROUCH
	20: {"clip": "stand_up"},  # PRONE -> STAND (user-provided "Stand Up.fbx")
}
## Death clip by the hitbox key that landed the killing blow (see
## NetConfig.DAMAGE_BY_HITBOX for the matching damage table). Anything not
## listed alternates between the two generic clips -- see _die().
const DEATH_CLIP_BY_HITBOX: Dictionary = {"head": "death_headshot"}
const DEATH_CLIPS_GENERIC: Array[String] = ["dying", "death_alt"]

## Hit shapes recorded into HitboxHistory every tick on the master (see
## get_hitbox_shapes()) and tested analytically by MatchServer.resolve_shot():
##  "single"  -> one capsule that follows STANCE_COLLISION (vertical) or, prone,
##               PRONE_HITBOX_* (horizontal along facing, head end forward).
##  "modular" -> capsules between limb joints, spheres for head/pelvis.
##               Each segment has its own frame for reprojecting blood effects.
const PRONE_HITBOX_HALF_LENGTH: float = 0.75
const PRONE_HITBOX_RADIUS: float = 0.28
const PRONE_HITBOX_CENTER: Vector3 = Vector3(0.0, 0.28, -0.2)  # body space, -Z = forward
const HITBOX_BONES: Dictionary = {
	"mixamorig_Head": {"key": "head", "radius": 0.16},
	"mixamorig_Spine": {"key": "torso", "end": "mixamorig_Spine2", "radius": 0.22},
	"mixamorig_Hips": {"key": "pelvis", "radius": 0.20},
	"mixamorig_LeftArm": {"key": "left_arm", "end": "mixamorig_LeftForeArm", "radius": 0.10},
	"mixamorig_LeftForeArm": {"key": "left_forearm", "end": "mixamorig_LeftHand", "radius": 0.09},
	"mixamorig_RightArm": {"key": "right_arm", "end": "mixamorig_RightForeArm", "radius": 0.10},
	"mixamorig_RightForeArm": {"key": "right_forearm", "end": "mixamorig_RightHand", "radius": 0.09},
	"mixamorig_LeftUpLeg": {"key": "left_leg", "end": "mixamorig_LeftLeg", "radius": 0.12},
	"mixamorig_LeftLeg": {"key": "left_shin", "end": "mixamorig_LeftFoot", "radius": 0.10},
	"mixamorig_RightUpLeg": {"key": "right_leg", "end": "mixamorig_RightLeg", "radius": 0.12},
	"mixamorig_RightLeg": {"key": "right_shin", "end": "mixamorig_RightFoot", "radius": 0.10},
}

@export var model_scene: PackedScene = preload("res://player/model/tony.fbx")
@export var weapon_library: DGDWeaponLibrary = preload("res://addons/dgd_weapon/library.tres")
## Modular inventory (ТЗ §3/§5): item catalogue, respawn kit and weapon-mount
## transforms are all data, editable without touching this script.
@export var item_catalog: DGDItemCatalog = preload("res://inventory/item_catalog.tres")
@export var starter_loadout: DGDStarterLoadout = preload("res://inventory/default_loadout.tres")
@export var mount_config: DGDWeaponMountConfig = preload("res://inventory/mount_config.tres")
const MOUNT_VISUAL = preload("res://addons/dgd_weapon/mount_visual.gd")
const WEAPON_MODIFIER = preload("res://addons/dgd_weapon/modifier.gd")
var _weapon_modifier: DGDWeaponModifier
var _muzzle_effect: DGDMuzzleEffect
var _firearm_motion := preload("res://addons/dgd_firearm/motion.gd").new()
var _shot_heat := 0.0
var _shot_heat_at := 0.0
var _auto_trigger := false
var _local_heat := 0.0
var _local_heat_at := 0.0
var _weapon_profile_id: String = ""
var _observed_weapon_profile: String = ""
@export var dying_clip: PackedScene = preload("res://player/animations/dying.fbx")

## Standing locomotion.
@export var rifle_idle_clip: PackedScene = preload("res://player/animations/idle.fbx")
@export var rifle_aim_idle_clip: PackedScene = preload("res://player/animations/aim_idle.fbx")
@export var rifle_walk_clip: PackedScene = preload("res://player/animations/walk_forward.fbx")
@export var rifle_run_clip: PackedScene = preload("res://player/animations/run_forward.fbx")
@export var walk_backward_clip: PackedScene = preload("res://player/animations/walk_backward.fbx")
@export var sprint_clip: PackedScene = preload("res://player/animations/sprint_forward.fbx")
@export var strafe_left_clip: PackedScene = preload("res://player/animations/strafe_left.fbx")
@export var strafe_right_clip: PackedScene = preload("res://player/animations/strafe_right.fbx")

## Crouch.
@export var crouch_idle_clip: PackedScene = preload("res://player/animations/crouch_idle.fbx")
@export var crouch_aim_idle_clip: PackedScene = preload("res://player/animations/crouch_aim_idle.fbx")
@export var crouch_walk_clip: PackedScene = preload("res://player/animations/crouch_walk_forward.fbx")
@export var crouch_walk_backward_clip: PackedScene = preload("res://player/animations/crouch_walk_backward.fbx")
@export var crouch_strafe_clip: PackedScene = preload("res://player/animations/crouch_strafe_left.fbx")
@export var crouch_fire_clip: PackedScene = preload("res://player/animations/crouch_fire.fbx")
## No separate crouch_to_stand_clip -- "Crouch To Stand.fbx" turned out to be
## the wrong animation (see REVIEW_NOTES.md); _sync_presentation() plays this same
## clip backwards instead so going down and coming up match exactly.
@export var stand_to_crouch_clip: PackedScene = preload("res://player/animations/stand_to_crouch.fbx")

## Prone.
@export var prone_idle_clip: PackedScene = preload("res://player/animations/prone_idle.fbx")
@export var prone_forward_clip: PackedScene = preload("res://player/animations/prone_forward.fbx")
@export var prone_backward_clip: PackedScene = preload("res://player/animations/prone_backward.fbx")
@export var prone_to_crouch_clip: PackedScene = preload("res://player/animations/prone_to_crouch.fbx")
@export var stand_up_clip: PackedScene = preload("res://player/animations/stand_up.fbx")

## Weapon handling / combat.
@export var firing_rifle_clip: PackedScene = preload("res://player/animations/fire.fbx")
@export var reload_clip: PackedScene = preload("res://player/animations/reload.fbx")
@export var rifle_pull_out_clip: PackedScene = preload("res://player/animations/rifle_pull_out.fbx")
@export var rifle_put_away_clip: PackedScene = preload("res://player/animations/rifle_put_away.fbx")
@export var rifle_punch_clip: PackedScene = preload("res://player/animations/melee.fbx")

## Reactions / death. Non-lethal hits get a procedural jerk instead of a clip
## -- see _play_hit_jerk() -- "Hit Reaction.fbx" turned out to play a crouch,
## not a flinch.
@export var death_headshot_clip: PackedScene = preload("res://player/animations/death_headshot.fbx")
@export var death_alt_clip: PackedScene = preload("res://player/animations/death_alt.fbx")

## Input wire layout (12 bytes): int8 move X/Y; uint16 yaw; int16 pitch;
## uint8 flags; uint8 stance/weapon; uint32 life id. The same payload drives
## host simulation and client replay; RPCs are reserved for discrete effects/shots.
const INPUT_PACKET_SIZE: int = PlayerInput.SIZE
const INPUT_FLAG_FIRE: int = 1
const INPUT_FLAG_SPRINT: int = 2
const INPUT_FLAG_JUMP: int = 4
const INPUT_FLAG_AIM: int = 8

var _replicator: Node
var _skeleton: Skeleton3D
var _anim_player: AnimationPlayer
var _camera: Camera3D
var _camera_pivot: Node3D
var _hitbox_history: HitboxHistory
## HITBOX_BONES bone name -> skeleton bone index, resolved once in _ready().
var _hitbox_bone_indices: Dictionary = {}
var _weapon_attachment: Node3D
var _weapon: Node3D
var _muzzle: Marker3D
var _spring_arm: SpringArm3D
var _view: View = View.THIRD_PERSON
var _aiming: bool = false
var _weapon_slot: int = WeaponSlot.MAIN
var _current_clip: String = ""
var _stance: int = Stance.STAND
## Last non-idle movement direction key ("forward"/"backward"/"left"/"right")
## retained only for directional hysteresis; velocity determines moving / idle.
var _last_move_dir: String = ""
## Current blend amount (0..1) of the procedural jump pose -- see
## LegTuckModifier / JUMP_TUCK_BLEND_SPEED.
var _leg_tuck_amount: float = 0.0

var _hp: int = NetConfig.MAX_HP
var _injured_parts: int = 0
var _observed_injured_parts: int = -1
var _dead: bool = false
var _status_emitted: bool = false

## Headless-test hook only (see `--automove` in _physics_process).
var _automove: bool = "--automove" in OS.get_cmdline_user_args()
var _autofire: bool = "--autofire" in OS.get_cmdline_user_args()
var _autoaim: bool = "--autoaim" in OS.get_cmdline_user_args()
var _autofire_accum: float = 0.0

var _yaw: float = 0.0
var _pitch: float = 0.0
# Local intent must NEVER be overwritten when Fusion replays old input.
var _look_yaw: float = 0.0
var _look_pitch: float = 0.0
var _wanted_stance: int = Stance.STAND
var _wanted_weapon: int = WeaponSlot.MAIN
var _jump_pending: bool = false
var _fire_pending: bool = false
var _shot_sequence: int = 0
var _local_next_fire_at: float = 0.0
# These fields are part of the authoritative snapshot (player.tscn).
var _life_id: int = 0
var _respawn_at: float = 0.0
var _last_shot_sequence: int = 0
var _next_fire_at: float = 0.0
var _observed_life_id: int = -1
var _observed_hp: int = -1
var _observed_stance: int = -1
var _observed_weapon: int = -1
var _observed_aim: bool = false
var _death_bone: String = ""
var _registered_id: int = -1
var _collision_stance: int = -1
var _camera_advance_velocity := Vector3.ZERO
var _view_body_position := Vector3.ZERO
var _view_correction := Vector3.ZERO
var _last_input_motion := Vector3.ZERO
var _view_snap_pending: bool = true


var _inventory: DGDPlayerInventory
var _reload_visual_active := false
## Three rigid mount points (MAIN/SECONDARY/PISTOL), indexed like WeaponSlot --
## shows whichever weapon slot is NOT currently active (ТЗ §2). Built in
## _build_model_and_skeleton(), refreshed every visual-pose tick.
var _weapon_mounts: Array[DGDWeaponMountVisual] = []
## Owner-only: Tab toggles this; while true, camera look/fire/weapon input is
## ignored (ТЗ §4 "при открытом инвентаре блокировать стрельбу и управление
## камерой") and the mouse cursor is released for the inventory UI.
var _inventory_open: bool = false

func _ready() -> void:
	add_to_group("players")
	_build_movement_collision()
	_build_model_and_skeleton()
	_build_spine_modifier()
	_build_leg_tuck_modifier()
	if _weapon_modifier:
		_skeleton.move_child(_weapon_modifier, _skeleton.get_child_count() - 1)
	_build_camera_rig()
	_build_replicator()
	_merge_animation_clips()
	if _anim_player:
		_anim_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	if _skeleton:
		_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL

	if _skeleton:
		for bone_name: String in HITBOX_BONES.keys():
			var idx := _skeleton.find_bone(bone_name)
			if idx != -1:
				_hitbox_bone_indices[bone_name] = idx
			var end_name: String = HITBOX_BONES[bone_name].get("end", "")
			if not end_name.is_empty():
				var end_idx := _skeleton.find_bone(end_name)
				if end_idx != -1:
					_hitbox_bone_indices[end_name] = end_idx
	# Record from visual_pose_updated, after the final skeleton modifier.
	_hitbox_history = HitboxHistory.new()
	_hitbox_history.name = "HitboxHistory"
	_hitbox_history.setup(self)
	add_child(_hitbox_history)

	_inventory = get_node("Inventory")
	_inventory.bind_player(self)
	_refresh_registration()
	_sync_presentation()


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
	collision_layer = NetConfig.layer_mask(NetConfig.PLAYER_BODY_LAYER_BIT)
	collision_mask = NetConfig.layer_mask(NetConfig.ENVIRONMENT_LAYER_BIT) | NetConfig.layer_mask(NetConfig.PLAYER_BODY_LAYER_BIT)


## Resizes MovementCollision for the current _stance. Same node throughout --
## no real crouch/prone silhouette reference, see STANCE_COLLISION.
func _apply_stance_collision() -> void:
	if _collision_stance == _stance:
		return
	var col := get_node_or_null("MovementCollision") as CollisionShape3D
	if not col or not (col.shape is CapsuleShape3D):
		return
	var cfg: Dictionary = STANCE_COLLISION[_stance]
	var shape := col.shape as CapsuleShape3D
	shape.radius = cfg["radius"]
	shape.height = cfg["height"]
	col.position.y = cfg["center_y"]
	_collision_stance = _stance


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
	# NOTE: tony.fbx's own baked clip imports as "mixamo_com" and is just the
	# T-pose (that's the Mixamo base download), so it is deliberately never
	# merged in anywhere -- the "idle" clip in _clip_table() is the real idle now.
	if _skeleton:
		_attach_weapon()
	else:
		push_warning("Player: no Skeleton3D found inside tony.fbx -- weapon/hitboxes skipped.")


func _attach_weapon() -> void:
	_weapon_modifier = WEAPON_MODIFIER.new()
	_weapon_modifier.name = "WeaponIK"
	_skeleton.add_child(_weapon_modifier)
	_weapon_modifier.modification_processed.connect(func(): visual_pose_updated.emit())
	# No default-profile fallback here (unlike the old single-weapon version):
	# an empty _weapon_profile_id is now a legitimate "unarmed" state, granted
	# by the inventory/starter kit rather than assumed. _apply_weapon_profile()
	# below already handles a null profile (hides the in-hand model entirely).
	_apply_weapon_profile()
	_build_weapon_mounts()


## Rigid mount points for the two weapon slots NOT currently in hand (ТЗ §2).
## Children of the same Skeleton3D as WeaponRoot so their `transform` stays
## skeleton-local, no manual world-space math needed (mirrors how
## DGDWeaponModifier parents its own weapon_root).
func _build_weapon_mounts() -> void:
	_weapon_mounts.clear()
	for i in WeaponSlot.UNARMED:  # MAIN, SECONDARY, PISTOL -- not UNARMED
		var mount := MOUNT_VISUAL.new()
		mount.name = "WeaponMount%d" % i
		_skeleton.add_child(mount)
		_weapon_mounts.append(mount)


func _apply_weapon_profile() -> void:
	if not _weapon_modifier: return
	var profile := weapon_library.find_profile(_weapon_profile_id) if not _weapon_profile_id.is_empty() else null
	_weapon_modifier.profile = profile
	_weapon_modifier.rebuild()
	_weapon = _weapon_modifier.model
	_weapon_attachment = _weapon_modifier.weapon_root
	_muzzle = _weapon_modifier.muzzle
	_firearm_motion.reset()
	_local_heat = 0.0
	if profile and _muzzle and not _muzzle_effect:
		_muzzle_effect = preload("res://addons/dgd_firearm/muzzle_effect.gd").new()
		_muzzle.add_child(_muzzle_effect)
	_observed_weapon_profile = _weapon_profile_id


## Direct override, independent of the inventory (used by the weapon addon's
## own tests/editor preview to force a profile without an equipped item). Real
## gameplay never calls this -- _weapon_profile_id is otherwise only ever
## derived from whatever the active weapon slot holds, see
## _on_process_input()/broadcast_respawn()/rpc_request_move().
func server_set_weapon_profile(id: String) -> bool:
	if not Fusion.is_master_client() or not weapon_library.find_profile(id): return false
	if id == _weapon_profile_id: return true
	_weapon_profile_id = id
	_shot_heat = 0.0
	_sync_presentation()
	return true


func _advance_visual_pose(delta: float) -> void:
	if _spine_modifier:
		_spine_modifier.pitch = 0.0 if _dead else (_look_pitch if _has_input_authority() else _pitch)
	if _weapon_modifier:
		_weapon_modifier.state = _stance * 2 + (1 if _aiming else 0)
		_weapon_modifier.allow_ik = _hp > 0 and _current_clip not in ["reload", "melee", "rifle_pull_out", "rifle_put_away"]
	if _anim_player: _anim_player.advance(delta)
	if _skeleton: _skeleton.advance(delta)
	_update_weapon_mounts()  # after skeleton.advance() so bone poses are this tick's


## Shows each inactive weapon slot's item on its configured mount point (ТЗ
## §2). Deterministic from replicated state (_weapon_slot, Inventory.slots_json)
## alone, so every peer -- including observers of another player -- renders
## the same result; the active slot is excluded so a weapon is never drawn
## both in-hand and on its mount at once.
func _update_weapon_mounts() -> void:
	if not _skeleton or not _inventory or _weapon_mounts.size() < WeaponSlot.UNARMED:
		return
	for slot in WeaponSlot.UNARMED:
		var mount := _weapon_mounts[slot]
		if slot == _weapon_slot or _dead:
			mount.visible = false
			continue
		var profile_id := _inventory.weapon_profile_id_at(slot)
		if profile_id.is_empty():
			mount.visible = false
			continue
		var profile := weapon_library.find_profile(profile_id)
		mount.show_profile(profile)
		if profile:
			var bone_idx := _skeleton.find_bone(mount_config.bone_for(slot))
			if bone_idx != -1:
				mount.apply_transform(_visual_bone_frame(bone_idx), mount_config.position_for(slot), mount_config.rotation_for(slot))


func _build_camera_rig() -> void:
	_camera_rig = CAMERA_RIG.new()
	_camera_rig.name = "CameraPivot"
	add_child(_camera_rig)
	_camera_rig.top_level = true
	_camera_rig.max_origin_distance = NetConfig.MAX_CAMERA_ORIGIN_DISTANCE - 0.2
	_camera_pivot = _camera_rig
	_spring_arm = _camera_rig.spring_arm
	_camera = _camera_rig.camera
	_spring_arm.collision_mask = NetConfig.layer_mask(NetConfig.ENVIRONMENT_LAYER_BIT)
	_spring_arm.add_excluded_object(get_rid())
	_camera_rig.configure(_camera_profile(), STANCE_PIVOT_Y[_stance], 0.0, 0.0, true)


func _camera_profile() -> DGDCameraProfile:
	return camera_settings.for_view(_view == View.FIRST_PERSON, _aiming)


func _update_camera(delta: float) -> void:
	if not _camera_rig:
		return
	_camera_rig.configure(_camera_profile(), STANCE_PIVOT_Y[_stance], delta,
		Vector2(velocity.x, velocity.z).length(), absf(velocity.y) < 0.05, _hp > 0)
	var firing := get_firing_settings()
	_firearm_motion.advance(delta,firing)
	_camera.rotation += _firearm_motion.camera_angles
	_update_view_transform()


func _update_view_transform() -> void:
	if not _camera_rig:
		return
	var fraction := Engine.get_physics_interpolation_fraction()
	var advance := _camera_advance_velocity * (fraction / Engine.physics_ticks_per_second)
	_camera_rig.set_pose(_view_body_position + _view_correction + advance, _look_yaw, _look_pitch)


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
	_sync_presentation()
	if _has_input_authority():
		_view_correction *= exp(-delta / NetConfig.OWNER_CORRECTION_DECAY_SEC)
		_update_camera(delta)
		if Fusion.is_in_room():
			_update_automatic_fire(Input.is_action_pressed("fire"),Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	if _spine_modifier:
		_spine_modifier.pitch = 0.0 if _dead else (_look_pitch if _has_input_authority() else _pitch)


## Current hit shapes for HitboxHistory -- capsules {key, a, b, r} (a == b is a
## sphere), see HITBOX_BONES. Empty while dead, which is what makes a rewind
## into the dead window a miss without any extra "was alive then" bookkeeping.
func get_hitbox_shapes() -> Array:
	if _hp <= 0:
		return []
	var shapes: Array = []
	if NetConfig.HITBOX_MODE == "modular" and _skeleton:
		for bone_name: String in HITBOX_BONES:
			if not _hitbox_bone_indices.has(bone_name):
				continue
			var info: Dictionary = HITBOX_BONES[bone_name]
			var frame := get_hitbox_frame(info["key"])
			var end: Vector3 = frame.origin
			var end_name: String = info.get("end", "")
			if _hitbox_bone_indices.has(end_name):
				end = _skeleton.global_transform * _visual_bone_frame(_hitbox_bone_indices[end_name]).origin
			shapes.append({"key": info["key"], "a": frame.origin, "b": end, "r": info["radius"], "frame": frame})
		return shapes
	var xf := global_transform
	if _stance == Stance.PRONE:
		var fwd := -xf.basis.z
		var c := xf * PRONE_HITBOX_CENTER
		shapes.append({
			"key": "body", "r": PRONE_HITBOX_RADIUS, "frame": xf,
			"a": c - fwd * PRONE_HITBOX_HALF_LENGTH, "b": c + fwd * PRONE_HITBOX_HALF_LENGTH,
		})
		return shapes
	var cfg: Dictionary = STANCE_COLLISION[_stance]
	var half: float = maxf(cfg["height"] * 0.5 - cfg["radius"], 0.0)
	var c: Vector3 = xf.origin + Vector3.UP * float(cfg["center_y"])
	shapes.append({"key": "body", "r": cfg["radius"], "a": c - Vector3.UP * half, "b": c + Vector3.UP * half, "frame": xf})
	return shapes


func _visual_bone_frame(index: int) -> Transform3D:
	if _weapon_modifier and _weapon_modifier.final_frames.has(index):
		return _weapon_modifier.final_frames[index]
	return _skeleton.get_bone_global_pose(index)


func get_hitbox_frame(key: String) -> Transform3D:
	if key != "body" and _skeleton:
		for bone_name in HITBOX_BONES:
			if _hitbox_bone_indices.has(bone_name) and HITBOX_BONES[bone_name]["key"] == key:
				return _skeleton.global_transform * _visual_bone_frame(_hitbox_bone_indices[bone_name])
	return global_transform


func _build_replicator() -> void:
	# Must exist as a real node authored in player.tscn (root_path/owner_mode
	# set there too), NOT created here in code: FusionSpawner.spawn() scans the
	# freshly-instantiated scene for a FusionReplicator synchronously, before
	# _ready() ever runs, and crashes (native FATAL, empty replicator array) if
	# it isn't already present at that point.
	_replicator = get_node("FusionServerReplicator")
	_replicator.connect("on_process_input", _on_process_input)
	# Runtime-tunable replication knobs live in NetConfig so the lag-comp rewind
	# in MatchServer can use the same interpolation value; the .tscn keeps only
	# what must exist at spawn time (root_path/owner_mode/replication mode).
	# These are real registered properties (unlike input_authority), so set() works.
	_replicator.set("object_interpolation_time", NetConfig.PROXY_INTERPOLATION_SEC)
	_replicator.set("update_interval", NetConfig.REPLICATION_UPDATE_INTERVAL_TICKS)


## name -> [source scene, looping]. One entry per merged clip name used
## throughout this script (LOCOMOTION_CLIPS, ACTION_CLIPS, STANCE_TRANSITION,
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
	var table := _clip_table()
	for clip_name: String in table:
		var entry: Array = table[clip_name]
		_merge_clip_into(lib, entry[0], clip_name, entry[1])


func _merge_clip_into(target_lib: AnimationLibrary, scene: PackedScene, new_name: String, looping: bool) -> void:
	DGDWeaponAssets.merge_clip(target_lib, scene, new_name, looping)


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
	if not _has_input_authority() or not Fusion.is_in_room():
		return
	if event.is_action_pressed("toggle_inventory"):
		_toggle_inventory()
		return
	if event.is_action_released("fire"):
		_auto_trigger = false
	if event.is_action_pressed("ui_cancel"):
		_auto_trigger = false
		if _inventory_open:
			_toggle_inventory()
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_jump_pending = false
		return
	if _inventory_open:
		return  # ТЗ §4: открытый инвентарь блокирует стрельбу и камеру
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return  # The capture click is not a shot.
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		_look_yaw = wrapf(_look_yaw - event.screen_relative.x * MOUSE_SENSITIVITY, -PI, PI)
		_look_pitch = clampf(_look_pitch - event.screen_relative.y * MOUSE_SENSITIVITY, PITCH_MIN, PITCH_MAX)
		_update_view_transform()
	elif event.is_action_pressed("fire"):
		_auto_trigger = true
		_try_fire()
	elif event.is_action_pressed("reload"):
		_request_reload()
	elif event.is_action_pressed("jump"):
		_jump_pending = true
	elif event.is_action_pressed("toggle_view"):
		set_view(View.FIRST_PERSON if _view == View.THIRD_PERSON else View.THIRD_PERSON)
	elif event.is_action_pressed("switch_weapon"):
		_request_weapon_slot((_wanted_weapon + 1) % WeaponSlot.size())
	elif event.is_action_pressed("weapon_slot_1"):
		_request_weapon_slot(WeaponSlot.MAIN)
	elif event.is_action_pressed("weapon_slot_2"):
		_request_weapon_slot(WeaponSlot.SECONDARY)
	elif event.is_action_pressed("weapon_slot_3"):
		_request_weapon_slot(WeaponSlot.PISTOL)
	elif event.is_action_pressed("unequip"):
		_request_weapon_slot(WeaponSlot.UNARMED)
	elif event.is_action_pressed("crouch"):
		_request_stance(Stance.STAND if _wanted_stance == Stance.CROUCH else Stance.CROUCH)
	elif event.is_action_pressed("prone"):
		_request_stance(Stance.STAND if _wanted_stance == Stance.PRONE else Stance.PRONE)
	elif event.is_action_pressed("melee"):
		_request_melee()


## Owner-only local presentation state -- not replicated, not part of
## simulation (ТЗ §5 keeps inventory UI separate from the network transport).
## Releases/recaptures the mouse the same way ui_cancel / a capture-click
## already do elsewhere in this function.
func _toggle_inventory() -> void:
	_inventory_open = not _inventory_open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _inventory_open else Input.MOUSE_MODE_CAPTURED
	if _inventory_open:
		_auto_trigger = false
	inventory_visibility_changed.emit(_inventory_open)


func set_view(view: View) -> void:
	_view = view
	_emit_local_status()


func set_aiming(aiming: bool) -> void:
	if aiming == _aiming:
		return
	_aiming = aiming
	_emit_local_status()


# Stance and equipment travel with input, so replay uses the state of THAT
# tick. They also replicate in snapshots for observers and late joiners.
func _request_weapon_slot(slot: int) -> void:
	if _hp > 0 and slot >= 0 and slot < WeaponSlot.size():
		_wanted_weapon = slot
		# Switching away from whatever slot is mid-reload cancels the local
		# prediction of it (generalizes the old "leaving the rifle slot" rule
		# to all three weapon slots).
		if slot != _weapon_slot and _inventory: _inventory.cancel_prediction()


func _request_stance(new_stance: int) -> void:
	if _hp > 0 and new_stance >= 0 and new_stance < Stance.size():
		_wanted_stance = new_stance


func _can_take_stance(new_stance: int) -> bool:
	if new_stance == _stance:
		return true
	var cfg: Dictionary = STANCE_COLLISION[new_stance]
	if float(cfg["height"]) <= float(STANCE_COLLISION[_stance]["height"]):
		return true
	var shape := CapsuleShape3D.new()
	shape.radius = cfg["radius"]
	shape.height = maxf(cfg["height"], shape.radius * 2.0)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(global_basis, global_position + Vector3.UP * (float(cfg["center_y"]) + 0.02))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


## Visual only -- no melee hit detection/damage yet, see REVIEW_NOTES.md.
func _request_melee() -> void:
	if _dead or not DGDInventory.is_weapon_slot(_weapon_slot):
		return
	Fusion.rpc(rpc_play_melee)


@rpc("any_peer", "call_local")
func rpc_play_melee() -> void:
	if not _rpc_from_owner_alive() or not DGDInventory.is_weapon_slot(_weapon_slot):
		return
	_play_action("melee")


## Fail closed. The installed SDK supplies sender ids in live two-peer tests.
func _rpc_sender_is(expected_id: int) -> bool:
	return expected_id > 0 and Fusion.get_rpc_sender() == expected_id


## Guard for the owner-driven state RPCs (stance / weapon slot / melee): the
## sender must be this Player's owner, and a corpse can't change state -- the
## client-side _request_* wrappers check _dead too, but the RPC body is what
## a modified or desynced client actually reaches.
func _rpc_from_owner_alive() -> bool:
	return not _dead and _rpc_sender_is(get_player_id())


func _rpc_from_master() -> bool:
	var room = Fusion.get_room()
	var master_id: int = room.call("get_master_client_id") if room else -1
	return _rpc_sender_is(master_id)


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
## clip when no correct reverse animation exists (see _sync_presentation()).
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
		var armed_title := _weapon_modifier.profile.title if DGDInventory.is_weapon_slot(_weapon_slot) and _weapon_modifier and _weapon_modifier.profile and not _weapon_profile_id.is_empty() else ""
		MatchServer.local_status_changed.emit("%s [Q]   %s [V]%s%s   [Tab] Inv" % [
			armed_title if not armed_title.is_empty() else WEAPON_SLOT_NAMES[_weapon_slot],
			"1st person" if _view == View.FIRST_PERSON else "3rd person",
			"   AIM" if _aiming else "",
			STANCE_STATUS_SUFFIX.get(_stance, ""),
		])


func _physics_process(delta: float) -> void:
	if not Fusion.is_in_room():
		return
	_refresh_registration()
	_sync_presentation()
	if _has_input_authority():
		_last_input_motion = Vector3.ZERO
		if _camera:
			_camera.current = true
		if not _status_emitted:
			_status_emitted = true
			_emit_hp()
			_emit_local_status()
			MatchServer.local_player_ready.emit(self)
		var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		var move_input := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if captured else Vector2.ZERO
		if _automove:
			move_input = Vector2(0.0, -1.0)
		if _autoaim:
			_aim_at_nearest_player()
		if _autofire:
			_autofire_accum += delta
			if _autofire_accum >= 2.0:
				_autofire_accum = 0.0
				_try_fire()
		var flags := (INPUT_FLAG_FIRE if _fire_pending else 0) \
			| (INPUT_FLAG_SPRINT if captured and Input.is_action_pressed("sprint") else 0) \
			| (INPUT_FLAG_JUMP if _jump_pending else 0) \
			| (INPUT_FLAG_AIM if captured and Input.is_action_pressed("aim") else 0)
		_jump_pending = false
		_fire_pending = false
		if _hp <= 0:
			move_input = Vector2.ZERO
			flags = 0
		_replicator.call("queue_input", delta, _pack_input(move_input, _look_yaw, _look_pitch, flags))
		# This SDK executes the host's own input inside queue_input().
		if not Fusion.is_master_client():
			_replicator.call("process_input_queue", delta)
	else:
		if _camera and _camera.current:
			_camera.current = false
		if Fusion.is_master_client():
			_replicator.call("process_input_queue", delta)
	_sync_presentation()
	if _has_input_authority():
		_update_view_correction()
		_camera_advance_velocity = Vector3.ZERO if test_move(global_transform, velocity * delta) else velocity
	_update_animation(delta)
	_advance_visual_pose(delta)


func _update_view_correction() -> void:
	# Preserve normal tick movement exactly. Only the extra displacement caused
	# by a network correction is eased out on the camera; physics snaps now.
	var correction := global_position - _view_body_position - _last_input_motion
	if _view_snap_pending or correction.length() >= 2.5:
		_view_correction = Vector3.ZERO
		_view_snap_pending = false
	else:
		_view_correction -= correction
		# Never smooth through solid cover after the server pushes us out of it.
		if test_move(global_transform, _view_correction):
			_view_correction = Vector3.ZERO
	_view_body_position = global_position


func _refresh_registration() -> void:
	var id := get_player_id()
	if id > 0 and id != _registered_id:
		MatchServer.register_player(self)
		_registered_id = id


func _sync_presentation() -> void:
	if _weapon_modifier and _observed_weapon_profile != _weapon_profile_id:
		_apply_weapon_profile()
		_emit_local_status()
	var new_life := _life_id != _observed_life_id
	if new_life:
		_firearm_motion.reset()
		_local_heat = 0.0
		_local_next_fire_at = 0.0
		if _weapon_modifier: _weapon_modifier.shot_motion.reset()
		if _muzzle_effect: _muzzle_effect.reset()
		if _camera_rig:
			_camera_rig.reset()
		_observed_life_id = _life_id
		_view_snap_pending = true
		_view_body_position = global_position
		_view_correction = Vector3.ZERO
		_dead = false
		_death_bone = ""
		_leg_tuck_amount = 0.0
		_wanted_stance = _stance
		# local intent is reset only on a new life, never on prediction rollback
		_wanted_weapon = _weapon_slot
		_jump_pending = false
		_current_clip = ""
		_last_move_dir = ""
		if _hitbox_history:
			_hitbox_history.clear()
		if _anim_player:
			_anim_player.stop()
	if _observed_hp != _hp or _observed_injured_parts != _injured_parts:
		if not new_life and _observed_hp > _hp and _hp > 0 and _has_input_authority() and _camera_rig:
			_camera_rig.motion.hit(_camera_profile())
		_observed_hp = _hp
		_observed_injured_parts = _injured_parts
		_emit_hp()
		if _hp <= 0 and not _dead:
			_die("head" if _injured_parts & NetConfig.INJURY_BITS["head"] else _death_bone)
	if _observed_stance != _stance:
		var transition: Dictionary = STANCE_TRANSITION.get(_observed_stance * 10 + _stance, {}) if _observed_stance >= 0 else {}
		_observed_stance = _stance
		_apply_stance_collision()
		if not _dead and not transition.is_empty():
			if transition.get("reversed", false):
				_play_action_reversed(transition["clip"], transition.get("speed", 1.0))
			else:
				_play_action(transition["clip"], transition.get("speed", 1.0))
		_emit_local_status()
	if _observed_weapon != _weapon_slot:
		if _observed_weapon >= 0 and not _dead:
			_play_action("rifle_pull_out" if DGDInventory.is_weapon_slot(_weapon_slot) else "rifle_put_away")
		_observed_weapon = _weapon_slot
		_emit_local_status()

	if _observed_aim != _aiming:
		_observed_aim = _aiming
		_emit_local_status()

	if _inventory:
		_inventory.sync_view()
		_sync_reload_animation()


func get_firing_settings() -> DGDFirearmSettings:
	var p := weapon_library.find_profile(_weapon_profile_id)
	if not p: p = weapon_library.default_profile()
	if p.firing == null: p.firing = DGDFirearmSettings.new()
	return p.firing

func _update_automatic_fire(trigger_held: bool, captured: bool) -> void:
	if _auto_trigger and trigger_held and captured and not _inventory_open and get_firing_settings().fire_mode == 1:
		_try_fire()

func _try_fire() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not _camera or _hp <= 0 or _inventory_open or _wanted_weapon != _weapon_slot or not DGDInventory.is_weapon_slot(_weapon_slot) or now < _local_next_fire_at or _current_clip in ["reload","rifle_pull_out","rifle_put_away","melee"]:
		return
	if not _inventory or _inventory.is_reloading() or _inventory.predicted_magazine() <= 0: return
	var p := get_firing_settings()
	# Preserve cadence across frame rounding; skip backlog after a long stall.
	_local_next_fire_at = now+p.interval() if now-_local_next_fire_at>p.interval() else _local_next_fire_at+p.interval()
	_shot_sequence = maxi(_shot_sequence, _last_shot_sequence) + 1
	_fire_pending = true
	_update_view_transform()
	_play_fire_clip()
	_local_heat = DGDBallistics.cool(p,_local_heat,now-_local_heat_at)
	var angle := DGDBallistics.spread(p,_aiming,_stance,Vector2(velocity.x,velocity.z).length(),absf(velocity.y)>0.1,_local_heat)
	var seed_value := DGDBallistics.shot_seed(get_player_id(),_life_id,_shot_sequence)
	var rays := DGDBallistics.directions(-_camera.global_basis.z,angle,p.pellet_count(),seed_value)
	MatchServer.predict_shot(self, _shot_sequence, _life_id, _camera.global_position, -_camera.global_basis.z, get_muzzle_position(),rays,p.value("max_range"))
	_inventory.predict_shot(_shot_sequence)
	_send_fire_request()
	_local_heat = minf(p.value("bloom_max"),_local_heat+p.value("bloom_per_shot"))
	_local_heat_at = now
	play_shot_effects(_shot_sequence,_life_id,_weapon_profile_id,true)

func play_shot_effects(sequence: int, life: int, profile_id: String, local: bool = false) -> void:
	if life != _life_id or profile_id != _weapon_profile_id: return
	var p := get_firing_settings()
	var seed_value := DGDBallistics.shot_seed(get_player_id(),life,sequence)
	_weapon_modifier.shot_motion.fire(p,seed_value,_aiming)
	if _muzzle_effect: _muzzle_effect.fire(p)
	if local:
		var previous := _firearm_motion.camera_angles
		_firearm_motion.fire(p,seed_value,_aiming)
		# Capture the ray before recoil. The next shot uses the visibly recoiled aim.
		_camera.rotation += _firearm_motion.camera_angles-previous
		_camera_rig.motion.fire_custom(p.value("camera_shake")*_camera_profile().value("shot_amplitude"),p.value("shake_duration"))


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
	_look_yaw = atan2(-to.x, -to.z) + (asin(clampf(lateral / dist, -1.0, 1.0)) if dist > 0.01 else 0.0)
	_look_pitch = 0.0


func _update_animation(delta: float) -> void:
	if delta <= 0.0:
		return

	if _dead or not _anim_player:
		return  # the death clip owns the skeleton until respawn

	var horizontal := Vector2(velocity.x, velocity.z)
	var speed := horizontal.length()
	# Replicated vertical velocity also avoids packet-induced jump-pose flicker.
	var airborne := absf(velocity.y) > JUMP_TUCK_AIR_THRESHOLD
	_leg_tuck_amount = move_toward(_leg_tuck_amount, 1.0 if airborne else 0.0, JUMP_TUCK_BLEND_SPEED * delta)
	if _leg_tuck_modifier:
		_leg_tuck_modifier.tuck = _leg_tuck_amount

	if _inventory and _inventory.is_reloading():
		_sync_reload_animation()
		return

	if _current_clip in ACTION_CLIPS and _anim_player.is_playing():
		return  # let a one-shot action (fire/reload/melee/stance change...) finish

	# Tracked as a *direction key*, not a clip name: forward pace (walk/run/
	# sprint) is resolved separately from simulation speed in
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

	var still_moving := speed > 0.35
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
## simulated / replicated speed rather than differentiated snapshot positions.
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
	if delta_time <= 0.0 or not is_finite(delta_time):
		return
	_refresh_registration()
	var input := _unpack_input(payload)
	if input.is_empty() or input["life"] != _life_id:
		return  # Never replay a previous life's queued movement after teleport.
	_yaw = input["yaw"]
	_pitch = input["pitch"]
	rotation.y = _yaw
	var flags: int = input["flags"]
	if _hp > 0:
		if _can_take_stance(input["stance"]):
			_stance = input["stance"]
		var previous_weapon_slot := _weapon_slot
		_weapon_slot = input["weapon"]
		_aiming = flags & INPUT_FLAG_AIM != 0
		# Runs identically during owner prediction and master execution, same
		# as _stance/_weapon_slot themselves -- Fusion's replication of
		# _weapon_profile_id reconciles the two exactly like every other
		# predicted field here. Edge-triggered (not every tick) so a manually
		# forced profile (server_set_weapon_profile(), used by weapon addon
		# tests) isn't stomped while the slot itself hasn't changed.
		if _weapon_slot != previous_weapon_slot and _inventory:
			_weapon_profile_id = _inventory.weapon_profile_id_at(_weapon_slot) if DGDInventory.is_weapon_slot(_weapon_slot) else ""
	_apply_stance_collision()  # also restores collider size during rollback
	var before_move := global_position
	_apply_movement(Vector2.ZERO if _hp <= 0 else input["move"], delta_time,
		flags & INPUT_FLAG_SPRINT != 0,
		flags & INPUT_FLAG_JUMP != 0 and _hp > 0 and _stance == Stance.STAND)
	_last_input_motion = global_position - before_move
	if is_new and flags & INPUT_FLAG_FIRE != 0 and not _has_input_authority():
		_play_fire_clip()


## See INPUT_PACKET_SIZE for the layout.
func _pack_input(move: Vector2, yaw: float, pitch: float, flags: int) -> PackedByteArray:
	return PlayerInput.encode(move, yaw, pitch, flags, _wanted_stance, _wanted_weapon, _life_id)


func _unpack_input(buf: PackedByteArray) -> Dictionary:
	return PlayerInput.decode(buf)


func _apply_movement(move_input: Vector2, delta_time: float, sprinting: bool, jump_pressed: bool) -> void:
	var basis_fwd := -transform.basis.z
	var basis_right := transform.basis.x
	var dir := Vector3.ZERO
	if move_input.length() > 0.01:
		var limited := move_input.limit_length()
		dir = basis_right * limited.x + basis_fwd * -limited.y
	var speed := _current_move_speed(sprinting)
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	# Re-query the floor after rollback; CharacterBody floor flags are not network state.
	var grounded := velocity.y <= 0.0 and test_move(global_transform, Vector3.DOWN * 0.04)
	if grounded:
		velocity.y = JUMP_VELOCITY if jump_pressed else 0.0
	else:
		velocity.y -= GRAVITY * delta_time
	# move_and_slide uses the ENGINE delta, but Fusion may replay a different
	# input duration. Scale for the move, then restore velocity in metres/second.
	var scale_delta := delta_time / get_physics_process_delta_time()
	velocity *= scale_delta
	move_and_slide()
	velocity /= scale_delta


func _send_fire_request() -> void:
	if not _camera:
		return
	var origin := _camera.global_position
	var direction := -_camera.global_transform.basis.z
	# The RPC target must be a *networked* node (one carrying a replicator), so
	# it is routed through the shooter's own Player object. Addressing the
	# MatchServer autoload directly failed with "No FusionReplicator found for
	# object 'Node'" -- register_broadcast_receiver() alone is not enough.
	# The shooter's own RTT rides along so the master can rewind the target to
	# what THIS peer was actually looking at -- see MatchServer._rewind_for().
	Fusion.rpc_to(
		NetConfig.RPC_TARGET_MASTER, rpc_request_fire,
		_shot_sequence, _life_id, origin, direction, float(Fusion.get_rtt()), get_muzzle_position(), _weapon_profile_id
	)


## Client -> master. Identity comes from the RPC context and this network object.
@rpc("any_peer", "reliable")
func rpc_request_fire(sequence: int, life_id: int, origin: Vector3, direction: Vector3, shooter_rtt: float, muzzle: Vector3, profile_id: String = "") -> void:
	if not Fusion.is_master_client() or not _rpc_sender_is(get_player_id()):
		return
	if (not profile_id.is_empty() and profile_id != _weapon_profile_id) or life_id != _life_id:
		return
	if sequence <= _last_shot_sequence or sequence > 0x7fffffff or not origin.is_finite() or not muzzle.is_finite() or not direction.is_finite() or not is_finite(shooter_rtt):
		return
	var now := float(Fusion.get_network_time())
	if not _inventory.receive_shot(sequence, now): return
	if _hp <= 0 or not DGDInventory.is_weapon_slot(_weapon_slot): return
	var p := get_firing_settings()
	# Allow one batched arrival (at most 100 ms), retaining cadence debt.
	if now + minf(p.interval(),0.1) < _next_fire_at or direction.length_squared() < 0.9 or direction.length_squared() > 1.1:
		return
	var allowance := NetConfig.MAX_CAMERA_ORIGIN_DISTANCE + SPRINT_SPEED * clampf(shooter_rtt, 0.0, NetConfig.MAX_REWIND_SEC)
	if origin.distance_to(global_position) > allowance or muzzle.distance_to(global_position) > allowance:
		return
	_last_shot_sequence = sequence
	_next_fire_at = maxf(now,_next_fire_at) + p.interval()
	_shot_heat = DGDBallistics.cool(p,_shot_heat,now-_shot_heat_at)
	var angle := DGDBallistics.spread(p,_aiming,_stance,Vector2(velocity.x,velocity.z).length(),absf(velocity.y)>0.1,_shot_heat)
	var rays := DGDBallistics.directions(direction,angle,p.pellet_count(),DGDBallistics.shot_seed(get_player_id(),life_id,sequence))
	_shot_heat = minf(p.value("bloom_max"),_shot_heat+p.value("bloom_per_shot"))
	_shot_heat_at = now
	_inventory.consume_shot()
	MatchServer.queue_shot(self, origin, direction.normalized(), shooter_rtt, life_id, sequence, muzzle,rays,p,_weapon_profile_id)


@rpc("any_peer", "call_local", "reliable")
func rpc_report_volley(payload: PackedByteArray) -> void:
	if _rpc_from_master(): MatchServer.report_volley(get_player_id(),payload)


@rpc("any_peer", "call_local", "reliable")
func rpc_report_hit(shooter_id: int, target_id: int, hit_bone: String, hit_position: Vector3, hp_left: int, visuals: PackedByteArray) -> void:
	if _rpc_from_master():
		MatchServer.report_hit(shooter_id, target_id, hit_bone, hit_position, hp_left, visuals)


## Only the state authority may modify health and respawn. Snapshots carry
## these values to current peers AND late joiners, including a future master.
func server_apply_damage(damage: int, hitbox_key: String = "body") -> int:
	if not Fusion.is_master_client() or _hp <= 0 or damage <= 0:
		return _hp
	_injured_parts |= NetConfig.injury_bit(hitbox_key)
	# A head hit is lethal independently of the weapon damage or current HP.
	_hp = 0 if hitbox_key == "head" else maxi(0, _hp - damage)
	if _hp == 0:
		_inventory.reload_until = 0.0
		_respawn_at = float(Fusion.get_network_time()) + NetConfig.RESPAWN_DELAY_SEC
	return _hp


func broadcast_respawn(spawn_pos: Vector3) -> void:
	if not Fusion.is_master_client():
		return
	_life_id += 1
	_inventory.grant_starter_kit()
	# The active slot index may be unchanged from before death, but its
	# contents just got reset by the starter kit -- always recompute (ТЗ §5:
	# "на возрождении выдавать настраиваемый стартовый комплект").
	_weapon_profile_id = _inventory.weapon_profile_id_at(_weapon_slot) if DGDInventory.is_weapon_slot(_weapon_slot) else ""
	_shot_heat = 0.0
	_shot_heat_at = 0.0
	_hp = NetConfig.MAX_HP
	_injured_parts = 0
	_respawn_at = 0.0
	_stance = Stance.STAND
	velocity = Vector3.ZERO
	global_position = spawn_pos
	_apply_stance_collision()
	_hitbox_history.clear()
	_replicator.call("teleport")
	_sync_presentation()


# ---------------------------------------------------------------------------
# Health / death (mirrored on every peer from the master's hit report).
# ---------------------------------------------------------------------------

func apply_hit_result(hp_left: int, _position: Vector3, hit_bone: String = "") -> void:
	if hp_left <= 0:
		_death_bone = hit_bone
	elif _hp > 0:
		_play_hit_jerk()


func _die(hit_bone: String = "") -> void:
	_dead = true
	_firearm_motion.reset()
	if _weapon_modifier: _weapon_modifier.shot_motion.reset()
	# Deterministic per-peer pick so every peer renders the same clip from only
	# data already in the broadcast hit report (no extra RPC field needed):
	# DEATH_CLIP_BY_HITBOX for the killing hitbox, else alternate between the
	# generic clips by the target's own id.
	var clip: String = DEATH_CLIP_BY_HITBOX.get(
		hit_bone, DEATH_CLIPS_GENERIC[absi(get_player_id()) % DEATH_CLIPS_GENERIC.size()]
	)
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


func _emit_hp() -> void:
	hp_changed.emit(_hp)
	if MatchServer and _has_input_authority():
		MatchServer.local_hp_changed.emit(_hp)
		MatchServer.local_injuries_changed.emit(_injured_parts, _hp)


# ---------------------------------------------------------------------------
# Accessors used by net/match_server.gd
# ---------------------------------------------------------------------------

## Tracer start: the compensator tip in the imported weapon. Hand/torso are
## fallbacks for models without that part.
func get_muzzle_position() -> Vector3:
	return _muzzle.global_position if _muzzle else (_weapon_attachment.global_position if _weapon_attachment else global_position + Vector3(0, 1.4, 0))


func is_local_player() -> bool:
	return _has_input_authority()


func get_replicator() -> Node:
	return _replicator


func get_player_id() -> int:
	return _replicator.call("get_input_authority") if _replicator else -1


func get_hp() -> int:
	return _hp


func is_dead() -> bool:
	return _hp <= 0


func get_weapon_slot() -> int:
	return _weapon_slot


func get_hitbox_history() -> HitboxHistory:
	return _hitbox_history


func _request_reload() -> void:
	if not _has_input_authority() or not Fusion.is_in_room() or _hp <= 0 or not _inventory or _inventory_open: return
	if not DGDInventory.is_weapon_slot(_weapon_slot) or _wanted_weapon != _weapon_slot: return
	if _inventory.is_reloading() or _inventory.reserve_for_active() <= 0 or _inventory.predicted_magazine() >= int(get_firing_settings().value("magazine_size")): return
	if _current_clip in ["rifle_pull_out","rifle_put_away","melee"]: return
	var nonce := _inventory.predict_reload()
	_sync_reload_animation()
	Fusion.rpc_to(NetConfig.RPC_TARGET_MASTER, rpc_request_reload, nonce, _life_id, _weapon_profile_id)


@rpc("any_peer", "reliable")
func rpc_request_reload(nonce: int, life: int, profile: String) -> void:
	if not Fusion.is_master_client() or not _rpc_sender_is(get_player_id()): return
	if life != _life_id or profile != _weapon_profile_id or nonce <= 0 or nonce > 0x7fffffff: return
	_inventory.start_reload(float(Fusion.get_network_time()), nonce)
	# Duplicate requests report the existing deadline without restarting it.
	Fusion.rpc(Callable(self,"rpc_reload_result"), nonce, life, _inventory.reload_until)


@rpc("any_peer", "call_local", "reliable")
func rpc_reload_result(nonce: int, life: int, deadline: float) -> void:
	if not _rpc_from_master() or not _has_input_authority() or life != _life_id: return
	_inventory.reload_result(nonce,deadline)
	_sync_reload_animation()


func _sync_reload_animation() -> void:
	if not _anim_player: return
	if _inventory.is_reloading():
		if _current_clip != "reload" or not _reload_visual_active:
			var clip := _anim_player.get_animation("reload")
			if clip:
				var duration := get_firing_settings().value("reload_time")
				_play_action("reload",clip.length/duration)
				_anim_player.seek(clampf(1.0-(_inventory.reload_deadline()-float(Fusion.get_network_time()))/duration,0.0,1.0)*clip.length,true)
		_reload_visual_active = true
	elif _reload_visual_active:
		_reload_visual_active = false
		if _current_clip == "reload":
			_anim_player.stop()
			_current_clip = ""


func server_tick_ammo(now: float) -> void:
	if _inventory: _inventory.server_tick(now)


## Inventory move (drag & drop), UI-facing entry point (ТЗ §4/§5): the owner
## sends a request, the master is the only one who mutates the inventory, and
## the moved item only visibly relocates once slots_json replicates back --
## see net/player_inventory.gd's request_move()/server_move() docs.
func request_move_item(from: int, to: int) -> void:
	if not _has_input_authority() or not Fusion.is_in_room() or not _inventory: return
	var nonce := _inventory.request_move()
	Fusion.rpc_to(NetConfig.RPC_TARGET_MASTER, rpc_request_move, nonce, from, to)


@rpc("any_peer", "reliable")
func rpc_request_move(nonce: int, from: int, to: int) -> void:
	if not Fusion.is_master_client() or not _rpc_sender_is(get_player_id()): return
	if _inventory.server_move(nonce, from, to) and DGDInventory.is_weapon_slot(_weapon_slot):
		_weapon_profile_id = _inventory.weapon_profile_id_at(_weapon_slot)


func get_inventory() -> DGDPlayerInventory:
	return _inventory
