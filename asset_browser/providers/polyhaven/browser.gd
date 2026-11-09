tool
extends VBoxContainer
# The "Poly Haven" tab of AssetBrowser: browse thumbnails, pick resolution/format, download.

const API = "https://api.polyhaven.com"
# Poly Haven asks API clients to send a unique User-Agent. Add your own name/contact if you like.
const USER_AGENT = "User-Agent: GodotAssetBrowser/0.2 (Godot 3 editor plugin)"
const PAGE_SIZE = 30
const THUMB_WORKERS = 4
const DEFAULT_SAVE_DIR = "res://PolyHaven"
const Planner = preload("res://addons/asset_browser/providers/polyhaven/planner.gd")

# id: asset type number used by the API (0 HDRI, 1 texture, 2 model)
const TYPES = [
	{"label": "HDRIs", "api": "hdris", "id": 0},
	{"label": "Textures / Materials", "api": "textures", "id": 1},
	{"label": "Models", "api": "models", "id": 2},
]
const SORTS = ["Popular", "Newest", "Name"]

var editor: EditorInterface

var _planner
var _api: HTTPRequest
var _dl: HTTPRequest
var _api_busy = false
var _loaded = false

var _assets = {}          # api type -> [entry]
var _files_cache = {}     # asset id -> files json
var _thumbs = {}          # asset id -> Texture
var _filtered = []
var _item_ids = []
var _page = 0
var _type_idx = 0
var _selected_id = ""
var _current_files = {}
var _last_res = ""
var _last_fmt = ""

var _thumb_workers = []
var _thumb_queue = []
var _placeholder: Texture

var _downloading = false
var _cancel = false
var _done_bytes = 0

# UI
var _type_opt: OptionButton
var _search: LineEdit
var _category_opt: OptionButton
var _sort_opt: OptionButton
var _list: ItemList
var _prev_btn: Button
var _next_btn: Button
var _page_label: Label
var _preview: TextureRect
var _name_label: Label
var _meta_label: Label
var _desc_label: Label
var _res_opt: OptionButton
var _fmt_row: HBoxContainer
var _fmt_opt: OptionButton
var _all_maps_check: CheckBox
var _material_check: CheckBox
var _dir_edit: LineEdit
var _dest_label: Label
var _size_label: Label
var _download_btn: Button
var _progress: ProgressBar
var _status: Label


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_planner = Planner.new()

	_api = HTTPRequest.new()
	_api.use_threads = true
	add_child(_api)
	_dl = HTTPRequest.new()
	_dl.use_threads = true
	add_child(_dl)
	for i in range(THUMB_WORKERS):
		var worker = HTTPRequest.new()
		worker.use_threads = true
		worker.set_meta("busy", false)
		worker.connect("request_completed", self, "_on_thumb_done", [worker])
		add_child(worker)
		_thumb_workers.append(worker)

	_placeholder = get_icon("Image", "EditorIcons")
	_build_ui()
	set_process(false)


func on_shown() -> void:
	if not _loaded:
		_loaded = true
		_load_type(_type_idx)


# ------------------------------------------------------------------------ UI

func _label(text: String) -> Label:
	var l = Label.new()
	l.text = text
	return l


