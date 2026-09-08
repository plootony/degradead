extends Node
class_name DGDPlayerInventory
## Replaces net/weapon_ammo.gd: the master-authoritative inventory + ammo/reload
## bookkeeping for one Player, child node "Inventory" in player.tscn. Same
## predict-request-confirm shape the old ammo node used (see reload_nonce/
## processed_shot below) now widened from "one magazine + one reserve int" to
## a full DGDInventory snapshot (ТЗ §5: host confirms moves/equip/ammo spend;
## duplicate/replayed requests are rejected by nonce watermarks).
##
## `slots_json` is the single source of truth for slot contents AND magazines
## (ТЗ §3: "остаток магазина хранить отдельно у каждого экземпляра оружия") --
## it replicates through the same FusionReplicationConfig mechanism that
## already carries _hp/_life_id/etc., so late join and host migration need no
## extra code (see player.tscn).
var slots_json: String = "[]"
var reload_until: float = 0.0
var reload_nonce: int = 0
var move_nonce: int = 0
var processed_shot: int = 0

var _source: Node
var _data := DGDInventory.new()
var _catalog: DGDItemCatalog
var _weapon_library: DGDWeaponLibrary
var _starter_loadout: DGDStarterLoadout

## Master-only bookkeeping (never replicated): which weapon slot start_reload()
## was called for. Needed because _weapon_slot itself can change mid-reload
## (three independently equippable weapons now, not one) -- without this,
## server_tick()/complete would silently credit whichever slot happens to be
## active WHEN THE TIMER ELAPSES instead of the one that was actually reloading.
var reload_slot: int = -1
var _pending_shots: Array[int] = []
var _predicted_reload_until := 0.0
var _pending_reload := 0
var _local_reload_nonce := 0
var _local_move_nonce := 0
var _observed_life := -1
var _observed_reload := 0.0
var _observed_slots_json := ""
var _last_view: Dictionary = {}


func bind_player(player: Node) -> void:
	_source = player
	_catalog = player.get("item_catalog")
	_weapon_library = player.get("weapon_library")
	_starter_loadout = player.get("starter_loadout")
	_data.deserialize(slots_json)
	_observed_slots_json = slots_json
	if Fusion.is_master_client():
		# Lazy first-time grant, same "still at its never-initialized sentinel"
		# trick the old weapon_ammo.gd used (there: magazine < 0) -- the very
		# first spawn never goes through Player.broadcast_respawn(), only
		# actual death/respawn does.
		if _is_empty():
			grant_starter_kit()
		var slot := _weapon_slot()
		if DGDInventory.is_weapon_slot(slot):
			player.set("_weapon_profile_id", _data.active_weapon_profile_id(_catalog, slot))
		server_tick(float(Fusion.get_network_time()))


func _is_empty() -> bool:
	for s in _data.slots:
		if not String(s["item"]).is_empty(): return false
	return true


func settings() -> DGDFirearmSettings:
	return _source.call("get_firing_settings")


func _weapon_slot() -> int:
	return int(_source.get("_weapon_slot")) if is_instance_valid(_source) else -1


func _flush() -> void:
	slots_json = _data.serialize()
	_observed_slots_json = slots_json


func _weapon_profile(item: DGDItemDef) -> DGDWeaponProfile:
	if not item or not _weapon_library: return null
	return _weapon_library.find_profile(item.weapon_profile_id)


func _reserve_for(slot: int) -> int:
	var profile := _weapon_profile(_data.weapon_item(_catalog, slot))
	return _data.total_ammo(_catalog, profile.firing.ammo_key()) if profile and profile.firing else 0


# ---------------------------------------------------------------------------
# Master-authoritative mutation.
# ---------------------------------------------------------------------------

func server_tick(now: float) -> void:
	if not Fusion.is_master_client() or not is_instance_valid(_source): return
	var slot := _weapon_slot()
	# Dying, going unarmed, OR switching to a DIFFERENT weapon slot than the
	# one that's actually reloading all cancel it -- see reload_slot's doc.
	if int(_source.get("_hp")) <= 0 or not DGDInventory.is_weapon_slot(slot) or (reload_until > 0.0 and slot != reload_slot):
		reload_until = 0.0
	elif reload_until > 0.0 and now >= reload_until:
		_complete_reload(reload_slot)
		reload_until = 0.0
	_flush()


