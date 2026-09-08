extends Control
## Local HUD only. The bit mask comes from authoritative player snapshots.
const REGIONS: Array[String] = ["head", "torso", "left_arm", "right_arm", "left_leg", "right_leg"]
const HEALTHY := Color.WHITE
const WOUNDED := Color("ff665e")
var _parts: Dictionary = {}
var _mask := 0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(100, 100)
	for key in REGIONS:
		var part := TextureRect.new()
		part.texture = load("res://ui/injuries/%s.svg" % key)
		part.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		part.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		part.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(part)
		part.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_parts[key] = part
	set_injuries(_mask, 100)

func set_injuries(mask: int, _hp: int) -> void:
	_mask = mask
	for key in _parts:
		var injured: bool = mask & NetConfig.INJURY_BITS[key] != 0
		_parts[key].modulate = WOUNDED if injured else HEALTHY
