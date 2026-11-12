tool
extends EditorPlugin

const MENU_ID := 9001
const MENU_TEXT := "Open with MetaHuman Rig"

var dock
var _popups := []
var _menu_path := ""


func _enter_tree() -> void:
	dock = preload("dock.gd").new()
	dock.editor_interface = get_editor_interface()
	dock.undo_redo = get_undo_redo()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	connect("scene_changed", dock, "on_scene_changed")
	call_deferred("_hook_filesystem_menus")
	set_process(true)
	set_process_input(true)


# Godot 3 has no API for the FileSystem dock's right-click menu, so we add an item to its popup menus.
func _find_class(n: Node, cls: String, out: Array) -> void:
	if n.get_class() == cls:
		out.append(n)
		return
	for c in n.get_children():
		_find_class(c, cls, out)


func _collect_popups(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is PopupMenu:
			out.append(c)
		_collect_popups(c, out)


func _hook_filesystem_menus() -> void:
	var docks := []
	_find_class(get_editor_interface().get_base_control(), "FileSystemDock", docks)
	if docks.empty():
		return
	_collect_popups(docks[0], _popups)
	for p in _popups:
		p.connect("about_to_show", self, "_on_menu_about_to_show", [p])
		p.connect("id_pressed", self, "_on_menu_id_pressed")


func _is_file_menu(p: PopupMenu) -> bool:
	for i in range(p.get_item_count()):
		var t := p.get_item_text(i)
		if t.begins_with("Copy Path") or t.begins_with("Show in File Manager") or t.begins_with("Open Scene") or t.begins_with("Rename") or t.begins_with("Duplicate"):
			return true
	return p.get_item_count() >= 9


func _remove_item(p: PopupMenu) -> void:
	var idx := p.get_item_index(MENU_ID)
	if idx >= 0:
		p.remove_item(idx)


func _on_menu_about_to_show(p: PopupMenu) -> void:
	_remove_item(p)
	var path: String = get_editor_interface().get_current_path()
	if path.get_extension().to_lower() in ["glb", "gltf"] and _is_file_menu(p):
		_menu_path = path
		p.add_item(MENU_TEXT, MENU_ID)


func _on_menu_id_pressed(id: int) -> void:
	if id == MENU_ID and _menu_path != "" and dock != null:
		dock.open_glb_with_rig(_menu_path)


# Receive 3D viewport input while any spatial node is selected, so the 3D face board can be dragged.
func handles(object) -> bool:
	return object is Spatial


func forward_spatial_gui_input(camera, event) -> bool:
	return dock != null and dock.forward_3d_input(camera, event)


# Ctrl+Z / Ctrl+Y for the face board. The face edits are entries of the editor's own undo history (see dock.gd), so Ctrl+Z
# is the editor's normal undo; here the edit that was finished a split second ago is put into the history first, and
# Ctrl+Y is made a redo everywhere (the editor's own redo is Ctrl+Shift+Z).
func _input(event) -> void:
	if dock == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if not event.get_command() or event.alt:
		return
	if event.scancode == KEY_S:      # make sure the latest face pose is in the scene before it is written to disk
		dock.flush_face_edit()
		dock.commit_face_state()
		return
	if event.scancode != KEY_Z and event.scancode != KEY_Y:
		return
	dock.flush_face_edit()
	if event.scancode == KEY_Y and not event.shift:
		var f = get_editor_interface().get_base_control().get_focus_owner()
		if f is LineEdit or f is TextEdit:
			return              # text fields have their own undo / redo
		get_undo_redo().redo()
		get_tree().set_input_as_handled()


# Control names over the 3D editor viewport (MetaHumanBodyRig > Show Names).
var _names_on := false


func _process(_delta: float) -> void:
	var on := _names_active()
	if on or _names_on:
		update_overlays()
	_names_on = on


func _names_active() -> bool:
	if dock == null:
		return false
	var rig = dock.body_rig
	return rig != null and is_instance_valid(rig) and rig.is_inside_tree() and rig.show_names


func _find_camera(n: Node):
	if n is Camera:
		return n
	for c in n.get_children():
		var r = _find_camera(c)
		if r != null:
			return r
	return null


func forward_spatial_draw_over_viewport(overlay) -> void:
	if not _names_active():
		return
	var par = overlay.get_parent()
	var cam = _find_camera(par) if par != null else null
	if cam == null:
		return
	var font: Font = overlay.get_font("font", "Label")
	var size: Rect2 = overlay.get_rect()
	for it in dock.body_rig.name_labels():
		var p: Vector3 = it["pos"]
		if cam.is_position_behind(p):
			continue
		var sp: Vector2 = cam.unproject_position(p) + Vector2(6, -5)
		if sp.x < -100 or sp.y < -20 or sp.x > size.size.x + 100 or sp.y > size.size.y + 20:
			continue
		overlay.draw_string(font, sp + Vector2(1, 1), it["text"], Color(0, 0, 0, 0.9))
		overlay.draw_string(font, sp, it["text"], it["col"].lightened(0.25))


func _exit_tree() -> void:
	for p in _popups:
		if is_instance_valid(p):
			_remove_item(p)
			if p.is_connected("about_to_show", self, "_on_menu_about_to_show"):
				p.disconnect("about_to_show", self, "_on_menu_about_to_show")
			if p.is_connected("id_pressed", self, "_on_menu_id_pressed"):
				p.disconnect("id_pressed", self, "_on_menu_id_pressed")
	_popups.clear()
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null
