extends Control
class_name DGDInventoryPanel
## Tab-toggled inventory UI (ТЗ §4), built at runtime like ui/combat_panel.gd
## and ui/injury_panel.gd. Pure presentation: every write goes through
## Player.request_move_item() (dynamic dispatch, same "avoid a preload cycle
## with player.gd" convention net/match_server.gd already uses for the Player
## node) so the UI never touches inventory data or the network directly
## (ТЗ §5, "отделить данные инвентаря от интерфейса и сетевого транспорта").
## Reads the local player's DGDPlayerInventory snapshot every frame while
## visible -- nine slots is cheap enough that a dedicated change signal
## would only add plumbing without a measurable benefit here.

const SLOT_SIZE := Vector2(56, 56)
const WEAPON_LABELS := ["1 Main", "2 Secondary", "3 Pistol"]

## One inventory cell: icon (or a placeholder initial when the item has no
## icon texture -- this prototype ships no art assets), stack count, and an
## "equipped" highlight. Drag source/target via Control's built-in
## _get_drag_data/_can_drop_data/_drop_data (ТЗ §4: "перемещение предметов...
## мышью").
class _SlotControl extends PanelContainer:
	var panel: DGDInventoryPanel
	var slot_index: int
	var _icon: TextureRect
	var _letter: Label
	var _count: Label
	var _active: ColorRect

	func _ready() -> void:
		custom_minimum_size = SLOT_SIZE
		var bg := ColorRect.new()
		bg.color = Color(1, 1, 1, 0.06)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)
		_active = ColorRect.new()
		_active.color = Color(1.0, 0.85, 0.2, 0.35)
		_active.set_anchors_preset(Control.PRESET_FULL_RECT)
		_active.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_active.visible = false
		add_child(_active)
		_icon = TextureRect.new()
		_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon)
		_letter = Label.new()
		_letter.set_anchors_preset(Control.PRESET_CENTER)
		_letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_letter.add_theme_font_size_override("font_size", 20)
		_letter.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_letter)
		_count = Label.new()
		_count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		_count.add_theme_font_size_override("font_size", 12)
		_count.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		_count.add_theme_constant_override("shadow_offset_x", 1)
		_count.add_theme_constant_override("shadow_offset_y", 1)
		_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_count)

	func refresh(item: DGDItemDef, count: int, active: bool) -> void:
		_active.visible = active
		if not item:
			_icon.texture = null
			_letter.text = ""
			_count.text = ""
			tooltip_text = ""
			return
		if item.icon:
			_icon.texture = item.icon
			_letter.text = ""
		else:
			_icon.texture = null
			_letter.text = item.title.substr(0, 1).to_upper() if not item.title.is_empty() else "?"
		_count.text = str(count) if count > 1 else ""
		tooltip_text = "%s x%d" % [item.title, count] if count > 1 else item.title

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if not panel or not is_instance_valid(panel.player):
			return null
		var inv: DGDPlayerInventory = panel.player.call("get_inventory")
		if not inv or inv.item_id_at(slot_index).is_empty():
			return null
		var preview := Label.new()
		preview.text = _letter.text if not _letter.text.is_empty() else "•"
		preview.add_theme_font_size_override("font_size", 22)
		set_drag_preview(preview)
		return {"slot": slot_index}

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return data is Dictionary and data.has("slot") and int(data["slot"]) != slot_index

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if panel:
			panel.request_move(int(data["slot"]), slot_index)


var player: Node
var _slots: Dictionary = {}  # slot index (int) -> _SlotControl


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_CENTER)

	var back := PanelContainer.new()
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(back)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	back.add_child(vbox)

	var title := Label.new()
	title.text = "Inventory  [Tab]"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var weapons := HBoxContainer.new()
	weapons.add_theme_constant_override("separation", 6)
	vbox.add_child(weapons)
	for i in 3:
		weapons.add_child(_labeled_slot(i, WEAPON_LABELS[i]))

	vbox.add_child(HSeparator.new())

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(grid)
	for i in DGDInventory.UNIVERSAL_COUNT:
		grid.add_child(_labeled_slot(DGDInventory.UNIVERSAL_START + i, ""))


func _labeled_slot(index: int, label_text: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	if not label_text.is_empty():
		var l := Label.new()
		l.text = label_text
		l.add_theme_font_size_override("font_size", 10)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(l)
	var slot := _SlotControl.new()
	slot.panel = self
	slot.slot_index = index
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	box.add_child(slot)
	_slots[index] = slot
	return box


## Connected once by net/lobby.gd to MatchServer.local_player_ready.
func set_player(p: Node) -> void:
	if player == p:
		return
	player = p
	if not player.is_connected("inventory_visibility_changed", _on_visibility_changed):
		player.connect("inventory_visibility_changed", _on_visibility_changed)


func _on_visibility_changed(open: bool) -> void:
	visible = open
	if open:
		_refresh()


func _process(_delta: float) -> void:
	if visible:
		_refresh()


func request_move(from: int, to: int) -> void:
	if is_instance_valid(player):
		player.call("request_move_item", from, to)


func _refresh() -> void:
	if not is_instance_valid(player):
		return
	var inv: DGDPlayerInventory = player.call("get_inventory")
	if not inv:
		return
	var catalog := inv.item_catalog()
	var active_slot := int(player.get("_weapon_slot"))
	for index: int in _slots.keys():
		var slot: _SlotControl = _slots[index]
		var id := inv.item_id_at(index)
		var item := (catalog.find(id) if catalog else null) if not id.is_empty() else null
		slot.refresh(item, inv.count_at(index), index == active_slot and DGDInventory.is_weapon_slot(index))
