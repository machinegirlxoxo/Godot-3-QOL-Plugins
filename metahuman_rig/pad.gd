tool
extends Control
# One face-board control: a 2D pad (or a 1D slider when only one axis exists).

signal changed(pad)

var title := ""
var ix := -1   # gui control index driven by horizontal axis (-1 = none)
var iy := -1   # gui control index driven by vertical axis (-1 = none)
var xr := [0.0, 1.0]
var yr := [0.0, 1.0]
var vx := 0.0
var vy := 0.0
var _dragging := false
var art_mode := false   # box is drawn by the board artwork: only draw the handle
var light := false


func setup(p_title: String, p_ix: int, p_xr, p_iy: int, p_yr) -> void:
	title = p_title
	ix = p_ix
	iy = p_iy
	xr = p_xr if p_ix >= 0 else [0.0, 1.0]
	yr = p_yr if p_iy >= 0 else [0.0, 1.0]
	hint_tooltip = title
	if ix >= 0 and iy >= 0:
		rect_min_size = Vector2(38, 38)
	elif ix >= 0:
		rect_min_size = Vector2(46, 16)
	else:
		rect_min_size = Vector2(16, 46)
	rect_size = rect_min_size


func set_values(x: float, y: float) -> void:
	vx = x
	vy = y
	update()


func _norm(v: float, r: Array) -> float:
	var span: float = r[1] - r[0]
	return 0.5 if span <= 0.0 else clamp((v - r[0]) / span, 0.0, 1.0)


func _handle_pos() -> Vector2:
	var m := 5.0
	var w := rect_size.x - 2 * m
	var h := rect_size.y - 2 * m
	var px := m + w * (_norm(vx, xr) if ix >= 0 else 0.5)
	var py := m + h * (1.0 - (_norm(vy, yr) if iy >= 0 else 0.5))
	return Vector2(px, py)


func _rest_pos() -> Vector2:
	var m := 5.0
	var w := rect_size.x - 2 * m
	var h := rect_size.y - 2 * m
	var px := m + w * (_norm(0.0, xr) if ix >= 0 else 0.5)
	var py := m + h * (1.0 - (_norm(0.0, yr) if iy >= 0 else 0.5))
	return Vector2(px, py)


func _draw() -> void:
	var active := abs(vx) > 0.001 or abs(vy) > 0.001
	if art_mode:
		var ink := Color(0.08, 0.08, 0.1) if light else Color(0.85, 0.85, 0.9)
		if active:
			draw_rect(Rect2(Vector2.ZERO, rect_size), Color(1.0, 0.8, 0.1, 0.14))
		draw_circle(_rest_pos(), 1.2, ink)
		var hp := _handle_pos()
		draw_circle(hp, 4.0, Color(1.0, 0.85, 0.1) if active else Color(0.95, 0.72, 0.05))
		draw_arc(hp, 4.0, 0.0, TAU, 14, ink, 1.0)
		return
	draw_rect(Rect2(Vector2.ZERO, rect_size), Color(0.12, 0.12, 0.14))
	draw_rect(Rect2(Vector2.ZERO, rect_size), Color(0.9, 0.7, 0.1) if active else Color(0.4, 0.4, 0.45), false)
	var rest := _rest_pos()
	draw_circle(rest, 1.5, Color(0.5, 0.5, 0.55))
	draw_circle(_handle_pos(), 3.5, Color(1.0, 0.8, 0.1) if active else Color(0.8, 0.8, 0.85))


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == BUTTON_LEFT:
		if ev.doubleclick:
			_dragging = false
			vx = 0.0
			vy = 0.0
			update()
			emit_signal("changed", self)
			return
		_dragging = ev.pressed
		if ev.pressed:
			_set_from_mouse(ev.position)
	elif ev is InputEventMouseMotion and _dragging:
		_set_from_mouse(ev.position)


func _set_from_mouse(p: Vector2) -> void:
	var m := 5.0
	var w := max(1.0, rect_size.x - 2 * m)
	var h := max(1.0, rect_size.y - 2 * m)
	if ix >= 0:
		var tx: float = clamp((p.x - m) / w, 0.0, 1.0)
		vx = lerp(xr[0], xr[1], tx)
		if abs(vx) < 0.02 * (xr[1] - xr[0]):
			vx = 0.0
	if iy >= 0:
		var ty: float = clamp(1.0 - (p.y - m) / h, 0.0, 1.0)
		vy = lerp(yr[0], yr[1], ty)
		if abs(vy) < 0.02 * (yr[1] - yr[0]):
			vy = 0.0
	update()
	emit_signal("changed", self)
