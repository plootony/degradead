@tool
extends Resource
class_name DGDWeaponMountConfig
## Where an inactive weapon slot's model rigidly attaches on the skeleton
## (ТЗ §2: "главное и дополнительное оружие закрепляются за левым и правым
## плечом; пистолет — на поясе", "предусмотреть настройку положения и
## вращения каждого крепления"). Same transform convention as
## DGDWeaponProfile's mount/holster fields (addons/dgd_weapon/profile.gd):
## position in metres, rotation in degrees, both bone-local.
##
## Only used for the two weapon slots that are NOT currently in hand -- the
## active slot renders through the existing DGDWeaponModifier IK pipeline
## instead (see addons/dgd_weapon/mount_visual.gd for the rigid-attach math,
## which mirrors DGDWeaponModifier's own holster case).
@export var main_bone := "mixamorig_Spine2"
@export var main_position := Vector3(-0.14, 0.05, -0.06)
@export var main_rotation := Vector3(0, 200, 80)

@export var secondary_bone := "mixamorig_Spine2"
@export var secondary_position := Vector3(0.14, 0.05, -0.06)
@export var secondary_rotation := Vector3(0, -20, -80)

@export var pistol_bone := "mixamorig_Hips"
@export var pistol_position := Vector3(0.12, -0.02, 0.02)
@export var pistol_rotation := Vector3(0, 90, 0)

## weapon_slot is Player.WeaponSlot.MAIN/SECONDARY/PISTOL (0/1/2).
func bone_for(weapon_slot: int) -> String:
	match weapon_slot:
		0: return main_bone
		1: return secondary_bone
		2: return pistol_bone
		_: return ""

func position_for(weapon_slot: int) -> Vector3:
	match weapon_slot:
		0: return main_position
		1: return secondary_position
		2: return pistol_position
		_: return Vector3.ZERO

func rotation_for(weapon_slot: int) -> Vector3:
	match weapon_slot:
		0: return main_rotation
		1: return secondary_rotation
		2: return pistol_rotation
		_: return Vector3.ZERO
