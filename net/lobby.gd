extends Node3D
## Main scene (run/main_scene in project.godot). Builds the (non-networked,
## identical-on-every-peer) test arena, shows a minimal join UI, connects to
## Photon via the Fusion singleton, and spawns a player.tscn instance for every
## player that joins the room (Шаг 4a lobby + Шаг 2/3 test ground).
##
## Deliberately not using Fusion's scene-streaming API (load_scene/SceneLoadMode)
## -- the arena is static, tiny, and identical for both clients just by virtue of
## being part of the one main scene everyone starts from, so there is nothing to
## stream. Only the players themselves are networked (via FusionSpawner).

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")

var _spawner: Node
var _players_root: Node3D
var _spawn_points: Array[Vector3] = []

var _join_panel: PanelContainer
var _status_label: Label
var _room_input: LineEdit
var _hud: Control
var _injury_panel: Control
var _combat_panel: VBoxContainer
var _inventory_panel: Control
var _hp_label: Label
var _weapon_label: Label
var _stats_label: Label
var _expecting_room: bool = false
var _join_button: Button
var _joining: bool = false


func _ready() -> void:
	_build_arena()
	_build_spawner()
	_build_ui()

	if Engine.has_singleton("Fusion"):
		Fusion.connected_to_photon.connect(_on_connected_to_photon)
		Fusion.connection_failed.connect(_on_connection_failed)
		Fusion.connection_status_changed.connect(_on_connection_status_changed)
		Fusion.room_joined.connect(_on_room_joined)
		if Fusion.has_signal("room_left"):
			Fusion.room_left.connect(_on_room_left)
		Fusion.player_joined.connect(_on_player_joined)
		Fusion.player_left.connect(_on_player_left)
		Fusion.master_client_changed.connect(_on_master_client_changed)
		# Diagnostic dump: confirms what the native extension actually resolved
		# from project.godot's [fusion] section (app id / mode / region), so a
		# single test run tells us whether those settings are even being read,
		# independent of whatever room-join outcome we get.
		print("[Fusion diag] app_id=%s sim_mode=%s default_region=%s" % [
			Fusion.get_configured_app_id(), Fusion.get_simulation_mode(), Fusion.get_default_region()
		])
	else:
		push_error("Lobby: 'Fusion' singleton not found -- is addons/fusion enabled/reimported?")

	# Diagnostic-only: `godot --path . -- --autojoin` presses Join automatically,
	# so a headless/console run can exercise connect->join without a real click.
	if "--autojoin" in OS.get_cmdline_user_args():
		call_deferred("_on_join_pressed")


# ---------------------------------------------------------------------------
# Static test arena: flat ground + a couple of cover boxes + 2 spawn points.
# ---------------------------------------------------------------------------

func _build_arena() -> void:
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = Sky.new()
	environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment = environment
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)

	# 200x200 floor: the first pass used 20x20 and players simply ran off the
	# edge and fell forever within a few seconds of holding W.
	_add_box(Vector3(200, 0.5, 200), Vector3(0, -0.25, 0), Color(0.35, 0.35, 0.38))
	for cover in [Vector3(6, 0.9, 0), Vector3(-6, 0.9, 4), Vector3(0, 0.9, -8), Vector3(10, 0.9, 10)]:
		_add_box(Vector3(1.8, 1.8, 1.8), cover, Color(0.5, 0.3, 0.2))
	# Low perimeter walls around the play area so you can't wander off by accident.
	var half := 30.0
	for wall in [Vector3(0, 1.5, -half), Vector3(0, 1.5, half)]:
		_add_box(Vector3(half * 2.0, 3.0, 1.0), wall, Color(0.3, 0.3, 0.34))
	for wall in [Vector3(-half, 1.5, 0), Vector3(half, 1.5, 0)]:
		_add_box(Vector3(1.0, 3.0, half * 2.0), wall, Color(0.3, 0.3, 0.34))

	# Two spawn points far enough apart to make an "явно нецелевой выстрел" easy
	# to set up manually while testing (aim away from the other spawn point).
	_spawn_points = [Vector3(-4, 0, -4), Vector3(4, 0, 4), Vector3(-12, 0, 8), Vector3(12, 0, -10)]
	MatchServer.set_spawn_points(_spawn_points)


