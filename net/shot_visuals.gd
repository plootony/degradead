extends RefCounted
class_name ShotVisuals
## Cosmetic metadata for a confirmed shot. Contact/normal are target-frame local
## for player hits and world-space for geometry. Health remains snapshot-owned.
const SIZE: int = 48
static func encode(sequence: int, shooter_life: int, target_life: int, muzzle: Vector3, contact: Vector3, normal: Vector3) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(SIZE)
	data.encode_u32(0, sequence)
	data.encode_u32(4, shooter_life)
	data.encode_s32(8, target_life)
	for i in 3:
		data.encode_float(12 + i * 4, muzzle[i])
		data.encode_float(24 + i * 4, contact[i])
		data.encode_float(36 + i * 4, normal[i])
	return data
static func decode(data: PackedByteArray) -> Dictionary:
	if data.size() != SIZE:
		return {}
	var muzzle := Vector3(data.decode_float(12), data.decode_float(16), data.decode_float(20))
	var contact := Vector3(data.decode_float(24), data.decode_float(28), data.decode_float(32))
	var normal := Vector3(data.decode_float(36), data.decode_float(40), data.decode_float(44))
	if not muzzle.is_finite() or not contact.is_finite() or not normal.is_finite():
		return {}
	return {"sequence": data.decode_u32(0), "shooter_life": data.decode_u32(4), "target_life": data.decode_s32(8), "muzzle": muzzle, "contact": contact, "normal": normal}
static func shot_key(shooter_id: int, life: int, sequence: int) -> String:
	return "%d:%d:%d" % [shooter_id, life, sequence]
