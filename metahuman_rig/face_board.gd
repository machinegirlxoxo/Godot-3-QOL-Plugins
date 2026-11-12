tool
extends ScrollContainer
# Rebuilds the MetaHuman face board from the DNA GUI controls.

signal gui_value_changed(index, value)

const Pad = preload("pad.gd")
const ArtLayer = preload("art_layer.gd")
const HandleLayer = preload("handle_layer.gd")

var _board := Control.new()
var _wrap := Control.new()    # sits between the ScrollContainer and the board so a zoom changes the scrollable size
var zoom := 1.0
var _pads := []
var light_theme := false
var _minx := 0.0
var _maxz := 0.0
var _scale := 1.0
var board_pixels := 900.0     # width of the artwork in board pixels (the 3D board uses more, for sharpness)
var base_font: Font = null    # optional DynamicFont used for text labels
var _layer = null
var _items := []


func _init() -> void:
	add_child(_wrap)
	_wrap.add_child(_board)


# Zoom the whole board (1.0 = 100 %). `anchor` is a point in this control's own coordinates that stays
# under the mouse while zooming (the middle of the view when left out).
func set_zoom(z: float, anchor = null) -> void:
	z = clamp(z, 0.25, 4.0)
	if is_equal_approx(z, zoom):
		return
	if anchor == null:
		anchor = rect_size * 0.5
	var content_pt: Vector2 = (Vector2(scroll_horizontal, scroll_vertical) + anchor) / zoom
	zoom = z
	_apply_zoom()
	# the scroll ranges only follow the new size after a layout pass
	yield(get_tree(), "idle_frame")
	var target: Vector2 = content_pt * zoom - anchor
	scroll_horizontal = int(max(0.0, round(target.x)))
	scroll_vertical = int(max(0.0, round(target.y)))


func _apply_zoom() -> void:
	_board.rect_scale = Vector2(zoom, zoom)
	_board.rect_position = Vector2.ZERO
	_wrap.rect_min_size = _board.rect_min_size * zoom


func content_size() -> Vector2:
	return _board.rect_min_size


func clear() -> void:
	for c in _board.get_children():
		c.queue_free()
	_pads.clear()
	_items = []
	_layer = null


