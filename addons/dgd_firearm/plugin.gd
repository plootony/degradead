@tool
extends EditorPlugin
const PATH := "res://addons/dgd_weapon/library.tres"
var library: DGDWeaponLibrary
var workspace: VBoxContainer
var _dirty := false
var _probe: RefCounted
func _enter_tree() -> void:
	library=load(PATH)
	workspace=preload("res://addons/dgd_firearm/workspace.gd").new()
	workspace.library=library
	workspace.edited.connect(edit_property)
	workspace.save_requested.connect(save)
	workspace.preset_requested.connect(preset)
	EditorInterface.get_editor_main_screen().add_child(workspace); workspace.hide()
	add_tool_menu_item("Настройка стрельбы DGD",open)
	EditorInterface.get_inspector().property_edited.connect(inspector_edit)
	if "--firearm-editor-test" in OS.get_cmdline_user_args():
		_probe=load("res://tests/firearm_editor.gd").new(); _probe.call_deferred("run",self)
func _exit_tree() -> void:
	save()
	remove_tool_menu_item("Настройка стрельбы DGD")
	EditorInterface.get_inspector().property_edited.disconnect(inspector_edit)
	if workspace: workspace.queue_free()
func _has_main_screen() -> bool: return true
func _get_plugin_name() -> String: return "Стрельба"
func _get_plugin_icon() -> Texture2D: return EditorInterface.get_editor_theme().get_icon("GPUParticles3D","EditorIcons")
func _make_visible(value: bool) -> void:
	if workspace:
		workspace.visible=value
		if value: workspace.refresh()
func _handles(object: Object) -> bool: return object is DGDFirearmSettings
func open() -> void: EditorInterface.set_main_screen_editor("Стрельба")
func edit_property(object: Resource,key: String,value: Variant) -> void:
	if object.get(key)==value: return
	var undo:=get_undo_redo()
	undo.create_action("Стрельба: %s / %s" % [object.get_instance_id(),key],UndoRedo.MERGE_ENDS,library)
	# Newly created nested settings have no path until the catalogue is saved.
	undo.force_fixed_history()
	undo.add_do_property(object,key,value)
	undo.force_fixed_history()
	undo.add_undo_property(object,key,object.get(key))
	undo.add_do_method(self,"changed"); undo.add_undo_method(self,"changed"); undo.commit_action()
func preset(type: int) -> void:
	edit_property(workspace.profile(),"firing",DGDFirearmSettings.preset(type))
	workspace.reset_preview()
func changed() -> void:
	_dirty=true; workspace.refresh(); workspace.status("Изменено. Ctrl+Z — отмена. Сохраните перед запуском игры.")
func inspector_edit(_key: String) -> void:
	for p in library.profiles:
		if EditorInterface.get_inspector().get_edited_object()==p.firing: changed(); return
func save() -> void:
	if not _dirty: return
	var problem:=library.validation_error()
	if not problem.is_empty(): workspace.status(problem); return
	var error:=ResourceSaver.save(library,PATH)
	if error==OK: _dirty=false; workspace.status("Сохранено. Перезапустите игру для применения настроек.")
	else: workspace.status("Ошибка записи: "+error_string(error))
func _save_external_data() -> void: save()
func _apply_changes() -> void: save()
func _build() -> bool:
	save(); return not _dirty

func _edit(object: Object) -> void:
	if not workspace: return
	for i in library.profiles.size():
		if library.profiles[i].firing==object:
			workspace.selected=i
			workspace.refresh()
			return
