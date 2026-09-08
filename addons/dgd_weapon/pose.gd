@tool
extends Resource
class_name DGDWeaponPose
@export var position := Vector3.ZERO
@export var rotation_degrees := Vector3.ZERO
@export_range(0, 1, 0.01) var right_weight := 1.0
@export_range(0, 1, 0.01) var left_weight := 1.0
