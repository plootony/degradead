extends SceneTree
## Regression: render-position delivery/corrections cannot restart locomotion.
var failures := 0
func _initialize(): call_deferred("run")
func check(ok: bool, label: String):
	if not ok: failures += 1
	print("[ANIM UNIT] ", label, " ", "PASS" if ok else "FAIL")
func run():
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var player = load("res://player/player.tscn").instantiate()
	scene.add_child(player)
	player.set_process(false)
	player.set_physics_process(false)
	var dt := 1.0 / 60.0
	var arrivals := [0.0, 0.0, -0.225, 0.0, 0.06, -0.3]
	for phase in [
		[Vector3(0, 0, -4.5), "run_forward"],
		[Vector3(0, 0, -6.5), "sprint_forward"],
		[Vector3(0, 0, -2.0), "walk_forward"],
		[Vector3(-4.5, 0, 0), "strafe_left"],
		[Vector3(4.5, 0, 0), "strafe_right"],
		[Vector3(0, 0, 4.5), "walk_backward"],
		[Vector3.ZERO, "idle"],
	]:
		player.velocity = phase[0]
		var stable := true
		var playback_peak := 0.0
		for tick in 180:
			player.position.z += arrivals[tick % arrivals.size()]
			player.position.y = 0.08 if tick % 3 == 0 else 0.0
			player._update_animation(dt)
			player._anim_player.advance(dt)
			playback_peak = maxf(playback_peak, player._anim_player.current_animation_position)
			stable = stable and player._current_clip == phase[1]
		check(stable, "batched_positions_" + phase[1])
		check(is_zero_approx(player._leg_tuck_amount), "no_false_jump_" + phase[1])
		check(playback_peak > 0.1, "clip_advances_" + phase[1])
	player._stance = 1
	player.velocity = Vector3(0, 0, -3)
	player._update_animation(dt)
	check(player._current_clip == "crouch_walk_forward", "crouch_motion")
	player._stance = 2
	player.velocity = Vector3(0, 0, -1.1)
	player._update_animation(dt)
	check(player._current_clip == "prone_forward", "prone_motion")
	player._stance = 0
	player.velocity = Vector3(0, 4, -4.5)
	for tick in 12: player._update_animation(dt)
	check(player._leg_tuck_amount > 0.9, "jump_velocity_drives_pose")
	player.velocity = Vector3.ZERO
	player.position += Vector3(20, 10, -20)
	for tick in 12: player._update_animation(dt)
	check(is_zero_approx(player._leg_tuck_amount) and player._current_clip == "idle", "teleport_does_not_trigger_locomotion")
	player._play_action("fire")
	player.velocity = Vector3(0, 0, -4.5)
	player._update_animation(dt)
	check(player._current_clip == "fire", "one_shot_action_preserved")
	player._die("head")
	player._update_animation(dt)
	check(player._current_clip == "death_headshot", "death_preserved")
	print("[ANIM UNIT RESULT] failures=", failures)
	quit(0 if failures == 0 else 1)
