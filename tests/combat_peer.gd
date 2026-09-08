extends SceneTree
## Start two instances in one unique room with --autojoin --autofire --autoaim.
var elapsed := 0.0
var saw_damage := false
var saw_death := false
var saw_respawn := false
func _initialize():
	call_deferred("start")
func start():
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
func _physics_process(delta):
	elapsed += delta
	for p in get_nodes_in_group("players"):
		saw_damage = saw_damage or p.get_hp() < 100
		saw_death = saw_death or p.get_hp() == 0
		saw_respawn = saw_respawn or p._life_id > 0
	if elapsed > 22:
		var passed := saw_damage and saw_death and saw_respawn
		print("[COMBAT] ", "PASS" if passed else "FAIL", " damage=", saw_damage, " death=", saw_death, " respawn=", saw_respawn)
		Fusion.disconnect_from_photon()
		quit(0 if passed else 1)
	return false