func _add_box(size: Vector3, pos: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	body.collision_layer = NetConfig.layer_mask(NetConfig.ENVIRONMENT_LAYER_BIT)
	body.collision_mask = 0

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	box_mesh.material = mat
	mesh_inst.mesh = box_mesh
	body.add_child(mesh_inst)

	add_child(body)


# ---------------------------------------------------------------------------
# Networked player spawning.
# ---------------------------------------------------------------------------

func _build_spawner() -> void:
	_players_root = Node3D.new()
	_players_root.name = "PlayersRoot"
	add_child(_players_root)

	_spawner = ClassDB.instantiate("FusionSpawner") as Node
	_spawner.name = "FusionSpawner"
	add_child(_spawner)
	_spawner.call("add_spawnable_scene", PLAYER_SCENE)
	_spawner.set("spawn_path", NodePath("../PlayersRoot"))


func _on_player_joined(player_id: int, player_name: String) -> void:
	print("Fusion: player joined -> id=%d name=%s" % [player_id, player_name])
	if not Fusion.is_master_client() or MatchServer.get_player(player_id):
		return
	var spawn_pos: Vector3 = MatchServer.next_spawn_point()
	# spawn() returns the new node directly, so configure it synchronously here.
	# (The pre-spawn Callable parameter was tried first and never fired in this
	# preview build -- every player ended up with input_authority 0, so their
	# own client never saw has_input_authority() become true and never made its
	# camera current: that was the "second window stays grey" bug.)
	var node: Node = _spawner.call("spawn", PLAYER_SCENE, Callable())
	if not node:
		push_warning("Lobby: spawn() returned null for player %d" % player_id)
		return
	_configure_spawned_player(node, player_id, spawn_pos)


func _configure_spawned_player(node: Node, player_id: int, spawn_pos: Vector3) -> void:
	node.global_position = spawn_pos
	var replicator: Node = node.get_node_or_null("FusionServerReplicator")
	if not replicator:
		push_warning("Lobby: spawned player %d has no FusionServerReplicator child" % player_id)
		return
	# input_authority is method-only on FusionServerReplicator (it is absent
	# from the class's registered PropertyName list, unlike root_path /
	# owner_mode), so .set("input_authority", ...) silently no-ops here.
	replicator.call("set_input_authority", player_id)
	MatchServer.register_player(node)
	print("[Lobby diag] spawned player_id=%d -> input_authority readback=%s" % [
		player_id, replicator.call("get_input_authority")
	])


func _on_player_left(player_id: int, _was_active: bool) -> void:
	print("Fusion: player left -> id=%d" % player_id)
	if Fusion.is_master_client():
		var player := MatchServer.get_player(player_id)
		if player:
			_spawner.call("despawn", player)


func _on_master_client_changed(_old_id: int, _new_id: int) -> void:
	if not Fusion.is_master_client():
		return
	# Defer until Fusion has applied ownership and room membership changes.
	call_deferred("_remove_departed_players")


func _remove_departed_players() -> void:
	if not Fusion.is_in_room() or not Fusion.is_master_client():
		return
	var active: Array[int] = []
	for member in Fusion.get_room().call("get_players"):
		if not member.call("get_is_inactive"):
			active.append(member.call("get_number"))
	for player in _players_root.get_children():
		if player.call("get_player_id") not in active:
			_spawner.call("despawn", player)


# ---------------------------------------------------------------------------
# Minimal join UI (LineEdit + Button + status Label), per ТЗ "UI - минимум".
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_join_panel = PanelContainer.new()
	_join_panel.set_anchors_preset(Control.PRESET_CENTER)
	layer.add_child(_join_panel)

	var vbox := VBoxContainer.new()
	_join_panel.add_child(vbox)

	_room_input = LineEdit.new()
	_room_input.text = _initial_room_code()
	_room_input.custom_minimum_size = Vector2(220, 0)
	vbox.add_child(_room_input)

	_join_button = Button.new()
	_join_button.text = "Join"
	_join_button.pressed.connect(_on_join_pressed)
	vbox.add_child(_join_button)

	_status_label = Label.new()
	_status_label.text = "Not connected"
	vbox.add_child(_status_label)

	# In-game HUD: hidden until we are actually in a room (the join panel goes
	# away at the same moment so it doesn't sit in the middle of the screen).
	_hud = Control.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.visible = false
	layer.add_child(_hud)

	_injury_panel = preload("res://ui/injury_panel.gd").new()
	_hud.add_child(_injury_panel)
	_injury_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_injury_panel.offset_left = 16
	_injury_panel.offset_right = 116
	_injury_panel.offset_top = 12
	_injury_panel.offset_bottom = 112
	MatchServer.local_injuries_changed.connect(_injury_panel.set_injuries)

	_combat_panel = preload("res://ui/combat_panel.gd").new()
	_hud.add_child(_combat_panel)
	_combat_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_combat_panel.offset_left = -260
	_combat_panel.offset_right = -20
	_combat_panel.offset_top = -128
	_combat_panel.offset_bottom = -20
	_hp_label = _combat_panel.hp_label
	MatchServer.local_ammo_changed.connect(_combat_panel.set_ammo)

	_inventory_panel = preload("res://ui/inventory_panel.gd").new()
	_inventory_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_hud.add_child(_inventory_panel)
	MatchServer.local_player_ready.connect(_inventory_panel.set_player)

	_weapon_label = Label.new()
	_weapon_label.position = Vector2(132, 44)
	_weapon_label.add_theme_font_size_override("font_size", 16)
	_weapon_label.text = ""  # filled by Player._emit_local_status() once it owns input
	_hud.add_child(_weapon_label)
	MatchServer.local_status_changed.connect(_on_local_status_changed)

	var crosshair := Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 28)
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	_hud.add_child(crosshair)

	# Connection / performance stats, top-right. Always visible (also useful
	# while connecting); refreshed on a timer, not every frame.
	_stats_label = Label.new()
	_stats_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_stats_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_stats_label.offset_right = -12
	_stats_label.offset_top = 10
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_stats_label.add_theme_font_size_override("font_size", 15)
	_stats_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_stats_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_stats_label.add_theme_constant_override("shadow_offset_x", 1)
	_stats_label.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(_stats_label)
	var stats_timer := Timer.new()
	stats_timer.wait_time = STATS_REFRESH_SEC
	stats_timer.autostart = true
	stats_timer.timeout.connect(_refresh_stats)
	add_child(stats_timer)
	_refresh_stats()

	MatchServer.local_hp_changed.connect(_on_local_hp_changed)
	_on_local_hp_changed(NetConfig.MAX_HP)


