@tool
extends VBoxContainer
signal edit_requested(index: int, key: String, value: float)
signal reset_requested(index: int)
signal save_requested
const SETTINGS = preload("res://addons/dgd_camera/settings.gd")
const PROFILE = preload("res://addons/dgd_camera/profile.gd")
const PREVIEW = preload("res://addons/dgd_camera/preview.gd")
var settings: DGDCameraSettings
var selected := 2
var preview: SubViewportContainer
var _inputs := {}
var _status: Label
var _select: OptionButton
var _refreshing := false

func _ready() -> void:
	name = "Камера"
	custom_minimum_size.x = 310
	add_theme_constant_override("separation", 8)
	_select = OptionButton.new()
	for title in SETTINGS.TITLES: _select.add_item(title)
	_select.select(selected)
	_select.item_selected.connect(select_profile)
	add_child(_select)
	preview = PREVIEW.new()
	add_child(preview)
	var actions := HBoxContainer.new()
	add_child(actions)
	var walk := CheckButton.new()
	walk.text = "Шаги"
	walk.toggled.connect(func(on): preview.walking = on)
	actions.add_child(walk)
	for action in [["Выстрел", preview.fire], ["Попадание", preview.hit]]:
		var button := Button.new()
		button.text = action[0]
		button.pressed.connect(action[1])
		actions.add_child(button)
	var stance := OptionButton.new()
	for title in ["Стоя", "Присед", "Лёжа"]: stance.add_item(title)
	stance.item_selected.connect(func(i): preview.stance_height = [1.6, 1.05, 0.35][i])
	add_child(stance)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 160
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(grid)
	for field in PROFILE.FIELDS:
		var label := Label.new()
		label.text = field[1]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = field[2]
		spin.max_value = field[3]
		spin.step = field[4]
		spin.suffix = field[5]
		spin.custom_minimum_size.x = 110
		spin.value_changed.connect(_request_value.bind(field[0]))
		grid.add_child(spin)
		_inputs[field[0]] = spin
	var buttons := HBoxContainer.new()
	add_child(buttons)
	var save := Button.new()
	save.text = "Сохранить"
	save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save.pressed.connect(func(): save_requested.emit())
	buttons.add_child(save)
	var reset := Button.new()
	reset.text = "Сбросить профиль"
	reset.pressed.connect(func(): reset_requested.emit(selected))
	buttons.add_child(reset)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	set_status("Предпросмотр обновляется сразу. Сохраните перед запуском игры.")
	refresh()

func select_profile(index: int) -> void:
	selected = clampi(index, 0, 3)
	if _select: _select.select(selected)
	refresh()

func refresh() -> void:
	if not settings or not preview: return
	_refreshing = true
	var profile := settings.profile_at(selected)
	for key in _inputs: _inputs[key].set_value_no_signal(profile.value(key))
	preview.profile = profile
	preview.first_person = selected < 2
	_refreshing = false

func _request_value(value: float, key: String) -> void:
	if not _refreshing: edit_requested.emit(selected, key, value)

func set_status(text: String) -> void:
	if _status: _status.text = text
