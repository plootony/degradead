extends Node
## Autoload (see [application]/autoload in project.godot). Same NodePath
## (/root/MatchServer) on every peer, which is what lets Fusion's RPC dispatch
## find "the same" receiver on each machine for a node that isn't itself a
## spawned/replicated scene object.
##
## Owns lag-compensated shot resolution (see resolve_shot(); NetConfig.HITBOX_MODE
## only picks which shapes each player records), the master-authoritative
## health bookkeeping, respawn timing (_poll_respawns()), and the pooled
## hit/tracer VFX that every peer plays from the broadcast hit report.

signal hit_reported(shooter_id: int, target_id: int, hit_bone: String, position: Vector3)
## Emitted on every peer whenever the LOCAL player's hp changes (HUD hook).
signal local_hp_changed(hp: int)
signal local_ammo_changed(state: Dictionary)
signal local_injuries_changed(parts: int, hp: int)
## Local player's weapon / view / aim summary line for the HUD.
signal local_status_changed(text: String)
## Fired once, the first physics tick the local Player confirms input
## authority -- lets the inventory UI (built before any player exists) grab a
## reference to call into (ui/inventory_panel.gd).
signal local_player_ready(player: Node)

## Sentinel hit_bone value for a shot that stopped on level geometry.
const HIT_WORLD: String = "world"

var _players: Dictionary = {}  # player_id: int -> Player node
var _shots: Array[Dictionary] = []
var _predictions: Array[Dictionary] = []
var _predicted_tracers: Dictionary = {}
var _seen_reports: Dictionary = {}
var _spawn_points: Array[Vector3] = []
var _next_spawn_index: int = 0


func _ready() -> void:
	process_physics_priority = 20000
	if Engine.has_singleton("Fusion"):
		Fusion.register_broadcast_receiver(self)


## player is a Player node (player/player.gd), kept as a loose Node here on
## purpose: MatchServer is an autoload, loaded before the scene tree exists, and
## a static Player type-hint would force it to eagerly load player.gd, which in
## turn references the MatchServer global at its top level -- a load-order
## cycle that fails with "Identifier not found: MatchServer". Dynamic .call()
## dispatch sidesteps that entirely.
func register_player(player: Node) -> void:
	var id: int = player.call("get_player_id")
	# Player ids start at 1; 0 means input_authority hasn't been assigned yet
	# (registration is retried later from _on_process_input), and registering it
	# would leave a phantom "id=0" duplicate of a real player in the registry.
	if id <= 0:
		return
	# Drop any earlier entry for this same node registered under a stale id.
	for known_id in _players.keys():
		if _players[known_id] == player and known_id != id:
			_players.erase(known_id)
	_players[id] = player
	_ensure_vfx_pools.call_deferred()


func unregister_player(player: Node) -> void:
	# Fusion can clear input_authority before _exit_tree(). Remove by identity.
	for id in _players.keys():
		if _players[id] == player:
			_players.erase(id)


func get_player(player_id: int) -> Node:
	# Do not assign a freed Variant to a typed Node before checking validity.
	var p = _players.get(player_id)
	if not is_instance_valid(p):
		_players.erase(player_id)
		return null
	return p


func set_spawn_points(points: Array[Vector3]) -> void:
	_spawn_points = points


func next_spawn_point() -> Vector3:
	if _spawn_points.is_empty():
		return Vector3.ZERO
	var fallback: Vector3 = _spawn_points[0]
	var best_clearance := -1.0
	for i in _spawn_points.size():
		var index := (_next_spawn_index + i) % _spawn_points.size()
		var point := _spawn_points[index]
		var clearance := INF
		for id in _players.keys():
			var player := get_player(id)
			if player and not player.call("is_dead"):
				clearance = minf(clearance, point.distance_to(player.global_position))
		if clearance >= 1.5:
			_next_spawn_index = index + 1
			return point
		if clearance > best_clearance:
			best_clearance = clearance
			fallback = point
	return fallback


