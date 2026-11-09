tool
extends VBoxContainer
# The "Fab / Megascans" tab. Fab has no public API, so this tab does not browse Fab itself.
# Instead it acts as an export target for the Fab tab of the Epic Games Launcher:
#   Launcher > Fab > settings > Export Target "Custom (socket port)" > same port as here > Export.
# The launcher downloads the asset and sends its description to this plugin, which copies the
# files into the project and builds the material / scene.

const Receiver = preload("res://addons/asset_browser/providers/fab/fab_receiver.gd")
const Importer = preload("res://addons/asset_browser/providers/fab/fab_importer.gd")

const DEFAULT_PORT = 24981
const DEFAULT_SAVE_DIR = "res://Fab"
const FAB_URL = "https://www.fab.com/sellers/Quixel"
const PREFIX = "asset_browser/fab/"

var editor: EditorInterface

var _receiver
var _importer
var _queue = []
var _busy = false
var _started = false

var _status_label: Label
var _port_spin: SpinBox
var _toggle_btn: Button
var _autostart_check: CheckBox
var _dir_edit: LineEdit
var _lod_opt: OptionButton
var _material_check: CheckBox
var _scene_check: CheckBox
var _parallax_check: CheckBox
var _history: ItemList
var _history_data = []
var _show_btn: Button
var _open_btn: Button
var _info: Label
var _folder_dialog: FileDialog


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_receiver = Receiver.new()
	_receiver.connect("payload_received", self, "_on_payload")
	_receiver.connect("message", self, "_set_info")
	add_child(_receiver)

	_importer = Importer.new()
	_importer.editor = editor
	_importer.connect("log_line", self, "_set_info")
	add_child(_importer)

	_build_ui()
	_load_settings()
	if _autostart_check.pressed:
		_start()


func on_shown() -> void:
	if not _started:
		_started = true
		_refresh_status()


func _exit_tree() -> void:
	if _receiver != null:
		_receiver.stop()


# ------------------------------------------------------------------------ UI

func _label(text: String) -> Label:
	var l = Label.new()
	l.text = text
	return l


func _build_ui() -> void:
	var top = HBoxContainer.new()
	add_child(top)
	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_status_label)
	top.add_child(_label("Port"))
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65535
	_port_spin.value = DEFAULT_PORT
	top.add_child(_port_spin)
	_toggle_btn = Button.new()
	_toggle_btn.connect("pressed", self, "_on_toggle_pressed")
	top.add_child(_toggle_btn)
	var site = Button.new()
	site.text = "Open Megascans on Fab"
	site.connect("pressed", self, "_open_site")
	top.add_child(site)

	var steps = Label.new()
	steps.autowrap = true
	steps.text = "How it works: Fab has no public API, so you pick the asset in the Fab tab of the Epic Games Launcher and this tab receives it.\n" \
		+ "1. Launcher > Fab > settings (gear): set Export Target to \"Custom (socket port)\" and enter the port above.\n" \
		+ "2. Open an asset you own (Megascans on Fab, once added to your library), choose a format (glTF or FBX), press Export.\n" \
		+ "3. The files are copied into your project and a material (and a ready-to-use scene for meshes) is created."
	add_child(steps)

	add_child(HSeparator.new())

	var opts = GridContainer.new()
	opts.columns = 2
	add_child(opts)
	opts.add_child(_label("Save in"))
	_dir_edit = LineEdit.new()
	_dir_edit.text = DEFAULT_SAVE_DIR
	_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dir_edit.connect("text_changed", self, "_save_settings_arg")
	opts.add_child(_dir_edit)
	opts.add_child(_label("Mesh LOD"))
	_lod_opt = OptionButton.new()
	for i in range(6):
		_lod_opt.add_item("LOD%d%s" % [i, " (highest detail)" if i == 0 else ""])
	_lod_opt.connect("item_selected", self, "_save_settings_arg")
	opts.add_child(_lod_opt)

	_material_check = _check("Create a material from the textures", true)
	_scene_check = _check("Create a ready-to-use scene (.scn) for meshes, with the material applied", true)
	_parallax_check = _check("Use the displacement map as parallax depth (off by default)", false)
	_autostart_check = _check("Start listening when the editor opens", true)

	var row = HBoxContainer.new()
	add_child(row)
	var folder_btn = Button.new()
	folder_btn.text = "Import from folder..."
	folder_btn.hint_tooltip = "Import an asset folder you already downloaded (for example the launcher's disk export)."
	folder_btn.connect("pressed", self, "_on_folder_pressed")
	row.add_child(folder_btn)

	add_child(_label("Imported this session"))
	_history = ItemList.new()
	_history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history.connect("item_selected", self, "_on_history_selected")
	add_child(_history)

	var hb = HBoxContainer.new()
	add_child(hb)
	_show_btn = Button.new()
	_show_btn.text = "Show in FileSystem"
	_show_btn.disabled = true
	_show_btn.connect("pressed", self, "_on_show_pressed")
	hb.add_child(_show_btn)
	_open_btn = Button.new()
	_open_btn.text = "Open scene"
	_open_btn.disabled = true
	_open_btn.connect("pressed", self, "_on_open_pressed")
	hb.add_child(_open_btn)

	_info = Label.new()
	_info.autowrap = true
	add_child(_info)

	var footer = Label.new()
	footer.autowrap = true
	footer.text = "Megascans from Fab use the Fab license, not CC0: keep them out of public repositories and redistributable asset packs."
	add_child(footer)

	_folder_dialog = FileDialog.new()
	_folder_dialog.mode = FileDialog.MODE_OPEN_DIR
	_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_folder_dialog.window_title = "Pick a downloaded asset folder"
	_folder_dialog.connect("dir_selected", self, "_on_folder_selected")
	add_child(_folder_dialog)


