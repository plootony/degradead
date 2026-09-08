extends VBoxContainer
## Compact, resolution-independent numeric combat HUD.
var hp_label: Label
var ammo_label: Label
var detail_label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_END
	add_theme_constant_override("separation",2)
	hp_label = _label(24)
	ammo_label = _label(32)
	detail_label = _label(14)
	detail_label.clip_text = true
	set_hp(100)
	set_ammo({})

func _label(font_size: int) -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size",font_size)
	label.add_theme_color_override("font_color",Color.WHITE)
	label.add_theme_color_override("font_shadow_color",Color(0,0,0,0.8))
	label.add_theme_constant_override("shadow_offset_x",1)
	label.add_theme_constant_override("shadow_offset_y",1)
	add_child(label)
	return label

func set_hp(hp: int) -> void:
	hp_label.text = "HP %d" % maxi(0,hp)

func set_ammo(state: Dictionary) -> void:
	ammo_label.text = "%d / %d" % [state.get("magazine",0),state.get("reserve",0)] if state.get("armed",false) else "— / —"
	detail_label.text = "Перезарядка · %d с" % state.get("seconds",0) if state.get("reloading",false) else str(state.get("type",""))
