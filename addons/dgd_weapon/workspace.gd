@tool
extends VBoxContainer
signal property_edited(object: Resource, key: String, value: Variant)
signal add_requested
signal duplicate_requested
signal save_requested
signal inspect_requested
const PREVIEW = preload("res://addons/dgd_weapon/preview.gd")
var library: DGDWeaponLibrary
var selected := 0
var state := 0
var target := 2
var preview: SubViewportContainer
var _weapons: OptionButton
var _states: OptionButton
var _targets: OptionButton
var _title: LineEdit
var _position: Array[SpinBox] = []
var _rotation: Array[SpinBox] = []
var _right: SpinBox
var _left: SpinBox
var _length: SpinBox
var _blend: SpinBox
var _timeline: HSlider
var _status: Label
var _metrics: Label
var _refreshing := false
const POSITION_KEYS := ["position", "right_position", "left_position", "right_pole", "left_pole", "muzzle_position", "mount_position"]
const ROTATION_KEYS := ["rotation_degrees", "right_rotation", "left_rotation", "", "", "muzzle_rotation", "mount_rotation"]

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	var bar := HBoxContainer.new()
	add_child(bar)
	_weapons = OptionButton.new()
	_weapons.custom_minimum_size.x = 180
	_weapons.item_selected.connect(func(i): selected = i; refresh())
	bar.add_child(_weapons)
	_button(bar, "Добавить модель…", func(): add_requested.emit())
	_button(bar, "Копия профиля", func(): duplicate_requested.emit())
	_button(bar, "Использовать в игре", func(): property_edited.emit(library, "default_id", current_profile().id))
	_button(bar, "Сохранить", func(): save_requested.emit())
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)
	add_child(row)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	preview = PREVIEW.new()
	preview.profile = current_profile()
	preview.dragged.connect(_drag)
	preview.target_selected.connect(func(i): target = i; refresh())
	left.add_child(preview)
	var hint := Label.new()
	hint.text = "ЛКМ: тянуть маркер · ПКМ: вращать вид · Колесо: масштаб"
	left.add_child(hint)
	var playback := HBoxContainer.new()
	left.add_child(playback)
	var clips := OptionButton.new()
	for name in PREVIEW.CLIPS: clips.add_item(name)
	clips.item_selected.connect(func(i): preview.set_clip(PREVIEW.CLIPS[i]))
	playback.add_child(clips)
	var play := CheckButton.new()
	play.text = "Играть"
	play.button_pressed = true
	play.toggled.connect(func(on): preview.playing = on)
	playback.add_child(play)
	var rate := SpinBox.new()
	rate.min_value = 0.1
	rate.max_value = 2.0
	rate.step = 0.1
	rate.value = 1.0
	rate.suffix = "×"
	rate.value_changed.connect(func(v): preview.speed = v)
	playback.add_child(rate)
	_timeline = HSlider.new()
	_timeline.step = 0.001
	_timeline.value_changed.connect(func(v): preview.seek(v))
	left.add_child(_timeline)
	_metrics = Label.new()
	left.add_child(_metrics)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 345
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(scroll)
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_theme_constant_override("separation", 10)
	scroll.add_child(fields)
	_label(fields, "Профиль оружия")
	_title = LineEdit.new()
	_title.text_changed.connect(func(v):
		if not _refreshing: property_edited.emit(current_profile(), "title", v))
	fields.add_child(_title)
	_button(fields, "Профиль и кости в инспекторе", func(): inspect_requested.emit())
	_label(fields, "Поза")
	_states = OptionButton.new()
	for text in DGDWeaponProfile.STATES: _states.add_item(text)
	_states.item_selected.connect(func(i):
		state = i
		preview.set_clip(["idle","aim_idle","crouch_idle","crouch_aim_idle","prone_idle","prone_idle"][i])
		clips.select(PREVIEW.CLIPS.find(preview.clip))
		refresh())
	fields.add_child(_states)
	_label(fields, "Что настраивать")
	_targets = OptionButton.new()
	for text in PREVIEW.TARGETS: _targets.add_item(text)
	_targets.item_selected.connect(func(i): target = i; refresh())
	fields.add_child(_targets)
	_position = _vector_controls(fields, "Положение, м", false)
	_rotation = _vector_controls(fields, "Вращение, °", true)
	_right = _number(fields, "IK правой руки", 0, 1, 0.01, func(v):
		if not _refreshing: property_edited.emit(current_profile().pose_at(state), "right_weight", v))
	_left = _number(fields, "IK левой руки", 0, 1, 0.01, func(v):
		if not _refreshing: property_edited.emit(current_profile().pose_at(state), "left_weight", v))
	_length = _number(fields, "Длина модели, м", 0.1, 2.0, 0.01, func(v):
		if not _refreshing: property_edited.emit(current_profile(), "model_length", v))
	_blend = _number(fields, "Скорость перехода", 1, 30, 0.5, func(v):
		if not _refreshing: property_edited.emit(current_profile(), "blend_speed", v))
	_status = Label.new()
	add_child(_status)
	refresh()

