tool
extends VBoxContainer
# The "Megascans" main-screen tab. Listens for Quixel Bridge's "Custom Socket Export" and imports
# what Bridge sends: textures -> material, OBJ/glTF meshes -> scene. Also imports a plain folder
# of Megascans/Fab files.

const Parser = preload("res://addons/megascans_link/parser.gd")
const BridgeServer = preload("res://addons/megascans_link/bridge_server.gd")

const DEFAULT_PORT = 24981
const DEFAULT_DIR = "res://Megascans"
const SETTING = "megascans_link/"

# Used instead of SpatialMaterial when the asset has an opacity map (foliage, decals).
const OPACITY_SHADER = """shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : hint_albedo;
uniform sampler2D opacity_tex : hint_white;
uniform sampler2D normal_tex : hint_normal;
uniform sampler2D roughness_tex : hint_white;
uniform sampler2D metallic_tex : hint_black;
uniform sampler2D ao_tex : hint_white;
uniform float alpha_cutoff : hint_range(0, 1) = 0.5;

void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb;
	ALPHA = texture(opacity_tex, UV).r;
	ALPHA_SCISSOR = alpha_cutoff;
	NORMALMAP = texture(normal_tex, UV).xyz;
	ROUGHNESS = texture(roughness_tex, UV).r;
	METALLIC = texture(metallic_tex, UV).r;
	AO = texture(ao_tex, UV).r;
	AO_LIGHT_AFFECT = 0.0;
}
"""

var editor: EditorInterface

var _parser
var _server

var _assets = []          # normalised assets shown in the list
var _thumbs = {}          # asset id -> Texture
var _selected = -1
var _queue = []
var _busy = false
var _loading = true
var _placeholder: Texture

# UI
var _port_spin: SpinBox
var _listen_btn: Button
var _autostart_check: CheckBox
var _auto_import_check: CheckBox
var _listen_label: Label
var _list: ItemList
var _folder_dialog: FileDialog
var _help: Label
var _preview: TextureRect
var _name_label: Label
var _meta_label: Label
var _material_check: CheckBox
var _scene_check: CheckBox
var _parallax_check: CheckBox
var _dir_edit: LineEdit
var _plan_label: Label
var _import_btn: Button
var _progress: ProgressBar
var _status: Label


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_parser = Parser.new()
	_server = BridgeServer.new()
	_placeholder = get_icon("Image", "EditorIcons")
	_build_ui()
	_load_settings()
	_loading = false
	set_process(false)
	if _autostart_check.pressed:
		_start_listening()


func _exit_tree() -> void:
	if _server != null:
		_server.stop()


func on_shown() -> void:
	pass


# ------------------------------------------------------------------------ settings

func _editor_settings():
	return editor.get_editor_settings() if editor != null else null


func _setting(key: String, default):
	var es = _editor_settings()
	if es != null and es.has_setting(SETTING + key):
		return es.get_setting(SETTING + key)
	return default


func _store(key: String, value) -> void:
	var es = _editor_settings()
	if es != null:
		es.set_setting(SETTING + key, value)


func _load_settings() -> void:
	_port_spin.value = int(_setting("port", DEFAULT_PORT))
	_dir_edit.text = str(_setting("dir", DEFAULT_DIR))
	_autostart_check.pressed = bool(_setting("auto_start", false))
	_auto_import_check.pressed = bool(_setting("auto_import", true))
	_material_check.pressed = bool(_setting("make_material", true))
	_scene_check.pressed = bool(_setting("make_scene", true))
	_parallax_check.pressed = bool(_setting("parallax", false))


func _on_option_changed(_arg = null) -> void:
	if _loading:
		return
	_store("port", int(_port_spin.value))
	_store("dir", _dir_edit.text)
	_store("auto_start", _autostart_check.pressed)
	_store("auto_import", _auto_import_check.pressed)
	_store("make_material", _material_check.pressed)
	_store("make_scene", _scene_check.pressed)
	_store("parallax", _parallax_check.pressed)
	_refresh_plan()


# ----------------------------------------------------------------------------- UI

func _label(text: String) -> Label:
	var l = Label.new()
	l.text = text
	return l


func _wrapped_label(parent: Node) -> Label:
	var l = Label.new()
	l.autowrap = true
	parent.add_child(l)
	return l