func reset_session() -> void:
	_players.clear()
	_shots.clear()
	_predictions.clear()
	_predicted_tracers.clear()
	_seen_reports.clear()
	_next_spawn_index = 0


func queue_shot(shooter: Node, origin: Vector3, direction: Vector3, rtt: float, life_id: int, sequence: int, muzzle: Vector3, rays: Array[Vector3] = [], firing: DGDFirearmSettings = null, profile_id: String = "") -> void:
	_shots.append({"shooter": weakref(shooter), "origin": origin, "direction": direction,
		"rtt": rtt, "life": life_id, "sequence": sequence, "muzzle": muzzle, "received_at": Time.get_ticks_msec() / 1000.0,"rays":rays,"firing":firing,"profile_id":profile_id})


func predict_shot(shooter: Node, sequence: int, life: int, origin: Vector3, direction: Vector3, muzzle: Vector3, rays: Array[Vector3] = [], max_range: float = 100.0) -> void:
	# The input event sends its RPC immediately; the visual query waits at most
	# one physics tick, where space queries are safe. Never draw an unclipped ray.
	_predictions.append({"shooter": weakref(shooter), "sequence": sequence, "life": life,
		"origin": origin, "direction": direction, "muzzle": muzzle,"rays":rays,"range":max_range})


func _draw_predictions() -> void:
	var pending := _predictions
	_predictions = []
	for shot in pending:
		var shooter = shot["shooter"].get_ref()
		if not is_instance_valid(shooter) or shooter.get("_life_id") != shot["life"]:
			continue
		var id: int = shooter.call("get_player_id")
		var rays: Array = shot.rays if not shot.rays.is_empty() else [shot.direction]
		var shapes := _collect_shot_shapes(-1.0)
		for i in rays.size():
			var key := _pellet_key(id,shot.life,shot.sequence,i)
			var result := trace_shot(id,shot.origin,rays[i],shot.muzzle,-1.0,shot.range,shapes)
			var confirmed: Dictionary = shot.get("confirmed_ends",{})
			var end: Vector3 = confirmed.get(i,shot.get("confirmed_end",result.position))
			var tracer := draw_tracer(shot.muzzle,end)
			if tracer:
				tracer.set_meta("shot_key",key)
				_predicted_tracers[key]={"node":weakref(tracer),"expires":Time.get_ticks_msec()+2000}



func _physics_process(_delta: float) -> void:
	if not Fusion.is_in_room():
		_predictions.clear()
	else:
		_draw_predictions()
	if not Fusion.is_in_room() or not Fusion.is_master_client():
		_shots.clear()
		return
	var now := float(Fusion.get_network_time())
	for player in _players.values():
		if is_instance_valid(player): player.server_tick_ammo(now)
	var pending := _shots
	_shots = []
	for shot in pending:
		var shooter: Node = shot["shooter"].get_ref()
		if not shooter or shooter.get("_life_id") != shot["life"] or shooter.call("is_dead"):
			continue
		var id: int = shooter.call("get_player_id")
		if shot.firing:
			var results := resolve_volley(id,shot.origin,shot.rays,shot.rtt,shot.received_at,shot.muzzle,shot.firing)
			var payload := ShotBatch.encode(shot.sequence,shot.life,shot.muzzle,shot.profile_id,results)
			Fusion.rpc(Callable(shooter,"rpc_report_volley"),payload)
		else:
			var result := resolve_shot(id, shot.origin, shot.direction, shot.rtt, shot.received_at, shot.muzzle)
			var visuals := ShotVisuals.encode(shot.sequence,shot.life,result.target_life,shot.muzzle,result.contact,result.normal)
			Fusion.rpc(Callable(shooter,"rpc_report_hit"),id,result.target_id,result.hit_bone,result.position,result.hp_left,visuals)

	_poll_respawns()


