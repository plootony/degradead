@tool
extends Node3D
class_name DGDMuzzleEffect
var flash: MeshInstance3D
var lamp: OmniLight3D
var smoke: Array[CPUParticles3D] = []
var _next := 0
var _age := 1.0
var _duration := 0.04
var _energy := 0.0
var fired_count := 0
func _ready() -> void:
	var gradient := Gradient.new()
	gradient.set_color(0,Color.WHITE)
	gradient.set_color(1,Color(1,1,1,0))
	var texture := GradientTexture2D.new()
	texture.gradient=gradient; texture.width=64; texture.height=64
	texture.fill=GradientTexture2D.FILL_RADIAL
	texture.fill_from=Vector2(0.5,0.5); texture.fill_to=Vector2(1,0.5)
	flash=MeshInstance3D.new()
	flash.mesh=QuadMesh.new()
	flash.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode=BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode=BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale=true
	material.albedo_texture=texture
	material.emission_enabled=true
	flash.material_override=material
	flash.position.z=-0.035; flash.visible=false
	add_child(flash)
	lamp=OmniLight3D.new()
	lamp.shadow_enabled=false; lamp.visible=false
	add_child(lamp)
	for i in 4:
		var particles := CPUParticles3D.new()
		particles.emitting=false; particles.one_shot=true; particles.explosiveness=0.9
		particles.local_coords=false; particles.direction=Vector3.FORWARD
		particles.spread=18; particles.gravity=Vector3(0,0.3,0)
		particles.mesh=QuadMesh.new()
		var mat := StandardMaterial3D.new()
		mat.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo=true
		mat.billboard_mode=BaseMaterial3D.BILLBOARD_ENABLED
		mat.billboard_keep_scale=true
		mat.albedo_texture=texture
		mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
		particles.mesh.material=mat
		var fade := Gradient.new()
		fade.set_color(0,Color.WHITE); fade.set_color(1,Color(1,1,1,0))
		particles.color_ramp=fade
		particles.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(particles); smoke.append(particles)
func fire(p: DGDFirearmSettings) -> void:
	if not flash: return
	fired_count+=1; _age=0; _duration=p.value("flash_duration")
	flash.visible=p.value("flash_size")>0 and p.value("flash_brightness")>0
	flash.scale=Vector3.ONE*maxf(0.0001,p.value("flash_size"))
	var mat := flash.material_override as StandardMaterial3D
	mat.albedo_color=p.flash_color
	mat.emission=p.flash_color
	mat.emission_energy_multiplier=p.value("flash_brightness")
	_energy=p.value("light_energy")
	lamp.light_color=p.flash_color; lamp.light_energy=_energy
	lamp.omni_range=p.value("light_range"); lamp.visible=_energy>0
	if p.value("smoke_size")>0 and p.value("smoke_opacity")>0:
		var particles := smoke[_next]
		_next=(_next+1)%smoke.size()
		particles.amount=int(p.value("smoke_amount"))
		particles.lifetime=p.value("smoke_lifetime")
		particles.scale_amount_min=p.value("smoke_size")*0.5
		particles.scale_amount_max=p.value("smoke_size")
		particles.initial_velocity_min=p.value("smoke_speed")*0.5
		particles.initial_velocity_max=p.value("smoke_speed")
		var brightness := p.value("smoke_brightness")
		particles.color=Color(brightness,brightness,brightness,p.value("smoke_opacity"))
		particles.restart(); particles.emitting=true
func reset() -> void:
	_age=1
	if flash: flash.visible=false
	if lamp: lamp.visible=false
	for particles in smoke: particles.emitting=false
func _process(delta: float) -> void:
	_age+=maxf(delta,0)
	if flash and _age>=_duration:
		flash.visible=false; lamp.visible=false
	elif lamp: lamp.light_energy=_energy*maxf(0,1-_age/_duration)
