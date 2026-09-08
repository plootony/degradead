extends Node
## Autoload (see [application]/autoload in project.godot). Same NodePath
## (/root/MatchServer) on every peer, which is what lets Fusion's RPC dispatch
## find "the same" receiver on each machine for a node that isn't itself a
## spawned/replicated scene object.
##
## Owns shot resolution for Шаг 4a (single collider, live raycast) and Шаг 4b
## (modular hitboxes, lag-compensated rewind) -- see NetConfig.HITBOX_MODE --
## plus the master-authoritative health / death / respawn bookkeeping.

signal hit_reported(shooter_id: int, target_id: int, hit_bone: String, position: Vector3)
## Emitted on every peer whenever the LOCAL player's hp changes (HUD hook).
signal local_hp_changed(hp: int)
## Local player's weapon / view / aim summary line for the HUD.
signal local_status_changed(text: String)

## Sentinel hit_bone value for a shot that stopped on level geometry.
const HIT_WORLD: String = "world"

var _players: Dictionary = {}  # player_id: int -> Player node
## Authoritative hp, master only. Other peers mirror it on the Player node
## from the broadcast hit report.
var _hp: Dictionary = {}       # player_id: int -> int
var _spawn_points: Array[Vector3] = []
var _next_spawn_index: int = 0


func _ready() -> void:
	if Engine.has_singleton("Fusion"):
		Fusion.register_broadcast_receiver(self)


## player is a Player node (player/player.gd), kept as a loose Node here on
## purpose: MatchServer is an autoload, loaded before the scene tree exists, and
## a static Player type-hint would force it to eagerly load player.gd, which in
## turn references the MatchServer global at its top level -- a load-order
## cycle that fails with "Identifier not found: MatchServer". Dynamic .call()
## dispatch sidesteps that entirely.
func register_player(player: Node) -> void:
	var id: int = player.call("get_player_id")
	# Player ids start at 1; 0 means input_authority hasn't been assigned yet
	# (registration is retried later from _on_process_input), and registering it
	# would leave a phantom "id=0" duplicate of a real player in the registry.
	if id <= 0:
		return
	# Drop any earlier entry for this same node registered under a stale id.
	for known_id in _players.keys():
		if _players[known_id] == player and known_id != id:
			_players.erase(known_id)
	_players[id] = player
	if not _hp.has(id):
		_hp[id] = NetConfig.MAX_HP


func unregister_player(player: Node) -> void:
	var id: int = player.call("get_player_id")
	if _players.get(id) == player:
		_players.erase(id)
		_hp.erase(id)


func get_player(player_id: int) -> Node:
	var p: Node = _players.get(player_id)
	return p if is_instance_valid(p) else null


func set_spawn_points(points: Array[Vector3]) -> void:
	_spawn_points = points


func next_spawn_point() -> Vector3:
	if _spawn_points.is_empty():
		return Vector3.ZERO
	var p: Vector3 = _spawn_points[_next_spawn_index % _spawn_points.size()]
	_next_spawn_index += 1
	return p


# ---------------------------------------------------------------------------
# Shot resolution (master only).
# ---------------------------------------------------------------------------

## Server-side hit resolution. Called from the shooter's Player node on the
## master peer -- the RPC itself has to be addressed to a networked node, so
## Player owns the RPC endpoints and delegates the logic here.
## Returns {target_id, hit_bone, position, hp_left}. hp_left is the target's
## remaining hp after this shot (-1 when nobody was hit).
func resolve_shot(shooter_id: int, origin: Vector3, direction: Vector3) -> Dictionary:
	var result: Dictionary
	if NetConfig.HITBOX_MODE == "modular":
		result = _resolve_shot_modular(shooter_id, origin, direction)
	else:
		result = _resolve_shot_single(shooter_id, origin, direction)

	result["hp_left"] = -1
	var target_id: int = result["target_id"]
	if target_id != -1:
		var hp: int = _hp.get(target_id, NetConfig.MAX_HP)
		hp = maxi(0, hp - NetConfig.damage_for(result["hit_bone"]))
		_hp[target_id] = hp
		result["hp_left"] = hp
		if hp == 0:
			_schedule_respawn(target_id)
	return result


