extends SceneTree
var elapsed := 0.0
var paired_at := -1.0
var seen := {}
var failures := 0
var reports := 0
func _initialize(): call_deferred("start")
func start():
	var catalog = load("res://addons/dgd_weapon/library.tres")
	var p = DGDFirearmSettings.preset(3)
	p.magazine_size=3; p.reserve_ammo=5; p.reload_time=1.4; p.rpm=300
	catalog.default_profile().firing=p
	var other = catalog.default_profile().duplicate(true)
	other.id="ammo_test_other"; other.firing.magazine_size=5; other.firing.reserve_ammo=999
	catalog.profiles.append(other)
	var scene=load("res://net/lobby.tscn").instantiate()
	root.add_child(scene);current_scene=scene
	root.get_node("MatchServer").hit_reported.connect(func(shooter,_target,_bone,_point):
		if shooter==2: reports+=1)
func once(key: String) -> bool:
	if seen.has(key): return false
	seen[key]=true
	return true
func check(ok: bool,key: String):
	if not ok: failures+=1
	print("[AMMO] ",key," ","PASS" if ok else "FAIL")
func fire(p):
	p._look_pitch=0.8 # Sky; no accidental headshot on the other test peer.
	p._try_fire()
func forged(p):
	p._shot_sequence+=1
	Fusion.rpc_to(-1,Callable(p,"rpc_request_fire"),p._shot_sequence,p._life_id,p._camera.global_position,-p._camera.global_basis.z,float(Fusion.get_rtt()),p.get_muzzle_position(),p._weapon_profile_id)
func _physics_process(delta):
	elapsed+=delta
	var server=root.get_node("MatchServer")
	var p=server.get_player(2)
	if Fusion.is_in_room() and p and (server.get_player(1) or paired_at >= 0):
		if paired_at<0: paired_at=elapsed
		var t:=elapsed-paired_at
		var own:=Fusion.get_local_player_id()==2
		var a=p._ammo
		if t>1 and once("initial"): check(a.magazine==3 and a.reserve==5,"initial_snapshot")
		for i in 3:
			if own and t>2+i*0.8 and once("shot%d"%i):
				fire(p)
				check(a.predicted_magazine()==2-i,"instant_ammo_%d"%i)
		if t>4.4 and once("empty"):
			check(a.magazine==0 and reports==24,"one_round_per_volley")
			if own:
				var before:int=p._shot_sequence
				fire(p);check(before==p._shot_sequence,"empty_blocks_prediction")
				forged(p)
		if own and t>5.2 and once("reload1"):
			p._request_reload();check(a.is_reloading() and p._current_clip=="reload","instant_reload")
		if t>5.7 and once("during"):
			check(a.is_reloading() and a.magazine==0 and a.reserve==5 and reports==24,"reload_snapshot_no_early_transfer")
			if own:
				forged(p)
				Fusion.rpc_to(-1,Callable(p,"rpc_request_reload"),a.reload_nonce,p._life_id,p._weapon_profile_id)
		if t>7.5 and once("complete1"): check(a.magazine==3 and a.reserve==2 and not a.is_reloading() and reports==24,"reload_and_rejected_shots")
		if own and t>8 and once("shot4"): fire(p)
		if own and t>8.8 and once("shot5"): fire(p)
		if own and t>9.6 and once("reload2"): p._request_reload()
		if t>11.5 and once("complete2"): check(a.magazine==3 and a.reserve==0,"partial_reload_conserves_ammo")
		if own and t>12 and once("shot6"): fire(p)
		if own and t>12.8 and once("no_stock"):
			p._request_reload(); check(not a.is_reloading(),"empty_reserve_blocks_reload")
		if t>13.5 and once("stock_check"): check(a.magazine==2 and a.reserve==0 and reports==48,"no_infinite_ammo")
		if Fusion.is_master_client() and t>13.8 and once("swap"):
			var original:String=p._weapon_profile_id
			p.server_set_weapon_profile("ammo_test_other")
			check(a.magazine==5 and a.reserve==0,"shared_caliber_reserve")
			a.consume_shot()
			p.server_set_weapon_profile(original)
			check(a.magazine==2 and a.reserve==0,"stored_original_magazine")
			p.server_set_weapon_profile("ammo_test_other")
			check(a.magazine==4 and a.reserve==0,"stored_second_magazine")
			p.server_set_weapon_profile(original)
		if t>14.8 and once("swap_snapshot"): check(a.magazine==2 and a.reserve==0,"swap_snapshot")
		if Fusion.is_master_client() and t>15 and once("reset"): p.broadcast_respawn(p.global_position)
		if own and t>16 and once("shot7"): fire(p)
		if own and t>17 and once("reload3"): p._request_reload()
		if Fusion.is_master_client() and t>17.6 and once("kill"):
			check(a.is_reloading(),"death_during_reload_setup")
			p.server_apply_damage(1,"head")
		if t>18.3 and once("dead"): check(p.get_hp()==0 and not a.is_reloading() and a.magazine==2 and a.reserve==5,"death_cancels_reload")
		if t>23 and once("respawn"): check(p.get_hp()==100 and a.magazine==3 and a.reserve==5 and not a.is_reloading(),"respawn_resets_ammo")
		if t>24:
			print("[AMMO RESULT] failures=",failures)
			Fusion.disconnect_from_photon();quit(0 if failures==0 else 1)
	if elapsed>38:
		print("[AMMO RESULT] timeout");Fusion.disconnect_from_photon();quit(1)
	return false