func _build_ui() -> void:
	var top = HBoxContainer.new()
	add_child(top)
	_type_opt = OptionButton.new()
	for t in TYPES:
		_type_opt.add_item(t["label"])
	_type_opt.connect("item_selected", self, "_on_type_selected")
	top.add_child(_type_opt)

	_search = LineEdit.new()
	_search.placeholder_text = "Search name, tag or category..."
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.clear_button_enabled = true
	_search.connect("text_changed", self, "_on_filter_changed")
	top.add_child(_search)

	_category_opt = OptionButton.new()
	_category_opt.connect("item_selected", self, "_on_filter_changed")
	top.add_child(_category_opt)

	_sort_opt = OptionButton.new()
	for s in SORTS:
		_sort_opt.add_item(s)
	_sort_opt.connect("item_selected", self, "_on_filter_changed")
	top.add_child(_sort_opt)

	var refresh = Button.new()
	refresh.text = "Refresh"
	refresh.connect("pressed", self, "_on_refresh_pressed")
	top.add_child(refresh)

	var credit = LinkButton.new()
	credit.text = "Powered by Poly Haven"
	credit.connect("pressed", self, "_open_site")
	top.add_child(credit)

	var split = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)

	# Left: grid of thumbnails + paging
	var left = VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.max_columns = 0
	_list.same_column_width = true
	_list.fixed_icon_size = Vector2(128, 128)
	_list.max_text_lines = 2
	_list.connect("item_selected", self, "_on_item_selected")
	left.add_child(_list)

	var pager = HBoxContainer.new()
	left.add_child(pager)
	_prev_btn = Button.new()
	_prev_btn.text = "< Prev"
	_prev_btn.connect("pressed", self, "_on_page", [-1])
	pager.add_child(_prev_btn)
	_page_label = Label.new()
	_page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_label.align = Label.ALIGN_CENTER
	pager.add_child(_page_label)
	_next_btn = Button.new()
	_next_btn.text = "Next >"
	_next_btn.connect("pressed", self, "_on_page", [1])
	pager.add_child(_next_btn)

	# Right: details + download options
	var scroll = ScrollContainer.new()
	scroll.rect_min_size = Vector2(340, 0)
	scroll.scroll_horizontal_enabled = false
	split.add_child(scroll)
	var right = VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(right)

	_preview = TextureRect.new()
	_preview.rect_min_size = Vector2(0, 220)
	_preview.expand = true
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	right.add_child(_preview)

	_name_label = _wrapped_label(right)
	_meta_label = _wrapped_label(right)
	_desc_label = _wrapped_label(right)

	right.add_child(HSeparator.new())

	var res_row = HBoxContainer.new()
	right.add_child(res_row)
	res_row.add_child(_label("Resolution"))
	_res_opt = OptionButton.new()
	_res_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_res_opt.connect("item_selected", self, "_on_res_selected")
	res_row.add_child(_res_opt)

	_fmt_row = HBoxContainer.new()
	right.add_child(_fmt_row)
	_fmt_row.add_child(_label("Format"))
	_fmt_opt = OptionButton.new()
	_fmt_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fmt_opt.connect("item_selected", self, "_on_fmt_selected")
	_fmt_row.add_child(_fmt_opt)

	_all_maps_check = CheckBox.new()
	_all_maps_check.text = "All maps (also DirectX normal + packed ARM)"
	_all_maps_check.connect("toggled", self, "_on_all_maps_toggled")
	right.add_child(_all_maps_check)

	_material_check = CheckBox.new()
	_material_check.text = "Create a SpatialMaterial from the maps"
	_material_check.pressed = true
	right.add_child(_material_check)

	right.add_child(_label("Save in"))
	_dir_edit = LineEdit.new()
	_dir_edit.text = DEFAULT_SAVE_DIR
	_dir_edit.connect("text_changed", self, "_on_dir_changed")
	right.add_child(_dir_edit)

	_dest_label = _wrapped_label(right)
	_size_label = _wrapped_label(right)

	_download_btn = Button.new()
	_download_btn.text = "Download"
	_download_btn.disabled = true
	_download_btn.connect("pressed", self, "_on_download_pressed")
	right.add_child(_download_btn)

	_progress = ProgressBar.new()
	_progress.percent_visible = false
	right.add_child(_progress)

	_status = _wrapped_label(right)

	var footer = Label.new()
	footer.text = "Assets are CC0 (no attribution required). Data and downloads come from api.polyhaven.com - Powered by Poly Haven."
	footer.autowrap = true
	add_child(footer)


func _wrapped_label(parent: Node) -> Label:
	var l = Label.new()
	l.autowrap = true
	parent.add_child(l)
	return l


func _open_site() -> void:
	OS.shell_open("https://polyhaven.com")


func _set_status(text: String) -> void:
	_status.text = text


# --------------------------------------------------------------------- network