func _schedule_respawn(player_id: int) -> void:
	await get_tree().create_timer(NetConfig.RESPAWN_DELAY_SEC).timeout
	var player := get_player(player_id)
	if not player or not (Engine.has_singleton("Fusion") and Fusion.is_master_client()):
		return
	_hp[player_id] = NetConfig.MAX_HP
	# Player owns the RPC endpoint (networked node); it broadcasts to all peers.
	player.call("broadcast_respawn", next_spawn_point())


## Broadcast receiver, executed on ALL peers (rpc_report_hit is call_local) --
## this is where both clients end up showing the identical result.
func report_hit(shooter_id: int, target_id: int, hit_bone: String, position: Vector3, hp_left: int) -> void:
	if target_id == -1:
		print("[shot] player %d missed (%s)" % [shooter_id, hit_bone if hit_bone != "" else "air"])
	else:
		print("[shot] player %d hit player %d (%s) at %s -> hp %d" % [shooter_id, target_id, hit_bone, position, hp_left])
	hit_reported.emit(shooter_id, target_id, hit_bone, position)

	var shooter := get_player(shooter_id)
	if shooter:
		shooter.call("show_tracer", position)
	if target_id != -1:
		_spawn_impact(position, Color(0.8, 0.05, 0.05), 24)
		var target := get_player(target_id)
		if target:
			target.call("apply_hit_result", hp_left, position, hit_bone)
	elif hit_bone == HIT_WORLD:
		_spawn_impact(position, Color(0.85, 0.8, 0.6), 12)


# ---------------------------------------------------------------------------
# Шаг 4a: single capsule, current position, live PhysicsServer raycast.
# Environment is included in the mask so walls block shots and misses land on
# geometry (impact effect) instead of vanishing.
# ---------------------------------------------------------------------------

func _resolve_shot_single(shooter_id: int, origin: Vector3, direction: Vector3) -> Dictionary:
	var dir := direction.normalized()
	var space_state := get_tree().root.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * NetConfig.MAX_SHOT_RANGE)
	query.collision_mask = NetConfig.hitbox_mask() | NetConfig.environment_mask()
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var shooter := get_player(shooter_id)
	if shooter:
		query.exclude = shooter.call("get_hitbox_rids")
	var hit := space_state.intersect_ray(query)

	if hit.is_empty():
		return {"target_id": -1, "hit_bone": "", "position": origin + dir * NetConfig.MAX_SHOT_RANGE}

	var collider: Object = hit["collider"]
	# get_meta(key, null) still errors on a missing key in 4.7 -- check first.
	if not collider.has_meta("player"):
		return {"target_id": -1, "hit_bone": HIT_WORLD, "position": hit["position"]}
	var hit_player: Node = collider.get_meta("player")
	var target_id: int = hit_player.call("get_player_id")
	if target_id == -1 or target_id == shooter_id or hit_player.call("is_dead"):
		return {"target_id": -1, "hit_bone": "", "position": hit["position"]}
	return {"target_id": target_id, "hit_bone": collider.get_meta("hitbox_key", "body"), "position": hit["position"]}


# ---------------------------------------------------------------------------
# Шаг 4b: modular hitboxes, rewound to the moment the shot was fired.
# ---------------------------------------------------------------------------

