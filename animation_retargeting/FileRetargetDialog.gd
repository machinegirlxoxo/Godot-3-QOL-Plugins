tool
extends ConfirmationDialog

# Retarget animations between two model files directly from the editor.
# Nothing is added to the edited scene: both models are instanced off-tree,
# fed to the original AnimationRetargeting logic, then freed again.

const AnimationRetargetingClass = preload("res://addons/animation_retargeting/AnimationRetargeting.gd")

var editor : EditorInterface

var _source_edit : LineEdit
var _target_edit : LineEdit
var _export_dir_edit : LineEdit
var _prefix_edit : LineEdit
var _suffix_edit : LineEdit
var _mapping_edit : TextEdit
var _position_check : CheckBox
var _rotation_check : CheckBox
var _scale_check : CheckBox
var _root_motion_check : CheckBox
var _in_place_check : CheckBox
var _export_player_check : CheckBox
var _source_scale_spin : SpinBox
var _target_scale_spin : SpinBox
var _status_label : Label

var _file_dialog : FileDialog
var _file_dialog_target : LineEdit


func _init():
	window_title = "Retarget Animations from Files"
	get_ok().text = "Retarget"
	rect_min_size = Vector2(560, 0)

	var box := VBoxContainer.new()
	add_child(box)

	_source_edit = _add_path_row(box, "Source model (has animations)", false)
	_target_edit = _add_path_row(box, "Target model (receives animations)", false)
	_export_dir_edit = _add_path_row(box, "Export folder", true)
	_export_dir_edit.text = "res://"

	var name_row := HBoxContainer.new()
	box.add_child(name_row)
	name_row.add_child(_make_label("Name prefix"))
	_prefix_edit = LineEdit.new()
	_prefix_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_prefix_edit)
	name_row.add_child(_make_label("suffix"))
	_suffix_edit = LineEdit.new()
	_suffix_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_suffix_edit)

	var scale_row := HBoxContainer.new()
	box.add_child(scale_row)
	scale_row.add_child(_make_label("Source scale"))
	_source_scale_spin = _make_scale_spin()
	scale_row.add_child(_source_scale_spin)
	scale_row.add_child(_make_label("Target scale"))
	_target_scale_spin = _make_scale_spin()
	scale_row.add_child(_target_scale_spin)

	_rotation_check = _add_check(box, "Retarget rotation", true)
	_position_check = _add_check(box, "Retarget position", false)
	_scale_check = _add_check(box, "Retarget scale", false)
	_root_motion_check = _add_check(box, "Root motion", false)
	_in_place_check = _add_check(box, "Fixate in place (zero root X/Z movement)", false)
	_export_player_check = _add_check(box, "Also export an AnimationPlayer scene (.scn)", false)

	box.add_child(_make_label("Custom bone mapping (optional JSON, {\"source_bone\": \"target_bone\"}). Leave empty to match by bone name."))
	_mapping_edit = TextEdit.new()
	_mapping_edit.rect_min_size = Vector2(0, 90)
	box.add_child(_mapping_edit)

	_status_label = Label.new()
	_status_label.autowrap = true
	box.add_child(_status_label)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.connect("file_selected", self, "_on_path_selected")
	_file_dialog.connect("dir_selected", self, "_on_path_selected")
	add_child(_file_dialog)

	connect("confirmed", self, "_on_confirmed")


func _make_label(p_text : String) -> Label:
	var label := Label.new()
	label.text = p_text
	return label


func _make_scale_spin() -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = 0.001
	spin.max_value = 1000.0
	spin.step = 0.001
	spin.value = 1.0
	return spin


func _add_check(p_parent : Node, p_text : String, p_pressed : bool) -> CheckBox:
	var check := CheckBox.new()
	check.text = p_text
	check.pressed = p_pressed
	p_parent.add_child(check)
	return check


func _add_path_row(p_parent : Node, p_text : String, p_is_dir : bool) -> LineEdit:
	p_parent.add_child(_make_label(p_text))
	var row := HBoxContainer.new()
	p_parent.add_child(row)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	var button := Button.new()
	button.text = "..."
	button.connect("pressed", self, "_on_browse_pressed", [edit, p_is_dir])
	row.add_child(button)
	return edit


func _on_browse_pressed(p_edit : LineEdit, p_is_dir : bool) -> void:
	_file_dialog_target = p_edit
	_file_dialog.clear_filters()
	if p_is_dir:
		_file_dialog.mode = FileDialog.MODE_OPEN_DIR
	else:
		_file_dialog.mode = FileDialog.MODE_OPEN_FILE
		for filter in ["*.glb", "*.gltf", "*.dae", "*.fbx", "*.tscn", "*.scn"]:
			_file_dialog.add_filter(filter)
	_file_dialog.popup_centered_ratio(0.6)


