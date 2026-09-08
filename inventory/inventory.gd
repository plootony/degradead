extends RefCounted
class_name DGDInventory
## Pure inventory data + rules -- no Node, no networking, no UI (ТЗ §5,
## "Отделить данные инвентаря от интерфейса и сетевого транспорта"). Owned and
## mutated only by the master via net/player_inventory.gd; everyone else only
## ever reads a copy rebuilt from the replicated `slots_json` snapshot.
##
## Slot layout (ТЗ §1): 0=main weapon, 1=secondary weapon, 2=pistol,
## 3..8=six universal cells (ammo boxes, medkits, misc).
const SLOT_COUNT: int = 9
const UNIVERSAL_START: int = 3
const UNIVERSAL_COUNT: int = 6

## Slot *category* -- what DGDItemDef.allowed_slots checks against. Distinct
## from a slot *index*: every universal cell (index 3..8) shares SlotKind.UNIVERSAL.
enum SlotKind { MAIN, SECONDARY, PISTOL, UNIVERSAL }

## One entry per slot: {"item": item id ("" = empty), "count": int,
## "magazine": int}. `magazine` is only meaningful for a weapon-slot entry
## (rounds currently chambered/loaded in THAT weapon instance, per ТЗ §3
## "остаток магазина хранить отдельно у каждого экземпляра оружия") and is -1
## for anything else.
var slots: Array[Dictionary] = []

func _init() -> void:
	clear()

func clear() -> void:
	slots.clear()
	for i in SLOT_COUNT:
		slots.append(_empty_slot())

static func _empty_slot() -> Dictionary:
	return {"item": "", "count": 0, "magazine": -1}

static func slot_kind_of(index: int) -> int:
	if index == SlotKind.MAIN or index == SlotKind.SECONDARY or index == SlotKind.PISTOL:
		return index
	return SlotKind.UNIVERSAL

static func is_weapon_slot(index: int) -> bool:
	return index >= 0 and index < UNIVERSAL_START

func item_id_at(index: int) -> String:
	return String(slots[index]["item"]) if index >= 0 and index < SLOT_COUNT else ""

func count_at(index: int) -> int:
	return int(slots[index]["count"]) if index >= 0 and index < SLOT_COUNT else 0

func magazine_at(weapon_slot: int) -> int:
	return int(slots[weapon_slot]["magazine"]) if is_weapon_slot(weapon_slot) else -1

func set_magazine_at(weapon_slot: int, value: int) -> void:
	if not is_weapon_slot(weapon_slot) or String(slots[weapon_slot]["item"]).is_empty():
		return
	var s: Dictionary = slots[weapon_slot]
	s["magazine"] = value
	slots[weapon_slot] = s