# ---------------------------------------------------------------------------
# Shot resolution (master only).
# ---------------------------------------------------------------------------

## Server-side hit resolution. Called from the shooter's Player node on the
## master peer -- the RPC itself has to be addressed to a networked node, so
## Player owns the RPC endpoints and delegates the logic here.
## shooter_rtt is the shooter's own Fusion.get_rtt() at fire time, sent with
## the request -- see _rewind_for().
## Returns {target_id, hit_bone, position, hp_left}. hp_left is the target's
## remaining hp after this shot (-1 when nobody was hit).
func resolve_shot(shooter_id: int, origin: Vector3, direction: Vector3, shooter_rtt: float, received_at: float = -1.0, muzzle: Vector3 = Vector3.INF) -> Dictionary:
	var now := Time.get_ticks_msec() / 1000.0 if received_at < 0.0 else received_at
	var target_time := now - _rewind_for(shooter_id, shooter_rtt)
	var result := trace_shot(shooter_id, origin, direction, origin if not muzzle.is_finite() else muzzle, target_time)
	var target := get_player(result["target_id"])
	if target:
		result["hp_left"] = target.call("server_apply_damage", NetConfig.damage_for(result["hit_bone"]), result["hit_bone"])
	return result


func resolve_volley(shooter_id: int, origin: Vector3, rays: Array, rtt: float, received_at: float, muzzle: Vector3, firing: DGDFirearmSettings) -> Array:
	var results: Array = []
	var target_time := received_at-_rewind_for(shooter_id,rtt)
	var cached_shapes := _collect_shot_shapes(target_time)
	# Query all pellets before applying damage: death must not erase the target
	# halfway through this single trigger's history sample.
	for ray in rays.slice(0,32):
		results.append(trace_shot(shooter_id,origin,ray,muzzle,target_time,firing.value("max_range"),cached_shapes))
	for hit in results:
		var target := get_player(hit.target_id)
		if target:
			hit.hp_left=target.call("server_apply_damage",DGDBallistics.damage_at(firing,origin.distance_to(hit.position),hit.hit_bone),hit.hit_bone)
	return results


func _collect_shot_shapes(target_time: float) -> Dictionary:
	var result: Dictionary = {}
	for id in _players.keys():
		var player := get_player(id)
		if not player: continue
		var history: HitboxHistory = player.call("get_hitbox_history")
		if history: result[id] = player.call("get_hitbox_shapes") if target_time<0 else history.sample_at(target_time)
	return result


