extends SceneTree
## Actual model + production HUD; --visual also saves a rendered game frame.
var failures := 0
func _initialize(): call_deferred("run")
func check(ok: bool, label: String):
	if not ok: failures += 1
	print("[INJURY] ", label, " ", "PASS" if ok else "FAIL")
func run():
	var reload_key := InputEventKey.new()
	reload_key.physical_keycode=KEY_R; reload_key.pressed=true; reload_key.device=0
	check(reload_key.is_action_pressed("reload"),"physical_r_reload_binding")
	var config = root.get_node("NetConfig")
	var server = root.get_node("MatchServer")
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	scene._join_panel.hide()
	scene._hud.show()
	var player = load("res://player/player.tscn").instantiate()
	scene.add_child(player)
	player.position = Vector3.ZERO
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(3, 2.1, 4)
	camera.look_at(Vector3(0, 0.95, 0))
	camera.current = true
	await physics_frame
	await process_frame
	var shapes: Array = player.get_hitbox_shapes()
	check(config.HITBOX_MODE == "modular" and shapes.size() == 11, "all_modular_segments_resolved")
	server._players[77] = player
	var keys := {}
	for shape in shapes:
		keys[shape.key] = true
		check(shape.frame.origin.is_equal_approx(shape.a), "frame_" + shape.key)
		if shape.key not in ["head", "pelvis"]:
			check(shape.a.distance_to(shape.b) > 0.05, "capsule_" + shape.key)
		var middle: Vector3 = (shape.a + shape.b) * 0.5
		var origin := middle + Vector3.BACK * 3
		var hit: Dictionary = server.trace_shot(-999, origin, Vector3.FORWARD, origin, -1.0)
		if shape.key in ["head", "left_shin", "right_shin"]:
			check(hit.target_id == 77 and hit.hit_bone == shape.key, "actual_ray_" + shape.key)
	check(keys.has("left_arm") and keys.has("right_arm") and keys.has("left_leg") and keys.has("right_leg"), "independent_limbs")
	check(config.injury_bit("left_forearm") == 4 and config.injury_bit("right_shin") == 32, "segments_map_to_correct_limb")
	check(config.damage_for("left_shin") == 25 and config.damage_for("right_forearm") == 20, "segment_damage_mapping")
	player.server_apply_damage(1, "head")
	check(player.get_hp() == 100 and player._injured_parts == 0, "non_authority_cannot_damage")
	var panel = scene._injury_panel
	server.local_injuries_changed.emit(4 | 32, 55)
	check(panel._parts.left_arm.modulate == panel.WOUNDED and panel._parts.right_leg.modulate == panel.WOUNDED, "hud_marks_correct_limbs")
	check(panel._parts.right_arm.modulate == panel.HEALTHY and panel._parts.left_leg.modulate == panel.HEALTHY, "hud_preserves_healthy_limbs")
	check(panel.mouse_filter == Control.MOUSE_FILTER_IGNORE, "hud_does_not_capture_input")
	server.local_injuries_changed.emit(1, 0)
	check(panel._parts.head.modulate == panel.WOUNDED, "hud_headshot_death")
	server.local_injuries_changed.emit(0, 100)
	check(panel._parts.head.modulate == panel.HEALTHY, "hud_respawn_reset")
	server.local_injuries_changed.emit(4 | 32, 55)
	scene._on_local_hp_changed(55)
	server.local_ammo_changed.emit({"magazine":7,"reserve":23,"type":"5.45×39","armed":true})
	check(scene._hp_label.text=="HP 55" and scene._combat_panel.ammo_label.text=="7 / 23","numeric_hp_and_ammo")
	server.local_ammo_changed.emit({"magazine":7,"reserve":23,"type":"5.45×39","armed":true,"reloading":true,"seconds":2})
	check(scene._combat_panel.detail_label.text.contains("Перезарядка"),"reload_hud")
	server.local_ammo_changed.emit({"magazine":7,"reserve":23,"type":"5.45×39","armed":true})
	await process_frame
	await process_frame
	check(scene._hud.get_global_rect().encloses(panel.get_global_rect()), "hud_within_viewport")
	var combat:Rect2=scene._combat_panel.get_global_rect()
	var viewport:Rect2=scene._hud.get_global_rect()
	check(viewport.encloses(combat) and absf(viewport.end.x-combat.end.x-20)<1 and absf(viewport.end.y-combat.end.y-20)<1,"combat_bottom_right")
	if "--visual" in OS.get_cmdline_user_args():
		await create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/dgd-injury-hud.png")
	print("[INJURY RESULT] failures=", failures)
	quit(0 if failures == 0 else 1)
