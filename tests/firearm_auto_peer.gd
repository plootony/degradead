extends SceneTree
var elapsed:=0.0
var paired_at:=-1.0
var started:=false
var released:=false
var reports:=0
var emitted:=0
var after_release:=-1
func _initialize(): call_deferred("start")
func start():
	var library=load("res://addons/dgd_weapon/library.tres")
	library.default_profile().firing=DGDFirearmSettings.new()
	var scene=load("res://net/lobby.tscn").instantiate()
	root.add_child(scene);current_scene=scene
	root.get_node("MatchServer").hit_reported.connect(func(shooter,_target,_bone,_position):
		if shooter==2: reports+=1)
func _physics_process(delta):
	elapsed+=delta
	var server=root.get_node("MatchServer")
	var p=server.get_player(2)
	if Fusion.is_in_room() and server.get_player(1) and p:
		if paired_at<0: paired_at=elapsed
		var t:=elapsed-paired_at
		if Fusion.get_local_player_id()==2:
			if not started and t>2:
				started=true
				# Headless DisplayServer cannot capture a mouse. Drive the same
				# trigger controller with explicit held/captured state instead.
				p._auto_trigger=true
				p._try_fire()
			if started and not released: p._update_automatic_fire(true,true)
			if not released and t>3:
				released=true
				p._auto_trigger=false
				emitted=p._muzzle_effect.fired_count
			if released:
				p._auto_trigger=true
				p._update_automatic_fire(true,false)
				p._auto_trigger=false
		if t>4 and after_release<0: after_release=reports
	if (paired_at>=0 and elapsed-paired_at>7) or elapsed>35:
		var good:=reports>=7 and reports<=11 and after_release==reports and (Fusion.get_local_player_id()!=2 or (emitted==reports))
		print("[AUTO PEER] ","PASS" if good else "FAIL"," confirmed=",reports," local_effects=",emitted," after_release=",after_release)
		Fusion.disconnect_from_photon();quit(0 if good else 1)
	return false
