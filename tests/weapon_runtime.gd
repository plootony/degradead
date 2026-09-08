extends SceneTree
var failures := 0
func _initialize(): call_deferred("run")
func check(ok: bool, name: String):
	if not ok: failures += 1
	print("[WEAPON] ", name, " ", "PASS" if ok else "FAIL")
func run():
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	scene._join_panel.hide()
	var p = load("res://player/player.tscn").instantiate()
	scene.add_child(p)
	p.set_process(false)
	p.set_physics_process(false)
	# Player no longer defaults to a weapon on its own (an empty
	# _weapon_profile_id is now a legitimate "unarmed" state, granted only via
	# Inventory -- see player.gd's _attach_weapon()) -- this test exercises the
	# addon's IK directly, so seed the profile the way an equipped inventory
	# slot would.
	p._weapon_profile_id = "aks74"
	p._apply_weapon_profile()
	p._current_clip = "idle"
	p._anim_player.play("idle")
	for i in 60:
		p._advance_visual_pose(1.0 / 60.0)
		await process_frame
	var m = p._weapon_modifier
	check(m.validation_error.is_empty(), "valid_bone_chains")
	check(m.final_frames.size() > 0, "post_ik_frames_captured")
	print("errors ",m.right_error," ",m.left_error)
	check(m.right_error < 0.01, "right_grip_reached")
	check(m.left_error < 0.04, "left_grip_reached")
	for side in ["right","left"]:
		var chain = m._right if side == "right" else m._left
		check(m.final_frames[chain[2]].basis.is_equal_approx(m.targets[side].basis),"wrist_rotation_"+side)
	var s = p._skeleton
	for key in ["left_arm", "left_forearm", "right_arm", "right_forearm"]:
		var bone = {"left_arm":"mixamorig_LeftArm", "left_forearm":"mixamorig_LeftForeArm", "right_arm":"mixamorig_RightArm", "right_forearm":"mixamorig_RightForeArm"}[key]
		check(p.get_hitbox_frame(key).is_equal_approx(s.global_transform * m.final_frames[s.find_bone(bone)]), "hitbox_"+key)
	var profile = m.profile
	var original = profile.duplicate(true)
	for state in 6:
		p._stance = state / 2
		p._aiming = state % 2 == 1
		p._current_clip = ["idle","aim_idle","crouch_idle","crouch_aim_idle","prone_idle","prone_idle"][state]
		p._anim_player.play(p._current_clip)
		p._anim_player.seek(0.2,true)
		for i in 60:
			p._advance_visual_pose(1.0/60.0)
			await process_frame
		check(m.right_error < 0.03 and m.left_error < 0.05,"pose_reach_%d right=%.4f left=%.4f" % [state,m.right_error,m.left_error])
		var mount: Transform3D = m.weapon_root.transform
		# Reevaluate the same paused base pose; the previous solved hand must not feed back.
		for i in 30:
			p._anim_player.seek(0.2,true)
			p._advance_visual_pose(1.0/60.0)
			await process_frame
		mount = m.weapon_root.transform
		for i in 30:
			p._anim_player.seek(0.2,true)
			p._advance_visual_pose(1.0/60.0)
			await process_frame
		check(m.weapon_root.position.distance_to(mount.origin) < 0.0001,"no_feedback_%d" % state)
	p._stance = 0
	p._aiming = false
	p._current_clip = "reload"
	p._anim_player.play("reload")
	for i in 60:
		p._advance_visual_pose(1.0/60.0)
		await process_frame
	check(m._weight < 0.001,"reload_releases_hands")
	# Player itself no longer toggles DGDWeaponModifier.equipped (the modular
	# inventory holsters an INACTIVE weapon slot on its own DGDWeaponMountVisual
	# instead, see player.gd's _update_weapon_mounts()) -- exercise the
	# addon's own holster capability directly.
	m.equipped = false
	for i in 5:
		p._advance_visual_pose(1.0/60.0)
		await process_frame
	check(not m.equipped and m.weapon_root.transform.is_equal_approx(m.final_frames[m._back] * profile.transform_at(profile.holster_position,profile.holster_rotation)),"holstered_on_back")
	m.equipped = true
	p._current_clip = "idle"
	p._anim_player.play("idle")
	for i in 60:
		p._advance_visual_pose(1.0/60.0)
		await process_frame
	check(m._weight > 0.999,"equip_restores_ik")
	var bone_lengths: Array[float] = []
	for chain in [m._right,m._left]:
		bone_lengths.append(m.final_frames[chain[0]].origin.distance_to(m.final_frames[chain[1]].origin))
		bone_lengths.append(m.final_frames[chain[1]].origin.distance_to(m.final_frames[chain[2]].origin))
	profile.left_position += Vector3(5,0,0)
	for i in 5:
		p._advance_visual_pose(1.0/60.0)
		await process_frame
	var n := 0
	for chain in [m._right,m._left]:
		for j in 2:
			var length: float = m.final_frames[chain[j]].origin.distance_to(m.final_frames[chain[j+1]].origin)
			check(is_equal_approx(length,bone_lengths[n]),"unreachable_preserves_bone_%d" % n)
			n += 1
	check(m.left_error > 1 and m.final_frames[m._left[2]].is_finite(),"unreachable_clamped_finite")
	profile.left_position = original.left_position
	profile.left_hand = "missing_bone"
	m.resolve_bones()
	check(not m.validation_error.is_empty(),"invalid_chain_reported")
	profile.left_hand = original.left_hand
	m.resolve_bones()
	for i in 60:
		p._advance_visual_pose(1.0/60.0)
		await process_frame
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(1.3, 1.7, -2.2)
	camera.look_at(Vector3(0, 1.15, 0))
	camera.current = true
	if "--visual" in OS.get_cmdline_user_args():
		await create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/dgd-weapon-runtime.png")
	print("[WEAPON RESULT] failures=",failures)
	quit(0 if failures == 0 else 1)