func _check(parent: Node, text: String) -> CheckBox:
	var c = CheckBox.new()
	c.text = text
	c.connect("toggled", self, "_on_option_changed")
	parent.add_child(c)
	return c


func _build_ui() -> void:
	var top = HBoxContainer.new()
	add_child(top)
	top.add_child(_label("Bridge port"))
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65535
	_port_spin.step = 1
	_port_spin.value = DEFAULT_PORT
	_port_spin.connect("value_changed", self, "_on_option_changed")
	top.add_child(_port_spin)
	_listen_btn = Button.new()
	_listen_btn.text = "Start listening"
	_listen_btn.connect("pressed", self, "_on_listen_pressed")
	top.add_child(_listen_btn)
	_autostart_check = _check(top, "Start with editor")
	_auto_import_check = _check(top, "Import automatically")
	_listen_label = Label.new()
	_listen_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_listen_label.text = "Not listening."
	top.add_child(_listen_label)
	var fab = LinkButton.new()
	fab.text = "Get Megascans on Fab"
	fab.connect("pressed", self, "_open_fab")
	top.add_child(fab)

	var split = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)

	# Left: assets received from Bridge
	var left = VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.max_columns = 0
	_list.same_column_width = true
	_list.fixed_icon_size = Vector2(112, 112)
	_list.max_text_lines = 2
	_list.connect("item_selected", self, "_on_item_selected")
	left.add_child(_list)
	var buttons = HBoxContainer.new()
	left.add_child(buttons)
	var folder_btn = Button.new()
	folder_btn.text = "Import folder..."
	folder_btn.hint_tooltip = "Import a folder of already-downloaded Megascans / Fab files (no Bridge needed)."
	folder_btn.connect("pressed", self, "_on_folder_pressed")
	buttons.add_child(folder_btn)
	var clear_btn = Button.new()
	clear_btn.text = "Clear list"
	clear_btn.connect("pressed", self, "_on_clear_pressed")
	buttons.add_child(clear_btn)

	_folder_dialog = FileDialog.new()
	_folder_dialog.mode = FileDialog.MODE_OPEN_DIR
	_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_folder_dialog.window_title = "Choose a folder with Megascans / Fab files"
	_folder_dialog.connect("dir_selected", self, "_on_folder_selected")
	add_child(_folder_dialog)

	# Right: details + options
	var scroll = ScrollContainer.new()
	scroll.rect_min_size = Vector2(360, 0)
	scroll.scroll_horizontal_enabled = false
	split.add_child(scroll)
	var right = VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(right)

	_help = _wrapped_label(right)
	_help.text = "How to use\n1. Press 'Start listening'.\n2. In Quixel Bridge open the export settings: set the export target to 'Custom Socket Export', the socket port to the port above, and the mesh format to OBJ (Godot 3 cannot import FBX).\n3. Download an asset in Bridge and press Export. It appears in the list on the left.\n\nNo Bridge? Use 'Import folder...' on a folder of downloaded Megascans files."

	_preview = TextureRect.new()
	_preview.rect_min_size = Vector2(0, 200)
	_preview.expand = true
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	right.add_child(_preview)
	_name_label = _wrapped_label(right)
	_meta_label = _wrapped_label(right)
	right.add_child(HSeparator.new())

	_material_check = _check(right, "Create a material from the maps")
	_scene_check = _check(right, "Create a scene from the meshes (3D assets)")
	_parallax_check = _check(right, "Use the displacement map as parallax depth")

	right.add_child(_label("Save in"))
	_dir_edit = LineEdit.new()
	_dir_edit.text = DEFAULT_DIR
	_dir_edit.connect("text_changed", self, "_on_option_changed")
	right.add_child(_dir_edit)

	_plan_label = _wrapped_label(right)
	_import_btn = Button.new()
	_import_btn.text = "Import"
	_import_btn.disabled = true
	_import_btn.connect("pressed", self, "_on_import_pressed")
	right.add_child(_import_btn)
	_progress = ProgressBar.new()
	_progress.percent_visible = false
	right.add_child(_progress)
	_status = _wrapped_label(right)

	var footer = Label.new()
	footer.autowrap = true
	footer.text = "Megascans content comes with its own license (the Fab Standard License, or the older Epic Content License for assets from the old Bridge/Quixel library, which only covers Unreal Engine). Check which one applies to your copy before using it in Godot. Not affiliated with Quixel or Epic Games."
	add_child(footer)


