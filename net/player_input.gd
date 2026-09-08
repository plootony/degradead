extends RefCounted
class_name PlayerInput
## Versioned, fixed-size input wire protocol. No scene, SDK or autoload dependency.
## 0..1 signed movement; 2..3 yaw; 4..5 pitch; 6 flags; 7 stance/weapon; 8..11 life.
## Changes require a NetConfig.NETWORK_VERSION bump on every peer.
const SIZE: int = 12
const MAX_PITCH: float = deg_to_rad(80.0)

static func encode(move: Vector2, yaw: float, pitch: float, flags: int, stance: int, weapon: int, life: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(SIZE)
	buf.encode_s8(0, int(roundf(clampf(move.x, -1.0, 1.0) * 127.0)))
	buf.encode_s8(1, int(roundf(clampf(move.y, -1.0, 1.0) * 127.0)))
	buf.encode_u16(2, int(roundf(wrapf(yaw, 0.0, TAU) / TAU * 65535.0)))
	buf.encode_s16(4, int(roundf(clampf(pitch / MAX_PITCH, -1.0, 1.0) * 32767.0)))
	buf.encode_u8(6, flags)
	buf.encode_u8(7, stance | (weapon << 2))
	buf.encode_u32(8, life)
	return buf

static func decode(buf: PackedByteArray) -> Dictionary:
	if buf.size() != SIZE:
		return {}
	var stance := buf.decode_u8(7) & 3
	var weapon := buf.decode_u8(7) >> 2
	if stance >= 3 or weapon >= 4 or buf.decode_u8(6) & 0xf0 != 0:
		return {}
	return {
		"move": Vector2(buf.decode_s8(0) / 127.0, buf.decode_s8(1) / 127.0).limit_length(),
		"yaw": buf.decode_u16(2) / 65535.0 * TAU,
		"pitch": clampf(buf.decode_s16(4) / 32767.0 * MAX_PITCH, -MAX_PITCH, MAX_PITCH),
		"flags": buf.decode_u8(6), "stance": stance, "weapon": weapon,
		"life": buf.decode_u32(8),
	}
