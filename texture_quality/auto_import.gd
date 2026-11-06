tool
extends Reference
# Converts textures that were imported before the plugin was enabled.
#
# New images already use Texture Quality automatically (ImportPlugin.get_priority).
# This pass rewrites the existing .import files and asks the editor to rescan, which
# reimports them in place. It deliberately does not use the Import dock's path, because
# that path asks the user to restart the editor when the importer changes.

const WAIT_LIMIT = 60000

var _import_plugin
var _editor_interface
var _tree
var _running = false
var _cancelled = false


func setup(import_plugin, editor_interface, tree) -> void:
	_import_plugin = import_plugin
	_editor_interface = editor_interface
	_tree = tree


func cancel() -> void:
	_cancelled = true
	_running = false


func convert_all() -> void:
	if _running or _cancelled or _import_plugin == null or _editor_interface == null or _tree == null:
		return
	_running = true

	var fs = _editor_interface.get_resource_filesystem()
	if fs == null:
		_running = false
		return

	# Plugins can load before EditorFileSystem's deferred first scan starts, so
	# get_filesystem() may still be null here. Wait for the scan to start, or for
	# the tree to be filled, and then wait for it to finish.
	var frames = 0
	while frames < 120 and not _cancelled:
		if fs.is_scanning():
			break
		var root = fs.get_filesystem()
		if root != null and (root.get_file_count() > 0 or root.get_subdir_count() > 0):
			break
		yield(_tree, "idle_frame")
		frames += 1

	if not fs.is_scanning() and fs.get_filesystem() == null:
		fs.scan()

	var waited = 0
	while fs.is_scanning() and waited < WAIT_LIMIT and not _cancelled:
		yield(_tree, "idle_frame")
		waited += 1
	if _cancelled:
		_running = false
		return

	var files = []
	_collect(fs.get_filesystem(), files)

	var converted = 0
	for path in files:
		if _cancelled:
			_running = false
			return
		if _convert(path):
			converted += 1

	if converted == 0:
		_running = false
		return

	print("Texture Quality: reimporting %d existing texture(s)..." % converted)

	# Changing the .import file is not enough on its own: the editor also stores a
	# .md5 note next to the imported files. _convert() removes it so the scan below
	# is guaranteed to see that the file must be imported again.
	var scan_started = false
	var tries = 0
	while tries < 5 and not _cancelled:
		if not fs.is_scanning():
			fs.scan()
			yield(_tree, "idle_frame")
			if fs.is_scanning():
				scan_started = true
				break
		yield(_tree, "idle_frame")
		tries += 1

	if scan_started:
		waited = 0
		while fs.is_scanning() and waited < WAIT_LIMIT and not _cancelled:
			yield(_tree, "idle_frame")
			waited += 1
		# The scan's process callback runs the queued reimports after is_scanning()
		# turns false. Give it a few frames to finish.
		for i in range(3):
			yield(_tree, "idle_frame")
		if not _cancelled:
			print("Texture Quality: %d texture(s) converted." % converted)
	else:
		print("Texture Quality: could not start an editor rescan; the textures will be converted on the next editor start.")

	_running = false


func _collect(dir, out: Array) -> void:
	if dir == null:
		return
	for i in range(dir.get_file_count()):
		var path = dir.get_file_path(i)
		if _is_candidate(path):
			out.append(path)
	for i in range(dir.get_subdir_count()):
		_collect(dir.get_subdir(i), out)


func _is_candidate(path: String) -> bool:
	# Leave the editor's own plugin assets alone.
	if path.begins_with("res://addons/"):
		return false
	var ext = path.get_extension().to_lower()
	if _import_plugin.get_recognized_extensions().find(ext) == -1:
		return false
	return _file_exists(path + ".import")


func _file_exists(path: String) -> bool:
	var f = File.new()
	return f.file_exists(path)


func _convert(path: String) -> bool:
	var cfg = ConfigFile.new()
	if cfg.load(path + ".import") != OK:
		return false

	var target = _import_plugin.get_importer_name()
	var current = str(cfg.get_value("remap", "importer", ""))
	if current == target:
		return false
	if current != "texture":
		# "keep" and importers from other plugins are left alone.
		return false

	var old = {}
	if cfg.has_section("params"):
		for key in cfg.get_section_keys("params"):
			old[key] = cfg.get_value("params", key)

	var old_path = str(cfg.get_value("remap", "path", ""))
	var options = _build_options(old)

	cfg.set_value("remap", "importer", target)
	if cfg.has_section("params"):
		cfg.erase_section("params")
	for key in options:
		cfg.set_value("params", key, options[key])
	if cfg.save(path + ".import") != OK:
		return false

	# Force the editor's reimport check to accept the conversion.
	_remove_md5(path, old_path)
	return true


# The imported-file hash note lives next to the imported data, named after the
# source path. Removing it makes _test_for_reimport() return true, which is what
# makes the editor actually reimport the file after we changed its importer.
func _remove_md5(path: String, old_import_path: String) -> void:
	var md5_path = ""
	if old_import_path != "":
		md5_path = old_import_path.get_basename() + ".md5"
	else:
		md5_path = "res://.import/%s-%s.md5" % [path.get_file(), path.md5_text()]
	var dir = Directory.new()
	if dir.file_exists(md5_path):
		dir.remove(md5_path)


# Keep the useful settings of the built-in texture importer so converting an
# existing texture doesn't silently change how it tiles, filters or is sized.
func _build_options(old: Dictionary) -> Dictionary:
	var values = {}
	for opt in _import_plugin.get_import_options(0):
		values[str(opt["name"])] = opt["default_value"]

	if old.has("flags/repeat"):
		values["repeat"] = int(old["flags/repeat"]) != 0
	if old.has("flags/filter"):
		values["filter"] = bool(old["flags/filter"])
	if old.has("flags/mipmaps"):
		values["mipmaps"] = bool(old["flags/mipmaps"])
	if old.has("flags/anisotropic"):
		values["anisotropic"] = bool(old["flags/anisotropic"])

	if old.has("size_limit"):
		values["max_size"] = int(old["size_limit"])
	elif old.has("process/size_limit"):
		values["max_size"] = int(old["process/size_limit"])

	# compress/mode: 0 = Lossless, 1 = Lossy, 2 = Video RAM, 3 = Uncompressed.
	# Keep non-VRAM textures uncompressed so 2D / UI art doesn't get S3TC artifacts.
	if old.has("compress/mode"):
		var mode = int(old["compress/mode"])
		values["compress"] = mode == 1 or mode == 2

	# Map the old colour-space flags to the plugin's "kind" option.
	# compress/normal_map: 0 = Detect, 1 = Enable, 2 = Disabled.
	var kind = int(values.get("kind", 0))
	var normal_mode = 0
	if old.has("compress/normal_map"):
		normal_mode = int(old["compress/normal_map"])
	if normal_mode == 1:
		kind = 2
	elif old.has("flags/srgb"):
		var srgb = int(old["flags/srgb"])
		if srgb == 1:
			kind = 1
		elif srgb == 0:
			kind = 3
	values["kind"] = kind

	return values