func current_profile() -> DGDWeaponProfile:
	selected = clampi(selected, 0, library.profiles.size()-1)
	return library.profiles[selected]

func selected_object() -> Resource:
	return current_profile().pose_at(state) if target == 0 else current_profile()

func refresh() -> void:
	if not preview: return
	_refreshing = true
	var p := current_profile()
	_weapons.clear()
	for profile in library.profiles: _weapons.add_item(profile.title + (" ✓" if profile.id == library.default_id else ""))
	_weapons.select(selected)
	if _title.text != p.title: _title.text = p.title
	_states.select(state)
	_targets.select(target)
	if preview.profile != p: preview.set_profile(p)
	preview.pose_index = state
	preview.selected = target
	var object := selected_object()
	var position: Vector3 = object.get(POSITION_KEYS[target])
	var rotation: Vector3 = Vector3.ZERO if ROTATION_KEYS[target].is_empty() else object.get(ROTATION_KEYS[target])
	for i in 3:
		_position[i].set_value_no_signal(position[i])
		_rotation[i].set_value_no_signal(rotation[i])
		_rotation[i].editable = not ROTATION_KEYS[target].is_empty()
	_right.set_value_no_signal(p.pose_at(state).right_weight)
	_left.set_value_no_signal(p.pose_at(state).left_weight)
	_length.set_value_no_signal(p.model_length)
	_blend.set_value_no_signal(p.blend_speed)
	_refreshing = false

func _vector_controls(parent: Node, text: String, rotation: bool) -> Array[SpinBox]:
	_label(parent, text)
	var row := HBoxContainer.new()
	parent.add_child(row)
	var result: Array[SpinBox] = []
	for i in 3:
		var spin := SpinBox.new()
		spin.prefix = ["X", "Y", "Z"][i]
		spin.min_value = -180.0 if rotation else -2.0
		spin.max_value = 180.0 if rotation else 2.0
		spin.step = 0.5 if rotation else 0.005
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.custom_minimum_size.x = 100
		spin.value_changed.connect(_vector_changed.bind(i, rotation))
		row.add_child(spin)
		result.append(spin)
	return result

func _vector_changed(value: float, axis: int, rotation: bool) -> void:
	if _refreshing: return
	var object := selected_object()
	var key: String = ROTATION_KEYS[target] if rotation else POSITION_KEYS[target]
	if key.is_empty(): return
	var vector: Vector3 = object.get(key)
	vector[axis] = value
	property_edited.emit(object, key, vector)

func _drag(index: int, value: Vector3) -> void:
	target = index
	property_edited.emit(selected_object(), POSITION_KEYS[index], value)

func _label(parent: Node, text: String) -> void:
	var label := Label.new()
	label.text = text
	parent.add_child(label)

func _button(parent: Node, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)

func _number(parent: Node, text: String, minimum: float, maximum: float, step: float, callback: Callable) -> SpinBox:
	_label(parent,text)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value_changed.connect(callback)
	parent.add_child(spin)
	return spin

func _process(_delta: float) -> void:
	if not is_visible_in_tree() or not preview or not preview.animator: return
	_timeline.max_value = maxf(0.001, preview.animator.current_animation_length)
	if not _timeline.has_focus(): _timeline.set_value_no_signal(preview.animator.current_animation_position)
	var m = preview.modifier
	_metrics.text = m.validation_error if not m.validation_error.is_empty() else "Отклонение кистей: правая %.1f мм · левая %.1f мм" % [m.right_error*1000, m.left_error*1000]

func status(text: String) -> void:
	if _status: _status.text = text
