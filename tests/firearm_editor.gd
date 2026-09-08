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
	var capacity:int=old.magazine_size
	var caliber:String=old.ammo_type
	var mode:int=old.fire_mode
	ui.fields.magazine_size.value=capacity+1
	ui._ammo_type.text="9×19 тест"
	ui._ammo_type.text_changed.emit(ui._ammo_type.text)
	ui._mode.item_selected.emit(1-mode)
	check(old.magazine_size==capacity+1 and old.ammo_type=="9×19 тест" and old.fire_mode==1-mode,"ammo_controls")
	plugin.save()
	saved=ResourceLoader.load(plugin.PATH,"",ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	check(saved.default_profile().firing.magazine_size==capacity+1 and saved.default_profile().firing.ammo_type=="9×19 тест" and saved.default_profile().firing.fire_mode==1-mode,"ammo_save_reload")
	for i in 3: history.undo()
	plugin.save()
	check(old.magazine_size==capacity and old.ammo_type==caliber and old.fire_mode==mode,"ammo_undo")
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