## Read-only query shared by prediction and authoritative resolution. A negative
## sample time uses currently displayed shapes; prediction never applies damage.
func trace_shot(shooter_id: int, origin: Vector3, direction: Vector3, muzzle: Vector3, target_time: float, max_range: float = NetConfig.MAX_SHOT_RANGE, cached_shapes: Dictionary = {}) -> Dictionary:
	var dir := direction.normalized()

	# Level geometry occludes: nothing further than the first wall counts.
	var best_dist := clampf(max_range,1,500)
	var result := {"target_id": -1, "hit_bone": "", "position": origin + dir * best_dist, "hp_left": -1, "target_life": -1, "contact": Vector3.ZERO, "normal": -dir}
	var space_state := get_tree().root.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * best_dist)
	query.collision_mask = NetConfig.layer_mask(NetConfig.ENVIRONMENT_LAYER_BIT)
	query.collide_with_areas = false
	var shooter := get_player(shooter_id)
	if shooter:
		var eye: Vector3 = shooter.global_position + Vector3.UP * float(shooter.STANCE_PIVOT_Y[shooter.get("_stance")])
		var obstruction := PhysicsRayQueryParameters3D.create(eye, origin)
		obstruction.collision_mask = query.collision_mask
		var blocked := space_state.intersect_ray(obstruction)
		if blocked.is_empty():
			obstruction.to = muzzle
			blocked = space_state.intersect_ray(obstruction)
		if not blocked.is_empty():
			result["hit_bone"] = HIT_WORLD
			result["position"] = blocked["position"]
			result["normal"] = blocked["normal"]
			return result
	var wall := space_state.intersect_ray(query)
	if not wall.is_empty():
		best_dist = origin.distance_to(wall["position"])
		result["hit_bone"] = HIT_WORLD
		result["position"] = wall["position"]
		result["normal"] = wall["normal"]

	for pid in _players.keys():
		if pid == shooter_id:
			continue
		var player := get_player(pid)
		if not player:
			continue
		var history: HitboxHistory = player.call("get_hitbox_history")
		if not history:
			continue
		var shapes: Array
		if cached_shapes.has(pid): shapes = cached_shapes[pid]
		else: shapes = player.call("get_hitbox_shapes") if target_time < 0.0 else history.sample_at(target_time)
		for shape in shapes:
			var dist := _ray_capsule_hit_distance(origin, dir, shape["a"], shape["b"], shape["r"])
			if dist >= 0.0 and dist < best_dist:
				best_dist = dist
				result["target_id"] = pid
				result["hit_bone"] = shape["key"]
				var hit_position := origin + dir * dist
				result["position"] = hit_position
				var frame: Transform3D = shape.get("frame", player.global_transform)
				result["contact"] = frame.affine_inverse() * hit_position
				result["target_life"] = int(player.get("_life_id"))
				var axis_point := Geometry3D.get_closest_point_to_segment(hit_position, shape["a"], shape["b"])
				result["normal"] = (frame.basis.inverse() * (hit_position - axis_point)).normalized()

	# A shoulder camera can see around a corner while the barrel is blocked.
	# Confirm the aim point is reachable from the actual muzzle as well.
	if shooter:
		var barrel_query := PhysicsRayQueryParameters3D.create(muzzle, result["position"])
		barrel_query.collision_mask = NetConfig.layer_mask(NetConfig.ENVIRONMENT_LAYER_BIT)
		var blocked := space_state.intersect_ray(barrel_query)
		if not blocked.is_empty():
			result["target_id"] = -1
			result["hit_bone"] = HIT_WORLD
			result["position"] = blocked["position"]
			result["normal"] = blocked["normal"]
			result["target_life"] = -1

	return result


## How far back to rewind a target for a shot from shooter_id, in seconds.
##
## Photon Cloud relays everything, so a client shooter sees the master's state
## one way late (rtt_shooter/2 + rtt_master/2), rendered a further
## PROXY_INTERPOLATION_SEC behind that, and the fire request takes another one
## way to come back -- at the moment it is processed here, the target the
## shooter aimed at is rtt_shooter + rtt_master + interpolation in the past.
## This is an estimate: exponential smoothing has no exact historical tick.
## The master itself shoots at what it simulates locally: no rewind at all.
## Using only the master's own get_rtt() here (the earlier version) rewound
## by the wrong peer's latency and collapsed to ~0 in the local test setup.
func _rewind_for(shooter_id: int, shooter_rtt: float) -> float:
	if not NetConfig.LAG_COMPENSATION or not Engine.has_singleton("Fusion"):
		return 0.0
	if shooter_id == Fusion.get_local_player_id():
		return 0.0
	var rewind := maxf(shooter_rtt, 0.0) + float(Fusion.get_rtt()) + NetConfig.PROXY_INTERPOLATION_SEC
	return clampf(rewind, 0.0, NetConfig.MAX_REWIND_SEC)