func _fetch_json(url: String):
	yield(get_tree(), "idle_frame")
	while _api_busy:
		yield(get_tree(), "idle_frame")
	_api_busy = true
	var err = _api.request(url, PoolStringArray([USER_AGENT, "Accept: application/json"]))
	if err != OK:
		_api_busy = false
		return null
	var r = yield(_api, "request_completed")
	_api_busy = false
	if r[0] != HTTPRequest.RESULT_SUCCESS or r[1] != 200:
		return null
	var parsed = JSON.parse(r[3].get_string_from_utf8())
	if parsed.error != OK:
		return null
	return parsed.result


func _load_type(idx: int) -> void:
	_type_idx = idx
	var api_type: String = TYPES[idx]["api"]
	_list.clear()
	_item_ids = []
	_clear_selection()
	if not _assets.has(api_type):
		_set_status("Loading the %s list from Poly Haven..." % TYPES[idx]["label"])
		var data = yield(_fetch_json(API + "/assets?t=" + api_type), "completed")
		if _type_idx != idx:
			return
		if not (data is Dictionary):
			_set_status("Could not load the asset list. Check your internet connection and press Refresh.")
			return
		_assets[api_type] = _to_entries(data)
		_set_status("")
	_rebuild_categories()
	_apply_filter()


func _to_entries(data: Dictionary) -> Array:
	var out = []
	for id in data.keys():
		var d = data[id]
		if not (d is Dictionary):
			continue
		var raw_tags = d.get("tags")
		if not (raw_tags is Array):
			raw_tags = []
		var tags = PoolStringArray(raw_tags)
		var cat = str(d.get("category", ""))
		var name = str(d.get("name", id))
		out.append({
			"id": id,
			"name": name,
			"cat": cat.split("/")[0],
			"search": (str(id) + " " + name + " " + tags.join(" ") + " " + cat).to_lower(),
			"downloads": int(d.get("download_count", 0)),
			"date": int(d.get("date_published", 0)),
			"thumb": str(d.get("thumbnail_url", "")),
			"raw": d,
		})
	return out


func _rebuild_categories() -> void:
	var cats = []
	for e in _assets.get(TYPES[_type_idx]["api"], []):
		if e["cat"] != "" and not cats.has(e["cat"]):
			cats.append(e["cat"])
	cats.sort()
	_category_opt.clear()
	_category_opt.add_item("All categories")
	for c in cats:
		_category_opt.add_item(c)


func _on_type_selected(idx: int) -> void:
	_search.text = ""
	_load_type(idx)


func _on_refresh_pressed() -> void:
	_assets.erase(TYPES[_type_idx]["api"])
	_load_type(_type_idx)


# -------------------------------------------------------------- list + paging

func _sort_popular(a, b) -> bool:
	return a["downloads"] > b["downloads"]


func _sort_newest(a, b) -> bool:
	return a["date"] > b["date"]


func _sort_name(a, b) -> bool:
	return a["name"].to_lower() < b["name"].to_lower()


func _on_filter_changed(_arg = null) -> void:
	_apply_filter()


func _apply_filter() -> void:
	var q = _search.text.strip_edges().to_lower()
	var cat = ""
	if _category_opt.selected > 0:
		cat = _category_opt.get_item_text(_category_opt.selected)
	_filtered = []
	for e in _assets.get(TYPES[_type_idx]["api"], []):
		if cat != "" and e["cat"] != cat:
			continue
		if q != "" and not (q in e["search"]):
			continue
		_filtered.append(e)
	match _sort_opt.selected:
		1:
			_filtered.sort_custom(self, "_sort_newest")
		2:
			_filtered.sort_custom(self, "_sort_name")
		_:
			_filtered.sort_custom(self, "_sort_popular")
	_page = 0
	_show_page()


func _on_page(delta: int) -> void:
	_page = int(clamp(_page + delta, 0, _page_count() - 1))
	_show_page()


func _page_count() -> int:
	return int(max(1, ceil(float(_filtered.size()) / PAGE_SIZE)))


func _show_page() -> void:
	_list.clear()
	_item_ids = []
	_thumb_queue.clear()
	var start = _page * PAGE_SIZE
	for i in range(start, int(min(start + PAGE_SIZE, _filtered.size()))):
		var e = _filtered[i]
		_list.add_item(e["name"], _thumbs.get(e["id"], _placeholder))
		_item_ids.append(e["id"])
		if not _thumbs.has(e["id"]):
			_thumb_queue.append({"id": e["id"], "url": e["thumb"]})
	_page_label.text = "Page %d / %d  (%d assets)" % [_page + 1, _page_count(), _filtered.size()]
	_prev_btn.disabled = _page <= 0
	_next_btn.disabled = _page >= _page_count() - 1
	_pump_thumbs()