## MatchServer is an autoload that outlives this scene: drop our listeners so a
## scene reload can't leave callables into freed labels hanging on its signals.
func _exit_tree() -> void:
	if is_instance_valid(_combat_panel) and MatchServer.local_ammo_changed.is_connected(_combat_panel.set_ammo):
		MatchServer.local_ammo_changed.disconnect(_combat_panel.set_ammo)
	if is_instance_valid(_injury_panel) and MatchServer.local_injuries_changed.is_connected(_injury_panel.set_injuries):
		MatchServer.local_injuries_changed.disconnect(_injury_panel.set_injuries)
	if is_instance_valid(_inventory_panel) and MatchServer.local_player_ready.is_connected(_inventory_panel.set_player):
		MatchServer.local_player_ready.disconnect(_inventory_panel.set_player)
	if MatchServer.local_status_changed.is_connected(_on_local_status_changed):
		MatchServer.local_status_changed.disconnect(_on_local_status_changed)
	if MatchServer.local_hp_changed.is_connected(_on_local_hp_changed):
		MatchServer.local_hp_changed.disconnect(_on_local_hp_changed)


func _on_local_status_changed(text: String) -> void:
	_weapon_label.text = text


const STATS_REFRESH_SEC: float = 0.25


func _refresh_stats() -> void:
	var lines: Array[String] = []
	lines.append("FPS %d  (%.1f ms)" % [Engine.get_frames_per_second(), _frame_ms])
	lines.append("physics %d Hz" % Engine.physics_ticks_per_second)
	if not Engine.has_singleton("Fusion"):
		lines.append("Fusion: not loaded")
		_stats_label.text = "\n".join(lines)
		return

	var status: int = Fusion.get_connection_status()
	lines.append("net: %s" % NetConfig.CONNECTION_STATUS_NAMES.get(status, str(status)))
	lines.append("region %s" % Fusion.get_default_region())
	if status >= NetConfig.CONNECTION_STATUS_CONNECTED:
		# get_rtt() returns seconds (observed ~0.2 against the "us" region).
		lines.append("ping %.0f ms" % (float(Fusion.get_rtt()) * 1000.0))
	if Fusion.is_in_room():
		var room = Fusion.get_room()
		var room_name: String = _room_input.text
		var count: int = 0
		if room:
			room_name = room.room_name
			count = room.player_count
		lines.append("room '%s'  players %d" % [room_name, count])
		lines.append("me id=%d  %s" % [
			Fusion.get_local_player_id(), "MASTER (server)" if Fusion.is_master_client() else "client"
		])
		lines.append("net time %.1f s" % float(Fusion.get_network_time()))
		lines.append("spawned avatars %d" % _players_root.get_child_count())
	_stats_label.text = "\n".join(lines)