## Closest positive distance along ray(origin, dir) to the capsule from a to b
## with radius r (a == b is a sphere), or -1.0 if it misses.
static func _ray_capsule_hit_distance(origin: Vector3, dir: Vector3, a: Vector3, b: Vector3, r: float) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 1e-8:
		return _ray_sphere_hit_distance(origin, dir, a, r)
	var axis := ab / sqrt(len2)
	var best := -1.0
	# Infinite cylinder around the axis, using only the components
	# perpendicular to it; a cylinder hit only counts inside the segment.
	var oa := origin - a
	var d_perp := dir - axis * dir.dot(axis)
	var oa_perp := oa - axis * oa.dot(axis)
	var qa := d_perp.length_squared()
	if qa > 1e-8:
		var qb := 2.0 * d_perp.dot(oa_perp)
		var qc := oa_perp.length_squared() - r * r
		var disc := qb * qb - 4.0 * qa * qc
		if disc >= 0.0:
			var sq := sqrt(disc)
			for t in [(-qb - sq) / (2.0 * qa), (-qb + sq) / (2.0 * qa)]:
				if t < 0.0:
					continue
				var h: float = (oa + dir * t).dot(axis)
				if h >= 0.0 and h * h <= len2:
					best = t
					break  # ascending order, first valid is the nearest
	# The two hemispherical end caps.
	for c in [a, b]:
		var t := _ray_sphere_hit_distance(origin, dir, c, r)
		if t >= 0.0 and (best < 0.0 or t < best):
			best = t
	return best


static func _ray_sphere_hit_distance(origin: Vector3, dir: Vector3, center: Vector3, radius: float) -> float:
	var oc := origin - center
	var b := oc.dot(dir)
	var c := oc.dot(oc) - radius * radius
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	var sq := sqrt(disc)
	var t := -b - sq
	if t < 0.0:
		t = -b + sq
	return t if t >= 0.0 else -1.0


# ---------------------------------------------------------------------------
# Hit report (every peer) + respawn timing (master).
# ---------------------------------------------------------------------------

## Broadcast receiver, executed on ALL peers (rpc_report_hit is call_local) --
## this is where both clients end up showing the identical result.
func report_hit(shooter_id: int, target_id: int, hit_bone: String, position: Vector3, hp_left: int, payload: PackedByteArray) -> void:
	var visual := ShotVisuals.decode(payload)
	if visual.is_empty():
		return
	var order := Vector2i(visual["shooter_life"], visual["sequence"])
	var previous: Vector2i = _seen_reports.get(shooter_id, Vector2i(-1, -1))
	if order.x < previous.x or (order.x == previous.x and order.y <= previous.y):
		return
	_seen_reports[shooter_id] = order
	_display_hit(shooter_id,target_id,hit_bone,position,hp_left,visual)

func report_volley(shooter_id: int, payload: PackedByteArray) -> void:
	var shot := ShotBatch.decode(payload)
	if shot.is_empty(): return
	var order := Vector2i(shot.shooter_life,shot.sequence)
	var previous: Vector2i = _seen_reports.get(shooter_id,Vector2i(-1,-1))
	if order.x<previous.x or (order.x==previous.x and order.y<=previous.y): return
	_seen_reports[shooter_id]=order
	var shooter := get_player(shooter_id)
	if shooter and shooter_id != Fusion.get_local_player_id():
		shooter.call("play_shot_effects",shot.sequence,shot.shooter_life,shot.profile,false)
	for i in shot.hits.size():
		var hit: Dictionary = shot.hits[i]
		var visual := {"sequence":shot.sequence,"shooter_life":shot.shooter_life,"muzzle":shot.muzzle,"target_life":hit.target_life,"contact":hit.contact,"normal":hit.normal,"pellet":i}
		_display_hit(shooter_id,hit.target_id,hit.hit_bone,hit.position,hit.hp_left,visual)

func _pellet_key(shooter_id: int, life: int, sequence: int, pellet: int) -> String:
	var key := ShotVisuals.shot_key(shooter_id,life,sequence)
	return key if pellet==0 else key+":"+str(pellet)