# ----------------------------------------------------------------- thumbnails

func _pump_thumbs() -> void:
	for worker in _thumb_workers:
		while not worker.get_meta("busy") and not _thumb_queue.empty():
			var item = _thumb_queue.pop_front()
			if item["url"] == "" or _thumbs.has(item["id"]):
				continue
			worker.set_meta("busy", true)
			worker.set_meta("id", item["id"])
			if worker.request(item["url"], PoolStringArray([USER_AGENT])) != OK:
				worker.set_meta("busy", false)


func _on_thumb_done(result: int, code: int, _headers, body: PoolByteArray, worker: HTTPRequest) -> void:
	var id = worker.get_meta("id")
	worker.set_meta("busy", false)
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var tex = _texture_from_bytes(body)
		if tex != null:
			_thumbs[id] = tex
			var idx = _item_ids.find(id)
			if idx != -1:
				_list.set_item_icon(idx, tex)
			if id == _selected_id:
				_preview.texture = tex
	_pump_thumbs()


func _texture_from_bytes(b: PoolByteArray) -> Texture:
	if b.size() < 12:
		return null
	var img = Image.new()
	var err = ERR_FILE_UNRECOGNIZED
	if b[0] == 0x89 and b[1] == 0x50:
		err = img.load_png_from_buffer(b)
	elif b[0] == 0xFF and b[1] == 0xD8:
		err = img.load_jpg_from_buffer(b)
	elif b[0] == 0x52 and b[1] == 0x49 and b[8] == 0x57 and b[9] == 0x45:
		err = img.load_webp_from_buffer(b)
	if err != OK:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


# ------------------------------------------------------------------- details

func _entry_by_id(id: String):
	for e in _assets.get(TYPES[_type_idx]["api"], []):
		if e["id"] == id:
			return e
	return null


func _clear_selection() -> void:
	_selected_id = ""
	_current_files = {}
	_preview.texture = null
	_name_label.text = ""
	_meta_label.text = ""
	_desc_label.text = ""
	_res_opt.clear()
	_fmt_opt.clear()
	_dest_label.text = ""
	_size_label.text = ""
	_download_btn.disabled = true


func _on_item_selected(idx: int) -> void:
	if idx < 0 or idx >= _item_ids.size():
		return
	_select_asset(_item_ids[idx])


func _select_asset(id: String) -> void:
	_selected_id = id
	var e = _entry_by_id(id)
	if e == null:
		return
	var raw: Dictionary = e["raw"]
	_name_label.text = e["name"]
	var raw_authors = raw.get("authors")
	if not (raw_authors is Dictionary):
		raw_authors = {}
	var authors = PoolStringArray(raw_authors.keys())
	_meta_label.text = "By %s\n%s\nDownloads: %d" % [authors.join(", "), str(raw.get("category", "")), e["downloads"]]
	_desc_label.text = str(raw.get("description", ""))
	_preview.texture = _thumbs.get(id)
	_res_opt.clear()
	_fmt_opt.clear()
	_download_btn.disabled = true
	_dest_label.text = ""
	_size_label.text = ""

	var files = _files_cache.get(id)
	if files == null:
		_set_status("Loading file list...")
		files = yield(_fetch_json(API + "/files/" + id.http_escape()), "completed")
		if _selected_id != id:
			return
		if not (files is Dictionary):
			_set_status("Could not load the file list for this asset.")
			return
		_files_cache[id] = files
		_set_status("")
	_current_files = files
	_populate_resolutions()


func _type_id() -> int:
	return TYPES[_type_idx]["id"]


func _populate_resolutions() -> void:
	var previous = _last_res
	if _res_opt.selected >= 0:
		previous = _res_opt.get_item_text(_res_opt.selected)
	var list = _planner.resolutions(_type_id(), _current_files, _all_maps_check.pressed)
	_res_opt.clear()
	for r in list:
		_res_opt.add_item(r)
	var pick = list.find(previous)
	if pick == -1:
		pick = list.find("2k")
	if pick == -1:
		pick = list.size() - 1
	if pick >= 0:
		_res_opt.select(pick)
	_populate_formats()