func _complete_reload(slot: int) -> void:
	var item := _data.weapon_item(_catalog, slot)
	var profile := _weapon_profile(item)
	if not profile or not profile.firing: return
	var capacity := int(profile.firing.value("magazine_size"))
	var mag := _data.magazine_at(slot)
	var need := maxi(0, capacity - mag)
	var taken := _data.remove_ammo(_catalog, profile.firing.ammo_key(), need)
	_data.set_magazine_at(slot, mag + taken)


## Called from Player.rpc_request_fire on the master. Mirrors the old
## receive_shot() contract exactly: the sequence watermark advances even for a
## rejected/empty/cooldown attempt, so a retried request never double-fires.
func receive_shot(sequence: int, now: float) -> bool:
	if not Fusion.is_master_client() or sequence <= processed_shot: return false
	processed_shot = sequence
	server_tick(now)
	var slot := _weapon_slot()
	return DGDInventory.is_weapon_slot(slot) and _data.magazine_at(slot) > 0 and reload_until <= 0.0


func consume_shot() -> void:
	if not Fusion.is_master_client(): return
	var slot := _weapon_slot()
	if DGDInventory.is_weapon_slot(slot):
		_data.set_magazine_at(slot, maxi(0, _data.magazine_at(slot) - 1))
	_flush()


func start_reload(now: float, nonce: int) -> bool:
	if not Fusion.is_master_client() or nonce <= reload_nonce: return false
	reload_nonce = nonce
	server_tick(now)
	var slot := _weapon_slot()
	if int(_source.get("_hp")) <= 0 or not DGDInventory.is_weapon_slot(slot) or reload_until > 0.0:
		return false
	var profile := _weapon_profile(_data.weapon_item(_catalog, slot))
	if not profile or not profile.firing:
		return false
	if _data.magazine_at(slot) >= int(profile.firing.value("magazine_size")) or _reserve_for(slot) <= 0:
		return false
	reload_until = now + profile.firing.value("reload_time")
	reload_slot = slot
	_flush()
	return true


## Called from Player.rpc_request_move on the master. `nonce` must strictly
## increase (ТЗ §5: "исключить... повторное выполнение одного запроса") --
## the watermark still advances on a rejected move so a stale retry can't
## re-attempt it either.
func server_move(nonce: int, from: int, to: int) -> bool:
	if not Fusion.is_master_client() or nonce <= move_nonce: return false
	move_nonce = nonce
	var moved := _data.move(_catalog, from, to)
	_flush()
	return moved


## Server-only: grants the configurable starter kit (ТЗ §5). Called from
## Player.broadcast_respawn() instead of the old reset_life().
func grant_starter_kit() -> void:
	if not Fusion.is_master_client(): return
	_data.apply_loadout(_catalog, _weapon_library, _starter_loadout)
	reload_until = 0.0
	_flush()


# ---------------------------------------------------------------------------
# Owner-side prediction (mirrors net/weapon_ammo.gd exactly, just reading
# magazine/reserve from the inventory snapshot instead of flat ints).
# ---------------------------------------------------------------------------

func predict_shot(sequence: int) -> void:
	_pending_shots.append(sequence)
	sync_view()


func predict_reload() -> int:
	_local_reload_nonce = maxi(_local_reload_nonce, reload_nonce) + 1
	_pending_reload = _local_reload_nonce
	_predicted_reload_until = float(Fusion.get_network_time()) + settings().value("reload_time")
	sync_view()
	return _pending_reload


func reload_result(nonce: int, deadline: float) -> void:
	if nonce != _pending_reload: return
	_pending_reload = 0
	_predicted_reload_until = maxf(0, deadline)
	sync_view()


func cancel_prediction() -> void:
	_predicted_reload_until = 0.0
	_pending_reload = 0


## Sends a move request and does NOT predict it locally -- the moved item only
## visibly relocates once the master's authoritative slots_json replicates
## back. Deliberately simpler than shot/reload prediction: item moves are not
## latency-sensitive (the inventory UI already blocks combat while open), and
## this removes an entire class of "duplicate under rapid drag" bugs by
## construction (see plan's "Ключевые архитектурные решения").
func request_move() -> int:
	_local_move_nonce = maxi(_local_move_nonce, move_nonce) + 1
	return _local_move_nonce


