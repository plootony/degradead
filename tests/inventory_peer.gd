extends SceneTree
## Live two-peer regression for the modular inventory (replaces ammo_peer.gd).
## Covers ТЗ's acceptance list end to end: weapon-slot switching + mount
## display, per-instance magazine persistence, compatible-ammo consumption
## with empty-box removal, and duplicate-request rejection on rapid item
## moves / reloads / weapon switches.
var elapsed := 0.0
var paired_at := -1.0
var seen := {}
var failures := 0
var reports := 0
const MAIN := 0
const SECONDARY := 1
const PISTOL := 2
const AMMO_A := 3  # first universal cell
const AMMO_B := 4  # second universal cell

func _initialize(): call_deferred("start")

func start():
	var weapons = load("res://addons/dgd_weapon/library.tres")
	var firing = DGDFirearmSettings.new()
	firing.magazine_size = 3; firing.reload_time = 1.4; firing.rpm = 300  # ammo_type stays "5.45×39"
	weapons.default_profile().firing = firing
	var other_profile = weapons.default_profile().duplicate(true)
	other_profile.id = "inventory_test_secondary"
	other_profile.firing = other_profile.firing.duplicate(true)
	other_profile.firing.magazine_size = 5
	weapons.profiles.append(other_profile)

	var catalog = load("res://inventory/item_catalog.tres")
	var secondary_item = catalog.find("aks74").duplicate(true)
	secondary_item.id = "inventory_test_secondary_item"
	secondary_item.weapon_profile_id = "inventory_test_secondary"
	catalog.items.append(secondary_item)

	var loadout = load("res://inventory/default_loadout.tres")
	loadout.entries = [
		{"slot": MAIN, "item_id": "aks74", "count": 1},
		{"slot": SECONDARY, "item_id": "inventory_test_secondary_item", "count": 1},
		{"slot": AMMO_A, "item_id": "ammo_545x39", "count": 5},
	]

	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene); current_scene = scene
	root.get_node("MatchServer").hit_reported.connect(func(shooter, _target, _bone, _point):
		if shooter == 2: reports += 1)

func once(key: String) -> bool:
	if seen.has(key): return false
	seen[key] = true
	return true

func check(ok: bool, key: String):
	if not ok: failures += 1
	print("[INVENTORY] ", key, " ", "PASS" if ok else "FAIL")

func fire(p):
	p._look_pitch = 0.8  # Sky; no accidental headshot on the other test peer.
	p._try_fire()

func forged_fire(p):
	p._shot_sequence += 1
	Fusion.rpc_to(-1, Callable(p, "rpc_request_fire"), p._shot_sequence, p._life_id, p._camera.global_position, -p._camera.global_basis.z, float(Fusion.get_rtt()), p.get_muzzle_position(), p._weapon_profile_id)

