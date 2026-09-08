@tool
extends Resource
class_name DGDWeaponLibrary
@export var profiles: Array[DGDWeaponProfile] = []
@export var default_id := "aks74"
func find_profile(id: String) -> DGDWeaponProfile:
	for p in profiles:
		if p and p.id == id: return p
	return null
func default_profile() -> DGDWeaponProfile:
	var p := find_profile(default_id)
	return p if p else (profiles[0] if not profiles.is_empty() else null)

func validation_error() -> String:
	if profiles.is_empty(): return "Добавьте хотя бы один профиль оружия."
	var ids: Dictionary = {}
	for profile in profiles:
		if not profile: return "В каталоге есть пустой профиль."
		if profile.id.strip_edges().is_empty(): return "Идентификатор оружия не должен быть пустым."
		if profile.id.to_utf8_buffer().size()>96: return "Идентификатор оружия слишком длинный: " + profile.title
		if ids.has(profile.id): return "Повторяющийся идентификатор: " + profile.id
		ids[profile.id] = true
		if not profile.model: return "У профиля нет модели: " + profile.title
	if not ids.has(default_id): return "Выберите стартовое оружие кнопкой «Использовать в игре»."
	return ""