func _resolve_shot_modular(shooter_id: int, origin: Vector3, direction: Vector3) -> Dictionary:
	var dir := direction.normalized()
	# Rewind by the measured round-trip time (the shot logically happened about
	# one network hop ago on the shooter's screen). Clamped to the history size.
	# get_rtt() returns seconds (observed ~0.2 against the "us" region).
	var rewind: float = 0.0
	if Engine.has_singleton("Fusion"):
		rewind = float(Fusion.get_rtt())
	rewind = clampf(rewind, 0.0, NetConfig.HITBOX_HISTORY_SEC)
	var target_time := (Time.get_ticks_msec() / 1000.0) - rewind

	# Level geometry occludes: nothing further than the first wall counts.
	var best := {
		"target_id": -1, "hit_bone": "",
		"position": origin + dir * NetConfig.MAX_SHOT_RANGE, "dist": NetConfig.MAX_SHOT_RANGE,
	}
	var space_state := get_tree().root.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * NetConfig.MAX_SHOT_RANGE)
	query.collision_mask = NetConfig.environment_mask()
	query.collide_with_areas = false
	var wall := space_state.intersect_ray(query)
	if not wall.is_empty():
		best = {
			"target_id": -1, "hit_bone": HIT_WORLD,
			"position": wall["position"], "dist": origin.distance_to(wall["position"]),
		}

	for pid in _players.keys():
		if pid == shooter_id:
			continue
		var player: Node = _players[pid]
		if not is_instance_valid(player) or player.call("is_dead"):
			continue
		var history: HitboxHistory = player.call("get_hitbox_history")
		if not history:
			continue
		var bones: Dictionary = history.sample_at(target_time)
		for bone_key in bones.keys():
			var center: Vector3 = bones[bone_key]
			var radius: float = history.radius_of(bone_key)
			var dist := _ray_sphere_hit_distance(origin, dir, center, radius)
			if dist >= 0.0 and dist < best["dist"]:
				best = {
					"target_id": pid, "hit_bone": bone_key,
					"position": origin + dir * dist, "dist": dist,
				}
	best.erase("dist")
	return best


## Closest positive intersection distance of ray(origin, dir) with a sphere, or
## -1.0 if it misses. Simplification: each bone hitbox is treated as a sphere
## rather than a capsule -- adequate for a viability test, not final geometry.
func _ray_sphere_hit_distance(origin: Vector3, dir: Vector3, center: Vector3, radius: float) -> float:
	var oc := origin - center
	var b := oc.dot(dir)
	var c := oc.dot(oc) - radius * radius
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	var sq := sqrt(disc)
	var t := -b - sq
	if t < 0.0:
		t = -b + sq
	return t if t >= 0.0 else -1.0


# ---------------------------------------------------------------------------
# Visual feedback (runs on every peer from report_hit).
# ---------------------------------------------------------------------------

func _spawn_impact(position: Vector3, color: Color, amount: int) -> void:
	var root := get_tree().current_scene
	if not root:
		return
	var particles := CPUParticles3D.new()
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.amount = amount
	particles.lifetime = 0.45
	particles.direction = Vector3.UP
	particles.spread = 180.0
	particles.initial_velocity_min = 2.0
	particles.initial_velocity_max = 4.5
	particles.gravity = Vector3(0, -9.8, 0)
	particles.scale_amount_min = 0.5
	particles.scale_amount_max = 1.0
	var mesh := SphereMesh.new()
	mesh.radius = 0.03
	mesh.height = 0.06
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	particles.mesh = mesh
	root.add_child(particles)
	particles.global_position = position
	particles.emitting = true
	get_tree().create_timer(particles.lifetime + 0.2).timeout.connect(particles.queue_free)


# ---------------------------------------------------------------------------
# Headless test hook (`-- --posdump`): periodically log every known player's
# position as seen by THIS peer, so a two-instance run can be checked for
# movement replication without a human at the keyboard.
# ---------------------------------------------------------------------------

var _posdump: bool = "--posdump" in OS.get_cmdline_user_args()
var _posdump_accum: float = 0.0


func _process(delta: float) -> void:
	if not _posdump:
		return
	_posdump_accum += delta
	if _posdump_accum < 1.0:
		return
	_posdump_accum = 0.0
	if not (Engine.has_singleton("Fusion") and Fusion.is_in_room()):
		return
	var parts: Array[String] = []
	for pid in _players.keys():
		var p: Node = _players[pid]
		if is_instance_valid(p):
			parts.append("id=%s pos=%.2f,%.2f,%.2f hp=%s" % [
				pid, p.global_position.x, p.global_position.y, p.global_position.z, p.call("get_hp")
			])
	print("[POS local_id=%d master=%s] %s" % [
		Fusion.get_local_player_id(), Fusion.is_master_client(), "; ".join(parts)
	])