func build(rig) -> void:
	clear()
	# group "CTRL_L_brow_down.ty" -> base "CTRL_L_brow_down", axis "ty"
	var groups := {}
	for i in range(rig.gui_names.size()):
		var n: String = rig.gui_names[i]
		var dot := n.rfind(".")
		var base := n.substr(0, dot) if dot >= 0 else n
		var axis := n.substr(dot + 1) if dot >= 0 else "tx"
		if not groups.has(base):
			groups[base] = {}
		groups[base][axis] = i
	var bases := groups.keys()
	bases.sort()

	var have := []
	var missing := []
	for b in bases:
		if rig.layout.has(b):
			have.append(b)
		else:
			missing.append(b)

	var art: Dictionary = rig.art if typeof(rig.art) == TYPE_DICTIONARY else {}
	var art_segs: Array = art.get("segs", [])
	var art_on: bool = art_segs.size() >= 4 and have.size() > 1
	var pos := {}
	var scale := 1.0
	var art_size := Vector2.ZERO
	if art_on:
		var minx := 1e9
		var maxx := -1e9
		var minz := 1e9
		var maxz := -1e9
		for k in range(0, art_segs.size() - 1, 2):
			minx = min(minx, art_segs[k])
			maxx = max(maxx, art_segs[k])
			minz = min(minz, art_segs[k + 1])
			maxz = max(maxz, art_segs[k + 1])
		for b in have:
			minx = min(minx, rig.layout[b][0])
			maxx = max(maxx, rig.layout[b][0])
			minz = min(minz, rig.layout[b][1])
			maxz = max(maxz, rig.layout[b][1])
		_minx = minx
		_maxz = maxz
		_scale = board_pixels / max(maxx - minx, 1e-6)
		scale = _scale
		for b in have:
			pos[b] = _px(rig.layout[b][0], rig.layout[b][1])
		art_size = Vector2((maxx - minx) * _scale + 24.0, (maxz - minz) * _scale + 24.0)
		var layer = ArtLayer.new()
		layer.light = light_theme
		var pts := PoolVector2Array()
		for k in range(0, art_segs.size() - 3, 4):
			pts.append(_px(art_segs[k], art_segs[k + 1]))
			pts.append(_px(art_segs[k + 2], art_segs[k + 3]))
		layer.segs = pts
		for l in art.get("labels", []):
			layer.labels.append({"text": str(l["text"]), "pos": _px(l["x"], l["z"]),
				"size": float(l["size"]) * _scale, "rot": -float(l.get("rot", 0.0)), "align": str(l.get("align", "LEFT"))})
		layer.rect_size = art_size
		layer.base_font = base_font
		layer.line_width = max(1.0, 1.4 * _scale / 900.0)
		_board.add_child(layer)
		_layer = HandleLayer.new()
		_layer.light = light_theme
		_layer.ui = _scale / 900.0
		_board.add_child(_layer)
		_layer.connect("changed", self, "_on_layer_changed")
	if art_on:
		pass
	elif have.size() > 1:
		var minx := 1e9
		var maxy := -1e9
		for b in have:
			minx = min(minx, rig.layout[b][0])
			maxy = max(maxy, rig.layout[b][1])
		var mind := 1e9
		for a in range(have.size()):
			for c in range(a + 1, have.size()):
				var pa: Array = rig.layout[have[a]]
				var pc: Array = rig.layout[have[c]]
				var d := Vector2(pa[0] - pc[0], pa[1] - pc[1]).length()
				if d > 1e-6:
					mind = min(mind, d)
		scale = min(40.0 / max(mind, 1e-6), 20000.0)
		for b in have:
			pos[b] = Vector2((rig.layout[b][0] - minx) * scale, (maxy - rig.layout[b][1]) * scale) + Vector2(10, 10)
	else:
		missing = bases
		have = []
	var board_size := Vector2(200, 100)
	for b in have:
		board_size.x = max(board_size.x, pos[b].x + 60)
		board_size.y = max(board_size.y, pos[b].y + 60)
	if art_on:
		board_size = Vector2(max(board_size.x, art_size.x), max(board_size.y, art_size.y))
	# controls without layout go in a grid underneath
	var gx := 10.0
	var gy := board_size.y + 10.0
	for b in missing:
		pos[b] = Vector2(gx, gy)
		gx += 60.0
		if gx > max(board_size.x, 600.0):
			gx = 10.0
			gy += 60.0
	if missing.size() > 0:
		board_size.y = gy + 60.0
		board_size.x = max(board_size.x, 600.0)
	_board.rect_min_size = board_size
	_apply_zoom()

	for b in bases:
		var g: Dictionary = groups[b]
		var ix: int = g.get("tx", -1)
		var iy: int = g.get("ty", -1)
		if ix < 0 and iy < 0:
			for k in g:
				if ix < 0:
					ix = g[k]
				elif iy < 0:
					iy = g[k]
		if art_on and have.has(b):
			_items.append(_make_item(b, groups[b], ix, iy, rig, pos[b], art))
			continue
		var pad = Pad.new()
		pad.setup(b, ix, rig.gui_ranges[ix] if ix >= 0 else [0, 1], iy, rig.gui_ranges[iy] if iy >= 0 else [0, 1])
		pad.light = light_theme
		pad.rect_position = pos[b]
		pad.connect("changed", self, "_on_pad_changed")
		_board.add_child(pad)
		_pads.append(pad)
	if _layer != null:
		_layer.items = _items
		_layer.rect_size = board_size
		_layer.update()


func _key_of(group: Dictionary, index: int) -> String:
	for k in group:
		if group[k] == index:
			return k
	return ""


func _vec_px(v) -> Vector2:
	return Vector2(float(v[0]) * _scale, -float(v[1]) * _scale)


# One handle: exact rest position (the Blender bone) plus how far it travels per unit of GUI value.
func _make_item(b: String, group: Dictionary, ix: int, iy: int, rig, rest: Vector2, art: Dictionary) -> Dictionary:
	var drive: Dictionary = art.get("drive", {})
	var rects: Dictionary = art.get("rects", {})
	var d: Dictionary = drive.get(b, {})
	var xr: Array = rig.gui_ranges[ix] if ix >= 0 else [0.0, 1.0]
	var yr: Array = rig.gui_ranges[iy] if iy >= 0 else [0.0, 1.0]
	var kx := _key_of(group, ix)
	var ky := _key_of(group, iy)
	var ux := Vector2.ZERO
	var uy := Vector2.ZERO
	if kx != "" and d.has(kx):
		ux = _vec_px(d[kx])
	if ky != "" and d.has(ky):
		uy = _vec_px(d[ky])
	var ui := _scale / 900.0
	var r: Array = rects.get(b, [])
	var uxn := Vector2.ZERO
	var uyn := Vector2.ZERO
	# Only controls WITHOUT travel data from Blender are calibrated to their drawn box. The exported
	# travel vectors are exact (limit x evaluated parent frame), and the boxes are axis-aligned
	# bounding boxes, which are wrong for slanted / scaled frames.
	if r.size() == 4:
		# Calibrate to the box drawn on the board: the handle reaches the box edge exactly at the
		# end of the GUI range, so dragging to the edge gives the full rig movement.
		var tl := _px(float(r[0]), float(r[3]))
		var br := _px(float(r[2]), float(r[1]))
		var box := Rect2(tl, br - tl)
		if ix >= 0 and ux.length() < 1e-6:
			var dirx := ux.normalized() if ux.length() > 1e-6 else Vector2(1, 0)
			var res := _calibrate(box, rest, dirx, xr)
			ux = res[0]
			uxn = res[1]
		if iy >= 0 and uy.length() < 1e-6:
			var diry := uy.normalized() if uy.length() > 1e-6 else Vector2(0, -1)
			var res2 := _calibrate(box, rest, diry, yr)
			uy = res2[0]
			uyn = res2[1]
	if ix >= 0 and ux.length() < 1e-6:
		ux = Vector2(40.0 * ui / max(xr[1] - xr[0], 1e-6), 0.0)
	if iy >= 0 and uy.length() < 1e-6:
		uy = Vector2(0.0, -40.0 * ui / max(yr[1] - yr[0], 1e-6))
	if uxn.length() < 1e-6:
		uxn = ux
	if uyn.length() < 1e-6:
		uyn = uy
	# size of the dot as drawn in Blender (its custom shape, in board metres -> pixels); default if not exported
	var rad := Vector2(2.3 * ui, 2.3 * ui)
	var dots: Dictionary = art.get("dots", {})
	if dots.has(b):
		rad = Vector2(float(dots[b][0]), float(dots[b][1])) * 0.5 * _scale
	return {"name": b, "ix": ix, "iy": iy, "rest": rest, "ux": ux, "uy": uy, "uxn": uxn, "uyn": uyn, "xr": xr, "yr": yr, "x": 0.0, "y": 0.0, "rad": rad}


