extends Node
class_name HitboxHistory
## Шаг 4b: per-player component that records a short history of each bone
## hitbox's world position so the server can "rewind" to the moment a shot was
## actually fired (lag compensation) instead of testing against current position.
##
## Attached as a child of player.tscn by player.gd; only the master/server peer
## actually needs (or fills) this buffer, since only it resolves shots.

var _hitbox_nodes: Dictionary = {}   # bone_key: String -> {node: Node3D, radius: float}
var _buffer: Array[Dictionary] = []  # {t: float(sec), bones: {bone_key: Vector3}}


func register_hitbox(bone_key: String, node3d: Node3D, radius: float) -> void:
	_hitbox_nodes[bone_key] = {"node": node3d, "radius": radius}


func _physics_process(_delta: float) -> void:
	if _hitbox_nodes.is_empty():
		return
	if not (Engine.has_singleton("Fusion") and Fusion.is_in_room() and Fusion.is_master_client()):
		return  # observers/non-authoritative peers don't need a history buffer

	var now := Time.get_ticks_msec() / 1000.0
	var snapshot := {}
	for key in _hitbox_nodes.keys():
		snapshot[key] = (_hitbox_nodes[key]["node"] as Node3D).global_position
	_buffer.append({"t": now, "bones": snapshot})

	var cutoff := now - NetConfig.HITBOX_HISTORY_SEC
	while _buffer.size() > 1 and _buffer[0]["t"] < cutoff:
		_buffer.pop_front()


## Returns the {bone_key: Vector3} snapshot closest to target_time (seconds,
## Time.get_ticks_msec()/1000.0 timebase), clamped to the buffer's range.
func sample_at(target_time: float) -> Dictionary:
	if _buffer.is_empty():
		return {}
	if target_time <= _buffer[0]["t"]:
		return _buffer[0]["bones"]
	if target_time >= _buffer[-1]["t"]:
		return _buffer[-1]["bones"]
	for i in range(_buffer.size() - 1, -1, -1):
		if _buffer[i]["t"] <= target_time:
			return _buffer[i]["bones"]
	return _buffer[0]["bones"]


func radius_of(bone_key: String) -> float:
	var entry: Dictionary = _hitbox_nodes.get(bone_key, {})
	return entry.get("radius", 0.25)
