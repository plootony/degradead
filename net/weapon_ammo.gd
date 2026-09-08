extends Node
class_name DGDWeaponAmmo
## Replicated scalars cover the active weapon. The archive changes only on
## weapon swaps, so firing does not resend the entire inventory each time.
var magazine: int = -1
var reserve: int = 0
var reload_until: float = 0.0
var active_profile: String = ""
var archive: String = "{}"
var processed_shot: int = 0
var reload_nonce: int = 0
var _source: Node
var _pending_shots: Array[int] = []
var _predicted_reload_until := 0.0
var _pending_reload := 0
var _local_reload_nonce := 0
var _observed_life := -1
var _observed_profile := ""
var _observed_reload := 0.0
var _last_view: Dictionary = {}

func bind_player(player: Node) -> void:
	_source = player
	if Fusion.is_master_client(): server_tick(float(Fusion.get_network_time()))

func settings() -> DGDFirearmSettings:
	return _source.call("get_firing_settings")

func server_tick(now: float) -> void:
	if not Fusion.is_master_client() or not is_instance_valid(_source): return
	if active_profile != _source.get("_weapon_profile_id") or magazine < 0:
		select_profile()
	if _source.get("_hp") <= 0 or _source.get("_weapon_slot") != 0:
		reload_until = 0.0
	elif reload_until > 0.0 and now >= reload_until:
		var transfer := mini(maxi(0,int(settings().value("magazine_size"))-magazine),reserve)
		magazine += transfer
		reserve -= transfer
		reload_until = 0.0

func select_profile() -> void:
	if not Fusion.is_master_client(): return
	var inventory = JSON.parse_string(archive)
	if not inventory is Dictionary: inventory = {}
	var magazines: Dictionary = inventory.get("magazines",{})
	var reserves: Dictionary = inventory.get("reserves",{})
	if not active_profile.is_empty() and magazine >= 0:
		magazines[active_profile] = magazine
		var previous = _source.get("weapon_library").find_profile(active_profile)
		if previous and previous.firing:
			reserves[previous.firing.ammo_key()] = reserve
	active_profile = _source.get("_weapon_profile_id")
	var p := settings()
	magazine = clampi(int(magazines.get(active_profile,p.value("magazine_size"))),0,int(p.value("magazine_size")))
	reserve = clampi(int(reserves.get(p.ammo_key(),p.value("reserve_ammo"))),0,9999)
	archive = JSON.stringify({"magazines":magazines,"reserves":reserves})
	reload_until = 0.0

func reset_life() -> void:
	if not Fusion.is_master_client(): return
	archive = "{}"
	active_profile = ""
	magazine = -1
	reload_until = 0.0
	select_profile()

func receive_shot(sequence: int, now: float) -> bool:
	if not Fusion.is_master_client() or sequence <= processed_shot: return false
	processed_shot = sequence # Also acknowledge rejected/empty/cooldown attempts.
	server_tick(now)
	return magazine > 0 and reload_until <= 0.0

func consume_shot() -> void:
	if Fusion.is_master_client(): magazine = maxi(0,magazine-1)

func start_reload(now: float, nonce: int) -> bool:
	if not Fusion.is_master_client() or nonce <= reload_nonce: return false
	reload_nonce = nonce
	server_tick(now)
	if _source.get("_hp") <= 0 or _source.get("_weapon_slot") != 0 or reload_until > 0.0:
		return false
	if magazine >= int(settings().value("magazine_size")) or reserve <= 0:
		return false
	reload_until = now + settings().value("reload_time")
	return true

func predict_shot(sequence: int) -> void:
	_pending_shots.append(sequence)
	sync_view()

func predict_reload() -> int:
	_local_reload_nonce = maxi(_local_reload_nonce,reload_nonce)+1
	_pending_reload = _local_reload_nonce
	_predicted_reload_until = float(Fusion.get_network_time())+settings().value("reload_time")
	sync_view()
	return _pending_reload

func reload_result(nonce: int, deadline: float) -> void:
	if nonce != _pending_reload: return
	_pending_reload = 0
	_predicted_reload_until = maxf(0,deadline)
	sync_view()

func cancel_prediction() -> void:
	_predicted_reload_until = 0.0
	_pending_reload = 0

func _owned() -> bool:
	return is_instance_valid(_source) and _source.call("_has_input_authority")

func is_reloading() -> bool:
	if not is_instance_valid(_source) or _source.get("_hp") <= 0 or _source.get("_weapon_slot") != 0: return false
	if _owned() and _source.get("_wanted_weapon") != 0: return false
	return reload_deadline() > float(Fusion.get_network_time())

func reload_deadline() -> float:
	return maxf(reload_until,_predicted_reload_until if _owned() else 0.0)

func _locally_completed_reload() -> bool:
	return _owned() and _source.get("_hp") > 0 and _source.get("_weapon_slot") == 0 and _source.get("_wanted_weapon") == 0 and reload_until > 0 and float(Fusion.get_network_time()) >= reload_until

func predicted_magazine() -> int:
	if active_profile != _source.get("_weapon_profile_id") or magazine < 0: return 0
	var amount := magazine
	# Complete locally at the shared deadline; host still validates every shot.
	if _locally_completed_reload():
		amount += mini(maxi(0,int(settings().value("magazine_size"))-magazine),reserve)
	if _owned():
		for sequence in _pending_shots:
			if sequence > processed_shot: amount -= 1
	return maxi(0,amount)

func get_view() -> Dictionary:
	var stock := reserve
	if _locally_completed_reload():
		stock -= mini(maxi(0,int(settings().value("magazine_size"))-magazine),reserve)
	return {"magazine":predicted_magazine(),"reserve":maxi(0,stock),"type":settings().ammo_key(),"reloading":is_reloading(),"seconds":maxi(0,ceili(reload_deadline()-float(Fusion.get_network_time()))),"armed":_source.get("_weapon_slot")==0}

func sync_view() -> void:
	if not is_instance_valid(_source): return
	if _observed_life != _source.get("_life_id") or _observed_profile != _source.get("_weapon_profile_id"):
		_pending_shots.clear()
		cancel_prediction()
		_observed_life = _source.get("_life_id")
		_observed_profile = _source.get("_weapon_profile_id")
	_pending_shots = _pending_shots.filter(func(sequence): return sequence > processed_shot)
	if reload_until > 0 or (_observed_reload > 0 and reload_until <= 0): _predicted_reload_until = 0.0
	_observed_reload = reload_until
	if _owned():
		var view := get_view()
		if view != _last_view:
			_last_view = view
			MatchServer.local_ammo_changed.emit(view)
