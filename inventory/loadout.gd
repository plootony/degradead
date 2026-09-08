@tool
extends Resource
class_name DGDStarterLoadout
## Configurable respawn kit (ТЗ §5: "на возрождении выдавать настраиваемый
## стартовый комплект"). Applied server-side by DGDInventory.apply_loadout().
## Each entry: {"slot": DGDInventory slot index (0..8), "item_id": String,
## "count": int}. Edited as a plain Array in the inspector -- no dedicated
## editor UI, same tier of tooling as DGDStarterLoadout's sibling .tres data
## resources (item_catalog.tres, mount_config.tres) in this prototype.
@export var entries: Array[Dictionary] = []

func validation_error(catalog: DGDItemCatalog) -> String:
	for entry in entries:
		var slot_index := int(entry.get("slot", -1))
		if slot_index < 0 or slot_index >= DGDInventory.SLOT_COUNT:
			return "Стартовый комплект: неверный номер слота %d" % slot_index
		var item_id: String = entry.get("item_id", "")
		if catalog and not catalog.find(item_id):
			return "Стартовый комплект: предмет не найден в каталоге: " + item_id
	return ""
