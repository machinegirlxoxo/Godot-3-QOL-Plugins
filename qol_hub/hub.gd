tool
extends VBoxContainer

const REPO_OWNER = "machinegirlxoxo"
const REPO_NAME = "Godot-3-QOL-Plugins"
const BRANCH = "main"

const RESULT_NAMES = {
	1: "chunked body size mismatch", 2: "can't connect", 3: "can't resolve host",
	4: "connection error", 5: "TLS handshake error", 6: "no response",
	7: "body size limit exceeded", 8: "request failed", 9: "can't open download file",
	10: "download file write error", 11: "redirect limit reached", 12: "timeout",
}

const TREE_URL = "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1"
const RAW_URL = "https://raw.githubusercontent.com/%s/%s/%s/%s"

const FALLBACK = {
	"animation_retargeting": ["animation_retargeting/AnimationRetargeting.gd", "animation_retargeting/AnimationRetargetingPluginSetup.gd", "animation_retargeting/FileRetargetDialog.gd", "animation_retargeting/ar_icon.png", "animation_retargeting/plugin.cfg"],
	"camera_preview": ["camera_preview/camera_inspector.gd", "camera_preview/camera_preview.gd", "camera_preview/plugin.cfg", "camera_preview/plugin.gd"],
	"viewmodel_material": ["viewmodel_material/plugin.cfg", "viewmodel_material/plugin.gd", "viewmodel_material/viewmodel_inspector.gd", "viewmodel_material/viewmodel_material.gd"]
}

var editor_plugin

var _list
var _status
var _refresh_btn
var _loaded = false
var _busy = false
var _updating = false

var _plugins = {}   # folder -> {"files": [paths], "cfg": {name, description, author, version}}
var _rows = {}      # folder -> {"btn": Button, "check": CheckButton}


func _ready():
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	rect_min_size = Vector2(400, 300)
	_build_ui()


func on_shown():
	if not _loaded:
		_loaded = true
		_refresh()
	else:
		for folder in _rows:
			_update_row(folder)


# ---------------------------------------------------------------- UI

func _build_ui():
	var header = HBoxContainer.new()
	add_child(header)

	var title = Label.new()
	title.text = "QOL Plugins  -  %s/%s" % [REPO_OWNER, REPO_NAME]
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)

	_refresh_btn = Button.new()
	_refresh_btn.text = "Refresh"
	_refresh_btn.connect("pressed", self, "_refresh")
	header.add_child(_refresh_btn)

	_status = Label.new()
	_status.autowrap = true
	add_child(_status)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.scroll_horizontal_enabled = false
	add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_list)


func _set_status(text):
	if _status:
		_status.text = text


func _add_card(folder):
	var cfg = _plugins[folder].cfg

	var panel = PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_child(panel)

	var h = HBoxContainer.new()
	panel.add_child(h)

	var v = VBoxContainer.new()
	v.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(v)

	var title = Label.new()
	var t = cfg.name
	if cfg.version != "":
		t += "   v" + cfg.version
	if cfg.author != "":
		t += "   by " + cfg.author
	title.text = t
	v.add_child(title)

	var desc = Label.new()
	desc.text = cfg.description
	desc.autowrap = true
	desc.modulate = Color(1, 1, 1, 0.7)
	v.add_child(desc)

	var right = VBoxContainer.new()
	h.add_child(right)

	var btn = Button.new()
	btn.connect("pressed", self, "_on_install", [folder])
	right.add_child(btn)

	var check = CheckButton.new()
	check.text = "Enabled"
	check.connect("toggled", self, "_on_toggle", [folder])
	right.add_child(check)

	_rows[folder] = {"btn": btn, "check": check}
	_update_row(folder)


func _update_row(folder):
	var row = _rows[folder]
	var installed = _is_installed(folder)
	row.btn.text = "Reinstall / Update" if installed else "Install"
	row.check.visible = installed
	_updating = true
	row.check.pressed = installed and _is_enabled(folder)
	_updating = false


# ---------------------------------------------------------------- State

func _is_installed(folder):
	return File.new().file_exists("res://addons/%s/plugin.cfg" % folder)


func _is_enabled(folder):
	if not ProjectSettings.has_setting("editor_plugins/enabled"):
		return false
	var list = ProjectSettings.get_setting("editor_plugins/enabled")
	return list.has("res://addons/%s/plugin.cfg" % folder)


# ---------------------------------------------------------------- Networking

