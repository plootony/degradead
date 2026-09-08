extends SceneTree
var failures := 0
func _initialize(): call_deferred("run")
func check(ok: bool, label: String):
	if not ok: failures += 1
	print("[CAMERA] ", label, " ", "PASS" if ok else "FAIL")
func run():
	var settings = load("res://addons/dgd_camera/camera_settings.tres").duplicate(true)
	var motion_script = load("res://addons/dgd_camera/motion.gd")
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	scene._join_panel.hide()
	scene._hud.show()
	var player = load("res://player/player.tscn").instantiate()
	scene.add_child(player)
	player.set_process(false)
	player.set_physics_process(false)
	player.camera_settings = settings
	player._view_body_position = Vector3.ZERO
	player._camera.current = true
	player._anim_player.play("idle")
	check(settings.for_view(true, false) == settings.first_person and settings.for_view(true, true) == settings.first_person_aim and settings.for_view(false, false) == settings.third_person and settings.for_view(false, true) == settings.third_person_aim, "four_profiles")
	var other_height: float = settings.first_person_aim.height
	settings.first_person.height += 0.1
	check(settings.first_person_aim.height == other_height, "profiles_independent")
	settings.first_person.height -= 0.1
	var save_error := ResourceSaver.save(settings, "/tmp/dgd-camera-roundtrip.tres")
	var restored = ResourceLoader.load("/tmp/dgd-camera-roundtrip.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	check(save_error == OK and is_equal_approx(restored.third_person.distance, settings.third_person.distance) and is_equal_approx(restored.first_person.fov, settings.first_person.fov), "resource_roundtrip")
	var p = settings.first_person.duplicate()
	p.step_amplitude = 0.0
	p.shot_amplitude = 0.0
	p.hit_amplitude = 0.0
	var motion = motion_script.new()
	motion.fire(p)
	motion.hit(p)
	check(motion.sample(0.1, p, 6.5, true).is_zero_approx(), "zero_disables_all_shake")
	p.shot_amplitude = 2.0
	motion.fire(p)
	check(motion.sample(0.0, p, 0, true).length() > 0.01, "shot_impulse")
	for i in 120: motion.sample(1.0 / 60.0, p, 0, true)
	check(motion.sample(0, p, 0, true).is_zero_approx(), "shot_settles")
	p.hit_amplitude = 3.0
	motion.hit(p)
	check(motion.sample(0, p, 0, true).length() > 0.01, "hit_impulse")
	check(motion.sample(0.1, p, 0, true, false).is_zero_approx(), "death_clears_shake")
	p.step_amplitude = 1.0
	check(motion.sample(0.1, p, 4.5, true).length() > 0.001, "moving_steps")
	for i in 120: motion.sample(1.0 / 60.0, p, 0, false)
	check(motion.sample(0, p, 0, false).length() < 0.00001, "airborne_or_idle_stops_steps")
	for index in 4:
		player._view = 1 if index < 2 else 0
		player._aiming = index % 2 == 1
		player._camera_rig.reset()
		player._update_camera(0.0)
		player._look_yaw = 0.75
		player._look_pitch = -0.12
		player._update_view_transform()
		check(is_equal_approx(player._camera_pivot.global_rotation.y, 0.75), "instant_look_%d" % index)
		var profile = settings.profile_at(index)
		check(is_equal_approx(player._spring_arm.spring_length, profile.distance) and is_equal_approx(player._camera.fov, profile.fov), "profile_applied_%d" % index)
		player._camera_rig.motion.fire(profile)
		player._update_camera(0.016)
		check(is_equal_approx(player._look_yaw, 0.75) and is_equal_approx(player._look_pitch, -0.12), "shake_preserves_input_%d" % index)
		player._look_yaw = 0.0
		player._look_pitch = 0.0
		player._camera_rig.reset()
		player._update_camera(0)
		await physics_frame
		await physics_frame
		await process_frame
		check(player._camera.global_position.distance_to(Vector3(0, 1.6, 0)) < 4.0, "origin_within_network_limit_%d" % index)
		if "--visual" in OS.get_cmdline_user_args():
			await create_timer(0.3).timeout
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("/tmp/dgd-camera-view-%d.png" % index)
	var extreme = settings.third_person.duplicate()
	extreme.distance = 3.0
	extreme.height = 0.5
	extreme.forward_offset = 0.25
	extreme.shoulder = 0.75
	extreme.tilt = 20.0
	player._camera_rig.reset()
	player._camera_rig.configure(extreme, 1.6, 0, 0, true)
	player._camera_rig.set_pose(Vector3.ZERO, 0, deg_to_rad(80.0))
	await physics_frame
	await physics_frame
	await process_frame
	check(player._camera.global_position.distance_to(Vector3(0, 1.6, 0)) <= 3.81, "extreme_pose_stays_inside_origin_limit")
	player._stance = 1
	player._camera_rig.reset()
	player._update_camera(0)
	check(is_equal_approx(player._camera_rig.anchor_offset.y, 1.15), "height_follows_crouch")
	player._stance = 0
	player._view = 0
	player._aiming = false
	player._camera_rig.reset()
	player._update_camera(0)
	var wall := StaticBody3D.new()
	scene.add_child(wall)
	wall.position = Vector3(0, 1.6, 1.5)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3, 3, 0.3)
	col.shape = box
	wall.add_child(col)
	await physics_frame
	await physics_frame
	await process_frame
	check(player._camera.global_position.z < 1.4, "spring_arm_stops_at_wall")
	print("[CAMERA RESULT] failures=", failures)
	quit(0 if failures == 0 else 1)
