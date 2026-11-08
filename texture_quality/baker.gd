tool
extends Reference
# Builds the resolution tiers for one source image. Called by the import plugin.
#
# options: tiers (int), min_size (int), lowest_size (int, px of the smallest tier, 0 = off),
#          max_size (int, 0 = no cap), compress (bool, S3TC),
#          kind (0 auto, 1 colour/sRGB, 2 normal map, 3 data/linear), repeat (bool), anisotropic (bool)
#
# Returns {} on failure, otherwise:
#   tiers   [{path, w, h, bytes}]  index 0 = biggest
#   flags   Texture flags to use when uploading
#   preview Image of the smallest tier (stored inside the imported texture)
#   files   every file written, for the import system


func _detect_kind(src: String) -> int:
	var n = src.get_file().to_lower()
	if "normal" in n or n.get_basename().ends_with("_n") or n.get_basename().ends_with("_nrm"):
		return Image.COMPRESS_SOURCE_NORMAL
	for word in ["albedo", "diffuse", "basecolor", "base_color", "color", "emission", "emissive", "_d."]:
		if word in n:
			return Image.COMPRESS_SOURCE_SRGB
	return Image.COMPRESS_SOURCE_GENERIC


func _kind_from_option(src: String, option: int) -> int:
	match option:
		1:
			return Image.COMPRESS_SOURCE_SRGB
		2:
			return Image.COMPRESS_SOURCE_NORMAL
		3:
			return Image.COMPRESS_SOURCE_GENERIC
	return _detect_kind(src)


func bake(src: String, save_path: String, opt: Dictionary) -> Dictionary:
	var img = Image.new()
	if img.load(src) != OK:
		return {}
	if img.is_compressed():
		img.decompress()
	if img.detect_alpha() == Image.ALPHA_NONE:
		img.convert(Image.FORMAT_RGB8)
	else:
		img.convert(Image.FORMAT_RGBA8)

	var max_size = int(opt.get("max_size", 0))
	if max_size > 0 and max(img.get_width(), img.get_height()) > max_size:
		var s = float(max_size) / max(img.get_width(), img.get_height())
		img.resize(int(max(1, round(img.get_width() * s))), int(max(1, round(img.get_height() * s))), Image.INTERPOLATE_LANCZOS)

	var sizes = []
	var w = img.get_width()
	var h = img.get_height()
	for i in range(int(opt.get("tiers", 5))):
		sizes.append(Vector2(w, h))
		if max(w, h) <= int(opt.get("min_size", 128)):
			break
		w = int(max(1, w / 2))
		h = int(max(1, h / 2))

	# Force the smallest tier to be really small so "Lowest" is clearly worse than the rest.
	var lowest_size = int(opt.get("lowest_size", 32))
	var tier_count = int(opt.get("tiers", 5))
	if lowest_size > 0 and tier_count >= 2 and sizes.size() >= 1:
		var last = sizes[sizes.size() - 1]
		if max(last.x, last.y) > lowest_size:
			var f = float(lowest_size) / max(img.get_width(), img.get_height())
			var low = Vector2(int(max(1, round(img.get_width() * f))), int(max(1, round(img.get_height() * f))))
			if sizes.size() >= tier_count:
				sizes[sizes.size() - 1] = low
			else:
				sizes.append(low)

	var kind = _kind_from_option(src, int(opt.get("kind", 0)))

	# Colour textures must be flagged sRGB or GLES3 shows them washed out.
	var use_mips = bool(opt.get("mipmaps", true))
	var flags = 0
	if use_mips:
		flags |= Texture.FLAG_MIPMAPS
	if bool(opt.get("filter", true)):
		flags |= Texture.FLAG_FILTER
	if bool(opt.get("repeat", true)):
		flags |= Texture.FLAG_REPEAT
	if bool(opt.get("anisotropic", false)):
		flags |= Texture.FLAG_ANISOTROPIC_FILTER
	if kind == Image.COMPRESS_SOURCE_SRGB:
		flags |= Texture.FLAG_CONVERT_TO_LINEAR

	var tiers = []
	var files = []
	var preview = null
	for i in range(sizes.size()):
		var t = Image.new()
		t.copy_from(img)
		if int(sizes[i].x) != t.get_width() or int(sizes[i].y) != t.get_height():
			t.resize(int(sizes[i].x), int(sizes[i].y), Image.INTERPOLATE_LANCZOS)
		if use_mips:
			t.generate_mipmaps(kind == Image.COMPRESS_SOURCE_NORMAL)
		if bool(opt.get("compress", true)):
			t.compress(Image.COMPRESS_S3TC, kind, 0.7)
		var path = "%s_t%d.res" % [save_path, i]
		if ResourceSaver.save(path, t) != OK:
			return {}
		files.append(path)
		tiers.append({"path": path, "w": t.get_width(), "h": t.get_height(), "bytes": t.get_data().size()})
		preview = t
	return {"tiers": tiers, "flags": flags, "preview": preview, "files": files}