func _physics_process(delta):
	elapsed += delta
	var server = root.get_node("MatchServer")
	var p = server.get_player(2)
	if Fusion.is_in_room() and p and (server.get_player(1) or paired_at >= 0):
		if paired_at < 0: paired_at = elapsed
		var t := elapsed - paired_at
		var own := Fusion.get_local_player_id() == 2
		var a = p.get_inventory()

		if t > 1 and once("initial"):
			check(a.magazine_at(MAIN) == 3 and a.item_id_at(AMMO_A) == "ammo_545x39" and a.count_at(AMMO_A) == 5, "initial_snapshot")
			check(p._weapon_mounts[SECONDARY].visible and not p._weapon_mounts[MAIN].visible, "secondary_mounted_while_main_active")

		# --- Item moves: relocation, slot-type compatibility, duplicate-nonce rejection ---
		if own and t > 1.5 and once("move1"):
			p.request_move_item(AMMO_A, AMMO_B)
		if t > 2 and once("move1_check"):
			check(a.item_id_at(AMMO_B) == "ammo_545x39" and a.item_id_at(AMMO_A) == "", "move_relocates_item")
		if own and t > 2.2 and once("move_incompatible"):
			p.request_move_item(AMMO_B, PISTOL)  # ammo box does not fit the pistol slot
		if t > 2.6 and once("move_incompatible_check"):
			check(a.item_id_at(PISTOL) == "" and a.item_id_at(AMMO_B) == "ammo_545x39", "incompatible_move_rejected")
		if own and t > 2.8 and once("move_dup"):
			var nonce: int = p._inventory.request_move()
			Fusion.rpc_to(-1, Callable(p, "rpc_request_move"), nonce, AMMO_B, AMMO_A)
			Fusion.rpc_to(-1, Callable(p, "rpc_request_move"), nonce, AMMO_A, AMMO_B)  # replay with the same nonce: must be a no-op
		if t > 3.2 and once("move_dup_check"):
			check(a.item_id_at(AMMO_A) == "ammo_545x39" and a.item_id_at(AMMO_B) == "", "duplicate_move_rejected")
		if own and t > 3.4 and once("move_back"):
			p.request_move_item(AMMO_A, AMMO_B)  # leave the box at AMMO_B for the rest of the run

		# --- Firing / reload / ammo-box depletion ---
		for i in 3:
			if own and t > 4 + i * 0.3 and once("shot%d" % i):
				fire(p)
				check(a.predicted_magazine() == 2 - i, "instant_ammo_%d" % i)
		if t > 5.2 and once("empty"):
			check(a.magazine_at(MAIN) == 0 and reports == 3, "one_report_per_shot")
			if own:
				var before: int = p._shot_sequence
				fire(p); check(before == p._shot_sequence, "empty_blocks_prediction")
				forged_fire(p)
		if own and t > 5.6 and once("reload1"):
			p._request_reload(); check(a.is_reloading() and p._current_clip == "reload", "instant_reload")
		if t > 6.1 and once("during"):
			check(a.is_reloading() and a.magazine_at(MAIN) == 0 and a.count_at(AMMO_B) == 5 and reports == 3, "reload_snapshot_no_early_transfer")
			if own: forged_fire(p)
		if t > 7.6 and once("complete1"):
			check(a.magazine_at(MAIN) == 3 and a.count_at(AMMO_B) == 2 and not a.is_reloading() and reports == 3, "reload_draws_compatible_ammo")

		# --- Drain again and start a second reload; death interrupts it
		# before completion (weapon slot unchanged here -- isolates
		# death-cancellation from the switch-cancellation case below). ---
		if own and t > 8 and once("shot3"): fire(p)
		if own and t > 8.3 and once("shot4"): fire(p)
		if own and t > 8.6 and once("shot5"): fire(p)
		if t > 8.9 and once("drained_again"):
			check(a.magazine_at(MAIN) == 0, "main_drained_again")
		if own and t > 9 and once("reload2"): p._request_reload()
		if t > 9.4 and once("reload2_during"):
			check(a.is_reloading(), "second_reload_started")
		if Fusion.is_master_client() and t > 9.6 and once("kill"):
			p.server_apply_damage(1, "head")
		if t > 10.2 and once("dead"):
			check(p.get_hp() == 0 and not a.is_reloading(), "death_cancels_reload")

		# --- Respawn grants a fresh starter kit ---
		if t > 15.5 and once("respawn"):
			check(p.get_hp() == 100 and a.magazine_at(MAIN) == 3 and a.item_id_at(AMMO_A) == "ammo_545x39" and a.count_at(AMMO_A) == 5, "respawn_grants_starter_kit")
			check(a.magazine_at(SECONDARY) == 5, "respawn_resets_every_slot")
			check(p._weapon_slot == MAIN and p._weapon_mounts[SECONDARY].visible and not p._weapon_mounts[MAIN].visible, "mount_reflects_active_after_respawn")

		# --- Per-instance magazine across a weapon-slot switch ---
		if own and t > 15.8 and once("switch_secondary"):
			p._request_weapon_slot(SECONDARY)
		if t > 16.3 and once("switch_secondary_check"):
			check(p._weapon_slot == SECONDARY and a.magazine_at(SECONDARY) == 5 and a.magazine_at(MAIN) == 3, "per_instance_magazine_preserved")
			check(p._weapon_mounts[MAIN].visible and not p._weapon_mounts[SECONDARY].visible, "mount_shows_inactive_only")

		# --- Switching weapon mid-reload cancels it (not just death), and
		# demonstrates the pooled reserve: SECONDARY's reload draws from
		# MAIN's own ammo box by shared caliber (ТЗ §3, "суммарный доступный
		# запас подходящего калибра"). ---
		if own and t > 16.6 and once("secondary_shot"): fire(p)
		if own and t > 17 and once("reload3"): p._request_reload()
		if t > 17.4 and once("reload3_during"):
			check(a.is_reloading() and a.count_at(AMMO_A) == 5, "pooled_reserve_starts_reload")
		if own and t > 17.6 and once("switch_main_mid_reload"):
			p._request_weapon_slot(MAIN)
		if t > 18.2 and once("switch_cancels_reload"):
			check(not a.is_reloading() and a.magazine_at(SECONDARY) == 4 and a.magazine_at(MAIN) == 3 and a.count_at(AMMO_A) == 5, "switch_cancels_other_slots_reload")

		if t > 19:
			print("[INVENTORY RESULT] failures=", failures)
			Fusion.disconnect_from_photon(); quit(0 if failures == 0 else 1)
	if elapsed > 40:
		print("[INVENTORY RESULT] timeout"); Fusion.disconnect_from_photon(); quit(1)
	return false
