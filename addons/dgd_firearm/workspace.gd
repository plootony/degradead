@tool
extends VBoxContainer
signal edited(object: Resource,key: String,value: Variant)
signal save_requested
signal preset_requested(type: int)
var library: DGDWeaponLibrary
var selected := 0
var preview: SubViewportContainer
var pattern: Control
var _weapons: OptionButton
var _type: OptionButton
var _mode: OptionButton
var _color: ColorPickerButton
var fields: Dictionary = {}
var _refreshing := false
var _status: Label
var _metrics: Label
var _auto := false
var _aim := false
var _stance := 0
var _moving := false
var _air := false
var _heat := 0.0
var _cooldown := 0.0
var _sequence := 0
const GROUPS := {
"Баллистика": [
["rpm","Темп, выстрелов/мин"],["damage","Урон пули / дробины"],["max_range","Дальность, м"],["falloff_start","Начало падения урона, м"],["minimum_damage","Доля урона вдали"],["arm_multiplier","Множитель урона рукам"],["leg_multiplier","Множитель урона ногам"],["pellets","Дробин в выстреле"],
["hip_spread","Разброс от бедра, °"],["aim_spread","Разброс в прицеле, °"],["movement_multiplier","Разброс в движении, ×"],["crouch_multiplier","Разброс в приседе, ×"],["prone_multiplier","Разброс лёжа, ×"],["air_multiplier","Разброс в воздухе, ×"],["bloom_per_shot","Добавка разброса за выстрел, °"],["bloom_max","Максимальная добавка, °"],["bloom_recovery","Восстановление точности, °/с"]],
"Отдача": [
["recoil_up","Отдача вверх, °"],["recoil_down","Отдача вниз, °"],["recoil_left","Увод влево, °"],["recoil_right","Увод вправо, °"],["aim_recoil_multiplier","Отдача в прицеле, ×"],["recoil_return","Скорость возврата прицела"],["camera_shake","Тряска камеры, ×"],["shake_duration","Длительность тряски, с"],["weapon_kickback","Откат оружия назад, м"],["weapon_lift","Подброс оружия, °"],["weapon_yaw","Увод оружия, °"],["weapon_roll","Крен оружия, °"],["weapon_shake","Дрожание оружия, °"],["weapon_return","Скорость возврата оружия"]],
"Огонь и дым": [
["flash_size","Размер вспышки, м"],["flash_brightness","Яркость вспышки"],["flash_duration","Длительность вспышки, с"],["light_energy","Свет на окружение"],["light_range","Радиус света, м"],["smoke_size","Размер частиц дыма, м"],["smoke_opacity","Плотность дыма"],["smoke_lifetime","Время жизни дыма, с"],["smoke_amount","Частиц дыма за выстрел"],["smoke_speed","Скорость дыма, м/с"],["smoke_brightness","Яркость дыма"]]}
func profile() -> DGDWeaponProfile:
	selected=clampi(selected,0,library.profiles.size()-1)
	return library.profiles[selected]
func settings() -> DGDFirearmSettings:
	if not profile().firing: profile().firing=DGDFirearmSettings.new()
	return profile().firing