func can_place(catalog: DGDItemCatalog, item_id: String, slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= SLOT_COUNT: return false
	if item_id.is_empty(): return true
	var item := catalog.find(item_id) if catalog else null
	return item != null and item.accepts_slot_kind(slot_kind_of(slot_index))

## Moves slot `from` into slot `to`: merges into a same-item stack when the
## item is stackable (max_stack > 1, i.e. ammo/consumables -- weapons always
## swap even when they share a profile, since each instance keeps its own
## `magazine`), otherwise swaps the two slots. Both directions are checked
## against `catalog` so an incompatible swap (e.g. a pistol displacing a rifle
## out of the pistol slot) is refused outright. Returns whether anything changed.
func move(catalog: DGDItemCatalog, from: int, to: int) -> bool:
	if from < 0 or from >= SLOT_COUNT or to < 0 or to >= SLOT_COUNT or from == to or not catalog:
		return false
	var a: Dictionary = slots[from]
	var b: Dictionary = slots[to]
	if String(a["item"]).is_empty():
		return false
	if not can_place(catalog, a["item"], to):
		return false
	var item := catalog.find(a["item"])
	if item and item.max_stack > 1 and a["item"] == b["item"]:
		var room: int = item.max_stack - int(b["count"])
		if room <= 0:
			return false
		var moved: int = mini(room, int(a["count"]))
		b["count"] = int(b["count"]) + moved
		a["count"] = int(a["count"]) - moved
		slots[to] = b
		slots[from] = _empty_slot() if int(a["count"]) <= 0 else a
		return true
	if not String(b["item"]).is_empty() and not can_place(catalog, b["item"], from):
		return false
	slots[from] = b
	slots[to] = a
	return true

## Places up to `count` of item_id into existing compatible stacks first, then
## empty compatible slots. Returns the leftover that did not fit. Used by the
## starter loadout (weapon instances pass their starting magazine).
func add_item(catalog: DGDItemCatalog, item_id: String, count: int, magazine: int = -1) -> int:
	if not catalog or count <= 0: return count
	var item := catalog.find(item_id)
	if not item: return count
	var remaining := count
	if item.max_stack > 1:
		for i in SLOT_COUNT:
			if remaining <= 0: break
			var s: Dictionary = slots[i]
			if String(s["item"]) != item_id: continue
			var room: int = item.max_stack - int(s["count"])
			if room <= 0: continue
			var add: int = mini(room, remaining)
			s["count"] = int(s["count"]) + add
			remaining -= add
			slots[i] = s
	for i in SLOT_COUNT:
		if remaining <= 0: break
		if not String(slots[i]["item"]).is_empty(): continue
		if not item.accepts_slot_kind(slot_kind_of(i)): continue
		var add: int = mini(item.max_stack, remaining)
		slots[i] = {"item": item_id, "count": add, "magazine": magazine if item.is_weapon() else -1}
		remaining -= add
	return remaining

## Drains up to `amount` rounds of `caliber` from matching AMMO stacks
## (ТЗ §3: "перезарядка расходует совместимые патроны из инвентаря; пустые
## коробки удаляются"). Returns how much was actually removed.
func remove_ammo(catalog: DGDItemCatalog, caliber: String, amount: int) -> int:
	if not catalog or amount <= 0 or caliber.is_empty(): return 0
	var removed := 0
	for i in SLOT_COUNT:
		if removed >= amount: break
		var s: Dictionary = slots[i]
		if String(s["item"]).is_empty(): continue
		var item := catalog.find(s["item"])
		if not item or not item.is_ammo() or item.ammo_caliber != caliber: continue
		var take: int = mini(int(s["count"]), amount - removed)
		removed += take
		var left: int = int(s["count"]) - take
		slots[i] = _empty_slot() if left <= 0 else {"item": s["item"], "count": left, "magazine": -1}
	return removed

func total_ammo(catalog: DGDItemCatalog, caliber: String) -> int:
	if not catalog or caliber.is_empty(): return 0
	var total := 0
	for s in slots:
		if String(s["item"]).is_empty(): continue
		var item := catalog.find(s["item"])
		if item and item.is_ammo() and item.ammo_caliber == caliber:
			total += int(s["count"])
	return total

func weapon_item(catalog: DGDItemCatalog, weapon_slot: int) -> DGDItemDef:
	if not catalog or not is_weapon_slot(weapon_slot): return null
	var id := item_id_at(weapon_slot)
	if id.is_empty(): return null
	var item := catalog.find(id)
	return item if item and item.is_weapon() else null

## Weapon profile id of whatever occupies `weapon_slot` (Player.WeaponSlot
## MAIN/SECONDARY/PISTOL), or "" when empty/unarmed -- drives the existing
## DGDWeaponModifier pipeline via Player._weapon_profile_id unchanged.
func active_weapon_profile_id(catalog: DGDItemCatalog, weapon_slot: int) -> String:
	var item := weapon_item(catalog, weapon_slot)
	return item.weapon_profile_id if item else ""

func serialize() -> String:
	var arr: Array = []
	for s in slots:
		arr.append([s["item"], s["count"], s["magazine"]])
	return JSON.stringify(arr)

func deserialize(json: String) -> void:
	clear()
	var parsed = JSON.parse_string(json)
	if not parsed is Array: return
	for i in mini(parsed.size(), SLOT_COUNT):
		var e = parsed[i]
		if e is Array and e.size() >= 3:
			slots[i] = {"item": str(e[0]), "count": int(e[1]), "magazine": int(e[2])}

## Server-only: grants the configurable starter kit (ТЗ §5, "на возрождении
## выдавать настраиваемый стартовый комплект"). Weapon entries start full --
## capacity comes from the linked DGDWeaponProfile's firing settings, the same
## `value("magazine_size")` accessor net/weapon_ammo.gd used to use.
func apply_loadout(catalog: DGDItemCatalog, weapon_library: DGDWeaponLibrary, loadout: DGDStarterLoadout) -> void:
	clear()
	if not catalog or not loadout: return
	for entry in loadout.entries:
		var slot_index := int(entry.get("slot", -1))
		var item_id: String = entry.get("item_id", "")
		var count: int = maxi(1, int(entry.get("count", 1)))
		if slot_index < 0 or slot_index >= SLOT_COUNT: continue
		var item := catalog.find(item_id)
		if not item or not item.accepts_slot_kind(slot_kind_of(slot_index)): continue
		var magazine := -1
		if item.is_weapon():
			var profile := weapon_library.find_profile(item.weapon_profile_id) if weapon_library else null
			magazine = int(profile.firing.value("magazine_size")) if profile and profile.firing else 0
		slots[slot_index] = {"item": item_id, "count": count, "magazine": magazine}
