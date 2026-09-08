@tool
extends RefCounted
class_name DGDBallistics
static func shot_seed(player_id: int, life: int, sequence: int) -> int:
	return ((player_id * 73856093) ^ (life * 19349663) ^ (sequence * 83492791)) & 0x7fffffff
static func cool(p: DGDFirearmSettings, heat: float, elapsed: float) -> float:
	return clampf(heat-maxf(0,elapsed)*p.value("bloom_recovery"),0,p.value("bloom_max"))
static func spread(p: DGDFirearmSettings, aiming: bool, stance: int, speed: float, airborne: bool, heat: float) -> float:
	var angle := p.value("aim_spread" if aiming else "hip_spread") + clampf(heat,0,p.value("bloom_max"))
	angle *= lerpf(1,p.value("movement_multiplier"),clampf(speed/4.5,0,1))
	if stance==1: angle *= p.value("crouch_multiplier")
	if stance==2: angle *= p.value("prone_multiplier")
	if airborne: angle *= p.value("air_multiplier")
	return minf(angle,40)
static func directions(direction: Vector3, angle_degrees: float, count: int, seed_value: int) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var forward := direction.normalized()
	var right := forward.cross(Vector3.UP if absf(forward.y)<0.99 else Vector3.RIGHT).normalized()
	var up := right.cross(forward).normalized()
	var result: Array[Vector3] = []
	# Uniform solid angle in a cone. Each pellet has an independent ray.
	for i in clampi(count,1,32):
		var cosine := lerpf(1,cos(deg_to_rad(clampf(angle_degrees,0,40))),rng.randf())
		var radius := sqrt(maxf(0,1-cosine*cosine))
		var azimuth := rng.randf()*TAU
		result.append((forward*cosine + (right*cos(azimuth)+up*sin(azimuth))*radius).normalized())
	return result
static func damage_at(p: DGDFirearmSettings, distance: float, bone: String) -> int:
	var start := minf(p.value("falloff_start"),p.value("max_range"))
	var amount := clampf((distance-start)/maxf(0.001,p.value("max_range")-start),0,1)
	var damage := p.value("damage")*lerpf(1,p.value("minimum_damage"),amount)
	if "arm" in bone: damage *= p.value("arm_multiplier")
	if "leg" in bone or "shin" in bone: damage *= p.value("leg_multiplier")
	return maxi(1 if bone=="head" else 0,roundi(damage))
