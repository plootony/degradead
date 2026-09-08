@tool
extends Resource
class_name DGDItemDef
## Static description of one inventory item, per ТЗ §3 ("Описание предметов
## вынести в ресурсы: ID, название, иконка, тип, модель, допустимые слоты и
## максимальный размер стопки"). Pure data -- no Node, no networking; read by
## inventory/inventory.gd and rendered by ui/inventory_panel.gd.

enum Type { WEAPON, AMMO, CONSUMABLE, MISC }

@export var id := ""
@export var title := ""
## Left empty for every shipped item (no art assets in this prototype) -- the UI
## falls back to a colored placeholder + initial letter when this is null.
@export var icon: Texture2D
@export_enum("Оружие", "Патроны", "Расходник", "Прочее") var type: int = Type.MISC
## World/inventory model, reserved for a future pickup/drop stage. Weapon items
## do NOT use this for in-hand/mount rendering -- that reuses the existing
## DGDWeaponProfile.model via weapon_profile_id below, so IK/animation/firing
## stay on the one weapon pipeline that already works.
@export var model: PackedScene
## Only meaningful when type == WEAPON: id into the shared DGDWeaponLibrary
## (addons/dgd_weapon/library.tres), reused for IK, mounting, muzzle and firing.
@export var weapon_profile_id := ""
## Only meaningful when type == AMMO: matched against DGDFirearmSettings.ammo_key().
@export var ammo_caliber := ""
## Which slot categories this item may occupy -- Inventory.SlotKind values.
## e.g. a rifle: [SlotKind.MAIN, SlotKind.SECONDARY]; a pistol: [SlotKind.PISTOL];
## ammo/medkits: [SlotKind.UNIVERSAL]. This single field is what "проверять
## совместимость типа предмета" (ТЗ §1) checks against on every move/equip.
@export var allowed_slots: Array[int] = []
## Stack cap per slot. For AMMO items this doubles as the ammo box's capacity
## (ТЗ §3 "коробки патронов содержат... оставшееся количество" -- the box's
## current rounds is the stack's `count`, capped by this).
@export_range(1, 999, 1) var max_stack := 1

func is_weapon() -> bool:
	return type == Type.WEAPON

func is_ammo() -> bool:
	return type == Type.AMMO

func accepts_slot_kind(kind: int) -> bool:
	return kind in allowed_slots
