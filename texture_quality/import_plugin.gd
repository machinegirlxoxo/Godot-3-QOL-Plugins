tool
extends EditorImportPlugin
# Adds "Texture Quality" to the Import dock's "Import As" list for images.
# Select an image in the FileSystem dock, pick "Texture Quality" under Import As, choose a preset
# or tweak the options, then press Reimport. The tiers are baked automatically and the image
# itself becomes a texture that swaps tiers at runtime, so materials keep using the original file.

const Baker = preload("res://addons/texture_quality/baker.gd")
const StreamedTexScript = preload("res://addons/texture_quality/streamed_tex.gd")


func get_importer_name() -> String:
	return "texture_quality.streamed_tex"


func get_visible_name() -> String:
	return "Texture Quality"


# When Godot meets a new image (no .import file yet) it picks the recognised importer with the
# highest priority. The built-in "Texture" importer is 1.0, so anything above that makes
# Texture Quality the default for every new png/jpg/webp/tga/bmp. Images that already have an
# .import file keep whatever importer they use; you can still switch any single image back to
# "Texture" in the Import dock's "Import As" list.
func get_priority() -> float:
	return 2.0


func get_recognized_extensions() -> Array:
	return ["png", "jpg", "jpeg", "webp", "tga", "bmp"]


func get_save_extension() -> String:
	return "res"


func get_resource_type() -> String:
	return "ImageTexture"


func get_preset_count() -> int:
	return 4


func get_preset_name(preset: int) -> String:
	match preset:
		1:
			return "Color (sRGB)"
		2:
			return "Normal Map"
		3:
			return "Data (Linear)"
	return "Auto"


func get_import_options(preset: int) -> Array:
	return [
		{"name": "tiers", "default_value": 6, "property_hint": PROPERTY_HINT_RANGE, "hint_string": "1,10"},
		{"name": "min_size", "default_value": 128},
		{"name": "lowest_size", "default_value": 64},
		{"name": "max_size", "default_value": 0},
		{"name": "compress", "default_value": true},
		{"name": "kind", "default_value": preset, "property_hint": PROPERTY_HINT_ENUM, "hint_string": "Auto,Color (sRGB),Normal Map,Data (Linear)"},
		{"name": "repeat", "default_value": true},
		{"name": "filter", "default_value": true},
		{"name": "mipmaps", "default_value": true},
		{"name": "anisotropic", "default_value": false},
		{"name": "priority", "default_value": 1.0},
	]


func get_option_visibility(_option: String, _options: Dictionary) -> bool:
	return true


func import(source_file: String, save_path: String, options: Dictionary, _r_platform_variants: Array, r_gen_files: Array) -> int:
	var baker = Baker.new()
	var result = baker.bake(source_file, save_path, options)
	if result.empty():
		return ERR_CANT_CREATE
	for p in result["files"]:
		r_gen_files.append(p)

	# The smallest tier is stored inside the texture, so it is never blank while tiers stream in.
	var tex = StreamedTexScript.new()
	tex._registered = true   # don't register this temporary instance with the managers
	tex.create_from_image(result["preview"], int(result["flags"]))
	tex.set_size_override(Vector2(int(result["tiers"][0]["w"]), int(result["tiers"][0]["h"])))
	tex.source_path = source_file
	tex.tiers = result["tiers"]
	tex.streamed_flags = int(result["flags"])
	tex.priority = float(options.get("priority", 1.0))
	return ResourceSaver.save("%s.%s" % [save_path, get_save_extension()], tex)
