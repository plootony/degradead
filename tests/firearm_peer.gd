extends SceneTree
var elapsed:=0.0
var paired_at:=-1.0
var shot:=false
var reports:=0
var damage_seen:=false
var effects_once:=false
var rapid_rejected:=false
var head_dead:=false
var second:=false
var local_immediate:=false
func _initialize(): call_deferred("start")
func start():
	var catalog=load("res://addons/dgd_weapon/library.tres")
	var p=DGDFirearmSettings.preset(3)
	p.damage=3;p.hip_spread=0.15;p.aim_spread=0.15;p.pellets=8
	catalog.default_profile().firing=p
	var scene=load("res://net/lobby.tscn").instantiate()
	root.add_child(scene);current_scene=scene
	root.get_node("MatchServer").hit_reported.connect(func(shooter,_target,_bone,_point):
		if shooter==2: reports+=1)
func _physics_process(delta):
	elapsed+=delta
	var server=root.get_node("MatchServer")
	var victim=server.get_player(1)
	var shooter=server.get_player(2)
	if Fusion.is_in_room() and victim and shooter:
		if paired_at<0: paired_at=elapsed
		var t:=elapsed-paired_at
		if Fusion.get_local_player_id()==2 and not shot and t>2:
			shot=true
			shooter._camera.look_at(victim.get_hitbox_frame("torso").origin)
			shooter._try_fire()
			local_immediate=shooter._muzzle_effect.fired_count==1 and shooter._firearm_motion.camera_angles.length()>0
			var sequence:int=shooter._shot_sequence
			shooter._try_fire()
			rapid_rejected=sequence==shooter._shot_sequence
		if t>3 and t<4:
			damage_seen=damage_seen or (victim.get_hp()<100 and victim.get_hp()>0)
			effects_once=shooter._muzzle_effect.fired_count==1 and reports==8
		if Fusion.get_local_player_id()==2 and not second and t>4.5:
			second=true
			shooter._camera.look_at(victim.get_hitbox_frame("head").origin)
			shooter._try_fire()
		head_dead=head_dead or victim.get_hp()==0
	if elapsed>14:
		var passed:=damage_seen and effects_once and head_dead and reports==16 and (Fusion.get_local_player_id()!=2 or (local_immediate and rapid_rejected))
		print("[FIREARM PEER] ","PASS" if passed else "FAIL"," reports=",reports," damage=",damage_seen," effects_once=",effects_once," head=",head_dead," immediate=",local_immediate," cooldown=",rapid_rejected)
		Fusion.disconnect_from_photon();quit(0 if passed else 1)
	return false
