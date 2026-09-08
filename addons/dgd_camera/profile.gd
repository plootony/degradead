@tool
extends Resource
class_name DGDCameraProfile
## Distances are metres, rotations are degrees, durations are seconds.
@export_range(0.0, 3.0, 0.01) var distance := 3.0
@export_range(0.5, 2.2, 0.01) var height := 1.6
@export_range(-0.75, 0.75, 0.01) var shoulder := 0.45
@export_range(-0.25, 0.25, 0.01) var forward_offset := 0.0
@export_range(-20.0, 20.0, 0.1) var tilt := 0.0
@export_range(40.0, 100.0, 0.5) var fov := 75.0
@export_range(1.0, 30.0, 0.5) var transition_speed := 12.0
@export_range(0.0, 3.0, 0.01) var step_amplitude := 0.18
@export_range(0.5, 4.0, 0.05) var step_frequency := 1.8
@export_range(0.0, 6.0, 0.05) var shot_amplitude := 0.3
@export_range(0.04, 1.0, 0.01) var shot_duration := 0.14
@export_range(0.0, 8.0, 0.05) var hit_amplitude := 0.8
@export_range(0.05, 1.0, 0.01) var hit_duration := 0.28

const FIELDS: Array = [
	["distance", "Дальность", 0.0, 3.0, 0.01, "м"],
	["height", "Высота стоя", 0.5, 2.2, 0.01, "м"],
	["shoulder", "Смещение вбок", -0.75, 0.75, 0.01, "м"],
	["forward_offset", "Смещение назад", -0.25, 0.25, 0.01, "м"],
	["tilt", "Наклон вверх", -20.0, 20.0, 0.1, "°"],
	["fov", "Угол обзора", 40.0, 100.0, 0.5, "°"],
	["transition_speed", "Скорость перехода", 1.0, 30.0, 0.5, ""],
	["step_amplitude", "Шаги: сила", 0.0, 3.0, 0.01, "°"],
	["step_frequency", "Шаги: частота", 0.5, 4.0, 0.05, "Гц"],
	["shot_amplitude", "Выстрел: сила", 0.0, 6.0, 0.05, "°"],
	["shot_duration", "Выстрел: затухание", 0.04, 1.0, 0.01, "с"],
	["hit_amplitude", "Попадание: сила", 0.0, 8.0, 0.05, "°"],
	["hit_duration", "Попадание: затухание", 0.05, 1.0, 0.01, "с"],
]

func value(key: String) -> float:
	for field in FIELDS:
		if field[0] == key:
			var v: float = get(key)
			return clampf(v, field[2], field[3]) if is_finite(v) else float(field[2])
	return 0.0
