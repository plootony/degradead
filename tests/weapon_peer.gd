extends SceneTree
var elapsed := 0.0
var paired_at := -1.0
var changed := false
var synced := false
var history_final := false
var client_rejected := false
func _initialize(): call_deferred("start")
func start():
	var library = load("res://addons/dgd_weapon/library.tres")
	var variant = library.default_profile().duplicate(true)
	variant.id = "test_variant"
	variant.title = "Test variant"
	variant.mount_position += Vector3(0.01,0,0)
	library.profiles.append(variant)
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
func _physics_process(delta):
	elapsed += delta
	var server = root.get_node("MatchServer")
	var p = server.get_player(2)
	if Fusion.is_in_room() and server.get_player(1) and p:
		if paired_at < 0: paired_at = elapsed
		if not changed and elapsed - paired_at > 1:
			changed = true
			if Fusion.is_master_client():
				p.server_set_weapon_profile("test_variant")
			else:
				client_rejected = not p.server_set_weapon_profile("aks74")
		synced = synced or (p._weapon_profile_id == "test_variant" and p._weapon_modifier.profile.id == "test_variant")
		if Fusion.is_master_client() and p._hitbox_history._count > 0:
			var samples: Array = p._hitbox_history._at(p._hitbox_history._count-1).shapes
			var actual: Array = p.get_hitbox_shapes()
			history_final = samples.size()==actual.size()
			for i in samples.size(): history_final = history_final and samples[i].a.distance_to(actual[i].a) < 0.01
	if elapsed > 12:
		var passed := synced and (history_final if Fusion.get_local_player_id() == 1 else client_rejected)
		print("[WEAPON PEER] ","PASS" if passed else "FAIL"," synced=",synced," final_hitbox_history=",history_final," client_change_rejected=",client_rejected)
		Fusion.disconnect_from_photon()
		quit(0 if passed else 1)
	return false
