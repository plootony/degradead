extends SceneTree
## Offline integration test; optional --visual saves a rendered verification frame.
class Target extends Node3D:
	var _life_id: int = 0
	func get_hitbox_frame(_key: String) -> Transform3D: return global_transform
	func apply_hit_result(_hp, _position, _bone): pass
	func get_hitbox_history(): return null
var failures := 0
var visual := "--visual" in OS.get_cmdline_user_args()
func check(value: bool, label: String):
	if not value: failures += 1
	print("[IMPACT] ", label, " ", "PASS" if value else "FAIL")
func _initialize(): call_deferred("run")
func box(parent, position: Vector3, size: Vector3, color: Color):
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material_override = material
	parent.add_child(mesh)
	mesh.position = position
	return mesh
func run():
	var local_id: int = Fusion.get_local_player_id()
	var codec = load("res://net/shot_visuals.gd")
	var server = root.get_node("MatchServer")
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(5, 4, 9)
	camera.look_at(Vector3(1.2, 0.8, 0))
	camera.current = true
	var light := DirectionalLight3D.new()
	scene.add_child(light)
	light.rotation_degrees = Vector3(-50, -30, 0)
	box(scene, Vector3(1, -0.1, 0), Vector3(12, 0.2, 10), Color(0.15, 0.17, 0.2))
	var target := Target.new()
	scene.add_child(target)
	target.position = Vector3(3, 0, 0)
	target.rotation.y = 0.5
	box(target, Vector3(0, 0.9, 0), Vector3(0.7, 1.8, 0.7), Color(0.2, 0.6, 0.35))
	box(scene, Vector3(0, 0.9, 0), Vector3(0.7, 1.8, 0.7), Color(0.2, 0.3, 0.55))
	server._players[2] = target
	var contact := Vector3(0, 1.15, 0.36)
	var muzzle := Vector3(-2, 1.3, 3)
	var payload: PackedByteArray = codec.encode(1, 0, 0, muzzle, contact, Vector3.BACK)
	var decoded: Dictionary = codec.decode(payload)
	check(payload.size() == 48 and decoded.contact.is_equal_approx(contact), "visual_packet_roundtrip")
	check(codec.decode(PackedByteArray([1])).is_empty(), "truncated_packet_rejected")
	server.report_hit(1, 2, "body", contact, 66, payload)
	var burst: CPUParticles3D = server._impact_pool[0]
	check(burst.global_position.is_equal_approx(target.global_transform * contact), "blood_matches_displayed_target")
	check(burst.direction.is_equal_approx(target.global_basis * Vector3.BACK), "blood_direction_follows_target")
	check(not burst.local_coords, "emitted_particles_remain_world_space")
	var count: int = server._impact_next
	server.report_hit(1, 2, "body", contact, 66, payload)
	check(server._impact_next == count, "duplicate_report_no_second_burst")
	target._life_id = 1
	server.report_hit(1, 2, "body", contact, 0, codec.encode(2, 0, 0, muzzle, contact, Vector3.BACK))
	check(server._impact_next == count, "old_life_has_no_blood_on_respawn")
	target._life_id = 0
	var first: MeshInstance3D = server.draw_tracer(muzzle, Vector3.ZERO)
	var key: String = codec.shot_key(local_id, 0, 1)
	first.set_meta("shot_key", key)
	server._predicted_tracers[key] = {"node": weakref(first), "expires": Time.get_ticks_msec()+2000}
	for i in server.VFX_POOL_SIZE:
		server.draw_tracer(Vector3(0, 4, 0), Vector3(1, 4, 0))
	var before: PackedVector3Array = first.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	server.report_hit(local_id, -1, "", Vector3(90, 0, 0), -1, codec.encode(1, 0, -1, muzzle, Vector3.ZERO, Vector3.UP))
	var after: PackedVector3Array = first.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(before == after, "late_ack_cannot_change_reused_tracer")
	var active: MeshInstance3D = server.draw_tracer(muzzle, Vector3.ZERO)
	var active_key: String = codec.shot_key(local_id, 0, 3)
	active.set_meta("shot_key", active_key)
	server._predicted_tracers[active_key] = {"node": weakref(active), "expires": Time.get_ticks_msec()+2000}
	var slots: int = server._tracer_next
	server.report_hit(local_id, -1, "", Vector3(1, 1, 0), -1, codec.encode(3, 0, -1, muzzle, Vector3.ZERO, Vector3.UP))
	var corrected: PackedVector3Array = active.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(corrected[1].is_equal_approx(Vector3(1, 1, 0)) and server._tracer_next == slots, "active_prediction_corrected_without_duplicate")
	server._predictions.append({"life": 0, "sequence": 4})
	server.report_hit(local_id, -1, "", Vector3(2, 1, 0), -1, codec.encode(4, 0, -1, muzzle, Vector3.ZERO, Vector3.UP))
	check(server._predictions[0].get("confirmed_end", Vector3.ZERO) == Vector3(2, 1, 0), "early_ack_updates_pending_prediction")
	server._predictions.clear()
	var wall := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2, 2, 0.2)
	col.shape = shape
	wall.add_child(col)
	scene.add_child(wall)
	wall.position = Vector3(0, 1, 0)
	await physics_frame
	await physics_frame
	var clipped: Dictionary = server.trace_shot(999, Vector3(0, 1, 5), Vector3.FORWARD, Vector3(0, 1, 5), -1)
	check(clipped.hit_bone == "world" and absf(clipped.position.z - 0.1) < 0.01, "prediction_stops_at_wall")
	# Fade old test lines, then display only the confirmed body hit.
	await create_timer(0.25).timeout
	server.report_hit(1, 2, "body", contact, 32, codec.encode(3, 0, 0, muzzle, contact, Vector3.BACK))
	if visual:
		await create_timer(0.075).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/dgd-impact-visual.png")
	print("[IMPACT RESULT] failures=", failures)
	quit(0 if failures == 0 else 1)
