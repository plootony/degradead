@tool
extends Resource
class_name DGDWeaponPlacement
## Free placement of a detached weapon, in skeleton space. Editor state only: it lives in the
## workspace, never in the library, and is baked into the profile mount when the weapon sticks
## back onto the hand. Field names match the profile's mount so the XYZ controls bind unchanged.
@export var mount_position := Vector3.ZERO
@export var mount_rotation := Vector3.ZERO
