tool
class_name StreamedTex
extends ImageTexture
# Produced by the "Texture Quality" importer. Holds the list of baked tiers and starts with the
# smallest one loaded. At runtime the TextureQuality autoload decides which tier it holds;
# in the editor the 3D toolbar menu decides.

export(String, FILE) var source_path = "" setget _set_source_path
export(Array) var tiers = []          # [{path, w, h, bytes}], index 0 = best
export(int) var streamed_flags = 7
export(float) var priority = 1.0

var _registered = false


func _set_source_path(value: String) -> void:
	source_path = value
	if value != "" and not _registered:
		_registered = true
		call_deferred("_register")


func _register() -> void:
	if tiers.empty():
		return
	if Engine.editor_hint:
		_register_editor()
		return
	var loop = Engine.get_main_loop()
	if loop is SceneTree:
		var mgr = loop.root.get_node_or_null("TextureQuality")
		if mgr != null:
			mgr.register_texture(self)
			return
	apply_tier(0)   # game without the autoload: best quality


func _register_editor() -> void:
	var list = []
	if Engine.has_meta("tq_editor_textures"):
		list = Engine.get_meta("tq_editor_textures")
	list.append(weakref(self))
	Engine.set_meta("tq_editor_textures", list)
	var level = 99
	if Engine.has_meta("tq_editor_level"):
		level = int(Engine.get_meta("tq_editor_level"))
	if level != 99:
		apply_tier(level)   # 99 = smallest tier, already loaded


# level 0 = best; anything above the last tier clamps to the smallest one.
func apply_tier(level: int) -> void:
	if tiers.empty():
		return
	var idx = int(clamp(level, 0, tiers.size() - 1))
	var img = load(tiers[idx]["path"])
	if img is Image:
		create_from_image(img, streamed_flags)
		set_size_override(Vector2(int(tiers[0]["w"]), int(tiers[0]["h"])))