# Pixels of handle travel per unit of GUI value, for positive and negative values, so that the
# range ends land on the edge of the box. Returns [positive_unit, negative_unit] (vectors).
func _calibrate(box: Rect2, rest: Vector2, dir: Vector2, rng: Array) -> Array:
	var hi: float = rng[1]
	var lo: float = rng[0]
	var dp := _exit_dist(box, rest, dir)
	var dn := _exit_dist(box, rest, -dir)
	if lo >= 0.0 and dp < 2.0 and dn > 2.0:
		dir = -dir      # the slider's positive direction points out of the box: flip it
		var t := dp
		dp = dn
		dn = t
	if hi <= 1e-6 and dn < 2.0 and dp > 2.0:
		dir = -dir      # range is 0 and below: the "negative" side must point into the box
		var t2 := dp
		dp = dn
		dn = t2
	var pos := Vector2.ZERO
	var neg := Vector2.ZERO
	if hi > 1e-6:
		pos = dir * (dp / hi)
	if lo < -1e-6:
		neg = dir * (dn / -lo)
	if pos.length() < 1e-6:
		pos = neg
	if neg.length() < 1e-6:
		neg = pos
	return [pos, neg]


func _exit_dist(box: Rect2, p: Vector2, d: Vector2) -> float:
	var t := 1e9
	var e := 0.5
	if d.x > 1e-6:
		t = min(t, (box.end.x + e - p.x) / d.x)
	elif d.x < -1e-6:
		t = min(t, (box.position.x - e - p.x) / d.x)
	if d.y > 1e-6:
		t = min(t, (box.end.y + e - p.y) / d.y)
	elif d.y < -1e-6:
		t = min(t, (box.position.y - e - p.y) / d.y)
	return max(t, 0.0) if t < 1e8 else 0.0


# True when board pixel `p` is on (or very near) a handle / pad.
func has_control_at(p: Vector2) -> bool:
	if _layer != null and _layer._nearest(p, 12.0 * _scale / 900.0) >= 0:
		return true
	for pad in _pads:
		if Rect2(pad.rect_position, pad.rect_size).has_point(p):
			return true
	return false


func _on_layer_changed(ix: int, vx: float, iy: int, vy: float) -> void:
	if ix >= 0:
		emit_signal("gui_value_changed", ix, vx)
	if iy >= 0:
		emit_signal("gui_value_changed", iy, vy)


func _px(x: float, z: float) -> Vector2:
	return Vector2((x - _minx) * _scale + 12.0, (_maxz - z) * _scale + 12.0)


func _on_pad_changed(pad) -> void:
	if pad.ix >= 0:
		emit_signal("gui_value_changed", pad.ix, pad.vx)
	if pad.iy >= 0:
		emit_signal("gui_value_changed", pad.iy, pad.vy)


func sync_from(rig) -> void:
	if _layer != null:
		for k in range(_items.size()):
			var it: Dictionary = _items[k]
			_layer.set_values(k, rig.gui_values[it["ix"]] if it["ix"] >= 0 else 0.0, rig.gui_values[it["iy"]] if it["iy"] >= 0 else 0.0)
	for pad in _pads:
		pad.set_values(rig.gui_values[pad.ix] if pad.ix >= 0 else 0.0, rig.gui_values[pad.iy] if pad.iy >= 0 else 0.0)
