extends SceneTree
var failures:=0
func _initialize(): call_deferred("run")
func check(ok: bool,label: String):
	if not ok: failures+=1
	print("[FIREARM] ",label," ","PASS" if ok else "FAIL")
func run():
	var p:=DGDFirearmSettings.preset(3)
	check(p.pellet_count()==8 and p.fire_mode==0,"shotgun_preset")
	p.pellets=1000
	check(p.pellet_count()==32,"pellet_limit")
	p.rpm=INF
	check(is_finite(p.interval()) and p.interval()>0,"invalid_settings_bounded")
	p=DGDFirearmSettings.new()
	var seed_value:=DGDBallistics.shot_seed(2,3,4)
	var rays:=DGDBallistics.directions(Vector3.FORWARD,5,32,seed_value)
	check(rays==DGDBallistics.directions(Vector3.FORWARD,5,32,seed_value),"prediction_server_same_seed")
	check(rays!=DGDBallistics.directions(Vector3.FORWARD,5,32,seed_value+1),"different_shots")
	var bounded:=true
	for ray in rays: bounded=bounded and is_equal_approx(ray.length(),1) and ray.dot(Vector3.FORWARD)>=cos(deg_to_rad(5.001))
	check(bounded,"cone_angle_and_unit_directions")
	check(DGDBallistics.directions(Vector3.UP,0,1,1)[0].is_equal_approx(Vector3.UP),"vertical_zero_spread")
	check(DGDBallistics.spread(p,true,2,0,false,0)<DGDBallistics.spread(p,false,0,4.5,true,1),"stance_aim_movement_spread")
	check(DGDBallistics.cool(p,2,10)==0,"bloom_recovers")
	check(DGDBallistics.damage_at(p,5,"torso")>DGDBallistics.damage_at(p,100,"torso"),"damage_falloff")
	check(DGDBallistics.damage_at(p,5,"left_forearm")<DGDBallistics.damage_at(p,5,"torso"),"limb_multiplier")
	var m:=DGDFirearmMotion.new()
	p.recoil_down=0;p.recoil_up=3;p.recoil_left=0;p.recoil_right=0
	m.fire(p,55,false)
	check(m.camera_angles.x>0 and m.camera_angles.y==0 and m.kickback>0,"up_recoil_and_kickback")
	var a=m.camera_angles
	for i in 120: m.advance(1.0/60,p)
	check(m.camera_angles.length()<0.00001 and m.kickback<0.00001,"recoil_returns")
	m.reset();p.recoil_down=3;p.recoil_up=0;m.fire(p,55,false)
	check(m.camera_angles.x<0,"down_recoil")
	m.reset();p.recoil_down=0;p.recoil_left=3;m.fire(p,55,false)
	check(m.camera_angles.y>0,"left_recoil")
	m.reset();p.recoil_left=0;p.recoil_right=3;m.fire(p,55,false)
	check(m.camera_angles.y<0,"right_recoil")
	var hits:Array=[]
	for i in 32: hits.append({"target_id":2,"target_life":3,"hp_left":66,"hit_bone":"left_forearm","position":Vector3(i,1,2),"contact":Vector3(0,1,0),"normal":Vector3.UP})
	var payload:=ShotBatch.encode(5,2,Vector3.ONE,"aks74",hits)
	var decoded:=ShotBatch.decode(payload)
	check(decoded.hits.size()==32 and decoded.hits[31].position.x==31 and decoded.profile=="aks74","shotgun_packet_roundtrip")
	check(ShotBatch.decode(payload.slice(0,payload.size()-1)).is_empty(),"truncated_packet")
	payload.encode_float(8,NAN)
	check(ShotBatch.decode(payload).is_empty(),"nonfinite_packet")
	var scene:=Node3D.new();root.add_child(scene);current_scene=scene
	var effect:=DGDMuzzleEffect.new();scene.add_child(effect)
	p=DGDFirearmSettings.new();effect.fire(p)
	check(effect.flash.visible and effect.lamp.visible and effect.smoke[0].emitting,"flash_light_smoke")
	effect._process(1)
	check(not effect.flash.visible and not effect.lamp.visible,"flash_expires")
	effect.reset();p.flash_size=0;p.light_energy=0;p.smoke_opacity=0;effect.fire(p)
	check(not effect.flash.visible and not effect.lamp.visible and not effect.smoke[1].emitting,"effects_can_disable")
	var server=root.get_node("MatchServer")
	var seen: Array[int] = [0]
	server.hit_reported.connect(func(_s,_t,_b,_p): seen[0]+=1)
	for hit in hits: hit.target_id=-1; hit.hit_bone="world"
	payload=ShotBatch.encode(1,0,Vector3.ZERO,"aks74",hits)
	server.report_volley(99,payload)
	server.report_volley(99,payload)
	check(seen[0]==32,"all_pellets_once_duplicate_ignored")
	print("[FIREARM RESULT] failures=",failures)
	quit(0 if failures==0 else 1)