func _set_status(text: String) -> void:
	_status.text = text


func _open_fab() -> void:
	OS.shell_open("https://www.fab.com/")


# ------------------------------------------------------------------ Bridge listener

func _on_listen_pressed() -> void:
	if _server.is_listening():
		_stop_listening()
	else:
		_start_listening()


func _start_listening() -> void:
	var p = int(_port_spin.value)
	var err = _server.start(p)
	if err != OK:
		_listen_label.text = "Could not listen on port %d (error %d). Is another app using it?" % [p, err]
		return
	set_process(true)
	_port_spin.editable = false
	_listen_btn.text = "Stop listening"
	_listen_label.text = "Listening on 127.0.0.1:%d - press Export in Bridge." % p


func _stop_listening() -> void:
	_server.stop()
	set_process(false)
	_port_spin.editable = true
	_listen_btn.text = "Start listening"
	_listen_label.text = "Not listening."


func _process(_delta: float) -> void:
	for text in _server.poll():
		_on_payload(text)


func _on_payload(text: String) -> void:
	var r = _parser.parse_payload(text)
	if not r["ok"]:
		_set_status(r["error"])
		return
	var first = -1
	for a in r["assets"]:
		var idx = _add_asset(a)
		if first == -1:
			first = idx
		if _auto_import_check.pressed:
			_queue.append(a)
	_select(first)
	_set_status("Received %d asset(s) from Bridge." % r["assets"].size())
	if _auto_import_check.pressed:
		_run_queue()


# ------------------------------------------------------------------------- the list

func _index_of(id: String) -> int:
	for i in range(_assets.size()):
		if _assets[i]["id"] == id:
			return i
	return -1


func _thumb_for(a: Dictionary) -> Texture:
	if _thumbs.has(a["id"]):
		return _thumbs[a["id"]]
	var path = str(a["preview"])
	if path != "" and File.new().file_exists(path):
		var img = Image.new()
		if img.load(path) == OK:
			var tex = ImageTexture.new()
			tex.create_from_image(img, Texture.FLAG_FILTER)
			_thumbs[a["id"]] = tex
			return tex
	return _placeholder


func _add_asset(a: Dictionary) -> int:
	var idx = _index_of(a["id"])
	if idx == -1:
		_assets.append(a)
		_list.add_item(a["name"], _thumb_for(a))
		return _assets.size() - 1
	_assets[idx] = a
	_list.set_item_text(idx, a["name"])
	_list.set_item_icon(idx, _thumb_for(a))
	return idx


func _select(idx: int) -> void:
	if idx < 0 or idx >= _assets.size():
		return
	_list.select(idx)    # select() does not emit item_selected
	_on_item_selected(idx)


func _on_item_selected(idx: int) -> void:
	if idx < 0 or idx >= _assets.size():
		return
	_selected = idx
	var a = _assets[idx]
	_help.visible = false
	_preview.texture = _thumb_for(a)
	_name_label.text = a["name"]
	var types = []
	for c in a["components"]:
		if str(c["type"]) != "" and not types.has(c["type"]):
			types.append(c["type"])
	_meta_label.text = "Type: %s\nResolution: %s\nMaps: %s\nMeshes: %d" % [
		a["type"], a["resolution"] if a["resolution"] != "" else "-",
		PoolStringArray(types).join(", ") if not types.empty() else "-", a["meshes"].size()]
	_refresh_plan()


func _on_clear_pressed() -> void:
	_assets = []
	_queue = []
	_selected = -1
	_list.clear()
	_preview.texture = null
	_name_label.text = ""
	_meta_label.text = ""
	_plan_label.text = ""
	_import_btn.disabled = true
	_help.visible = true


func _refresh_plan() -> void:
	if _selected < 0 or _selected >= _assets.size():
		return
	var p = _parser.build_plan(_assets[_selected], _dir_edit.text)
	if not p["ok"]:
		_plan_label.text = p["error"]
		_import_btn.disabled = true
		return
	var roles = PoolStringArray(p["maps"].keys())
	var text = "Will be saved in: %s/\n%d texture(s), %d mesh file(s)" % [p["folder"], p["jobs"].size() - p["meshes"].size(), p["meshes"].size()]
	if not p["maps"].empty():
		text += "\nMaterial maps: " + roles.join(", ")
	for n in p["notes"]:
		text += "\n" + n
	_plan_label.text = text
	_import_btn.disabled = _busy


