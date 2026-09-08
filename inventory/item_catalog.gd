@tool
extends Resource
class_name DGDItemCatalog
## Shared item catalogue, same "every peer ships the same .tres" contract as
## DGDWeaponLibrary (addons/dgd_weapon/library.gd) -- item ids are looked up by
## string over the wire, never the Resource itself.
@export var items: Array[DGDItemDef] = []

func find(id: String) -> DGDItemDef:
	if id.is_empty(): return null
	for item in items:
		if item and item.id == id: return item
	return null

func validation_error() -> String:
	var ids: Dictionary = {}
	for item in items:
		if not item: return "В каталоге есть пустой предмет."
		if item.id.strip_edges().is_empty(): return "Идентификатор предмета не должен быть пустым."
		if ids.has(item.id): return "Повторяющийся идентификатор предмета: " + item.id
		ids[item.id] = true
		if item.allowed_slots.is_empty(): return "У предмета не выбраны допустимые слоты: " + item.title
		if item.is_weapon() and item.weapon_profile_id.is_empty():
			return "У оружейного предмета не указан профиль оружия: " + item.title
		if item.is_ammo() and item.ammo_caliber.is_empty():
			return "У патронов не указан калибр: " + item.title
	return ""
