extends SceneTree
## Live Photon regression peer. Run via run_network.py, not as the game's entry point.
var elapsed := 0.0
var stage_time := -1.0
var role := ""
var seen := {}
var failures := 0
var migration_sent := false
var damaged_after_respawn := false
var start_pos := Vector3.ZERO
var owner_started := -1.0
var max_queue := 0
var last_log := -1
var jump_sent := false
var apex := 0.0
var rtt_peak := 0.0
var prediction_resets := 0
var camera_error_peak := 0.0
func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			role = arg.substr(7)
	call_deferred("start")
func start():
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
func check_once(key: String, ok: bool):
	if seen.has(key):
		return
	seen[key] = true
	if not ok:
		failures += 1
	print("[CHECK] ", role, " ", key, " ", "PASS" if ok else "FAIL")
func player(id: int):
	for p in get_nodes_in_group("players"):
		if p.get_player_id() == id:
			return p
	return null
func _physics_process(delta):
	elapsed += delta
	if elapsed > 35:
		print("[RESULT] ", role, " failures=", failures, " checks=", seen.keys(), " max_queue=", max_queue, " rtt_peak_ms=", snappedf(rtt_peak * 1000.0, 0.1), " prediction_resets=", prediction_resets, " camera_correction_peak=", camera_error_peak)
		Fusion.disconnect_from_photon()
		quit(0 if failures == 0 and seen.size() >= 2 else 1)
		return false
	if not Fusion.is_in_room():
		return false
	rtt_peak = maxf(rtt_peak, float(Fusion.get_rtt()))
	var target = player(2)
	if not target:
		return false
	if stage_time < 0:
		stage_time = elapsed
	var t := elapsed - stage_time
	var local = player(Fusion.get_local_player_id())
	if local and role == "client":
		if owner_started < 0:
			owner_started = elapsed
			start_pos = local.position
			local.get_replicator().connect("state_reset", func(info):
				if info.call("get_reason") == 1:
					prediction_resets += 1)
		var own_t := elapsed - owner_started
		camera_error_peak = maxf(camera_error_peak, local._view_correction.length())
		local._automove = own_t < 2.0
		local._look_yaw = 0.0
		if own_t > 0.4 and not jump_sent:
			jump_sent = true
			local._jump_pending = true
		if own_t < 2.0:
			apex = maxf(apex, local.position.y - start_pos.y)
		if own_t > 0.07:
			check_once("local_prediction_before_rtt", local.position.distance_to(start_pos) > 0.05)
		if own_t > 2.0 and own_t < 2.2:
			check_once("bounded_camera_correction", camera_error_peak < 0.5)
			check_once("jump_replay_and_landing", apex > 0.8 and apex < 1.4 and absf(local.position.y - start_pos.y) < 0.05)
			check_once("movement_distance", absf(local.position.distance_to(start_pos) - 9.0) < 0.5)
		if own_t > 2.2 and local._life_id == 0:
			local._request_stance(1)
			local._request_weapon_slot(1)
		# Simulate many old input callbacks without changing fresh mouse intent.
		if own_t > 3 and not seen.has("look_survives_replay"):
			var host = player(1)
			if host:
				Fusion.rpc_to(-1, Callable(host, "rpc_request_fire"), 900, 0, Vector3(-4, 1.6, -4), Vector3.BACK, 0.1, Vector3(-4, 1.6, -4))
			Fusion.rpc_to(-1, Callable(local, "rpc_request_fire"), 901, 0, Vector3(INF, 0, 0), Vector3.BACK, 0.1, Vector3(-4, 1.6, -4))
			local._look_yaw = 0.75
			var old = local._pack_input(Vector2.ZERO, -0.5, -0.2, 0)
			local._on_process_input(1, 1.0 / 60.0, old, false)
			check_once("look_survives_replay", is_equal_approx(local._look_yaw, 0.75))
		if local._life_id > 0 and not seen.has("old_life_input_rejected"):
			var stale = local._pack_input(Vector2(1, 0), 0, 0, 4)
			stale.encode_u32(8, 0)
			var before: Vector3 = local.position
			local._on_process_input(1, 1.0 / 60.0, stale, false)
			check_once("old_life_input_rejected", local.position == before)
	if role == "host":
		if t > 4.0 and not seen.has("damage_before_migration"):
			target.server_apply_damage(68, "left_forearm")
			check_once("damage_before_migration", target.get_hp() == 32)
			check_once("limb_injury_recorded", target._injured_parts == 4)
		if t > 6.0:
			check_once("forged_shooter_rejected", player(1)._last_shot_sequence == 0)
			check_once("invalid_shot_rejected", target._last_shot_sequence == 0)
			check_once("stance_equipment_snapshot", target._stance == 1 and target._weapon_slot == 1)
		if t > 11.0 and not seen.has("kill_before_migration"):
			target.server_apply_damage(1, "head")
			check_once("kill_before_migration", target.get_hp() == 0)
			check_once("headshot_one_damage_is_lethal", target.get_hp() == 0 and target._injured_parts == 5)
		if t > 12.0 and not migration_sent:
			migration_sent = true
			Fusion.get_room().call("set_master_client", 2)
	if role == "observer" and t > 1.0 and t < 3.0:
		check_once("late_join_hp", target.get_hp() == 32)
		check_once("late_join_injury", target._injured_parts == 4)
		check_once("late_join_stance_equipment", target._stance == 1 and target._weapon_slot == 1)
	if role == "client" and Fusion.is_master_client():
		if target._life_id == 0:
			check_once("migrated_death_deadline", target.get_hp() == 0 and target._respawn_at > float(Fusion.get_network_time()))
			check_once("migrated_injuries", target._injured_parts == 5)
		elif not damaged_after_respawn:
			check_once("respawn_after_migration", target.get_hp() == 100 and target._stance == 0)
			check_once("respawn_clears_injuries", target._injured_parts == 0)
			target.server_apply_damage(34)
			damaged_after_respawn = true
			check_once("damage_after_migration", target.get_hp() == 66)
	if target._life_id > 0 and target.get_hp() == 66:
		check_once("final_health_converged", true)
		check_once("final_injuries_converged", target._injured_parts == 2)
	if Fusion.is_master_client():
		max_queue = maxi(max_queue, target.get_replicator().get_input_queue_count())
	if int(t) != last_log:
		last_log = int(t)
		print("[STATE] ", role, " t=", int(t), " id=", Fusion.get_local_player_id(), " master=", Fusion.is_master_client(), " hp=", target.get_hp(), " life=", target._life_id, " stance=", target._stance, " pos=", target.position)
	return false
