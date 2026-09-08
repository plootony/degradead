@tool
extends RefCounted
class_name DGDFirearmMotion
var camera_angles := Vector3.ZERO
var weapon_angles := Vector3.ZERO
var kickback := 0.0
var age := 10.0
var phase := 0.0
func reset() -> void:
	camera_angles=Vector3.ZERO; weapon_angles=Vector3.ZERO; kickback=0; age=10
func fire(p: DGDFirearmSettings, seed_value: int, aiming: bool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x4b135
	var scale := p.value("aim_recoil_multiplier") if aiming else 1.0
	camera_angles += Vector3(deg_to_rad(rng.randf_range(-p.value("recoil_down"),p.value("recoil_up"))),deg_to_rad(rng.randf_range(-p.value("recoil_right"),p.value("recoil_left"))),0)*scale
	camera_angles = camera_angles.clamp(Vector3(-0.5,-0.5,0),Vector3(0.5,0.5,0))
	weapon_angles += Vector3(p.value("weapon_lift"),rng.randf_range(-p.value("weapon_yaw"),p.value("weapon_yaw")),rng.randf_range(-p.value("weapon_roll"),p.value("weapon_roll")))*PI/180*scale
	weapon_angles = weapon_angles.clamp(Vector3(-0.5,-0.5,-0.5),Vector3(0.5,0.5,0.5))
	kickback = minf(0.2,kickback+p.value("weapon_kickback")*scale)
	age=0; phase=rng.randf()*TAU
func advance(delta: float, p: DGDFirearmSettings) -> void:
	delta=maxf(0,delta)
	camera_angles *= exp(-p.value("recoil_return")*delta)
	var decay := exp(-p.value("weapon_return")*delta)
	weapon_angles *= decay; kickback *= decay; age += delta
func weapon_transform(p: DGDFirearmSettings, muzzle_basis: Basis) -> Transform3D:
	var shake := deg_to_rad(p.value("weapon_shake"))*exp(-age*p.value("weapon_return"))
	var angles := weapon_angles + Vector3(sin(age*83+phase),sin(age*107+phase),cos(age*97+phase))*shake
	return Transform3D(muzzle_basis*Basis.from_euler(angles)*muzzle_basis.inverse(),muzzle_basis*Vector3(0,0,kickback))