func _owned() -> bool:
	return is_instance_valid(_source) and _source.call("_has_input_authority")


func is_reloading() -> bool:
	if not is_instance_valid(_source) or int(_source.get("_hp")) <= 0: return false
	var slot := _weapon_slot()
	if not DGDInventory.is_weapon_slot(slot): return false
	if _owned() and int(_source.get("_wanted_weapon")) != slot: return false
	return reload_deadline() > float(Fusion.get_network_time())


func reload_deadline() -> float:
	return maxf(reload_until, _predicted_reload_until if _owned() else 0.0)


func _locally_completed_reload() -> bool:
	if not _owned() or int(_source.get("_hp")) <= 0: return false
	var slot := _weapon_slot()
	return DGDInventory.is_weapon_slot(slot) and int(_source.get("_wanted_weapon")) == slot \
		and reload_until > 0 and float(Fusion.get_network_time()) >= reload_until


func predicted_magazine() -> int:
	var slot := _weapon_slot()
	if not DGDInventory.is_weapon_slot(slot): return 0
	var amount := _data.magazine_at(slot)
	if amount < 0: return 0
	if _locally_completed_reload():
		var profile := _weapon_profile(_data.weapon_item(_catalog, slot))
		var capacity := int(profile.firing.value("magazine_size")) if profile and profile.firing else amount
		amount += mini(maxi(0, capacity - amount), _reserve_for(slot))
	if _owned():
		for sequence in _pending_shots:
			if sequence > processed_shot: amount -= 1
	return maxi(0, amount)


func get_view() -> Dictionary:
	var slot := _weapon_slot()
	var armed := DGDInventory.is_weapon_slot(slot)
	var stock := _reserve_for(slot) if armed else 0
	if _locally_completed_reload():
		var profile := _weapon_profile(_data.weapon_item(_catalog, slot))
		var capacity := int(profile.firing.value("magazine_size")) if profile and profile.firing else 0
		stock -= mini(maxi(0, capacity - _data.magazine_at(slot)), stock)
	return {
		"magazine": predicted_magazine(), "reserve": maxi(0, stock), "type": settings().ammo_key(),
		"reloading": is_reloading(), "seconds": maxi(0, ceili(reload_deadline() - float(Fusion.get_network_time()))),
		"armed": armed,
	}


func sync_view() -> void:
	if not is_instance_valid(_source): return
	if slots_json != _observed_slots_json:
		_data.deserialize(slots_json)
		_observed_slots_json = slots_json
	if _observed_life != int(_source.get("_life_id")):
		_pending_shots.clear()
		cancel_prediction()
		_observed_life = int(_source.get("_life_id"))
	_pending_shots = _pending_shots.filter(func(sequence): return sequence > processed_shot)
	if reload_until > 0 or (_observed_reload > 0 and reload_until <= 0): _predicted_reload_until = 0.0
	_observed_reload = reload_until
	if _owned():
		var view := get_view()
		if view != _last_view:
			_last_view = view
			MatchServer.local_ammo_changed.emit(view)


# ---------------------------------------------------------------------------
# Read-only accessors for UI / weapon-mount visuals -- every peer's own copy
# of _data, kept current by sync_view() above.
# ---------------------------------------------------------------------------

func reserve_for_active() -> int:
	return _reserve_for(_weapon_slot())

## Loose-ammo pool for whatever weapon occupies `weapon_slot`, regardless of
## which slot is currently active -- test/UI convenience around _reserve_for().
func total_ammo_for(weapon_slot: int) -> int:
	return _reserve_for(weapon_slot)

func item_catalog() -> DGDItemCatalog:
	return _catalog

func item_id_at(slot_index: int) -> String:
	return _data.item_id_at(slot_index)

func count_at(slot_index: int) -> int:
	return _data.count_at(slot_index)

func magazine_at(weapon_slot: int) -> int:
	return _data.magazine_at(weapon_slot)

func weapon_profile_id_at(weapon_slot: int) -> String:
	return _data.active_weapon_profile_id(_catalog, weapon_slot)

func can_place(item_id: String, slot_index: int) -> bool:
	return _data.can_place(_catalog, item_id, slot_index)