func _ready() -> void:
	size_flags_vertical=Control.SIZE_EXPAND_FILL
	size_flags_horizontal=Control.SIZE_EXPAND_FILL
	var bar := HBoxContainer.new(); add_child(bar)
	_weapons=OptionButton.new(); _weapons.custom_minimum_size.x=180; bar.add_child(_weapons)
	_weapons.item_selected.connect(func(i): selected=i; reset_preview(); refresh())
	_type=OptionButton.new(); bar.add_child(_type)
	for title in ["Автомат","Пистолет","Пистолет-пулемёт","Дробовик","Винтовка"]: _type.add_item(title)
	_type.item_selected.connect(func(i): edited.emit(settings(),"weapon_type",i))
	button(bar,"Применить пресет типа",func(): preset_requested.emit(_type.selected))
	button(bar,"Сохранить",func(): save_requested.emit())
	var row := HBoxContainer.new(); row.size_flags_vertical=Control.SIZE_EXPAND_FILL; add_child(row)
	var left := VBoxContainer.new(); left.size_flags_horizontal=Control.SIZE_EXPAND_FILL; row.add_child(left)
	preview=preload("res://addons/dgd_firearm/preview.gd").new(); preview.profile=profile(); left.add_child(preview)
	var controls := HBoxContainer.new(); left.add_child(controls)
	button(controls,"Выстрел",fire)
	checkbox(controls,"Серия",func(v): _auto=v)
	checkbox(controls,"Прицел",func(v): _aim=v; update_pose())
	checkbox(controls,"Движение",func(v): _moving=v; update_pose())
	checkbox(controls,"В воздухе",func(v): _air=v)
	var controls2 := HBoxContainer.new(); left.add_child(controls2)
	var stance := OptionButton.new(); controls2.add_child(stance)
	for title in ["Стоя","Присед","Лёжа"]: stance.add_item(title)
	stance.item_selected.connect(func(i): _stance=i; update_pose())
	var shake := checkbox(controls2,"Камера",func(v): preview.shake_enabled=v); shake.button_pressed=true
	button(controls2,"Очистить мишень",reset_preview)
	var distance := SpinBox.new(); distance.min_value=1; distance.max_value=500; distance.value=20; distance.suffix="м"; controls2.add_child(distance)
	distance.value_changed.connect(func(v): pattern.distance=v; pattern.clear())
	pattern=preload("res://addons/dgd_firearm/pattern.gd").new(); pattern.custom_minimum_size.y=170; left.add_child(pattern)
	_metrics=Label.new(); left.add_child(_metrics)
	var tabs := TabContainer.new(); tabs.custom_minimum_size.x=440; row.add_child(tabs)
	for group in GROUPS:
		var scroll := ScrollContainer.new(); scroll.name=group; scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED; tabs.add_child(scroll)
		var box := VBoxContainer.new(); box.size_flags_horizontal=Control.SIZE_EXPAND_FILL; scroll.add_child(box)
		if group=="Баллистика":
			_mode=OptionButton.new(); _mode.add_item("Одиночный огонь"); _mode.add_item("Автоматический огонь"); box.add_child(_mode)
			_mode.item_selected.connect(func(i): edited.emit(settings(),"fire_mode",i))
		for item in GROUPS[group]:
			var line := HBoxContainer.new(); box.add_child(line)
			var label := Label.new(); label.text=item[1]; label.size_flags_horizontal=Control.SIZE_EXPAND_FILL; line.add_child(label)
			var spin := SpinBox.new(); spin.custom_minimum_size.x=105
			var limits: Vector2=DGDFirearmSettings.LIMITS[item[0]]
			spin.min_value=limits.x; spin.max_value=limits.y
			spin.step=1 if item[0] in ["rpm","damage","pellets","smoke_amount","max_range","falloff_start"] else (0.001 if item[0]=="weapon_kickback" else 0.01)
			spin.value_changed.connect(change.bind(item[0])); line.add_child(spin); fields[item[0]]=spin
		if group=="Огонь и дым":
			_color=ColorPickerButton.new(); _color.text="Цвет вспышки"; box.add_child(_color)
			_color.color_changed.connect(func(c): edited.emit(settings(),"flash_color",c))
	_status=Label.new(); add_child(_status)
	refresh()
func button(parent: Node,title: String,callback: Callable) -> Button:
	var b:=Button.new(); b.text=title; b.pressed.connect(callback); parent.add_child(b); return b
func checkbox(parent: Node,title: String,callback: Callable) -> CheckBox:
	var b:=CheckBox.new(); b.text=title; b.toggled.connect(callback); parent.add_child(b); return b
func change(value: float,key: String) -> void:
	if not _refreshing: edited.emit(settings(),key,int(value) if key in ["pellets","smoke_amount"] else value)
func refresh() -> void:
	if not preview: return
	_refreshing=true
	_weapons.clear()
	for p in library.profiles: _weapons.add_item(p.title)
	_weapons.select(selected)
	_type.select(settings().weapon_type); _mode.select(settings().fire_mode)
	_color.color=settings().flash_color
	for key in fields: fields[key].set_value_no_signal(settings().value(key))
	fields.pellets.editable=settings().weapon_type==3
	if preview.profile != profile(): preview.set_profile(profile())
	_refreshing=false
func update_pose() -> void:
	preview.pose_index=_stance*2+int(_aim)
	preview.set_clip((["walk_forward","crouch_walk_forward","prone_forward"] if _moving else (["aim_idle","crouch_aim_idle","prone_idle"] if _aim else ["idle","crouch_idle","prone_idle"]))[_stance])
func reset_preview() -> void:
	_heat=0; _cooldown=0
	if pattern: pattern.clear()
	if preview:
		preview.recoil.reset(); preview.modifier.shot_motion.reset(); preview.camera_shake.reset()
func fire() -> void:
	if _cooldown>0: return
	var p:=settings()
	_cooldown=p.interval() if _cooldown<=-p.interval() else _cooldown+p.interval()
	_sequence+=1
	var seed_value:=DGDBallistics.shot_seed(1,0,_sequence)
	var angle:=DGDBallistics.spread(p,_aim,_stance,4.5 if _moving else 0.0,_air,_heat)
	var direction: Vector3=Basis.from_euler(preview.recoil.camera_angles)*Vector3.FORWARD
	var rays:=DGDBallistics.directions(direction,angle,p.pellet_count(),seed_value)
	pattern.distance=minf(pattern.distance,p.value("max_range")); pattern.spread=angle; pattern.add_rays(rays)
	preview.fire(seed_value,_aim)
	_heat=minf(p.value("bloom_max"),_heat+p.value("bloom_per_shot"))
func _process(delta: float) -> void:
	if not is_visible_in_tree() or not preview: return
	_cooldown=maxf(-settings().interval(),_cooldown-delta)
	_heat=DGDBallistics.cool(settings(),_heat,delta)
	if _auto: fire()
	_metrics.text="%d выстр./мин · %d дробин/пуль · добавка разброса %.2f°" % [settings().value("rpm"),settings().pellet_count(),_heat]
func status(message: String) -> void:
	if _status: _status.text=message