func _display_hit(shooter_id: int, target_id: int, hit_bone: String, position: Vector3, hp_left: int, visual: Dictionary) -> void:
	if _posdump:
		print("[shot] player %d target %d (%s) at %s -> hp %d" % [shooter_id, target_id, hit_bone, position, hp_left])
	hit_reported.emit(shooter_id, target_id, hit_bone, position)

	var display_position := position
	var normal: Vector3 = visual["normal"]
	var target := get_player(target_id)
	var same_life := target != null and int(target.get("_life_id")) == int(visual["target_life"])
	if target_id != -1 and same_life:
		var frame: Transform3D = target.call("get_hitbox_frame", hit_bone)
		display_position = frame * Vector3(visual["contact"])
		normal = (frame.basis * normal).normalized()
		spawn_impact(display_position, Color(0.8, 0.05, 0.05), normal)
		target.call("apply_hit_result", hp_left, display_position, hit_bone)
	elif target_id == -1 and hit_bone == HIT_WORLD:
		spawn_impact(display_position, Color(0.85, 0.8, 0.6), normal)

	var key := _pellet_key(shooter_id, visual["shooter_life"], visual["sequence"],visual.get("pellet",0))
	if shooter_id == Fusion.get_local_player_id():
		# Correct a still-visible prediction in place; never flash a second line
		# after a slow acknowledgement or modify a slot reused by another shot.
		var predicted: Dictionary = _predicted_tracers.get(key, {})
		_predicted_tracers.erase(key)
		if predicted.is_empty():
			# An acknowledgement can beat the next physics tick on a fast link.
			for pending in _predictions:
				if pending["life"] == visual["shooter_life"] and pending["sequence"] == visual["sequence"]:
					if not pending.has("confirmed_ends"): pending["confirmed_ends"]={}
					pending["confirmed_ends"][visual.get("pellet",0)] = display_position
					if visual.get("pellet",0)==0: pending["confirmed_end"] = display_position
		else:
			var tracer = predicted["node"].get_ref()
			if is_instance_valid(tracer) and tracer.visible and tracer.get_meta("shot_key", "") == key:
				_set_tracer_points(tracer, visual["muzzle"], display_position)
	else:
		draw_tracer(visual["muzzle"], display_position)


func _process(delta: float) -> void:
	_print_posdump(delta)
	var now := Time.get_ticks_msec()
	for key in _predicted_tracers.keys():
		if now >= int(_predicted_tracers[key]["expires"]):
			_predicted_tracers.erase(key)


func _poll_respawns() -> void:
	var now := float(Fusion.get_network_time())
	for pid in _players.keys():
		var player := get_player(pid)
		if player and player.call("is_dead") and float(player.get("_respawn_at")) > 0.0 and now >= float(player.get("_respawn_at")):
			player.call("broadcast_respawn", next_spawn_point())


# ---------------------------------------------------------------------------
# Visual feedback (runs on every peer). Pooled: under automatic fire the old
# new()-per-hit version allocated a particle system + mesh + material (and a
# tracer mesh + material + tween) on every peer for every shot.
# ---------------------------------------------------------------------------

const VFX_POOL_SIZE: int = 64
const IMPACT_LIFETIME_SEC: float = 0.45
const TRACER_FADE_SEC: float = 0.15

var _impact_pool: Array[CPUParticles3D] = []
var _impact_next: int = 0
var _tracer_pool: Array[MeshInstance3D] = []
var _tracer_next: int = 0


func spawn_impact(position: Vector3, color: Color, normal: Vector3 = Vector3.UP) -> void:
	if not _ensure_vfx_pools():
		return
	var particles := _impact_pool[_impact_next]
	_impact_next = (_impact_next + 1) % VFX_POOL_SIZE
	particles.global_position = position
	particles.color = color
	particles.direction = normal.normalized() if normal.length_squared() > 0.0001 else Vector3.UP
	particles.restart()
	particles.emitting = true