func _populate_formats() -> void:
	var previous = _last_fmt
	if _fmt_opt.selected >= 0:
		previous = _fmt_opt.get_item_text(_fmt_opt.selected)
	_fmt_opt.clear()
	var res = _selected_res()
	var list = []
	if res != "":
		list = _planner.formats(_type_id(), _current_files, res, _all_maps_check.pressed)
	for f in list:
		_fmt_opt.add_item(f)
	var preferred = {0: "hdr", 1: "jpg", 2: "gltf"}[_type_id()]
	var pick = list.find(previous)
	if pick == -1:
		pick = list.find(preferred)
	if pick == -1:
		pick = 0
	if pick >= 0 and not list.empty():
		_fmt_opt.select(pick)
	_fmt_row.visible = _type_id() != 2
	_all_maps_check.visible = _type_id() == 1
	_material_check.visible = _type_id() == 1
	_refresh_plan()


func _selected_res() -> String:
	if _res_opt.selected < 0:
		return ""
	return _res_opt.get_item_text(_res_opt.selected)


func _selected_fmt() -> String:
	if _fmt_opt.selected < 0:
		return ""
	return _fmt_opt.get_item_text(_fmt_opt.selected)


func _make_plan() -> Dictionary:
	return _planner.plan(_type_id(), _selected_id, _current_files, _selected_res(), _selected_fmt(), _all_maps_check.pressed, _dir_edit.text)


func _refresh_plan() -> void:
	if _selected_id == "" or _selected_res() == "":
		return
	var p = _make_plan()
	if not p["ok"]:
		_dest_label.text = p["error"]
		_size_label.text = ""
		_download_btn.disabled = true
		return
	var total = 0
	for j in p["jobs"]:
		total += j["size"]
	_dest_label.text = "Will be saved in: %s/" % p["folder"]
	_size_label.text = "%d file(s), about %.1f MB" % [p["jobs"].size(), total / 1048576.0]
	_download_btn.disabled = false


func _on_res_selected(_i: int) -> void:
	_last_res = _selected_res()
	_populate_formats()


func _on_fmt_selected(_i: int) -> void:
	_last_fmt = _selected_fmt()
	_refresh_plan()


func _on_all_maps_toggled(_pressed: bool) -> void:
	if _selected_id != "":
		_populate_resolutions()


func _on_dir_changed(_text: String) -> void:
	_refresh_plan()


# ------------------------------------------------------------------ download

func _process(_delta: float) -> void:
	if _downloading:
		_progress.value = _done_bytes + _dl.get_downloaded_bytes()


func _on_download_pressed() -> void:
	if _downloading:
		_cancel = true
		_dl.cancel_request()
		# cancel_request() does not emit a signal, so wake up the waiting download loop ourselves.
		_dl.emit_signal("request_completed", HTTPRequest.RESULT_REQUEST_FAILED, 0, PoolStringArray(), PoolByteArray())
		return
	var p = _make_plan()
	if not p["ok"]:
		_set_status(p["error"])
		return
	var id = _selected_id
	_downloading = true
	_cancel = false
	_download_btn.text = "Cancel"
	set_process(true)
	var ok = yield(_download_all(p["jobs"]), "completed")
	_downloading = false
	set_process(false)
	_download_btn.text = "Download"
	if ok:
		_progress.value = _progress.max_value
		_set_status("Done. Saved in %s/" % p["folder"])
		editor.get_resource_filesystem().scan()
		if _type_id() == 1 and _material_check.pressed:
			_create_material_when_ready(id, p["folder"], p["maps"])
	elif _cancel:
		_set_status("Download cancelled.")


