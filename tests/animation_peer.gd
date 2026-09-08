extends SceneTree
## Two live peers moving forward; observer clip must not oscillate with snapshots.
var elapsed := 0.0
var paired_at := -1.0
var samples := 0
var wrong_clip := 0
var switches := 0
var last_clip := ""
var velocity_min := INF
var velocity_max := 0.0
var idle_seen := false
var baseline := "--baseline" in OS.get_cmdline_user_args()
func _initialize(): call_deferred("start")
func start():
	var scene = load("res://net/lobby.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
func _physics_process(delta):
	elapsed += delta
	var server = root.get_node("MatchServer")
	var local = server.get_player(Fusion.get_local_player_id())
	var remote = server.get_player(2 if Fusion.get_local_player_id() == 1 else 1)
	if local and remote:
		if paired_at < 0: paired_at = elapsed
		var t := elapsed - paired_at
		local._automove = t < 5.0
		if t > 1.5 and t < 4.5:
			samples += 1
			var clip: String = remote._current_clip
			if clip != "run_forward": wrong_clip += 1
			if not last_clip.is_empty() and last_clip != clip: switches += 1
			last_clip = clip
			var speed: float = Vector2(remote.velocity.x, remote.velocity.z).length()
			velocity_min = minf(velocity_min, speed)
			velocity_max = maxf(velocity_max, speed)
		if t > 6.0 and remote._current_clip == "idle": idle_seen = true
	if elapsed > 12:
		var good := samples > 100 and wrong_clip == 0 and switches == 0 and idle_seen
		print("[ANIMATION] ", "PASS" if good else "FAIL", " local=", Fusion.get_local_player_id(), " samples=", samples, " wrong_clip=", wrong_clip, " switches=", switches, " velocity=", velocity_min, "..", velocity_max, " stopped=", idle_seen)
		Fusion.disconnect_from_photon()
		quit(0 if good or baseline else 1)
	return false
