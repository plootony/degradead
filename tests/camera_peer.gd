extends SceneTree
## Two Photon peers: real fire callback, damage snapshot and local-only impulses.
var elapsed := 0.0
var paired_at := -1.0
var shot := 0
var saw_damage := false
var saw_head := false
var saw_death := false
var saw_respawn := false
var saw_local_shake := false
var remote_unchanged := true
func _initialize(): call_deferred("start")
func start():
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	root.get_node("MatchServer").hit_reported.connect(func(shooter, target, bone, _point):
		if shooter == 2 and target == 1 and bone == "head": saw_head = true)
func _physics_process(delta):
	elapsed += delta
	var server = root.get_node("MatchServer")
	var victim = server.get_player(1)
	var shooter = server.get_player(2)
	if Fusion.is_in_room() and victim and shooter:
		if paired_at < 0: paired_at = elapsed
		var t := elapsed - paired_at
		var local_id: int = Fusion.get_local_player_id()
		if local_id == 2 and ((shot == 0 and t > 2.0) or (shot == 1 and t > 4.0)):
			shooter._camera.look_at(victim.get_hitbox_frame("torso" if shot == 0 else "head").origin)
			shooter._try_fire()
			shot += 1
			if shooter._camera_rig.motion._shot_strength > 0: saw_local_shake = true
		saw_damage = saw_damage or (victim.get_hp() > 0 and victim.get_hp() < 100)
		saw_death = saw_death or victim.get_hp() == 0
		saw_respawn = saw_respawn or (saw_death and victim._life_id > 0 and victim.get_hp() == 100)
		if local_id == 1:
			saw_local_shake = saw_local_shake or victim._camera_rig.motion._hit_strength > 0
			remote_unchanged = remote_unchanged and is_zero_approx(shooter._camera_rig.motion._shot_strength)
		else:
			remote_unchanged = remote_unchanged and is_zero_approx(victim._camera_rig.motion._hit_strength)
	if elapsed > 16:
		var passed := saw_damage and saw_head and saw_death and saw_respawn and saw_local_shake and remote_unchanged
		print("[CAMERA PEER] ", "PASS" if passed else "FAIL", " damage=", saw_damage, " head=", saw_head, " death=", saw_death, " respawn=", saw_respawn, " local_shake=", saw_local_shake, " remote_unchanged=", remote_unchanged)
		Fusion.disconnect_from_photon()
		quit(0 if passed else 1)
	return false
