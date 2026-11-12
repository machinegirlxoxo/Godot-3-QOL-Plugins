tool
extends EditorPlugin

var editor : EditorInterface
var editor_plugin : EditorInspectorPlugin

var animation_retargeting : Node

var scene2d_calculate_retargeting_data_button : Button
var scene2d_start_retargeting_button : Button 
var scene2d_correction_mode_button : Button

var scene3d_calculate_retargeting_data_button : Button
var scene3d_start_retargeting_button : Button 
var scene3d_correction_mode_button : Button

const AnimationRetargetingClass = preload("res://addons/animation_retargeting/AnimationRetargeting.gd")
const RetargetWindowClass = preload("res://addons/animation_retargeting/RetargetWindow.gd")

# Right-click entry in the FileSystem dock
const MODEL_EXTENSIONS = ["glb", "gltf", "dae", "fbx"]
const FS_MENU_ID = 800
const FS_MENU_TEXT = "Retarget Animation"

var retarget_window : AcceptDialog
var _fs_dock : Node
var _fs_popups : Array = []
var _fs_selected_model : String = ""


func _enter_tree():
	
	add_custom_type("AnimationRetargeting", "Node", AnimationRetargetingClass, preload("res://addons/animation_retargeting/ar_icon.png"))
	
	editor = get_editor_interface()
	
	# Retarget window (no nodes in the scene needed), opened from the FileSystem dock:
	# right-click a 3D model > Retarget Animation
	retarget_window = RetargetWindowClass.new()
	retarget_window.editor = editor
	editor.get_base_control().add_child(retarget_window)
	_install_filesystem_menu()
	
	# 2D Editor Window
	
	scene2d_calculate_retargeting_data_button = Button.new()
	scene2d_calculate_retargeting_data_button.set_button_icon(editor.get_base_control().get_icon("Play", "EditorIcons"))
	scene2d_calculate_retargeting_data_button.set_text(tr("Calculate Retargeting Data"))
	scene2d_calculate_retargeting_data_button.hide();
	scene2d_calculate_retargeting_data_button.connect("pressed", self, "_calculate_retargeting_data")
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, scene2d_calculate_retargeting_data_button)
	
	scene2d_start_retargeting_button = Button.new()
	scene2d_start_retargeting_button.set_button_icon(editor.get_base_control().get_icon("Play", "EditorIcons"))
	scene2d_start_retargeting_button.set_text(tr("Retarget Animations"))
	scene2d_start_retargeting_button.hide()
	scene2d_start_retargeting_button.connect("pressed", self, "_start_retargeting")
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, scene2d_start_retargeting_button)
	
	scene2d_correction_mode_button = Button.new()
	scene2d_correction_mode_button.set_button_icon(editor.get_base_control().get_icon("Tools", "EditorIcons"))
	scene2d_correction_mode_button.set_text(tr("Correction Mode"))
	scene2d_correction_mode_button.set_toggle_mode(true)
	scene2d_correction_mode_button.hide()
	scene2d_correction_mode_button.connect("pressed", self, "_toggle_correction_mode")
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, scene2d_correction_mode_button)
	
	# 3D Editor Window
	
	scene3d_calculate_retargeting_data_button = Button.new()
	scene3d_calculate_retargeting_data_button.set_button_icon(editor.get_base_control().get_icon("Play", "EditorIcons"))
	scene3d_calculate_retargeting_data_button.set_text(tr("Calculate Retargeting Data"))
	scene3d_calculate_retargeting_data_button.hide()
	scene3d_calculate_retargeting_data_button.connect("pressed", self, "_calculate_retargeting_data")
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, scene3d_calculate_retargeting_data_button)
	
	scene3d_start_retargeting_button = Button.new()
	scene3d_start_retargeting_button.set_button_icon(editor.get_base_control().get_icon("Play", "EditorIcons"))
	scene3d_start_retargeting_button.set_text(tr("Retarget Animations"))
	scene3d_start_retargeting_button.hide()
	scene3d_start_retargeting_button.connect("pressed", self, "_start_retargeting")
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, scene3d_start_retargeting_button)
	
	scene3d_correction_mode_button = Button.new()
	scene3d_correction_mode_button.set_button_icon(editor.get_base_control().get_icon("Tools", "EditorIcons"))
	scene3d_correction_mode_button.set_text(tr("Correction Mode"))
	scene3d_correction_mode_button.set_toggle_mode(true)
	scene3d_correction_mode_button.hide()
	scene3d_correction_mode_button.connect("pressed", self, "_toggle_correction_mode")
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, scene3d_correction_mode_button)
	
	animation_retargeting = null



