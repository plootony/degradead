@tool
extends Resource
class_name DGDFirearmSettings
@export_enum("Автомат", "Пистолет", "Пистолет-пулемёт", "Дробовик", "Винтовка") var weapon_type := 0
@export_enum("Одиночный", "Автоматический") var fire_mode := 1
@export_range(1, 500, 1) var magazine_size := 30
@export_range(0, 9999, 1) var reserve_ammo := 90
@export var ammo_type := "5.45×39"
@export_range(0.2, 15, 0.1) var reload_time := 2.2
@export_range(30, 1200, 1) var rpm := 600.0
@export_range(1, 200, 1) var damage := 34.0
@export_range(1, 500, 1) var max_range := 100.0
@export_range(0, 500, 1) var falloff_start := 30.0
@export_range(0, 1, 0.01) var minimum_damage := 0.5
@export_range(0, 2, 0.01) var arm_multiplier := 0.6
@export_range(0, 2, 0.01) var leg_multiplier := 0.75
@export_range(1, 32, 1) var pellets := 8
@export_range(0, 20, 0.01) var hip_spread := 0.6
@export_range(0, 20, 0.01) var aim_spread := 0.08
@export_range(0, 4, 0.01) var movement_multiplier := 1.8
@export_range(0, 4, 0.01) var crouch_multiplier := 0.75
@export_range(0, 4, 0.01) var prone_multiplier := 0.5
@export_range(0, 6, 0.01) var air_multiplier := 2.5
@export_range(0, 5, 0.01) var bloom_per_shot := 0.2
@export_range(0, 10, 0.01) var bloom_max := 2.0
@export_range(0, 20, 0.1) var bloom_recovery := 3.0
@export_range(0, 15, 0.01) var recoil_up := 1.2
@export_range(0, 15, 0.01) var recoil_down := 0.0
@export_range(0, 10, 0.01) var recoil_left := 0.2
@export_range(0, 10, 0.01) var recoil_right := 0.2
@export_range(0, 2, 0.01) var aim_recoil_multiplier := 0.7
@export_range(1, 30, 0.1) var recoil_return := 7.0
@export_range(0, 10, 0.01) var camera_shake := 1.0
@export_range(0.02, 1, 0.01) var shake_duration := 0.14
@export_range(0, 0.15, 0.001) var weapon_kickback := 0.025
@export_range(0, 20, 0.1) var weapon_lift := 2.0
@export_range(0, 10, 0.1) var weapon_yaw := 0.4
@export_range(0, 10, 0.1) var weapon_roll := 0.5
@export_range(0, 5, 0.1) var weapon_shake := 0.3
@export_range(1, 40, 0.1) var weapon_return := 18.0
@export_range(0, 1, 0.01) var flash_size := 0.14
@export_range(0, 12, 0.1) var flash_brightness := 3.0
@export_range(0.01, 0.2, 0.005) var flash_duration := 0.045
@export var flash_color := Color(1.0, 0.65, 0.15)
@export_range(0, 8, 0.1) var light_energy := 1.5
@export_range(0.1, 5, 0.1) var light_range := 1.8
@export_range(0, 0.6, 0.01) var smoke_size := 0.12
@export_range(0, 1, 0.01) var smoke_opacity := 0.3
@export_range(0.1, 3, 0.1) var smoke_lifetime := 0.5
@export_range(1, 24, 1) var smoke_amount := 8
@export_range(0, 3, 0.05) var smoke_speed := 0.5
@export_range(0, 2, 0.05) var smoke_brightness := 0.65

const LIMITS := {
	"magazine_size":Vector2(1,500),"reserve_ammo":Vector2(0,9999),"reload_time":Vector2(0.2,15),
	"rpm":Vector2(30,1200),"damage":Vector2(1,200),"max_range":Vector2(1,500),"falloff_start":Vector2(0,500),"minimum_damage":Vector2(0,1),
	"arm_multiplier":Vector2(0,2),"leg_multiplier":Vector2(0,2),"pellets":Vector2(1,32),
	"hip_spread":Vector2(0,20),"aim_spread":Vector2(0,20),"movement_multiplier":Vector2(0,4),"crouch_multiplier":Vector2(0,4),"prone_multiplier":Vector2(0,4),"air_multiplier":Vector2(0,6),
	"bloom_per_shot":Vector2(0,5),"bloom_max":Vector2(0,10),"bloom_recovery":Vector2(0,20),
	"recoil_up":Vector2(0,15),"recoil_down":Vector2(0,15),"recoil_left":Vector2(0,10),"recoil_right":Vector2(0,10),"aim_recoil_multiplier":Vector2(0,2),"recoil_return":Vector2(1,30),
	"camera_shake":Vector2(0,10),"shake_duration":Vector2(0.02,1),"weapon_kickback":Vector2(0,0.15),"weapon_lift":Vector2(0,20),"weapon_yaw":Vector2(0,10),"weapon_roll":Vector2(0,10),"weapon_shake":Vector2(0,5),"weapon_return":Vector2(1,40),
	"flash_size":Vector2(0,1),"flash_brightness":Vector2(0,12),"flash_duration":Vector2(0.01,0.2),"light_energy":Vector2(0,8),"light_range":Vector2(0.1,5),
	"smoke_size":Vector2(0,0.6),"smoke_opacity":Vector2(0,1),"smoke_lifetime":Vector2(0.1,3),"smoke_amount":Vector2(1,24),"smoke_speed":Vector2(0,3),"smoke_brightness":Vector2(0,2)}
func value(key: String) -> float:
	var n := float(get(key))
	var bounds: Vector2 = LIMITS[key]
	return clampf(n if is_finite(n) else bounds.x,bounds.x,bounds.y)
func ammo_key() -> String:
	return ammo_type.strip_edges().substr(0,64) if not ammo_type.strip_edges().is_empty() else "Универсальные"
func interval() -> float: return 60.0/value("rpm")
func pellet_count() -> int: return int(value("pellets")) if weapon_type == 3 else 1
static func preset(type: int) -> DGDFirearmSettings:
	var p := DGDFirearmSettings.new()
	p.weapon_type = clampi(type,0,4)
	match type:
		1:
			p.magazine_size=15; p.reserve_ammo=60; p.ammo_type="9×19"; p.reload_time=1.8
			p.fire_mode=0; p.rpm=300; p.damage=28; p.hip_spread=0.9; p.recoil_up=2.0
		2:
			p.magazine_size=30; p.reserve_ammo=120; p.ammo_type="9×19"; p.reload_time=2.0
			p.rpm=850; p.damage=22; p.hip_spread=1.0; p.recoil_up=0.8; p.falloff_start=18
		3:
			p.magazine_size=8; p.reserve_ammo=32; p.ammo_type="12/70"; p.reload_time=3.0
			p.fire_mode=0; p.rpm=90; p.damage=10; p.hip_spread=3.5; p.aim_spread=2.5; p.recoil_up=5; p.weapon_kickback=0.065; p.weapon_lift=7; p.flash_size=0.24; p.falloff_start=10; p.max_range=60
		4:
			p.magazine_size=5; p.reserve_ammo=20; p.ammo_type="7.62×51"; p.reload_time=3.0
			p.fire_mode=0; p.rpm=60; p.damage=90; p.hip_spread=1.5; p.aim_spread=0.02; p.recoil_up=5; p.max_range=400; p.falloff_start=150; p.weapon_kickback=0.05
	return p
