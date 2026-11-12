tool
extends Control
# Static artwork of the Blender face board (outlines, frames, labels), drawn underneath the handles.

var segs := PoolVector2Array()   # pairs of points, in pixels
var labels := []                 # {text, pos, size, rot, align}
var light := false
var line_width := 1.0
var base_font: Font = null       # a DynamicFont gives crisp text at any size
var _fonts := {}


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE


func _crisp_font(px: float):
	if base_font == null or not (base_font is DynamicFont):
		return null
	var s := int(clamp(round(px), 4.0, 256.0))
	if not _fonts.has(s):
		var f: DynamicFont = base_font.duplicate()
		f.size = s
		f.use_filter = true
		_fonts[s] = f
	return _fonts[s]


func _draw() -> void:
	var col := Color(0.08, 0.08, 0.1) if light else Color(0.78, 0.78, 0.84)
	if segs.size() >= 2:
		draw_multiline(segs, col, line_width)
	var fallback: Font = get_font("font", "Label")
	var fh: float = max(fallback.get_height(), 1.0)
	for l in labels:
		var crisp = _crisp_font(float(l["size"]))
		var font: Font = crisp if crisp != null else fallback
		var sc: float = 1.0 if crisp != null else clamp(float(l["size"]) / fh, 0.15, 8.0)
		var w: float = font.get_string_size(l["text"]).x * sc
		var dx := 0.0
		if l["align"] == "CENTER":
			dx = -w * 0.5
		elif l["align"] == "RIGHT":
			dx = -w
		draw_set_transform(l["pos"], l["rot"], Vector2(sc, sc))
		draw_string(font, Vector2(dx / sc, 0.0), l["text"], col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
