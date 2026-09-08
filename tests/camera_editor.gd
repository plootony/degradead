@tool
extends RefCounted
var failures := 0
func check(ok: bool, label: String):
	if not ok: failures += 1
	print("[CAMERA EDITOR] ", label, " ", "PASS" if ok else "FAIL")
func run(plugin: EditorPlugin) -> void:
	await plugin.get_tree().create_timer(1.0).timeout
	plugin._editor_dock.make_visible()
	await plugin.get_tree().process_frame
	var dock = plugin._dock
	var settings = plugin._settings
	check(dock.is_visible_in_tree(), "dock_visible")
	check(dock._inputs.size() == 13, "all_controls")
	for i in 4:
		dock.select_profile(i)
		check(dock.preview.profile == settings.profile_at(i), "select_profile_%d" % i)
	var old: float = settings.first_person.height
	plugin._edit_value(0, "height", old + 0.1)
	check(is_equal_approx(settings.first_person.height, old + 0.1), "edit_value")
	var manager = plugin.get_undo_redo()
	var history = manager.get_history_undo_redo(manager.get_object_history_id(settings))
	history.undo()
	check(is_equal_approx(settings.first_person.height, old), "undo")
	history.redo()
	check(is_equal_approx(settings.first_person.height, old + 0.1), "redo")
	plugin._save()
	var saved = ResourceLoader.load(plugin.PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(is_equal_approx(saved.first_person.height, old + 0.1), "save_to_disk")
	history.undo()
	plugin._save()
	plugin._reset_profile(0)
	check(is_equal_approx(settings.first_person.height, old), "reset_profile")
	history.undo()
	plugin._save()
	dock.select_profile(2)
	dock.preview.walking = true
	dock.preview.fire()
	dock.preview.hit()
	check(dock.preview.rig.motion._shot_strength > 0 and dock.preview.rig.motion._hit_strength > 0, "preview_events")
	if "--visual" in OS.get_cmdline_user_args():
		plugin._editor_dock.make_visible()
		await plugin.get_tree().create_timer(1.0).timeout
		check(dock.preview.rig.camera.position.z > 2.5, "third_person_preview_distance")
		await RenderingServer.frame_post_draw
		dock.get_viewport().get_texture().get_image().save_png("/tmp/dgd-camera-editor.png")
	print("[CAMERA EDITOR RESULT] failures=", failures)
	plugin.get_tree().quit(0 if failures == 0 else 1)