## Short-lived line from `from` to `to`.
func draw_tracer(from: Vector3, to: Vector3) -> MeshInstance3D:
	if not _ensure_vfx_pools():
		return null
	var inst := _tracer_pool[_tracer_next]
	_tracer_next = (_tracer_next + 1) % VFX_POOL_SIZE
	_set_tracer_points(inst, from, to)
	inst.set_meta("shot_key", "")
	var old_tween: Tween = inst.get_meta("tween") if inst.has_meta("tween") else null
	if old_tween and old_tween.is_valid():
		old_tween.kill()
	var material := inst.material_override as StandardMaterial3D
	material.albedo_color.a = 1.0
	inst.visible = true
	# Each pool slot has its own material so alpha works in every renderer
	# and one tracer cannot fade another.
	var tween := inst.create_tween()
	tween.tween_property(material, "albedo_color:a", 0.0, TRACER_FADE_SEC)
	tween.tween_callback(func() -> void: inst.visible = false)
	inst.set_meta("tween", tween)
	return inst


func _set_tracer_points(inst: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var mesh := inst.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()


## Lazily builds both pools under the current scene (they're freed with it).
func _ensure_vfx_pools() -> bool:
	var root := get_tree().current_scene
	if not root:
		return false
	if not _impact_pool.is_empty() and is_instance_valid(_impact_pool[0]):
		return true
	_impact_pool.clear()
	_tracer_pool.clear()

	var impact_mesh := SphereMesh.new()
	impact_mesh.radius = 0.03
	impact_mesh.height = 0.06
	var impact_mat := StandardMaterial3D.new()
	impact_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	impact_mat.vertex_color_use_as_albedo = true  # tinted per emitter via CPUParticles3D.color
	impact_mesh.material = impact_mat
	for i in VFX_POOL_SIZE:
		var particles := CPUParticles3D.new()
		particles.one_shot = true
		particles.explosiveness = 1.0
		particles.amount = 16
		particles.lifetime = IMPACT_LIFETIME_SEC
		particles.direction = Vector3.UP
		particles.spread = 65.0
		particles.local_coords = false
		particles.initial_velocity_min = 2.0
		particles.initial_velocity_max = 4.5
		particles.gravity = Vector3(0, -9.8, 0)
		particles.scale_amount_min = 0.5
		particles.scale_amount_max = 1.0
		particles.emitting = false
		particles.mesh = impact_mesh
		root.add_child(particles)
		_impact_pool.append(particles)

	var tracer_mat := StandardMaterial3D.new()
	tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer_mat.albedo_color = Color(1.0, 0.85, 0.4)
	tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for i in VFX_POOL_SIZE:
		var inst := MeshInstance3D.new()
		inst.mesh = ImmediateMesh.new()
		inst.material_override = tracer_mat.duplicate()
		inst.visible = false
		root.add_child(inst)
		_tracer_pool.append(inst)
	return true


# ---------------------------------------------------------------------------
# Headless test hook (`-- --posdump`): periodically log every known player's
# position as seen by THIS peer, so a two-instance run can be checked for
# movement replication without a human at the keyboard.
# ---------------------------------------------------------------------------

var _posdump: bool = "--posdump" in OS.get_cmdline_user_args()
var _posdump_accum: float = 0.0


func _print_posdump(delta: float) -> void:
	if not _posdump:
		return
	_posdump_accum += delta
	if _posdump_accum < 1.0:
		return
	_posdump_accum = 0.0
	if not (Engine.has_singleton("Fusion") and Fusion.is_in_room()):
		return
	var parts: Array[String] = []
	for pid in _players.keys():
		var p := get_player(pid)
		if p:
			parts.append("id=%s pos=%.2f,%.2f,%.2f hp=%s" % [
				pid, p.global_position.x, p.global_position.y, p.global_position.z, p.call("get_hp")
			])
	print("[POS local_id=%d master=%s] %s" % [
		Fusion.get_local_player_id(), Fusion.is_master_client(), "; ".join(parts)
	])
