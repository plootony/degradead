@tool
extends EditorPlugin
const UI = preload("res://addons/dgd_weapon/workspace.gd")
const PROFILE = preload("res://addons/dgd_weapon/profile.gd")
const PATH := "res://addons/dgd_weapon/library.tres"
var workspace: VBoxContainer
var library: DGDWeaponLibrary
var _dialog: EditorFileDialog
var _dirty := false
var _probe: RefCounted
func _enter_tree() -> void:
	library = load(PATH)
	workspace = UI.new()
	workspace.library = library
	workspace.property_edited.connect(_edit_property)
	workspace.add_requested.connect(func(): _dialog.popup_centered_ratio(0.7))
	workspace.duplicate_requested.connect(_duplicate)
	workspace.save_requested.connect(_save)
	workspace.inspect_requested.connect(func(): EditorInterface.edit_resource(workspace.current_profile()))
	EditorInterface.get_editor_main_screen().add_child(workspace)
	workspace.hide()
	_dialog = EditorFileDialog.new()
	_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_dialog.filters = PackedStringArray(["*.tscn,*.scn,*.fbx,*.glb,*.gltf ; 3D модель оружия"])
	_dialog.file_selected.connect(_add_model)
	workspace.add_child(_dialog)
	add_tool_menu_item("Оружие IK DGD", _open)
	EditorInterface.get_inspector().property_edited.connect(_inspector_edited)
	if "--weapon-plugin-test" in OS.get_cmdline_user_args():
		_probe = load("res://tests/weapon_editor.gd").new()
		_probe.call_deferred("run",self)
func _exit_tree() -> void:
	_save()
	if EditorInterface.get_inspector().property_edited.is_connected(_inspector_edited):
		EditorInterface.get_inspector().property_edited.disconnect(_inspector_edited)
	remove_tool_menu_item("Оружие IK DGD")
	if workspace: workspace.queue_free()
func _open() -> void:
	EditorInterface.set_main_screen_editor("Оружие IK")
func _has_main_screen() -> bool: return true
func _get_plugin_name() -> String: return "Оружие IK"
func _get_plugin_icon() -> Texture2D: return EditorInterface.get_editor_theme().get_icon("Skeleton3D", "EditorIcons")
func _make_visible(visible: bool) -> void:
	if workspace: workspace.visible = visible
func _edit_property(object: Resource, key: String, value: Variant) -> void:
	if object.get(key) == value: return
	var undo := get_undo_redo()
	undo.create_action("Оружие IK: %s / %s" % [object.get_instance_id(), key], UndoRedo.MERGE_ENDS, library)
	undo.add_do_property(object, key, value)
	undo.add_undo_property(object, key, object.get(key))
	undo.add_do_method(self,"_changed",key)
	undo.add_undo_method(self,"_changed",key)
	undo.commit_action()
func _changed(key: String = "") -> void:
	_dirty = true
	workspace.refresh()
	if key in ["model", "model_length", "hidden_nodes"]: workspace.preview.modifier.rebuild()
	workspace.preview.modifier.resolve_bones()
	workspace.status("Есть изменения. Ctrl+Z — отмена. Сохраните перед запуском игры.")
func _add_model(path: String) -> void:
	var scene = load(path)
	if not scene is PackedScene:
		workspace.status("Выберите импортированную 3D-модель или сцену.")
		return
	var node = scene.instantiate()
	var valid := node is Node3D
	node.free()
	if not valid:
		workspace.status("Корень сцены должен быть Node3D.")
		return
	var p := PROFILE.new()
	p.id = "weapon_%d" % Time.get_ticks_usec()
	p.title = path.get_file().get_basename()
	p.model = scene
	p.hidden_nodes = PackedStringArray()
	_append(p)
func _duplicate() -> void:
	var p: DGDWeaponProfile = workspace.current_profile().duplicate(true)
	p.id = "weapon_%d" % Time.get_ticks_usec()
	p.title += " — копия"
	_append(p)
func _append(profile: DGDWeaponProfile) -> void:
	for i in 6: profile.pose_at(i)
	var next: Array[DGDWeaponProfile] = library.profiles.duplicate()
	next.append(profile)
	var undo := get_undo_redo()
	undo.create_action("Оружие IK: добавить профиль", UndoRedo.MERGE_DISABLE, library)
	undo.add_do_property(library,"profiles",next)
	undo.add_undo_property(library,"profiles",library.profiles.duplicate())
	undo.add_do_method(self,"_changed")
	undo.add_undo_method(self,"_changed")
	undo.commit_action()
	workspace.selected = next.size()-1
	workspace.refresh()
func _save() -> void:
	if not _dirty: return
	var problem := library.validation_error()
	if not problem.is_empty():
		workspace.status(problem)
		return
	var error := ResourceSaver.save(library,PATH)
	if error == OK:
		_dirty = false
		workspace.status("Сохранено. Перезапустите игру для применения профилей.")
	else: workspace.status("Ошибка сохранения: " + error_string(error))
func _save_external_data() -> void: _save()
func _apply_changes() -> void: _save()
func _build() -> bool:
	_save()
	var problem := library.validation_error()
	if not problem.is_empty(): workspace.status(problem)
	return not _dirty and problem.is_empty()

func _inspector_edited(key: String) -> void:
	var object := EditorInterface.get_inspector().get_edited_object()
	if object in library.profiles:
		_changed(key)
		return
	for profile in library.profiles:
		if object in profile.poses:
			_changed(key)
			return

func _handles(object: Object) -> bool:
	return object == library or object is DGDWeaponProfile or object is DGDWeaponPose

func _edit(object: Object) -> void:
	if not workspace: return
	for i in library.profiles.size():
		var p := library.profiles[i]
		if object == p or object in p.poses:
			workspace.selected = i
			if object in p.poses: workspace.state = p.poses.find(object)
			workspace.refresh()
			return