# ---------------------------------------------------------------- FileSystem dock right-click entry
# Godot 3 has no API for this, so the dock's own popup menus are hooked. The dock rebuilds those menus on every
# right click, so the entry is added in "about_to_show" and only when exactly one 3D model file is selected.

func _install_filesystem_menu() -> void:
	_fs_dock = _find_node_of_class(editor.get_base_control(), "FileSystemDock")
	if _fs_dock == null:
		push_warning("Animation Retargeting: could not find the FileSystem dock, so the right-click entry is not available.")
		return
	for child in _fs_dock.get_children():
		if child is PopupMenu:
			child.connect("about_to_show", self, "_on_fs_popup_about_to_show", [child])
			child.connect("id_pressed", self, "_on_fs_popup_id_pressed")
			_fs_popups.append(child)


func _uninstall_filesystem_menu() -> void:
	for popup in _fs_popups:
		if not is_instance_valid(popup):
			continue
		if popup.is_connected("about_to_show", self, "_on_fs_popup_about_to_show"):
			popup.disconnect("about_to_show", self, "_on_fs_popup_about_to_show")
		if popup.is_connected("id_pressed", self, "_on_fs_popup_id_pressed"):
			popup.disconnect("id_pressed", self, "_on_fs_popup_id_pressed")
		var index = popup.get_item_index(FS_MENU_ID)
		if index != -1:
			popup.remove_item(index)
	_fs_popups.clear()
	_fs_dock = null


func _find_node_of_class(node: Node, p_class: String) -> Node:
	if node.get_class() == p_class:
		return node
	for child in node.get_children():
		var found = _find_node_of_class(child, p_class)
		if found != null:
			return found
	return null


func _on_fs_popup_about_to_show(popup: PopupMenu) -> void:
	if popup.get_item_count() < 3:
		return
	var path = _selected_model_in_filesystem_dock()
	var index = popup.get_item_index(FS_MENU_ID)
	if path == "":
		if index != -1:
			popup.remove_item(index)
		return
	_fs_selected_model = path
	if index == -1:
		popup.add_separator()
		popup.add_icon_item(editor.get_base_control().get_icon("Animation", "EditorIcons"), FS_MENU_TEXT, FS_MENU_ID)
	popup.rect_size = Vector2(popup.rect_size.x, 1)


func _on_fs_popup_id_pressed(id: int) -> void:
	if id == FS_MENU_ID and _fs_selected_model != "":
		call_deferred("_open_retarget_window", _fs_selected_model)


func _open_retarget_window(path: String) -> void:
	if retarget_window != null:
		retarget_window.open_with(path)


func _collect_visible_lists_and_trees(node: Node, lists: Array, trees: Array) -> void:
	if node is ItemList and node.is_visible_in_tree():
		lists.append(node)
	elif node is Tree and node.is_visible_in_tree():
		trees.append(node)
	for child in node.get_children():
		_collect_visible_lists_and_trees(child, lists, trees)


# The path of the single model file selected in the dock (right file list or, in tree-only mode, the tree).
func _selected_model_in_filesystem_dock() -> String:
	if _fs_dock == null:
		return ""
	var lists : Array = []
	var trees : Array = []
	_collect_visible_lists_and_trees(_fs_dock, lists, trees)

	var use_list = null
	var use_tree = null
	for l in lists:
		if l.has_focus():
			use_list = l
	for t in trees:
		if t.has_focus():
			use_tree = t
	if use_list == null and use_tree == null:
		# nothing reports focus: prefer the file list if it has a selection, otherwise the tree
		for l in lists:
			if l.get_selected_items().size() > 0:
				use_list = l
		if use_list == null and trees.size() > 0:
			use_tree = trees[0]

	var paths : Array = []
	if use_list != null:
		for i in use_list.get_selected_items():
			paths.append(str(use_list.get_item_metadata(i)))
	elif use_tree != null:
		var item = use_tree.get_next_selected(null)
		while item != null:
			paths.append(str(item.get_metadata(0)))
			item = use_tree.get_next_selected(item)

	if paths.size() != 1:
		return ""
	if MODEL_EXTENSIONS.has(paths[0].get_extension().to_lower()):
		return paths[0]
	return ""


