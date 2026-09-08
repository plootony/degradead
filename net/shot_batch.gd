extends RefCounted
class_name ShotBatch
## One bounded message per trigger, including shotgun pellets. No object deserialization.
const BONES := ["","world","body","head","torso","pelvis","left_arm","left_forearm","right_arm","right_forearm","left_leg","left_shin","right_leg","right_shin","legs"]
const RECORD := 52
static func encode(sequence: int, life: int, muzzle: Vector3, profile: String, hits: Array) -> PackedByteArray:
	var name_bytes := profile.to_utf8_buffer()
	if hits.is_empty() or hits.size()>32 or name_bytes.size()>96: return PackedByteArray()
	var data := PackedByteArray()
	data.resize(25+name_bytes.size()+RECORD*hits.size())
	data.encode_u32(0,sequence); data.encode_u32(4,life)
	for i in 3: data.encode_float(8+i*4,muzzle[i])
	data.encode_u32(20,hits.size()); data[24]=name_bytes.size()
	for i in name_bytes.size(): data[25+i]=name_bytes[i]
	var offset := 25+name_bytes.size()
	for hit in hits:
		data.encode_s32(offset,hit.target_id)
		data.encode_s32(offset+4,hit.target_life)
		data.encode_s32(offset+8,hit.hp_left)
		data.encode_u32(offset+12,maxi(0,BONES.find(hit.hit_bone)))
		for i in 3:
			data.encode_float(offset+16+i*4,hit.position[i])
			data.encode_float(offset+28+i*4,hit.contact[i])
			data.encode_float(offset+40+i*4,hit.normal[i])
		offset+=RECORD
	return data
static func decode(data: PackedByteArray) -> Dictionary:
	if data.size()<25 or data.size()>1785: return {}
	var count := data.decode_u32(20)
	var length := int(data[24])
	if count<1 or count>32 or length>96 or data.size()!=25+length+count*RECORD: return {}
	var muzzle := Vector3(data.decode_float(8),data.decode_float(12),data.decode_float(16))
	if not muzzle.is_finite(): return {}
	var result := {"sequence":data.decode_u32(0),"shooter_life":data.decode_u32(4),"muzzle":muzzle,"profile":data.slice(25,25+length).get_string_from_utf8(),"hits":[]}
	var offset := 25+length
	for n in count:
		var bone := data.decode_u32(offset+12)
		if bone>=BONES.size(): return {}
		var vectors: Array[Vector3] = []
		for start in [16,28,40]:
			var v := Vector3(data.decode_float(offset+start),data.decode_float(offset+start+4),data.decode_float(offset+start+8))
			if not v.is_finite(): return {}
			vectors.append(v)
		result.hits.append({"target_id":data.decode_s32(offset),"target_life":data.decode_s32(offset+4),"hp_left":data.decode_s32(offset+8),"hit_bone":BONES[bone],"position":vectors[0],"contact":vectors[1],"normal":vectors[2]})
		offset+=RECORD
	return result
