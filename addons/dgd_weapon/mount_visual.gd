@tool
extends Node3D
class_name DGDWeaponMountVisual
## Rigid (non-IK) attachment point for a weapon slot that is NOT currently in
## hand -- ТЗ §2 "предусмотреть настройку положения и вращения каждого
## крепления" / "исключить одновременное отображение одного оружия в руках и
## на креплении". Parented directly under the Skeleton3D by Player (same spot
## DGDWeaponModifier.weapon_root uses), so its `transform` is skeleton-local --
## no arm IK involved, only a rigid bone-follow, same maths
## DGDWeaponModifier already uses for its own holster case.
##
## Reuses the existing weapon model pipeline (DGDWeaponAssets.instantiate_weapon)
## so a mounted weapon is the same asset/scale as the in-hand one, just without
## the IK solve -- and reuses DGDWeaponProfile.transform_at() for the
## position/rotation-degrees convention already used throughout this addon.
const ASSETS = preload("res://addons/dgd_weapon/assets.gd")

var model: Node3D
var current_profile_id: String = ""

## Rebuilds the displayed model only when the profile actually changed --
## called every visual-pose tick, so this must be cheap on the common
## (unchanged) path.
func show_profile(profile: DGDWeaponProfile) -> void:
	var id: String = profile.id if profile else ""
	if id == current_profile_id:
		visible = profile != null
		return
	if is_instance_valid(model):
		remove_child(model)
		model.queue_free()
	model = null
	current_profile_id = id
	if profile:
		model = ASSETS.instantiate_weapon(profile)
		add_child(model)
	visible = profile != null

func apply_transform(bone_pose: Transform3D, position: Vector3, rotation_degrees: Vector3) -> void:
	transform = bone_pose * DGDWeaponProfile.transform_at(position, rotation_degrees)
