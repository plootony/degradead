@tool
extends RefCounted
class_name DGDCameraMotion
var _phase := 0.0
var _step_weight := 0.0
var _shot_age := 1.0
var _shot_duration := 0.14
var _shot_strength := 0.0
var _hit_age := 1.0
var _hit_duration := 0.28
var _hit_strength := 0.0
var _hit_side := 1.0

func reset() -> void:
	_phase = 0.0
	_step_weight = 0.0
	_shot_strength = 0.0
	_hit_strength = 0.0

func fire(profile: DGDCameraProfile) -> void:
	_shot_age = 0.0
	_shot_duration = profile.value("shot_duration")
	_shot_strength = deg_to_rad(profile.value("shot_amplitude"))

func fire_custom(amplitude: float, duration: float) -> void:
	_shot_age = 0.0
	_shot_duration = maxf(0.02,duration)
	_shot_strength = deg_to_rad(maxf(0,amplitude))

func hit(profile: DGDCameraProfile) -> void:
	_hit_age = 0.0
	_hit_duration = profile.value("hit_duration")
	_hit_strength = deg_to_rad(profile.value("hit_amplitude"))
	_hit_side *= -1.0

func sample(delta: float, profile: DGDCameraProfile, speed: float, grounded: bool, alive: bool = true) -> Vector3:
	if not alive:
		reset()
		return Vector3.ZERO
	delta = maxf(delta, 0.0)
	var walking := grounded and speed > 0.35
	_step_weight = lerpf(_step_weight, clampf(speed / 4.5, 0.0, 1.5) if walking else 0.0, 1.0 - exp(-16.0 * delta))
	if walking:
		_phase = fmod(_phase + delta * TAU * profile.value("step_frequency") * clampf(speed / 4.5, 0.25, 1.5), TAU * 2.0)
	var steps := deg_to_rad(profile.value("step_amplitude")) * _step_weight
	var result := Vector3(sin(_phase * 2.0) * steps, 0.0, cos(_phase) * steps * 0.55)
	if _shot_age < _shot_duration:
		var t := _shot_age / _shot_duration
		result.x += _shot_strength * (1.0 - t) * (1.0 - t) * cos(t * TAU)
	if _hit_age < _hit_duration:
		var t := _hit_age / _hit_duration
		var impulse := _hit_strength * (1.0 - t) * (1.0 - t)
		result += Vector3(-impulse * cos(t * TAU), _hit_side * impulse * sin(t * TAU), _hit_side * impulse * 0.6)
	_shot_age += delta
	_hit_age += delta
	return result
