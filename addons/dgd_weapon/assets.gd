@tool
extends RefCounted
class_name DGDWeaponAssets
static func find_type(node: Node, type: Variant) -> Node:
	if is_instance_of(node, type): return node
	for child in node.get_children():
		var found := find_type(child, type)
		if found: return found
	return null
static func bounds(node: Node, transform: Transform3D = Transform3D.IDENTITY) -> AABB:
	var points: Array[Vector3] = []
	_collect_bounds(node, transform, points)
	if points.is_empty(): return AABB()
	var box := AABB(points[0], Vector3.ZERO)
	for point in points: box = box.expand(point)
	return box
static func _collect_bounds(node: Node, transform: Transform3D, points: Array[Vector3]) -> void:
	if node is MeshInstance3D:
		for i in 8: points.append(transform * node.get_aabb().get_endpoint(i))
	for child in node.get_children():
		_collect_bounds(child, transform * child.transform if child is Node3D else transform, points)
static func instantiate_weapon(profile: DGDWeaponProfile) -> Node3D:
	if not profile or not profile.model: return Node3D.new()
	var instance := profile.model.instantiate()
	if not instance is Node3D:
		instance.free()
		return Node3D.new()
	var model := instance as Node3D
	for child in model.get_children():
		if child.name in profile.hidden_nodes:
			model.remove_child(child)
			child.free()
	var box := bounds(model, model.transform)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest > 0.0001: model.scale *= clampf(profile.model_length, 0.1, 2.0) / longest
	return model
static func merge_clip(target: AnimationLibrary, scene: PackedScene, name: String, looping: bool) -> void:
	if target.has_animation(name) or not scene: return
	var temp := scene.instantiate()
	var player := find_type(temp, AnimationPlayer) as AnimationPlayer
	if player:
		for key in player.get_animation_list():
			if key == "RESET": continue
			var animation: Animation = player.get_animation(key).duplicate()
			animation.loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE
			for track in animation.get_track_count():
				if animation.track_get_type(track) != Animation.TYPE_POSITION_3D or not String(animation.track_get_path(track)).ends_with("mixamorig_Hips"): continue
				if animation.track_get_key_count(track) == 0: continue
				var first: Vector3 = animation.track_get_key_value(track, 0)
				for k in animation.track_get_key_count(track):
					var value: Vector3 = animation.track_get_key_value(track, k)
					animation.track_set_key_value(track, k, Vector3(first.x, value.y, first.z))
			target.add_animation(name, animation)
			break
	temp.free()