func _on_path_selected(p_path : String) -> void:
	if _file_dialog_target:
		_file_dialog_target.text = p_path


func _find_first_of_class(p_node : Node, p_class : String) -> Node:
	if p_node.is_class(p_class):
		return p_node
	for child in p_node.get_children():
		var found : Node = _find_first_of_class(child, p_class)
		if found:
			return found
	return null


func _load_instance(p_path : String) -> Node:
	if p_path == "" or not ResourceLoader.exists(p_path):
		return null
	var scene = load(p_path)
	if scene is PackedScene:
		return scene.instance()
	return null


func _on_confirmed() -> void:
	# Re-open on failure so the user doesn't lose their settings.
	var error : String = _run_retargeting()
	if error != "":
		_status_label.text = error
		push_error("Animation Retargeting: " + error)
		popup_centered()
	else:
		_status_label.text = ""


func _run_retargeting() -> String:
	var source_root : Node = _load_instance(_source_edit.text.strip_edges())
	if source_root == null:
		return "Could not load source model: " + _source_edit.text
	var target_root : Node = _load_instance(_target_edit.text.strip_edges())
	if target_root == null:
		source_root.free()
		return "Could not load target model: " + _target_edit.text

	var mapping : Dictionary = {}
	var mapping_text : String = _mapping_edit.text.strip_edges()
	if mapping_text != "":
		var parsed : JSONParseResult = JSON.parse(mapping_text)
		if parsed.error != OK or not parsed.result is Dictionary:
			source_root.free()
			target_root.free()
			return "Bone mapping is not a valid JSON dictionary."
		mapping = parsed.result

	# Temporary container, never added to the editor's scene tree.
	var temp_root := Node.new()
	temp_root.name = "RetargetTemp"
	source_root.name = "Source"
	target_root.name = "Target"
	temp_root.add_child(source_root)
	temp_root.add_child(target_root)

	var source_skeleton : Node = _find_first_of_class(source_root, "Skeleton")
	var source_player : Node = _find_first_of_class(source_root, "AnimationPlayer")
	var target_skeleton : Node = _find_first_of_class(target_root, "Skeleton")
	var target_player : Node = _find_first_of_class(target_root, "AnimationPlayer")

	var error : String = ""
	if source_skeleton == null:
		error = "No Skeleton found in the source model."
	elif source_player == null or source_player.get_animation_list().empty():
		error = "No AnimationPlayer with animations found in the source model."
	elif target_skeleton == null:
		error = "No Skeleton found in the target model."

	if error != "":
		temp_root.free()
		return error

	# The target model doesn't need to ship its own AnimationPlayer.
	if target_player == null:
		target_player = AnimationPlayer.new()
		target_player.name = "AnimationPlayer"
		target_root.add_child(target_player)

	var export_dir : String = _export_dir_edit.text.strip_edges().trim_suffix("/")
	if export_dir == "":
		export_dir = "res:/"
	if export_dir != "res:/":
		var dir := Directory.new()
		if not dir.dir_exists(export_dir):
			dir.make_dir_recursive(export_dir)

	var retargeting : Node = AnimationRetargetingClass.new()
	temp_root.add_child(retargeting)

	retargeting.source_skeleton_node_path = retargeting.get_path_to(source_skeleton)
	retargeting.source_animationplayer_node_path = retargeting.get_path_to(source_player)
	retargeting.retarget_skeleton_node_path = retargeting.get_path_to(target_skeleton)
	retargeting.retarget_animationplayer_node_path = retargeting.get_path_to(target_player)

	retargeting.retarget_position = _position_check.pressed
	retargeting.retarget_rotation = _rotation_check.pressed
	retargeting.retarget_scale = _scale_check.pressed
	retargeting.root_motion = _root_motion_check.pressed
	retargeting.fixate_in_place = _in_place_check.pressed
	retargeting.source_skeleton_scale = _source_scale_spin.value
	retargeting.retarget_skeleton_scale = _target_scale_spin.value
	retargeting.animation_rename_prefix = _prefix_edit.text
	retargeting.animation_rename_suffix = _suffix_edit.text
	retargeting.export_animations = true
	retargeting.export_animationplayer = _export_player_check.pressed
	retargeting.animation_export_format = AnimationRetargetingClass.ANIMATION_EXPORT_ANIM
	retargeting.animation_export_directory = export_dir
	retargeting.replace_retarget_animations = true
	if not mapping.empty():
		retargeting.custom_bone_mapping = mapping

	if retargeting.calculate_retargeting_data():
		retargeting.retarget_skeleton_animations()
	else:
		error = "No matching bones found between the two skeletons. Try a custom bone mapping."

	temp_root.free()

	if editor:
		editor.get_resource_filesystem().scan()
	return error
