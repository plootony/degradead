@tool
extends Resource
class_name DGDCameraSettings
const PROFILE = preload("res://addons/dgd_camera/profile.gd")
const KEYS: Array[String] = ["first_person", "first_person_aim", "third_person", "third_person_aim"]
const TITLES: Array[String] = ["Первое лицо", "Первое лицо — прицел", "Третье лицо", "Третье лицо — прицел"]
@export var first_person: DGDCameraProfile
@export var first_person_aim: DGDCameraProfile
@export var third_person: DGDCameraProfile
@export var third_person_aim: DGDCameraProfile

func profile_at(index: int) -> DGDCameraProfile:
	index = clampi(index, 0, 3)
	if get(KEYS[index]) == null:
		set(KEYS[index], default_profile(index))
	return get(KEYS[index])

func for_view(first: bool, aiming: bool) -> DGDCameraProfile:
	return profile_at((0 if first else 2) + (1 if aiming else 0))

static func default_profile(index: int) -> DGDCameraProfile:
	var p := PROFILE.new()
	if index < 2:
		p.distance = 0.0
		p.height = 1.68
		p.shoulder = 0.0
		p.forward_offset = -0.12
		p.fov = 80.0 if index == 0 else 55.0
		p.step_amplitude = 0.35 if index == 0 else 0.08
		p.shot_amplitude = 0.65 if index == 0 else 0.4
		p.hit_amplitude = 1.4
	elif index == 3:
		p.distance = 1.3
		p.height = 1.7
		p.shoulder = 0.6
		p.fov = 50.0
		p.step_amplitude = 0.08
		p.shot_amplitude = 0.2
	return p
