extends SceneTree
## Two real peers: client sends ONE aimed shot, both verify head/death/respawn.
var elapsed := 0.0
var paired_at := -1.0
var fired := false
var head_report := false
var death := false
var cleared := false
func _initialize(): call_deferred("start")
func start():
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	root.get_node("MatchServer").hit_reported.connect(func(shooter, target, bone, _point):
		if shooter == 2 and target == 1 and bone == "head": head_report = true)
func _physics_process(delta):
	elapsed += delta
	var server = root.get_node("MatchServer")
	var target = server.get_player(1)
	var shooter = server.get_player(2)
	if Fusion.is_in_room() and target and shooter:
		if paired_at < 0: paired_at = elapsed
		if elapsed - paired_at > 2.0 and Fusion.get_local_player_id() == 2 and not fired:
			fired = true
			shooter._camera.look_at(target.get_hitbox_frame("head").origin)
			shooter._shot_sequence += 1
			shooter._send_fire_request()
		if target.get_hp() == 0 and target._injured_parts == 1: death = true
		if death and target._life_id > 0 and target.get_hp() == 100 and target._injured_parts == 0: cleared = true
	if elapsed > 14:
		var passed := head_report and death and cleared
		print("[HEADSHOT] ", "PASS" if passed else "FAIL", " report=", head_report, " death=", death, " respawn=", cleared)
		Fusion.disconnect_from_photon()
		quit(0 if passed else 1)
	return false