func _download_all(jobs: Array) -> bool:
	yield(get_tree(), "idle_frame")
	var total = 0
	for j in jobs:
		total += j["size"]
	_progress.max_value = max(total, 1)
	_done_bytes = 0
	var dir = Directory.new()
	var file = File.new()
	for i in range(jobs.size()):
		var j = jobs[i]
		if _cancel:
			return false
		# Skip files that are already here and intact.
		if file.file_exists(j["path"]) and j["md5"] != "" and file.get_md5(j["path"]) == j["md5"]:
			_done_bytes += j["size"]
			continue
		dir.make_dir_recursive(j["path"].get_base_dir())
		var tmp = j["path"] + ".part"
		_dl.download_file = tmp
		_set_status("Downloading %d/%d: %s" % [i + 1, jobs.size(), j["path"].get_file()])
		if _dl.request(j["url"], PoolStringArray([USER_AGENT])) != OK:
			_set_status("Could not start the download of " + j["path"].get_file())
			return false
		var r = yield(_dl, "request_completed")
		if _cancel:
			_remove_file(tmp)
			return false
		if r[0] != HTTPRequest.RESULT_SUCCESS or r[1] != 200:
			_remove_file(tmp)
			_set_status("Download failed for %s (result %d, HTTP %d)." % [j["path"].get_file(), r[0], r[1]])
			return false
		if j["md5"] != "" and file.get_md5(tmp) != j["md5"]:
			_remove_file(tmp)
			_set_status("Checksum mismatch for %s. The file was discarded." % j["path"].get_file())
			return false
		_remove_file(j["path"])
		dir.rename(tmp, j["path"])
		_done_bytes += j["size"]
	return true


func _remove_file(path: String) -> void:
	var dir = Directory.new()
	if dir.file_exists(path):
		dir.remove(path)


# ----------------------------------------------------------- SpatialMaterial

func _role_of(map_key: String) -> String:
	match map_key.to_lower():
		"diffuse", "diff", "color", "albedo":
			return "albedo"
		"nor_gl", "normal":
			return "normal"
		"rough", "roughness":
			return "roughness"
		"metal", "metallic", "metalness":
			return "metallic"
		"ao":
			return "ao"
		"emission", "emissive":
			return "emission"
	return ""


func _create_material_when_ready(id: String, folder: String, maps: Dictionary) -> void:
	yield(get_tree(), "idle_frame")
	var roles = {}
	for k in maps.keys():
		var role = _role_of(k)
		if role != "":
			roles[role] = maps[k]
	if not roles.has("albedo"):
		return
	_set_status("Waiting for the editor to import the textures...")
	var file = File.new()
	var waited = 0.0
	var ready = false
	while waited < 90.0 and not ready:
		ready = true
		for role in roles.keys():
			if not file.file_exists(roles[role] + ".import"):
				ready = false
		if not ready:
			yield(get_tree().create_timer(0.5), "timeout")
			waited += 0.5
	if not ready:
		_set_status("Textures were saved, but the import took too long to create the material. Create it by hand.")
		return
	yield(get_tree().create_timer(1.0), "timeout")

	var tex = {}
	for role in roles.keys():
		var t = load(roles[role])
		if t == null:
			_set_status("Textures were saved, but could not be loaded yet. Create the material by hand.")
			return
		tex[role] = t

	var m = SpatialMaterial.new()
	m.albedo_texture = tex["albedo"]
	if tex.has("normal"):
		m.normal_enabled = true
		m.normal_texture = tex["normal"]
	if tex.has("roughness"):
		m.roughness = 1.0
		m.roughness_texture = tex["roughness"]
		m.roughness_texture_channel = SpatialMaterial.TEXTURE_CHANNEL_RED
	if tex.has("metallic"):
		m.metallic = 1.0
		m.metallic_texture = tex["metallic"]
		m.metallic_texture_channel = SpatialMaterial.TEXTURE_CHANNEL_RED
	if tex.has("ao"):
		m.ao_enabled = true
		m.ao_texture = tex["ao"]
		m.ao_texture_channel = SpatialMaterial.TEXTURE_CHANNEL_RED
	if tex.has("emission"):
		m.emission_enabled = true
		m.emission_texture = tex["emission"]
	var path = "%s/%s.tres" % [folder, id]
	if ResourceSaver.save(path, m) == OK:
		_set_status("Done. Material saved as %s" % path)
		editor.get_resource_filesystem().scan()
	else:
		_set_status("Could not save the material.")
