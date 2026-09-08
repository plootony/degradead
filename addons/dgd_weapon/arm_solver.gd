@tool
extends RefCounted
class_name DGDArmSolver
## Analytic two-bone IK. Only rotations change; bone lengths never stretch.
static func solve(s: Skeleton3D, chain: PackedInt32Array, target: Transform3D, pole: Vector3, weight: float) -> float:
	weight = clampf(weight, 0, 1)
	if chain.size() != 3: return 0.0
	if weight <= 0: return s.get_bone_global_pose(chain[2]).origin.distance_to(target.origin)
	var old: Array[Quaternion] = []
	for bone in chain: old.append(s.get_bone_pose_rotation(bone))
	var a := s.get_bone_global_pose(chain[0]).origin
	var b := s.get_bone_global_pose(chain[1]).origin
	var c := s.get_bone_global_pose(chain[2]).origin
	var upper := a.distance_to(b)
	var lower := b.distance_to(c)
	if upper < 0.00001 or lower < 0.00001: return 0.0
	var ray := target.origin - a
	var length := ray.length()
	var direction := ray / length if length > 0.00001 else (c - a).normalized()
	if direction.is_zero_approx(): direction = Vector3.FORWARD
	var reach := clampf(length, absf(upper - lower) + 0.00001, upper + lower - 0.00001)
	var side := pole - a
	side -= direction * side.dot(direction)
	if side.length_squared() < 0.000001:
		side = b - a
		side -= direction * side.dot(direction)
	if side.length_squared() < 0.000001:
		side = direction.cross(Vector3.UP if absf(direction.y) < 0.9 else Vector3.RIGHT)
	side = side.normalized()
	var along := (upper * upper - lower * lower + reach * reach) / (2.0 * reach)
	var elbow := a + direction * along + side * sqrt(maxf(0, upper * upper - along * along))
	rotate_bone_toward(s, chain[0], b - a, elbow - a)
	b = s.get_bone_global_pose(chain[1]).origin
	c = s.get_bone_global_pose(chain[2]).origin
	rotate_bone_toward(s, chain[1], c - b, a + direction * reach - b)
	set_global_rotation(s, chain[2], target.basis.orthonormalized().get_rotation_quaternion())
	var solved: Array[Quaternion] = []
	for bone in chain: solved.append(s.get_bone_pose_rotation(bone))
	for i in 3: s.set_bone_pose_rotation(chain[i], old[i].slerp(solved[i], weight))
	return s.get_bone_global_pose(chain[2]).origin.distance_to(target.origin)
static func rotate_bone_toward(s: Skeleton3D, bone: int, from: Vector3, to: Vector3) -> void:
	if from.length_squared() < 0.0000001 or to.length_squared() < 0.0000001: return
	var rotation := Quaternion(from.normalized(), to.normalized())
	set_global_rotation(s, bone, rotation * s.get_bone_global_pose(bone).basis.orthonormalized().get_rotation_quaternion())
static func set_global_rotation(s: Skeleton3D, bone: int, rotation: Quaternion) -> void:
	var parent := s.get_bone_parent(bone)
	var parent_rotation := Quaternion.IDENTITY if parent < 0 else s.get_bone_global_pose(parent).basis.orthonormalized().get_rotation_quaternion()
	s.set_bone_pose_rotation(bone, parent_rotation.inverse() * rotation)