func _exit_tree():
	
	_uninstall_filesystem_menu()
	if retarget_window != null:
		retarget_window.queue_free()
		retarget_window = null
	
	# 2D Editor Window
	
	if scene2d_calculate_retargeting_data_button != null:
		remove_control_from_container(CONTAINER_CANVAS_EDITOR_MENU, scene2d_calculate_retargeting_data_button)
	if scene2d_start_retargeting_button != null:
		remove_control_from_container(CONTAINER_CANVAS_EDITOR_MENU, scene2d_start_retargeting_button)
	if scene2d_correction_mode_button != null:
		remove_control_from_container(CONTAINER_CANVAS_EDITOR_MENU, scene2d_correction_mode_button)
	
	# 3D Editor Window
	
	if scene3d_calculate_retargeting_data_button != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, scene3d_calculate_retargeting_data_button)
	if scene3d_start_retargeting_button != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, scene3d_start_retargeting_button)
	if scene3d_correction_mode_button != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, scene3d_correction_mode_button)
	
	remove_custom_type("AnimationRetargeting")


func can_handle(object) -> bool:
	return object is AnimationRetargetingClass

func handles(object) -> bool:
	return object is AnimationRetargetingClass


func edit(object) -> void:
	if object is AnimationRetargetingClass:
		animation_retargeting = object
	
	if object != animation_retargeting:
		animation_retargeting = object
		if scene2d_calculate_retargeting_data_button:
			scene2d_calculate_retargeting_data_button.pressed = false
		if scene2d_start_retargeting_button:
			scene2d_start_retargeting_button.pressed = false
		if scene2d_correction_mode_button:
			scene2d_correction_mode_button.pressed = false
		
		if scene3d_calculate_retargeting_data_button:
			scene3d_calculate_retargeting_data_button.pressed = false
		if scene3d_start_retargeting_button:
			scene3d_start_retargeting_button.pressed = false
		if scene3d_correction_mode_button:
			scene3d_correction_mode_button.pressed = false
	
	_start_retargeting()


func make_visible(p_visible : bool):
	
	if p_visible:
		if scene2d_calculate_retargeting_data_button:
			scene2d_calculate_retargeting_data_button.visible = true
		if scene2d_start_retargeting_button:
			scene2d_start_retargeting_button.visible = true
		if scene2d_correction_mode_button:
			scene2d_correction_mode_button.visible = true
		
		if scene3d_calculate_retargeting_data_button:
			scene3d_calculate_retargeting_data_button.visible = true
		if scene3d_start_retargeting_button:
			scene3d_start_retargeting_button.visible = true
		if scene3d_correction_mode_button:
			scene3d_correction_mode_button.visible = true
	else:
		if scene2d_calculate_retargeting_data_button:
			scene2d_calculate_retargeting_data_button.visible = false
		if scene2d_start_retargeting_button:
			scene2d_start_retargeting_button.visible = false
		if scene2d_correction_mode_button:
			scene2d_correction_mode_button.visible = false
		
		if scene3d_calculate_retargeting_data_button:
			scene3d_calculate_retargeting_data_button.visible = false
		if scene3d_start_retargeting_button:
			scene3d_start_retargeting_button.visible = false
		if scene3d_correction_mode_button:
			scene3d_correction_mode_button.visible = false


func _start_retargeting():
	if not animation_retargeting:
		return
	
	if scene2d_start_retargeting_button.pressed or scene3d_start_retargeting_button.pressed:
			animation_retargeting.start_retargeting()


func _toggle_correction_mode() -> void:
	if not animation_retargeting:
		return
	
	if scene3d_correction_mode_button:
		if scene3d_correction_mode_button.pressed:
			animation_retargeting.enable_correction_mode()
			scene2d_correction_mode_button.pressed = false
	if scene3d_correction_mode_button:
		if !scene3d_correction_mode_button.pressed:
			animation_retargeting.disable_correction_mode()
			scene3d_correction_mode_button.pressed = false
			scene2d_correction_mode_button.pressed = false
			
			
func _calculate_retargeting_data() -> void:
	if not animation_retargeting:
		return
	
