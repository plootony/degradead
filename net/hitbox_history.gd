extends Node
class_name HitboxHistory
## Bounded tick history. Sampling interpolates positions between adjacent ticks;
## stance changes, death and teleport never blend into a fictional hitbox.
var _source: Node
var _buffer: Array[Dictionary] = []
var _head: int = 0
var _count: int = 0

func setup(source: Node) -> void:
	_source = source
	if source.has_signal("visual_pose_updated"):
		source.connect("visual_pose_updated", _record_pose)
	process_physics_priority = 10000
	_buffer.resize(ceili(NetConfig.HITBOX_HISTORY_SEC * Engine.physics_ticks_per_second) + 2)

func _physics_process(_delta: float) -> void:
	if is_instance_valid(_source) and _source.has_signal("visual_pose_updated"):
		return
	_record_pose()

func _record_pose() -> void:
	if not is_instance_valid(_source) or not Fusion.is_in_room() or not Fusion.is_master_client():
		return
	record(Time.get_ticks_msec() / 1000.0, _source.call("get_hitbox_shapes"))

func record(time: float, shapes: Array) -> void:
	if _buffer.is_empty():
		_buffer.resize(ceili(NetConfig.HITBOX_HISTORY_SEC * Engine.physics_ticks_per_second) + 2)
	_buffer[_head] = {"t": time, "shapes": shapes}
	_head = (_head + 1) % _buffer.size()
	_count = mini(_count + 1, _buffer.size())

func _at(index: int) -> Dictionary:
	return _buffer[(_head - _count + index + _buffer.size()) % _buffer.size()]

func sample_at(target_time: float) -> Array:
	if _count == 0 or target_time < float(_at(0)["t"]):
		return []  # No target existed in this history yet.
	var low := 0
	var high := _count - 1
	while low < high:
		var mid := (low + high + 1) / 2
		if float(_at(mid)["t"]) <= target_time:
			low = mid
		else:
			high = mid - 1
	var older := _at(low)
	if low == _count - 1:
		return older["shapes"]
	var newer := _at(low + 1)
	var before: Array = older["shapes"]
	var after: Array = newer["shapes"]
	if before.size() != after.size():
		return before
	var span := float(newer["t"]) - float(older["t"])
	var weight := clampf((target_time - float(older["t"])) / maxf(span, 0.000001), 0.0, 1.0)
	var result: Array = []
	for i in before.size():
		var a: Dictionary = before[i]
		var b: Dictionary = after[i]
		# A different radius/length means a stance transition, not locomotion.
		if a["key"] != b["key"] or not is_equal_approx(a["r"], b["r"]) or not is_equal_approx(a["a"].distance_to(a["b"]), b["a"].distance_to(b["b"])):
			return before
		var frame_a: Transform3D = a.get("frame", Transform3D.IDENTITY)
		var frame_b: Transform3D = b.get("frame", Transform3D.IDENTITY)
		result.append({"frame": frame_a.interpolate_with(frame_b, weight), "key": a["key"], "r": a["r"], "a": a["a"].lerp(b["a"], weight), "b": a["b"].lerp(b["b"], weight)})
	return result

func clear() -> void:
	_head = 0
	_count = 0