var _frame_ms: float = 0.0

func _process(delta: float) -> void:
	# Smoothed frame time for the stats block (FPS alone hides hitches).
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)


func _on_local_hp_changed(hp: int) -> void:
	_combat_panel.set_hp(hp)


## Diagnostic/testing convenience: `godot ... -- --room=SOMECODE` overrides the
## default room code (Photon rooms stick around for EmptyRoomTtlMs after the
## last peer leaves, so repeated --autojoin test runs would otherwise keep
## rejoining the same stale room as a non-master player and never spawn).
func _initial_room_code() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--room="):
			return arg.substr(len("--room="))
	return NetConfig.DEFAULT_ROOM_CODE


func _on_join_pressed() -> void:
	if not Engine.has_singleton("Fusion") or _joining or Fusion.is_in_room():
		return
	_room_input.text = _room_input.text.strip_edges()
	if _room_input.text.is_empty():
		_status_label.text = "Enter a room code"
		return
	_joining = true
	_join_button.disabled = true
	if Fusion.is_connected_to_photon():
		_on_connected_to_photon()
	else:
		_status_label.text = "Connecting..."
		Fusion.connect_to_photon("", "", NetConfig.NETWORK_VERSION)


func _on_connected_to_photon() -> void:
	_status_label.text = "Connected, joining room '%s'..." % _room_input.text
	_expecting_room = true
	var options = ClassDB.instantiate("FusionRoomOptions")
	options.call("set_player_ttl_ms", 0)
	options.call("set_empty_room_ttl_ms", 0)
	Fusion.join_or_create_room(_room_input.text, options)


func _on_connection_failed(reason: String) -> void:
	_joining = false
	_join_button.disabled = false
	_expecting_room = false
	_status_label.text = "Connection failed: %s" % reason
	print("[Fusion diag] connection_failed: %s" % reason)


## Fusion has no dedicated "room join failed" signal -- on a rejected
## CreateGame/JoinGame (e.g. the "Unsupported Plugin" error from the server),
## the status reverts from JoiningRoom back to ConnectedToPhoton instead of
## RoomJoined ever firing. Catching that reversion is what actually surfaces
## the failure in the UI instead of it only ever showing up in the console.
func _on_connection_status_changed(status: int) -> void:
	print("[Fusion diag] connection_status_changed -> %d" % status)
	if status == NetConfig.CONNECTION_STATUS_DISCONNECTED or status == NetConfig.CONNECTION_STATUS_ERROR:
		_on_room_left()
	if _expecting_room and status == NetConfig.CONNECTION_STATUS_CONNECTED:
		_expecting_room = false
		_joining = false
		_join_button.disabled = false
		_status_label.text = "Room join failed (see console for the exact Photon error)."


func _on_room_joined() -> void:
	_joining = false
	_join_button.disabled = false
	_expecting_room = false
	_status_label.text = "In room '%s' (%d players)" % [
		_room_input.text, Fusion.get_room().player_count if Fusion.get_room() else 1
	]
	print("[Lobby] %s" % _status_label.text)
	# The connect UI has done its job: hide it so it doesn't cover the game and
	# doesn't eat the click that captures the mouse.
	_join_panel.visible = false
	_hud.visible = true


func _on_room_left() -> void:
	_joining = false
	_expecting_room = false
	_join_button.disabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for player in _players_root.get_children():
		player.queue_free()
	MatchServer.reset_session()
	_join_panel.visible = true
	_hud.visible = false
	_injury_panel.set_injuries(0, NetConfig.MAX_HP)
	_inventory_panel.player = null
	_inventory_panel.visible = false
	_status_label.text = "Left room"
