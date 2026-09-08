@tool
extends "res://addons/dgd_weapon/preview.gd"
var effects: DGDMuzzleEffect
var recoil := DGDFirearmMotion.new()
var camera_shake := preload("res://addons/dgd_camera/motion.gd").new()
var shake_profile := preload("res://addons/dgd_camera/profile.gd").new()
var shake_enabled := true
func _ready() -> void:
	super._ready()
	shake_profile.step_amplitude=0
	effects=preload("res://addons/dgd_firearm/muzzle_effect.gd").new()
	modifier.muzzle.add_child(effects)
func set_profile(value: DGDWeaponProfile) -> void:
	super.set_profile(value)
	recoil.reset()
	camera_shake.reset()
	if effects: effects.reset()
func fire(seed_value: int, aiming: bool) -> void:
	var p := profile.firing
	modifier.shot_motion.fire(p,seed_value,aiming)
	recoil.fire(p,seed_value,aiming)
	camera_shake.fire_custom(p.value("camera_shake")*0.3,p.value("shake_duration"))
	effects.fire(p)
func _process(delta: float) -> void:
	super._process(delta)
	if not is_visible_in_tree() or not profile or not camera: return
	for marker in _markers: marker.visible=false
	recoil.advance(delta,profile.firing)
	var shake := camera_shake.sample(delta,shake_profile,0,false)
	if shake_enabled: camera.basis *= Basis.from_euler(recoil.camera_angles+shake)
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT: return
	super._gui_input(event)