func _check(text: String, on: bool) -> CheckBox:
	var c = CheckBox.new()
	c.text = text
	c.pressed = on
	c.connect("toggled", self, "_save_settings_arg")
	add_child(c)
	return c


func _open_site() -> void:
	OS.shell_open(FAB_URL)


func _set_info(text: String) -> void:
	_info.text = text
	_refresh_status()


func _refresh_status() -> void:
	if _receiver == null or _status_label == null:
		return
	if _receiver.is_listening():
		_status_label.text = "Listening on %s:%d" % [_receiver.bind_address, _receiver.port]
		_toggle_btn.text = "Stop"
	else:
		_status_label.text = "Not listening"
		_toggle_btn.text = "Start"


# ------------------------------------------------------------------ settings

func _settings():
	return editor.get_editor_settings() if editor != null else null


func _load_settings() -> void:
	var s = _settings()
	if s == null:
		return
	if s.has_setting(PREFIX + "port"):
		_port_spin.value = int(s.get_setting(PREFIX + "port"))
	if s.has_setting(PREFIX + "save_dir"):
		_dir_edit.text = str(s.get_setting(PREFIX + "save_dir"))
	if s.has_setting(PREFIX + "lod"):
		_lod_opt.select(int(clamp(int(s.get_setting(PREFIX + "lod")), 0, 5)))
	if s.has_setting(PREFIX + "make_material"):
		_material_check.pressed = bool(s.get_setting(PREFIX + "make_material"))
	if s.has_setting(PREFIX + "make_scene"):
		_scene_check.pressed = bool(s.get_setting(PREFIX + "make_scene"))
	if s.has_setting(PREFIX + "parallax"):
		_parallax_check.pressed = bool(s.get_setting(PREFIX + "parallax"))
	if s.has_setting(PREFIX + "autostart"):
		_autostart_check.pressed = bool(s.get_setting(PREFIX + "autostart"))


func _save_settings_arg(_a = null) -> void:
	_save_settings()


func _save_settings() -> void:
	var s = _settings()
	if s == null:
		return
	s.set_setting(PREFIX + "port", int(_port_spin.value))
	s.set_setting(PREFIX + "save_dir", _dir_edit.text)
	s.set_setting(PREFIX + "lod", _lod_opt.selected)
	s.set_setting(PREFIX + "make_material", _material_check.pressed)
	s.set_setting(PREFIX + "make_scene", _scene_check.pressed)
	s.set_setting(PREFIX + "parallax", _parallax_check.pressed)
	s.set_setting(PREFIX + "autostart", _autostart_check.pressed)


# ----------------------------------------------------------------- listening

func _start() -> void:
	_save_settings()
	if _receiver.start(int(_port_spin.value)) == OK:
		_set_info("Ready. Press Export in the Fab tab of the Epic Games Launcher (target: Custom socket port %d)." % int(_port_spin.value))
	_refresh_status()


func _on_toggle_pressed() -> void:
	if _receiver.is_listening():
		_receiver.stop()
		_set_info("Stopped listening.")
	else:
		_start()
	_refresh_status()


# -------------------------------------------------------------------- import

func _opts() -> Dictionary:
	return {
		"base_dir": _dir_edit.text,
		"lod": _lod_opt.selected,
		"make_material": _material_check.pressed,
		"make_scene": _scene_check.pressed,
		"parallax": _parallax_check.pressed,
	}


func _on_payload(data) -> void:
	var assets = _importer.normalize(data)
	if assets.empty():
		_set_info("Received data from the launcher, but it did not describe any asset.")
		return
	for a in assets:
		_queue.append(a)
	_set_info("Received %d asset(s) from Fab." % assets.size())
	_run_queue()


func _on_folder_pressed() -> void:
	_folder_dialog.popup_centered_ratio(0.6)


func _on_folder_selected(dir: String) -> void:
	var a = _importer.asset_from_folder(dir)
	if a["textures"].empty() and a["meshes"].empty():
		_set_info("No textures or meshes found in that folder.")
		return
	_queue.append(a)
	_run_queue()


func _run_queue() -> void:
	if _busy:
		return
	_busy = true
	while not _queue.empty():
		var asset = _queue.pop_front()
		_set_info("Importing %s ..." % asset["name"])
		var r = yield(_importer.import_asset(asset, _opts()), "completed")
		_add_history(r)
		if r["ok"]:
			_set_info(("Imported %s into %s" % [r["name"], r["folder"]]) + ((". " + r["error"]) if r["error"] != "" else ""))
		else:
			_set_info("Import failed for %s: %s" % [r["name"], r["error"]])
	_busy = false


func _add_history(r: Dictionary) -> void:
	var label = ("%s  [%s]" if r["ok"] else "%s  [failed]") % [r["name"], r["folder"]]
	_history.add_item(label)
	_history_data.append(r)
	var idx = _history.get_item_count() - 1
	_history.select(idx)
	_on_history_selected(idx)


func _on_history_selected(idx: int) -> void:
	if idx < 0 or idx >= _history_data.size():
		return
	var r = _history_data[idx]
	_show_btn.disabled = not r["ok"]
	_open_btn.disabled = r["scene"] == ""


func _on_show_pressed() -> void:
	var sel = _history.get_selected_items()
	if sel.empty():
		return
	var r = _history_data[sel[0]]
	var path = r["scene"] if r["scene"] != "" else (r["material"] if r["material"] != "" else r["folder"])
	if editor.has_method("select_file"):
		editor.select_file(path)


func _on_open_pressed() -> void:
	var sel = _history.get_selected_items()
	if sel.empty():
		return
	var r = _history_data[sel[0]]
	if r["scene"] != "":
		editor.open_scene_from_path(r["scene"])
