@tool
extends RefCounted
var failures:=0
func check(ok: bool,label: String):
	if not ok: failures+=1
	print("[FIREARM EDITOR] ",label," ","PASS" if ok else "FAIL")
func run(plugin: EditorPlugin) -> void:
	await plugin.get_tree().create_timer(1).timeout
	plugin.open()
	var ui=plugin.workspace
	await plugin.get_tree().process_frame
	check(ui.is_visible_in_tree(),"workspace_visible")
	check(ui.fields.size()==DGDFirearmSettings.LIMITS.size(),"all_numeric_settings")
	var old=ui.settings()
	var damage:float=old.damage
	ui.fields.damage.value=damage+1
	check(old.damage==damage+1,"edit_damage")
	var manager=plugin.get_undo_redo()
	var history=manager.get_history_undo_redo(manager.get_object_history_id(plugin.library))
	history.undo();check(old.damage==damage,"undo")
	history.redo();check(old.damage==damage+1,"redo")
	plugin.save()
	var saved=ResourceLoader.load(plugin.PATH,"",ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	check(saved.default_profile().firing.damage==damage+1,"save_reload")
	history.undo();plugin.save()
	plugin.preset(3)
	check(ui.settings().pellet_count()==8,"shotgun_preset")
	for i in 20: await plugin.get_tree().process_frame
	ui.fire()
	check(ui.pattern.points.size()==8 and ui.preview.effects.fired_count>0,"shotgun_preview")
	if "--visual" in OS.get_cmdline_user_args():
		plugin.open()
		await plugin.get_tree().create_timer(0.3).timeout
		ui._cooldown=0;ui.fire()
		await RenderingServer.frame_post_draw
		ui.get_viewport().get_texture().get_image().save_png("/tmp/dgd-firearm-editor.png")
	history.undo();plugin.save()
	check(ui.settings()==old and old.damage==damage,"restore_profile")
	print("[FIREARM EDITOR RESULT] failures=",failures)
	plugin.get_tree().quit(0 if failures==0 else 1)
