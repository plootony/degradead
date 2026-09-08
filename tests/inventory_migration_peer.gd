extends SceneTree
## Live 3-peer regression: late join + host migration for the modular
## inventory (replaces ammo_migration_peer.gd). The host starts a reload on
## player 2's MAIN weapon, a third peer joins late, then the host disconnects
## -- which is what forces Photon to promote a new master among the
## remaining peers. The promoted peer (and the late-joining observer) must
## see the exact same slots_json / reload deadline the old host had: no
## reset, no double-grant of the starter kit, no duplicated ammo transfer.
var elapsed := 0.0
var started := -1.0
var joined := -1.0
var role := ""
var seen := {}
var failures := 0

func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.substr(7)
	call_deferred("start")

func start():
	var weapons = load("res://addons/dgd_weapon/library.tres")
	var firing = DGDFirearmSettings.new()
	firing.magazine_size = 3; firing.reload_time = 10.0  # ammo_type stays "5.45×39"
	weapons.default_profile().firing = firing
	var loadout = load("res://inventory/default_loadout.tres")
	loadout.entries = [
		{"slot": 0, "item_id": "aks74", "count": 1},
		{"slot": 3, "item_id": "ammo_545x39", "count": 5},
	]
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene); current_scene = scene

func check(ok: bool, key: String):
	if seen.has(key): return
	seen[key] = true
	if not ok: failures += 1
	print("[INVENTORY MIGRATION] ", key, " ", "PASS" if ok else "FAIL")

func finish():
	print("[INVENTORY MIGRATION RESULT] failures=", failures)
	Fusion.disconnect_from_photon(); quit(0 if failures == 0 else 1)

func _physics_process(delta):
	elapsed += delta
	var server = root.get_node("MatchServer")
	var p = server.get_player(2)
	if Fusion.is_in_room() and p:
		var a = p.get_inventory()
		if role == "host" and started < 0 and elapsed > 5:
			started = elapsed
			a.consume_shot(); a.consume_shot()  # magazine 3 -> 1
			check(a.start_reload(float(Fusion.get_network_time()), 1), "migration_reload_started")
			print("[INVENTORY MIGRATION START]")
		if role == "host" and started > 0 and server.get_player(3):
			if joined < 0: joined = elapsed
			if elapsed - joined > 1:
				check(a.is_reloading(), "late_join_does_not_disturb_reload")
				finish()  # disconnecting here forces Photon to promote a new master

		if role != "host" and a.reload_until > 0:
			check(a.magazine_at(0) == 1 and a.count_at(3) == 5 and a.is_reloading(),
				"late_join_reload" if role == "observer" else "client_reload")

		if role == "client" and Fusion.is_master_client() and seen.has("client_reload"):
			check(a.reload_until > 0 and a.magazine_at(0) == 1, "migration_preserves_deadline")
			if not a.is_reloading() and a.magazine_at(0) == 3 and not seen.has("reload_completed"):
				check(a.count_at(3) == 3, "migrated_master_completes_reload")  # need 2, box 5 -> 3
				a.consume_shot()  # magazine 3 -> 2, leaves room for a second reload
				check(a.start_reload(float(Fusion.get_network_time()), 2), "second_reload_after_migration")
				p._request_weapon_slot(3)  # UNARMED -- generalizes the old "holster cancels reload" rule
				started = elapsed
			if seen.has("migrated_master_completes_reload") and elapsed - started > 1:
				check(a.reload_until == 0 and a.magazine_at(0) == 2 and a.count_at(3) == 3, "unequip_cancels_reload")
				if elapsed - started > 3: finish()

		if role == "observer" and seen.has("late_join_reload") and p._weapon_slot == 3 and a.reload_until == 0:
			check(a.magazine_at(0) == 2 and a.count_at(3) == 3, "observer_sees_post_migration_state")
			finish()
	if elapsed > 35:
		print("[INVENTORY MIGRATION RESULT] timeout ", role, " ", seen)
		Fusion.disconnect_from_photon(); quit(1)
	return false