# -------------------------------------------------------------------- folder import

func _on_folder_pressed() -> void:
	_folder_dialog.popup_centered_ratio(0.6)


func _list_files(path: String, depth: int) -> Array:
	var out = []
	var d = Directory.new()
	if d.open(path) != OK:
		return out
	d.list_dir_begin(true, true)
	var n = d.get_next()
	while n != "":
		var full = path.plus_file(n)
		if d.current_is_dir():
			if depth > 0:
				out += _list_files(full, depth - 1)
		else:
			out.append(full)
		n = d.get_next()
	d.list_dir_end()
	return out


func _on_folder_selected(path: String) -> void:
	var a = _parser.asset_from_folder(_list_files(path, 2), path.get_file())
	if a["components"].empty() and a["meshes"].empty():
		_set_status("No textures or meshes found in that folder.")
		return
	_select(_add_asset(a))
	_set_status("Folder loaded. Check the options, then press Import.")


# ------------------------------------------------------------------------- importing

func _on_import_pressed() -> void:
	if _selected < 0 or _selected >= _assets.size():
		return
	_queue.append(_assets[_selected])
	_run_queue()


func _run_queue() -> void:
	if _busy:
		return
	_busy = true
	_import_btn.disabled = true
	while not _queue.empty():
		var asset = _queue.pop_front()
		yield(_import_asset(asset), "completed")
	_busy = false
	_refresh_plan()


func _file_len(path: String) -> int:
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return -1
	var n = f.get_len()
	f.close()
	return n


func _copy_file(src: String, dst: String) -> bool:
	var dir = Directory.new()
	dir.make_dir_recursive(dst.get_base_dir())
	var existing = _file_len(dst)
	if existing >= 0 and existing == _file_len(src):
		return true    # already here
	return dir.copy(src, dst) == OK


# Bridge's OBJ files point at a .mtl file we do not copy. Godot 3 logs an error when it is
# missing, so write an empty stub with the name the OBJ asks for.
func _ensure_mtl_stub(obj_path: String) -> void:
	var f = File.new()
	if f.open(obj_path, File.READ) != OK:
		return
	var mtl = ""
	var lines = 0
	while not f.eof_reached() and lines < 60:
		var line = f.get_line().strip_edges()
		lines += 1
		if line.begins_with("mtllib "):
			mtl = line.substr(7).strip_edges()
			break
	f.close()
	if mtl == "" or "/" in mtl or "\\" in mtl or ".." in mtl or mtl.get_extension().to_lower() != "mtl":
		return
	var path = obj_path.get_base_dir() + "/" + mtl
	if f.file_exists(path):
		return
	if f.open(path, File.WRITE) == OK:
		f.store_line("# Intentionally empty (written by Megascans Link).")
		f.close()


func _rescan() -> void:
	if editor != null:
		editor.get_resource_filesystem().scan()


