@tool
extends Resource
class_name DGDWeaponProfile
const POSE = preload("res://addons/dgd_weapon/pose.gd")
const STATES: Array[String] = ["Стоя", "Стоя — прицел", "Присед", "Присед — прицел", "Лёжа", "Лёжа — прицел"]
const HAND_BASIS := Basis(Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1))
@export var id := "aks74"
@export var title := "AKS-74"
@export var model: PackedScene = preload("res://player/weapon/aks74.fbx")
@export_range(0.1, 2.0, 0.01) var model_length := 0.9
@export var hidden_nodes := PackedStringArray(["54539", "54539 case", "ak74 30rnd empty bakelite mag"])
# Weapon and grips use metres, independent of the imported model units.
@export var mount_position := Vector3(0.09775, 0.17091, 0.03)
@export var mount_rotation := Vector3(0, 180, 90)
@export var right_position := Vector3(-0.17091, -0.09775, 0.03)
@export var right_rotation := HAND_BASIS.inverse().get_euler() * 180.0 / PI
@export var left_position := Vector3(0.16, -0.035, 0.025)
@export var left_rotation := Vector3(0, 0, -90)
# Pole offsets are added to the pre-IK animated elbows, in skeleton-local axes.
@export var right_pole := Vector3(-0.08, -0.12, 0.0)
@export var left_pole := Vector3(0.08, -0.12, 0.0)
@export var muzzle_position := Vector3(0.559, 0.0177, 0)
@export var muzzle_rotation := Vector3(0, -90, 0)
@export var holster_position := Vector3(0, 0, -0.2)
@export var holster_rotation := Basis(Vector3(0.454, 0.891, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(0.891, -0.454, 0.0)).orthonormalized().get_euler() * 180.0 / PI
@export_range(1, 30, 0.5) var blend_speed := 14.0
@export var poses: Array[DGDWeaponPose] = []
@export var right_upper := "mixamorig_RightArm"
@export var right_lower := "mixamorig_RightForeArm"
@export var right_hand := "mixamorig_RightHand"
@export var left_upper := "mixamorig_LeftArm"
@export var left_lower := "mixamorig_LeftForeArm"
@export var left_hand := "mixamorig_LeftHand"
@export var back_bone := "mixamorig_Spine2"

func pose_at(index: int) -> DGDWeaponPose:
	while poses.size() < 6: poses.append(POSE.new())
	index = clampi(index, 0, 5)
	if poses[index] == null: poses[index] = POSE.new()
	return poses[index]

static func transform_at(position: Vector3, degrees: Vector3) -> Transform3D:
	return Transform3D(Basis.from_euler(degrees * PI / 180.0), position)