# Always yields at least once, so callers can safely `yield(_fetch(url), "completed")`.
func _fetch(url):
	var http = HTTPRequest.new()
	add_child(http)
	var err = http.request(url, PoolStringArray(["User-Agent: godot-qol-hub"]))
	if err != OK:
		http.queue_free()
		yield(get_tree(), "idle_frame")
		return {"ok": false, "code": 0, "body": PoolByteArray(), "error": "request() failed (error %d)" % err}
	var r = yield(http, "request_completed")
	http.queue_free()
	var ok = r[0] == HTTPRequest.RESULT_SUCCESS and r[1] == 200
	var msg = ""
	if not ok:
		msg = "HTTP %d, result %d (%s)" % [r[1], r[0], RESULT_NAMES.get(r[0], "?")]
		print("[QOL Hub] ", url, " -> ", msg)
	return {"ok": ok, "code": r[1], "body": r[3], "error": msg}


func _finish_refresh():
	_busy = false
	_refresh_btn.disabled = false


func _refresh():
	if _busy:
		return
	_busy = true
	_refresh_btn.disabled = true
	_set_status("Fetching plugin list from GitHub...")

	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	_plugins.clear()

	var folders = {}
	var res = yield(_fetch(TREE_URL % [REPO_OWNER, REPO_NAME, BRANCH]), "completed")
	var from_api = false
	if res.ok:
		var parsed = JSON.parse(res.body.get_string_from_utf8())
		if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
			from_api = true
			# Group files by top-level folder; a folder with a plugin.cfg is a plugin.
			for e in parsed.result.get("tree", []):
				if e.type != "blob":
					continue
				var parts = e.path.split("/", false)
				if parts.size() < 2:
					continue
				if not folders.has(parts[0]):
					folders[parts[0]] = []
				folders[parts[0]].append(e.path)
	if not from_api:
		folders = FALLBACK.duplicate(true)
		_set_status("GitHub API unavailable (%s). Using the built-in plugin list." % res.error)

	var names = []
	for f in folders:
		if folders[f].has(f + "/plugin.cfg"):
			names.append(f)
	names.sort()

	for folder in names:
		var cfg = {"name": folder, "description": "", "author": "", "version": ""}
		var cres = yield(_fetch(RAW_URL % [REPO_OWNER, REPO_NAME, BRANCH, folder + "/plugin.cfg"]), "completed")
		if cres.ok:
			var cf = ConfigFile.new()
			if cf.parse(cres.body.get_string_from_utf8()) == OK:
				cfg.name = str(cf.get_value("plugin", "name", folder))
				cfg.description = str(cf.get_value("plugin", "description", ""))
				cfg.author = str(cf.get_value("plugin", "author", ""))
				cfg.version = str(cf.get_value("plugin", "version", ""))
		_plugins[folder] = {"files": folders[folder], "cfg": cfg}
		_add_card(folder)

	if names.empty():
		_set_status("No plugins found in the repo.")
	else:
		if from_api:
			_set_status("%d plugins available. Install puts them in res://addons/." % names.size())
	_finish_refresh()


# ---------------------------------------------------------------- Install / enable

func _on_install(folder):
	if _busy:
		return
	_busy = true
	_refresh_btn.disabled = true
	var row = _rows[folder]
	row.btn.disabled = true

	# Download everything first so a failed download doesn't leave a half-installed plugin.
	var downloaded = {}
	var files = []
	for p in _plugins[folder].files:
		if not p.ends_with(".import"):   # let Godot generate its own import data
			files.append(p)

	var i = 0
	for path in files:
		i += 1
		_set_status("Downloading %s (%d/%d): %s" % [folder, i, files.size(), path])
		var res = yield(_fetch(RAW_URL % [REPO_OWNER, REPO_NAME, BRANCH, path.replace(" ", "%20")]), "completed")
		if not res.ok:
			_set_status("Failed to download %s: %s. Nothing was installed." % [path, res.error])
			row.btn.disabled = false
			_finish_refresh()
			return
		downloaded[path] = res.body

	for path in downloaded:
		var target = "res://addons/" + path
		Directory.new().make_dir_recursive(target.get_base_dir())
		var f = File.new()
		if f.open(target, File.WRITE) != OK:
			_set_status("Could not write %s." % target)
			row.btn.disabled = false
			_finish_refresh()
			return
		f.store_buffer(downloaded[path])
		f.close()

	editor_plugin.get_editor_interface().get_resource_filesystem().scan()
	yield(get_tree().create_timer(1.0), "timeout")

	row.btn.disabled = false
	_update_row(folder)
	_set_status("Installed %s to res://addons/%s. Tick 'Enabled' to turn it on." % [_plugins[folder].cfg.name, folder])
	_finish_refresh()


func _on_toggle(pressed, folder):
	if _updating:
		return
	editor_plugin.get_editor_interface().set_plugin_enabled(folder, pressed)
	_set_status("%s %s." % [_plugins[folder].cfg.name, "enabled" if pressed else "disabled"])
