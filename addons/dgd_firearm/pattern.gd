@tool
extends Control
var points: Array[Vector2] = []
var distance := 20.0
var spread := 0.0
func clear() -> void:
	points.clear(); queue_redraw()
func add_rays(rays: Array[Vector3]) -> void:
	for ray in rays:
		if ray.z < -0.0001: points.append(Vector2(ray.x,-ray.y)*distance/-ray.z)
	while points.size()>512: points.pop_front()
	queue_redraw()
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO,size),Color("16202c"))
	var center := size*0.5
	var extent := maxf(0.3,distance*tan(deg_to_rad(maxf(2,spread))))
	for point in points: extent=maxf(extent,maxf(absf(point.x),absf(point.y))*1.15)
	var scale := minf(size.x,size.y)*0.42/extent
	for i in 4: draw_circle(center,extent*scale*(i+1)/4,Color("455567"),false,1,true)
	draw_line(center-Vector2(10,0),center+Vector2(10,0),Color.WHITE)
	draw_line(center-Vector2(0,10),center+Vector2(0,10),Color.WHITE)
	for point in points: draw_circle(center+point*scale,2.5,Color("ffbc61"))
	draw_string(ThemeDB.fallback_font,Vector2(10,20),"Мишень %.0f м · радиус %.2f м · %d попаданий" % [distance,extent,points.size()],HORIZONTAL_ALIGNMENT_LEFT,-1,14,Color.WHITE)
