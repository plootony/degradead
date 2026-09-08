extends SceneTree
var failures: int = 0
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var MatchScript = load("res://net/match_server.gd")
	var p = load("res://player/player.gd").new()
	p._life_id = 42
	p._wanted_stance = 1
	p._wanted_weapon = 1
	for yaw in [-PI, -0.1, 0.0, PI, TAU + 0.1]:
		var wire: PackedByteArray = p._pack_input(Vector2(-1.0, 0.5), yaw, 0.45, 14)
		var decoded: Dictionary = p._unpack_input(wire)
		check(wire.size() == 12, "Input size")
		check(absf(angle_difference(yaw, decoded.yaw)) < 0.0002, "Yaw round trip")
		check(absf(decoded.pitch - 0.45) < 0.0001, "Pitch round trip")
		check(decoded.life == 42 and decoded.stance == 1 and decoded.weapon == 1, "Input state round trip")
	check(p._unpack_input(PackedByteArray([1])).is_empty(), "Truncated input rejected")
	var bad: PackedByteArray = p._pack_input(Vector2.ZERO, 0, 0, 0)
	bad[7] = 255
	check(p._unpack_input(bad).is_empty(), "Invalid stance/slot rejected")
	p.free()
	var h = load("res://net/hitbox_history.gd").new()
	var shape := {"key": "body", "a": Vector3.ZERO, "b": Vector3.UP, "r": 0.35, "frame": Transform3D.IDENTITY}
	var moved := {"key": "body", "a": Vector3(2, 0, 0), "b": Vector3(2, 1, 0), "r": 0.35, "frame": Transform3D(Basis.IDENTITY, Vector3(2, 0, 0))}
	h.record(1.0, [shape])
	h.record(2.0, [moved])
	check(h.sample_at(0.5).is_empty(), "No hit before spawn")
	check(h.sample_at(1.5)[0].a.is_equal_approx(Vector3(1, 0, 0)), "Subtick hitbox interpolation")
	check(h.sample_at(1.5)[0].frame.origin.is_equal_approx(Vector3(1, 0, 0)), "Historical contact frame matches interpolated hitbox")
	h.record(3.0, [])
	check(h.sample_at(2.5).size() == 1 and h.sample_at(3.0).is_empty(), "Death boundary")
	h.clear()
	check(h.sample_at(2).is_empty(), "Teleport clears old history")
	for i in 100:
		h.record(float(i), [shape])
	check(h._count == h._buffer.size(), "History stays bounded")
	check(h.sample_at(0).is_empty() and h.sample_at(99).size() == 1, "History wraparound ordering")
	h.free()
	var hit: float = MatchScript._ray_capsule_hit_distance(Vector3(0, 0.5, -5), Vector3.FORWARD * -1, Vector3.ZERO, Vector3.UP, 0.5)
	check(is_equal_approx(hit, 4.5), "Capsule side intersection")
	check(MatchScript._ray_capsule_hit_distance(Vector3(3, 0.5, -5), Vector3.BACK, Vector3.ZERO, Vector3.UP, 0.5) < 0, "Capsule miss")
	check(is_equal_approx(MatchScript._ray_capsule_hit_distance(Vector3(0, 3, 0), Vector3.DOWN, Vector3.ZERO, Vector3.UP, 0.5), 1.5), "Capsule cap intersection")
	check(is_equal_approx(MatchScript._ray_capsule_hit_distance(Vector3(0, 0, -5), Vector3.BACK, Vector3.ZERO, Vector3.ZERO, 0.5), 4.5), "Degenerate capsule is a sphere")
	print("[UNIT] failures=", failures)
	quit(0 if failures == 0 else 1)
