@tool
extends EditorPlugin
const DOCK = preload("res://addons/dgd_camera/dock.gd")
const SETTINGS = preload("res://addons/dgd_camera/settings.gd")
const PATH := "res://addons/dgd_camera/camera_settings.tres"
var _editor_dock: EditorDock
var _dock: VBoxContainer
var _settings: DGDCameraSettings
var _dirty := false
var _test_probe: RefCounted

func _enter_tree() -> void:
	_settings = load(PATH)
	_dock = DOCK.new()
	_dock.settings = _settings
	_dock.edit_requested.connect(_edit_value)
	_dock.reset_requested.connect(_reset_profile)
	_dock.save_requested.connect(_save)
	_editor_dock = EditorDock.new()
	_editor_dock.title = "Камера"
	_editor_dock.layout_key = "DgdCamera"
	_editor_dock.icon_name = &"Camera3D"
	_editor_dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	_editor_dock.add_child(_dock)
	add_dock(_editor_dock)
	add_tool_menu_item("Камера DGD", _editor_dock.make_visible)
	if "--camera-plugin-test" in OS.get_cmdline_user_args():
		_test_probe = load("res://tests/camera_editor.gd").new()
		_test_probe.call_deferred("run", self)

func _exit_tree() -> void:
	_save()
	remove_tool_menu_item("Камера DGD")
	if is_instance_valid(_editor_dock):
		remove_dock(_editor_dock)
		_editor_dock.queue_free()

func _edit_value(index: int, key: String, value: float) -> void:
	var profile := _settings.profile_at(index)
	var old: float = profile.get(key)
	if is_equal_approx(old, value): return
	var undo := get_undo_redo()
	undo.create_action("Камера: " + SETTINGS.TITLES[index] + " / " + key, UndoRedo.MERGE_ENDS, _settings)
	undo.add_do_property(profile, key, value)
	undo.add_undo_property(profile, key, old)
	undo.add_do_method(self, "_changed")
	undo.add_undo_method(self, "_changed")
	undo.commit_action()

func _reset_profile(index: int) -> void:
	var undo := get_undo_redo()
	undo.create_action("Камера: сброс " + SETTINGS.TITLES[index], UndoRedo.MERGE_DISABLE, _settings)
	undo.add_do_property(_settings, SETTINGS.KEYS[index], SETTINGS.default_profile(index))
	undo.add_undo_property(_settings, SETTINGS.KEYS[index], _settings.profile_at(index))
	undo.add_do_method(self, "_changed")
	undo.add_undo_method(self, "_changed")
	undo.commit_action()

func _changed() -> void:
	_dirty = true
	_settings.emit_changed()
	_dock.refresh()
	_dock.set_status("Есть изменения. Ctrl+Z — отменить.")

func _save() -> void:
	if not _dirty or not _settings: return
	var error := ResourceSaver.save(_settings, PATH)
	if error == OK:
		_dirty = false
		if is_instance_valid(_dock): _dock.set_status("Сохранено. Настройки применятся при запуске игры.")
	elif is_instance_valid(_dock):
		_dock.set_status("Не удалось сохранить: " + error_string(error))

func _save_external_data() -> void:
	_save()

func _apply_changes() -> void:
	_save()

func _build() -> bool:
	_save()
	return not _dirty

func _get_plugin_name() -> String:
	return "DGD Camera"
