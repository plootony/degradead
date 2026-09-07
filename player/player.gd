extends CharacterBody3D
class_name Player
## Player avatar: WASD movement + mouse look (Шаг 2), Idle/Run/Fire animation (Шаг 3),
## Fusion client-server prediction + hitscan shooting (Шаг 4a/4b).
##
## The scene file (player.tscn) is intentionally a bare shell (this script + a
## CollisionShape3D). Everything that depends on the Mixamo import's internal node
## layout -- which we can't hand-author blind without opening the Godot editor --
## is built at runtime in _ready() by searching the instanced model for a
## Skeleton3D/AnimationPlayer by type, instead of hardcoding a guessed NodePath.

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
var _hitbox_history: HitboxHistory
var _idle_clip_name: String = ""
var _idle_is_static_pose: bool = false
var _current_clip: String = ""

## Headless-test hook only (see `--automove` in _physics_process).
var _automove: bool = "--automove" in OS.get_cmdline_user_args()
var _autofire: bool = "--autofire" in OS.get_cmdline_user_args()
var _autofire_accum: float = 0.0

var _yaw: float = 0.0
var _pitch: float = 0.0
var _prev_global_position: Vector3


func _ready() -> void:
	_prev_global_position = global_position
	_build_movement_collision()
	_build_model_and_skeleton()
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
	# Movement collider only needs to see the environment; kept off the dedicated
	# hitbox layer so it never interferes with shot raycasts.
	collision_layer = 1 << 1  # "player_body" (layer 2)
	collision_mask = 1 << 0   # "environment" (layer 1)


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
	_normalize_weapon_scale(weapon)
	attachment.add_child(weapon)


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

	var arm := SpringArm3D.new()
	arm.name = "SpringArm"
	arm.spring_length = 4.0
	arm.add_excluded_object(get_rid())
	_camera_pivot.add_child(arm)

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	arm.add_child(_camera)


func _build_single_hitbox() -> void:
	_hitbox_single = Area3D.new()
	_hitbox_single.name = "Hitbox"
	_hitbox_single.collision_layer = NetConfig.hitbox_mask()
	_hitbox_single.collision_mask = 0
	_hitbox_single.monitorable = true
	_hitbox_single.monitoring = false
	_hitbox_single.set_meta("player", self)
	var shape := CapsuleShape3D.new()
	shape.height = body_capsule_height
	shape.radius = body_capsule_radius
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = body_capsule_center_y
	_hitbox_single.add_child(col)
	add_child(_hitbox_single)


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
		area.collision_layer = NetConfig.hitbox_mask()
		area.collision_mask = 0
		area.monitoring = false
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
	_merge_clip_into(lib, run_forward_clip, "run_forward")
	_merge_clip_into(lib, run_backward_clip, "run_backward")
	_merge_clip_into(lib, reload_clip, "reload")


func _merge_clip_into(target_lib: AnimationLibrary, scene: PackedScene, new_name: String) -> void:
	if target_lib.has_animation(new_name) or not scene:
		return
	var temp := scene.instantiate()
	var src_player := _find_child_of_type(temp, AnimationPlayer) as AnimationPlayer
	if src_player:
		for lib_name in src_player.get_animation_library_list():
			var src_lib := src_player.get_animation_library(lib_name)
			for anim_name in src_lib.get_animation_list():
				target_lib.add_animation(new_name, src_lib.get_animation(anim_name))
				break  # each Mixamo "without skin" export has exactly one clip
			if target_lib.has_animation(new_name):
				break
	temp.free()


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
		var fire_pressed := Input.is_action_just_pressed("fire")
		if _autofire:
			# Headless test hook (`-- --autofire`): pull the trigger on a timer
			# so the shot RPC -> server raycast -> broadcast path can be checked.
			_autofire_accum += delta
			if _autofire_accum >= 2.0:
				_autofire_accum = 0.0
				fire_pressed = true
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


func _update_animation(delta: float) -> void:
	if delta <= 0.0:
		return
	var apparent_velocity := (global_position - _prev_global_position) / delta
	_prev_global_position = global_position
	var horizontal := Vector2(apparent_velocity.x, apparent_velocity.z)
	var speed := horizontal.length()

	# Tracked as a *state*, not just a clip name: "idle" and "run_forward" can
	# share the same underlying clip (idle is that clip frozen on frame 0), so
	# comparing clip names alone would leave the character frozen while running.
	var state := "idle"
	if speed > 0.35:
		var forward := -transform.basis.z
		var moving_forward := Vector2(forward.x, forward.z).dot(horizontal) >= 0.0
		state = "run_forward" if moving_forward else "run_backward"

	if state == _current_clip or not _anim_player:
		return
	# Don't cut a fire/reload one-shot short while it is still playing.
	if _current_clip == "reload" and _anim_player.is_playing():
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
	_apply_movement(input.get("move", Vector2.ZERO), delta_time)

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
	var result: Dictionary = await MatchServer.resolve_shot(shooter_id, origin, direction)
	Fusion.rpc(rpc_report_hit, shooter_id, result["target_id"], result["hit_bone"], result["position"])


## RPC entry point, broadcast to every peer so both clients show the same result.
@rpc("any_peer", "call_local")
func rpc_report_hit(shooter_id: int, target_id: int, hit_bone: String, position: Vector3) -> void:
	MatchServer.report_hit(shooter_id, target_id, hit_bone, position)


# ---------------------------------------------------------------------------
# Accessors used by net/match_server.gd
# ---------------------------------------------------------------------------

func get_replicator() -> Node:
	return _replicator


func get_player_id() -> int:
	return _replicator.call("get_input_authority") if _replicator else -1


func get_hitbox_history() -> HitboxHistory:
	return _hitbox_history


func get_single_hitbox_node() -> Area3D:
	return _hitbox_single
