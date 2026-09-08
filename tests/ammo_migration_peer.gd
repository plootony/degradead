extends SceneTree
var elapsed := 0.0
var started := -1.0
var joined := -1.0
var role := ""
var seen := {}
var failures := 0
func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role=arg.substr(7)
	call_deferred("start")
func start():
	var catalog=load("res://addons/dgd_weapon/library.tres")
	var p=DGDFirearmSettings.new()
	p.magazine_size=3;p.reserve_ammo=5;p.reload_time=10
	catalog.default_profile().firing=p
	var second=catalog.default_profile().duplicate(true)
	second.id="ammo_migration_second";catalog.profiles.append(second)
	var scene=load("res://net/lobby.tscn").instantiate()
	root.add_child(scene);current_scene=scene
func check(ok: bool,key: String):
	if seen.has(key): return
	seen[key]=true
	if not ok: failures+=1
	print("[AMMO] ",key," ","PASS" if ok else "FAIL")
func finish():
	print("[AMMO RESULT] failures=",failures)
	Fusion.disconnect_from_photon();quit(0 if failures==0 else 1)
func _physics_process(delta):
	elapsed+=delta
	var server=root.get_node("MatchServer")
	var p=server.get_player(2)
	if Fusion.is_in_room() and p:
		var a=p._ammo
		if role=="host" and started<0 and elapsed>5:
			started=elapsed
			var original:String=p._weapon_profile_id
			p.server_set_weapon_profile("ammo_migration_second")
			a.consume_shot()
			p.server_set_weapon_profile(original)
			a.consume_shot();a.consume_shot()
			check(a.start_reload(float(Fusion.get_network_time()),1),"migration_reload_started")
			print("[AMMO MIGRATION START]")
		if role=="host" and started>0 and server.get_player(3):
			if joined<0: joined=elapsed
			if elapsed-joined>1:
				check(a.is_reloading(),"host_leaves_during_reload");finish()
		if role!="host" and a.reload_until>0:
			check(a.magazine==1 and a.reserve==5 and a.is_reloading(),"late_join_reload" if role=="observer" else "client_reload")
		if role=="client" and Fusion.is_master_client() and seen.has("client_reload"):
			check(a.reload_until>0 and a.magazine==1,"migration_preserves_deadline")
			if not a.is_reloading() and a.magazine==3 and not seen.has("reload_completed"):
				check(a.reserve==3,"reload_completed")
				p.server_set_weapon_profile("ammo_migration_second")
				check(a.magazine==2 and a.reserve==3,"migration_preserves_archive")
				# Cancellation must retain both magazine and reserve.
				check(a.start_reload(float(Fusion.get_network_time()),2),"holster_reload_setup")
				p._request_weapon_slot(1)
				started=elapsed
			if seen.has("reload_completed") and elapsed-started>1:
				check(a.reload_until==0 and a.magazine==2 and a.reserve==3,"holster_cancels_reload")
				# Give the observer time to verify the migrated snapshot.
				if elapsed-started>3: finish()
		if role=="observer" and seen.has("late_join_reload") and p._weapon_profile_id=="ammo_migration_second" and p._weapon_slot==1 and a.reload_until==0:
			check(a.magazine==2 and a.reserve==3,"observer_after_migration");finish()
	if elapsed>35:
		print("[AMMO RESULT] timeout ",role," ",seen);Fusion.disconnect_from_photon();quit(1)
	return false