func _import_asset(asset: Dictionary) -> bool:
	yield(get_tree(), "idle_frame")
	var plan = _parser.build_plan(asset, _dir_edit.text)
	if not plan["ok"]:
		_set_status(plan["error"])
		return false

	var jobs = plan["jobs"]
	_progress.max_value = jobs.size() + 1
	_progress.value = 0
	var file = File.new()
	for i in range(jobs.size()):
		var j = jobs[i]
		_set_status("Copying %d/%d: %s" % [i + 1, jobs.size(), j["dst"].get_file()])
		if not file.file_exists(j["src"]):
			_set_status("Bridge listed a file that is not on disk: " + j["src"])
			return false
		if not _copy_file(j["src"], j["dst"]):
			_set_status("Could not copy " + j["src"].get_file())
			return false
		_progress.value = i + 1
		yield(get_tree(), "idle_frame")

	for mesh in plan["meshes"]:
		if mesh.get_extension().to_lower() == "obj":
			_ensure_mtl_stub(mesh)
	_rescan()
	var wanted = []
	for role in plan["maps"].keys():
		wanted.append(plan["maps"][role])
	wanted += plan["meshes"]
	var make_material = _material_check.pressed and plan["maps"].has("albedo")
	var make_scene = _scene_check.pressed and not plan["meshes"].empty()
	var done_text = "Done. Saved in %s/" % plan["folder"]

	if make_material or make_scene:
		_set_status("Waiting for the editor to import the files...")
		var ready = yield(_wait_for_import(wanted), "completed")
		if not ready:
			_set_status("Files were saved, but the import took too long to build the material/scene. Create them by hand, or import again once the editor has finished.")
			return true

		var material = null
		if make_material:
			var tex = {}
			for role in plan["maps"].keys():
				var t = _load_texture(plan["maps"][role])
				if t != null:
					tex[role] = t
			if tex.has("albedo"):
				material = _build_material(tex, _parallax_check.pressed)
				var mpath = "%s/%s.tres" % [plan["folder"], plan["slug"]]
				if ResourceSaver.save(mpath, material) == OK:
					material.take_over_path(mpath)    # so the scene references the .tres instead of embedding a copy
					done_text += "\nMaterial: " + mpath
				else:
					material = null
					done_text += "\nCould not save the material."
			else:
				done_text += "\nCould not load the textures yet - create the material by hand."

		if make_scene:
			var root = _build_scene(plan["slug"], _parser.scene_meshes(plan["meshes"]), material)
			if root != null:
				var spath = "%s/%s.tscn" % [plan["folder"], plan["slug"]]
				var packed = PackedScene.new()
				if packed.pack(root) == OK and ResourceSaver.save(spath, packed) == OK:
					done_text += "\nScene: " + spath
				else:
					done_text += "\nCould not save the scene."
				root.free()
			else:
				done_text += "\nNo mesh could be loaded yet - add it to a scene by hand."
		_rescan()

	for n in plan["notes"]:
		done_text += "\n" + n
	_progress.value = _progress.max_value
	_set_status(done_text)
	return true


# Waits (up to ~90 s) until the editor has written the .import file for every path.
func _wait_for_import(paths: Array) -> bool:
	yield(get_tree(), "idle_frame")
	if editor == null:
		return true    # no editor (tests): nothing to wait for
	var file = File.new()
	var waited = 0.0
	while waited < 90.0:
		var ready = true
		for p in paths:
			if not file.file_exists(p + ".import"):
				ready = false
				break
		if ready:
			yield(get_tree().create_timer(1.0), "timeout")
			return true
		yield(get_tree().create_timer(0.5), "timeout")
		waited += 0.5
	return false


func _load_texture(path: String) -> Texture:
	var t = load(path)
	if t is Texture:
		return t
	var img = Image.new()    # fallback when the editor has not imported it (yet)
	if img.load(path) == OK:
		var it = ImageTexture.new()
		it.create_from_image(img)
		return it
	return null


# ------------------------------------------------------------------ material + scene

func _build_material(tex: Dictionary, parallax: bool) -> Material:
	if tex.has("opacity"):
		var shader = Shader.new()
		shader.code = OPACITY_SHADER
		var sm = ShaderMaterial.new()
		sm.shader = shader
		var uniforms = {"albedo": "albedo_tex", "opacity": "opacity_tex", "normal": "normal_tex",
				"roughness": "roughness_tex", "metallic": "metallic_tex", "ao": "ao_tex"}
		for role in uniforms.keys():
			if tex.has(role):
				sm.set_shader_param(uniforms[role], tex[role])
		return sm

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
	if parallax and tex.has("displacement"):
		m.depth_enabled = true
		m.depth_texture = tex["displacement"]
	return m


func _node_name(path: String) -> String:
	var n = path.get_file().get_basename()
	for bad in [".", ":", "/", "@", "%", "\""]:
		n = n.replace(bad, "_")
	return n


func _override_materials(node: Node, mat: Material) -> void:
	if node is MeshInstance:
		node.material_override = mat
	for c in node.get_children():
		_override_materials(c, mat)


# Returns a Spatial with one child per mesh, or null if none of the meshes could be loaded.
func _build_scene(scene_name: String, mesh_paths: Array, mat: Material) -> Node:
	var root = Spatial.new()
	root.name = scene_name
	for mp in mesh_paths:
		var res = load(mp)
		var node = null
		if res is Mesh:
			node = MeshInstance.new()
			node.mesh = res
			if mat != null:
				node.material_override = mat
		elif res is PackedScene:
			node = res.instance()
			if mat != null:
				_override_materials(node, mat)
		if node == null:
			continue
		node.name = _node_name(mp)
		root.add_child(node)
		node.owner = root
	if root.get_child_count() == 0:
		root.free()
		return null
	return root
