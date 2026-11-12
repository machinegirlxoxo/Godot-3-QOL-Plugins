tool
extends Control
# All face-board handles on top of the artwork. Each control keeps the exact rest position of its
# Blender bone and moves along its own travel vectors (slanted brow sliders, box corners, ...).
# One layer handles the mouse for every handle, so overlapping slider boxes never steal clicks.

signal changed(ix, vx, iy, vy)

var items := []          # {name, ix, iy, rest, ux, uy, xr, yr, x, y}
var light := false
var ui := 1.0            # pixels per "design pixel" (board is built at a larger size for sharpness)
var _drag := -1
var _offset := Vector2.ZERO


func _init() -> void:
	mouse_filter = MOUSE_FILTER_STOP


func _handle_pos(it: Dictionary) -> Vector2:
	var p: Vector2 = it["rest"]
	if it["ix"] >= 0:
		var xv: float = it["x"]
		p += (it["ux"] if xv >= 0.0 else it["uxn"]) * xv
	if it["iy"] >= 0:
		var yv: float = it["y"]
		p += (it["uy"] if yv >= 0.0 else it["uyn"]) * yv
	return p


func set_values(index: int, x: float, y: float) -> void:
	var it: Dictionary = items[index]
	it["x"] = x
	it["y"] = y
	update()


func _draw() -> void:
	var ink := Color(0.08, 0.08, 0.1) if light else Color(0.85, 0.85, 0.9)
	for k in range(items.size()):
		var it: Dictionary = items[k]
		var active: bool = abs(float(it["x"])) > 0.001 or abs(float(it["y"])) > 0.001
		var hp := _handle_pos(it)
		var rad: Vector2 = it.get("rad", Vector2(2.3 * ui, 2.3 * ui))
		if active:
			draw_line(it["rest"], hp, Color(1.0, 0.85, 0.1, 0.55), 1.1 * ui)
			draw_circle(it["rest"], 1.0 * ui, ink)
		var ring := PoolVector2Array()
		for a in range(21):
			var t := TAU * float(a) / 20.0
			ring.append(hp + Vector2(cos(t) * rad.x, sin(t) * rad.y))
		draw_colored_polygon(ring, Color(1.0, 0.85, 0.1) if (active or k == _drag) else Color(0.95, 0.72, 0.05))
		draw_polyline(ring, ink, 0.9 * ui, true)


func _nearest(p: Vector2, max_dist: float) -> int:
	var best := -1
	var bd := 1e18
	for k in range(items.size()):
		var rad: Vector2 = items[k].get("rad", Vector2(2.3 * ui, 2.3 * ui))
		# dots are small (1-5 mm on the board): grab area = dot + a margin, never above max_dist
		var reach: float = min(max_dist, max(max(rad.x, rad.y) + 2.0 * ui, 4.0 * ui))
		var d: float = _handle_pos(items[k]).distance_to(p)
		if d <= reach and d < bd:
			bd = d
			best = k
	return best


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == BUTTON_LEFT:
		if ev.pressed:
			var k := _nearest(ev.position, 9.0 * ui)
			if k < 0:
				return
			if ev.doubleclick:
				_drag = -1
				var it: Dictionary = items[k]
				it["x"] = 0.0
				it["y"] = 0.0
				update()
				emit_signal("changed", it["ix"], 0.0, it["iy"], 0.0)
				return
			_drag = k
			_offset = _handle_pos(items[k]) - ev.position
			accept_event()
		else:
			_drag = -1
			update()
	elif ev is InputEventMouseMotion and _drag >= 0:
		_move(ev.position + _offset)
		accept_event()


func _solve(it: Dictionary, d: Vector2, ux: Vector2, uy: Vector2) -> Vector2:
	var x := 0.0
	var y := 0.0
	if it["ix"] >= 0 and it["iy"] >= 0:
		var det: float = ux.x * uy.y - ux.y * uy.x
		if abs(det) > 1e-6:
			x = (d.x * uy.y - d.y * uy.x) / det
			y = (ux.x * d.y - ux.y * d.x) / det
		else:
			x = d.dot(ux) / max(ux.dot(ux), 1e-9)
	elif it["ix"] >= 0:
		x = d.dot(ux) / max(ux.dot(ux), 1e-9)
	elif it["iy"] >= 0:
		y = d.dot(uy) / max(uy.dot(uy), 1e-9)
	return Vector2(x, y)


func _move(target: Vector2) -> void:
	var it: Dictionary = items[_drag]
	var d: Vector2 = target - it["rest"]
	var v := _solve(it, d, it["ux"], it["uy"])
	# units differ for negative values: solve again with the side the first guess landed on
	var ux: Vector2 = it["ux"] if v.x >= 0.0 else it["uxn"]
	var uy: Vector2 = it["uy"] if v.y >= 0.0 else it["uyn"]
	v = _solve(it, d, ux, uy)
	var xr: Array = it["xr"]
	var yr: Array = it["yr"]
	var x := v.x
	var y := v.y
	if it["ix"] >= 0:
		x = clamp(x, xr[0], xr[1])
	if it["iy"] >= 0:
		y = clamp(y, yr[0], yr[1])
	it["x"] = x
	it["y"] = y
	update()
	emit_signal("changed", it["ix"], x, it["iy"], y)
