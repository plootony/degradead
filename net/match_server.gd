extends Node
## Autoload (see [application]/autoload in project.godot). Same NodePath
## (/root/MatchServer) on every peer, which is what lets Fusion's RPC dispatch
## find "the same" receiver on each machine for a node that isn't itself a
## spawned/replicated scene object.
##
## Owns shot resolution for Шаг 4a (single collider, live raycast) and Шаг 4b
## (modular hitboxes, lag-compensated rewind) -- see NetConfig.HITBOX_MODE.

signal hit_reported(shooter_id: int, target_id: int, hit_bone: String, position: Vector3)

var _players: Dictionary = {}  # player_id: int -> Player node


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


func unregister_player(player: Node) -> void:
	var id: int = player.call("get_player_id")
	if _players.get(id) == player:
		_players.erase(id)


## Server-side hit resolution. Called (and awaited) from the shooter's Player
## node on the master peer -- the RPC itself has to be addressed to a networked
## node, so Player owns the RPC endpoints and delegates the logic here.
func resolve_shot(shooter_id: int, origin: Vector3, direction: Vector3) -> Dictionary:
	# Обязательная искусственная задержка перед обработкой выстрела (Шаг 4a):
	# тест должен показывать поведение при реальной сети, а не на localhost.
	await get_tree().create_timer(NetConfig.ARTIFICIAL_DELAY_SEC).timeout

	if NetConfig.HITBOX_MODE == "modular":
		return _resolve_shot_modular(shooter_id, origin, direction)
	return _resolve_shot_single(shooter_id, origin, direction)


## RPC entry point, broadcast to ALL peers by request_fire() above -- this is
## where both clients end up showing the identical result (movement/DoD 2nd bullet).
func report_hit(shooter_id: int, target_id: int, hit_bone: String, position: Vector3) -> void:
	if target_id == -1:
		print("[shot] player %d missed" % shooter_id)
	else:
		print("[shot] player %d hit player %d (%s) at %s" % [shooter_id, target_id, hit_bone, position])
	hit_reported.emit(shooter_id, target_id, hit_bone, position)


# ---------------------------------------------------------------------------
# Шаг 4a: single capsule, current position, live PhysicsServer raycast.
# ---------------------------------------------------------------------------

func _resolve_shot_single(shooter_id: int, origin: Vector3, direction: Vector3) -> Dictionary:
	var dir := direction.normalized()
	var space_state := get_tree().root.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * NetConfig.MAX_SHOT_RANGE)
	query.collision_mask = NetConfig.hitbox_mask()
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := space_state.intersect_ray(query)

	if hit.is_empty():
		return {"target_id": -1, "hit_bone": "", "position": origin + dir * NetConfig.MAX_SHOT_RANGE}

	var collider: Object = hit["collider"]
	var hit_player: Node = collider.get_meta("player", null)
	var target_id: int = hit_player.call("get_player_id") if hit_player else -1
	if target_id == -1 or target_id == shooter_id:
		return {"target_id": -1, "hit_bone": "", "position": hit["position"]}
	return {"target_id": target_id, "hit_bone": "body", "position": hit["position"]}


# ---------------------------------------------------------------------------
# Шаг 4b: modular hitboxes, rewound to the moment the shot was fired.
# ---------------------------------------------------------------------------

func _resolve_shot_modular(shooter_id: int, origin: Vector3, direction: Vector3) -> Dictionary:
	var dir := direction.normalized()
	# The artificial delay IS the only "ping" in this local test, so it doubles as
	# the rewind window: the shot logically happened this long ago on the client.
	var target_time := (Time.get_ticks_msec() / 1000.0) - NetConfig.ARTIFICIAL_DELAY_SEC

	var best := {
		"target_id": -1, "hit_bone": "",
		"position": origin + dir * NetConfig.MAX_SHOT_RANGE, "dist": NetConfig.MAX_SHOT_RANGE,
	}
	for pid in _players.keys():
		if pid == shooter_id:
			continue
		var player: Node = _players[pid]
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
			parts.append("id=%s pos=%.2f,%.2f,%.2f" % [
				pid, p.global_position.x, p.global_position.y, p.global_position.z
			])
	print("[POS local_id=%d master=%s] %s" % [
		Fusion.get_local_player_id(), Fusion.is_master_client(), "; ".join(parts)
	])
