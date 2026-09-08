@tool
extends RefCounted
var failures := 0
func check(ok: bool, label: String):
	if not ok: failures += 1
	print("[WEAPON EDITOR] ", label, " ", "PASS" if ok else "FAIL")
func run(plugin: EditorPlugin) -> void:
	await plugin.get_tree().create_timer(1.0).timeout
	plugin._open()
	await plugin.get_tree().process_frame
	var ui = plugin.workspace
	if "--preview-only" in OS.get_cmdline_user_args():
		ui.preview.playing = false
		ui.preview.seek(0.2)
		for i in 12: await plugin.get_tree().process_frame
		plugin._open()
		await RenderingServer.frame_post_draw
		ui.get_viewport().get_texture().get_image().save_png("/tmp/dgd-weapon-editor.png")
		plugin.get_tree().quit()
		return
	var p = ui.current_profile()
	var manager = plugin.get_undo_redo()
	var history = manager.get_history_undo_redo(manager.get_object_history_id(plugin.library))
	check(ui.is_visible_in_tree(), "workspace_visible")
	for i in 6:
		ui._states.item_selected.emit(i)
		check(ui.preview.pose_index == i, "pose_%d" % i)
	ui._states.item_selected.emit(0)
	ui.preview.playing = false
	ui.preview.seek(0.2)
	for i in 30: await plugin.get_tree().process_frame
	check(ui.preview.modifier.validation_error.is_empty(), "preview_skeleton")
	for i in 7:
		ui.target = i
		ui.refresh()
		var expected: Vector3 = ui.selected_object().get(ui.POSITION_KEYS[i])
		check(ui.preview.value_from_world(i,ui.preview.point_for(i)).distance_to(expected) < 0.0001, "marker_coordinates_%d" % i)
	ui.target = 2
	ui.refresh()
	var old: Vector3 = p.left_position
	ui._position[0].value = old.x + 0.02
	check(is_equal_approx(p.left_position.x,old.x+0.02), "numeric_edit")
	history.undo()
	check(p.left_position.is_equal_approx(old), "undo")
	history.redo()
	check(is_equal_approx(p.left_position.x,old.x+0.02), "redo")
	plugin._save()
	var saved = ResourceLoader.load(plugin.PATH,"",ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	check(saved.default_profile().left_position.is_equal_approx(p.left_position), "saved_profile")
	history.undo()
	plugin._save()
	var count: int = plugin.library.profiles.size()
	plugin._duplicate()
	check(plugin.library.profiles.size()==count+1 and ui.current_profile().id != p.id, "duplicate_unique_weapon")
	check(ui.current_profile().pose_at(0) != p.pose_at(0), "independent_pose_resources")
	history.undo()
	plugin._save()
	plugin._add_model("res://player/weapon/aks74.fbx")
	check(plugin.library.profiles.size()==count+1, "add_model")
	var next_id: String = ui.current_profile().id
	plugin._edit_property(plugin.library,"default_id",next_id)
	check(plugin.library.default_profile().id == next_id, "choose_game_weapon")
	history.undo()
	history.undo()
	plugin._save()
	ui.selected = 0
	ui.state = 0
	ui.target = 2
	ui.refresh()
	for i in 30: await plugin.get_tree().process_frame
	var preview = ui.preview
	var screen: Vector2 = preview.camera.unproject_position(preview.point_for(2)) * preview.size / Vector2(preview._viewport.size)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = screen
	preview._gui_input(press)
	check(preview._drag and preview.selected == 2, "pick_left_grip")
	var motion := InputEventMouseMotion.new()
	motion.position = screen + Vector2(15,0)
	preview._gui_input(motion)
	check(not p.left_position.is_equal_approx(old), "drag_grip")
	press.pressed = false
	preview._gui_input(press)
	history.undo()
	plugin._save()
	check(p.left_position.is_equal_approx(old) and plugin.library.profiles.size()==count, "restored_defaults")
	if "--visual" in OS.get_cmdline_user_args():
		plugin._open()
		await plugin.get_tree().create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		ui.get_viewport().get_texture().get_image().save_png("/tmp/dgd-weapon-editor.png")
	print("[WEAPON EDITOR RESULT] failures=",failures)
	plugin.get_tree().quit(0 if failures==0 else 1)
