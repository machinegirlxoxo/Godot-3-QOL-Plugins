tool
extends AcceptDialog

# "Retarget Animations" window, opened from the FileSystem dock: right-click a model > Retarget Animation.
#
#  - Left: 3D preview with the source and the target model side by side. Both play the selected animation,
#    the target plays the retargeted version live. Drag = orbit, right/middle drag = pan, wheel = zoom.
#  - Right: pick the source / target model, retarget options, search + list of the source animations.
#  - "Export Animations" asks where to save and what to name the file (empty name = original animation name).
#    Several animations at once: it asks for the folder only and keeps the original names.
#
# The retargeting itself is done by AnimationRetargeting.gd (unchanged); this window only drives it.

const AnimationRetargetingClass = preload("res://addons/animation_retargeting/AnimationRetargeting.gd")
const MODEL_FILTERS = ["*.glb", "*.gltf", "*.dae", "*.fbx", "*.tscn", "*.scn"]
const PREVIEW_ANIM = "__retarget_preview"
const GRID_HALF_SIZE = 10

var editor : EditorInterface

# ---- preview
var _view_holder : Control
var _view_container : ViewportContainer
var _viewport : Viewport
var _world : Spatial
var _camera : Camera
var _source_label : Label
var _target_label : Label
var _yaw = 0.0
var _pitch = -0.15
var _distance = 4.0
var _focus = Vector3(0, 1, 0)
var _source_top = Vector3.ZERO
var _target_top = Vector3.ZERO

# ---- models
var _source_holder : Spatial
var _target_holder : Spatial
var _source_skel : Skeleton
var _target_skel : Skeleton
var _source_player : AnimationPlayer
var _target_player : AnimationPlayer
var _source_path = ""
var _target_path = ""
var _retargeting : Node
var _retarget_ready = false

# ---- ui
var _source_edit : LineEdit
var _target_edit : LineEdit
var _rotation_check : CheckBox
var _position_check : CheckBox
var _scale_check : CheckBox
var _root_motion_check : CheckBox
var _in_place_check : CheckBox
var _source_scale : SpinBox
var _target_scale : SpinBox
var _mapping_edit : TextEdit
var _export_dialog : ConfirmationDialog
var _dlg_dir : LineEdit
var _dlg_name : LineEdit
var _dlg_name_label : Label
var _dlg_info : Label
var _search : LineEdit
var _anim_list : ItemList
var _export_button : Button
var _log : RichTextLabel
var _file_dialog : FileDialog

var _pending_browse = ""
var _export_dir_touched = false
var _last_export_dir = "res://"
var _pending_ids = []
var _all_anims = []
var _current_anim = ""


func _init() -> void:
	window_title = "Retarget Animations"
	resizable = true
	get_ok().text = "Close"

	var split := HSplitContainer.new()
	split.rect_min_size = Vector2(760, 440)
	add_child(split)

	# ------------------------------------------------------------ left: preview + log
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)

	_view_holder = Control.new()
	_view_holder.rect_min_size = Vector2(380, 240)
	_view_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_holder.rect_clip_content = true
	left.add_child(_view_holder)
	_build_preview()

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.rect_min_size = Vector2(0, 60)
	left.add_child(_log)

	# ------------------------------------------------------------ right: settings + animation list
	var right := VBoxContainer.new()
	right.rect_min_size = Vector2(390, 0)
	split.add_child(right)

	right.add_child(_make_label("Source Model (has the animations)"))
	_source_edit = _add_path_row(right, "source")
	_source_edit.connect("text_entered", self, "_on_path_entered", [true])

	right.add_child(_make_label("Target Model (receives the animations)"))
	_target_edit = _add_path_row(right, "target")
	_target_edit.connect("text_entered", self, "_on_path_entered", [false])

	var swap := Button.new()
	swap.text = "Swap Source / Target"
	swap.connect("pressed", self, "_on_swap_pressed")
	right.add_child(swap)

	var retarget_body := _add_section(right, "Retargeter Options", false)
	_rotation_check = _add_check(retarget_body, "Retarget rotation", true)
	_position_check = _add_check(retarget_body, "Retarget position", false)
	_scale_check = _add_check(retarget_body, "Retarget scale", false)
	_root_motion_check = _add_check(retarget_body, "Root motion", false)
	_in_place_check = _add_check(retarget_body, "Fixate in place (zero root X/Z movement)", false)
	var scale_row := HBoxContainer.new()
	retarget_body.add_child(scale_row)
	scale_row.add_child(_make_label("Source scale"))
	_source_scale = _make_scale_spin()
	scale_row.add_child(_source_scale)
	scale_row.add_child(_make_label("Target scale"))
	_target_scale = _make_scale_spin()
	scale_row.add_child(_target_scale)
	_source_scale.connect("value_changed", self, "_on_rebuild_requested")
	_target_scale.connect("value_changed", self, "_on_rebuild_requested")
	retarget_body.add_child(_make_label("Bone mapping (optional JSON {\"source_bone\": \"target_bone\"}):"))
	_mapping_edit = TextEdit.new()
	_mapping_edit.rect_min_size = Vector2(0, 70)
	retarget_body.add_child(_mapping_edit)
	var apply_mapping := Button.new()
	apply_mapping.text = "Apply Mapping"
	apply_mapping.connect("pressed", self, "_on_rebuild_requested", [0])
	retarget_body.add_child(apply_mapping)

	for check in [_rotation_check, _position_check, _scale_check, _root_motion_check, _in_place_check]:
		check.connect("toggled", self, "_on_option_toggled")

	_search = LineEdit.new()
	_search.placeholder_text = "Search animations"
	_search.clear_button_enabled = true
	_search.connect("text_changed", self, "_on_search_changed")
	right.add_child(_search)

	_anim_list = ItemList.new()
	_anim_list.select_mode = ItemList.SELECT_MULTI
	_anim_list.rect_min_size = Vector2(0, 90)
	_anim_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_anim_list.connect("multi_selected", self, "_on_anim_selected")
	right.add_child(_anim_list)

	_export_button = Button.new()
	_export_button.text = "Export Animations"
	_export_button.disabled = true
	_export_button.connect("pressed", self, "_on_export_pressed")
	right.add_child(_export_button)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.connect("file_selected", self, "_on_file_chosen")
	_file_dialog.connect("dir_selected", self, "_on_file_chosen")
	add_child(_file_dialog)
	_build_export_dialog()

	connect("popup_hide", self, "_on_window_hidden")


func _ready() -> void:
	set_process(true)


# ================================================================== opening / closing

# Called by the plugin when you pick "Retarget Animation" on a model in the FileSystem dock.
func open_with(path: String) -> void:
	_clear_all()
	_log.clear()
	_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	# Never bigger than the screen, so the Close button and the Export button stay reachable.
	var screen := OS.get_screen_size()
	popup_centered(Vector2(min(1240, screen.x * 0.85), min(780, screen.y * 0.8)))
	_set_model(true, path)
	# The clicked model has no animations: use it as the target instead.
	if _source_player == null or _source_player.get_animation_list().size() == 0:
		_set_model(false, path)
		_set_model(true, "")
		_log_info("The model has no animations, so it was placed in Target. Pick a source model that has animations.")


func _on_window_hidden() -> void:
	_viewport.render_target_update_mode = Viewport.UPDATE_DISABLED
	_clear_all()


func _clear_all() -> void:
	_free_retargeting()
	_remove_model(true)
	_remove_model(false)
	_source_edit.text = ""
	_target_edit.text = ""
	_all_anims = []
	_current_anim = ""
	_anim_list.clear()
	_export_dir_touched = false
	_update_export_button()


# ================================================================== preview scene

func _build_preview() -> void:
	_view_container = ViewportContainer.new()
	_view_container.stretch = true
	_view_container.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	_view_holder.add_child(_view_container)
	_view_container.connect("gui_input", self, "_on_view_input")

	_viewport = Viewport.new()
	_viewport.own_world = true
	_viewport.msaa = Viewport.MSAA_4X
	_viewport.render_target_update_mode = Viewport.UPDATE_DISABLED
	_view_container.add_child(_viewport)

	_world = Spatial.new()
	_viewport.add_child(_world)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.42, 0.43, 0.46)
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.55
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_world.add_child(world_env)

	var key := DirectionalLight.new()
	key.rotation_degrees = Vector3(-50, 35, 0)
	key.light_energy = 0.9
	_world.add_child(key)
	var fill := DirectionalLight.new()
	fill.rotation_degrees = Vector3(-30, -150, 0)
	fill.light_energy = 0.4
	_world.add_child(fill)

	_world.add_child(_make_grid())

	_camera = Camera.new()
	_camera.fov = 50.0
	_camera.near = 0.05
	_camera.far = 1000.0
	_camera.current = true
	_world.add_child(_camera)
	_update_camera()

	_source_label = _make_overlay_label("Source")
	_target_label = _make_overlay_label("Target")
	_view_holder.add_child(_source_label)
	_view_holder.add_child(_target_label)

	var hint := Label.new()
	hint.text = "  Drag: orbit    Right drag: pan    Wheel: zoom"
	hint.add_color_override("font_color", Color(1, 1, 1, 0.55))
	hint.set_anchors_and_margins_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE)
	_view_holder.add_child(hint)


func _make_grid() -> ImmediateGeometry:
	var grid := ImmediateGeometry.new()
	var material := SpatialMaterial.new()
	material.flags_unshaded = true
	material.vertex_color_use_as_albedo = true
	grid.material_override = material
	grid.begin(Mesh.PRIMITIVE_LINES)
	for i in range(-GRID_HALF_SIZE, GRID_HALF_SIZE + 1):
		var line_color = Color(0.6, 0.6, 0.63)
		if i == 0:
			line_color = Color(0.3, 0.45, 0.85)
		grid.set_color(line_color)
		grid.add_vertex(Vector3(i, 0, -GRID_HALF_SIZE))
		grid.add_vertex(Vector3(i, 0, GRID_HALF_SIZE))
		line_color = Color(0.6, 0.6, 0.63)
		if i == 0:
			line_color = Color(0.85, 0.3, 0.3)
		grid.set_color(line_color)
		grid.add_vertex(Vector3(-GRID_HALF_SIZE, 0, i))
		grid.add_vertex(Vector3(GRID_HALF_SIZE, 0, i))
	grid.end()
	return grid


func _make_overlay_label(p_text: String) -> Label:
	var label := Label.new()
	label.text = p_text
	label.visible = false
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_color_override("font_color", Color(1, 1, 1))
	label.add_color_override("font_color_shadow", Color(0, 0, 0, 0.85))
	label.add_constant_override("shadow_offset_x", 1)
	label.add_constant_override("shadow_offset_y", 1)
	return label


func _update_camera() -> void:
	var basis := Basis(Vector3(_pitch, _yaw, 0.0))
	_camera.transform = Transform(basis, _focus + basis.xform(Vector3(0, 0, _distance)))


func _on_view_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.button_mask & BUTTON_MASK_LEFT:
			_yaw -= event.relative.x * 0.01
			_pitch = clamp(_pitch - event.relative.y * 0.01, -1.45, 1.45)
			_update_camera()
		elif event.button_mask & (BUTTON_MASK_RIGHT | BUTTON_MASK_MIDDLE):
			var cam_basis = _camera.transform.basis
			_focus += (-cam_basis.x * event.relative.x + cam_basis.y * event.relative.y) * _distance * 0.0015
			_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == BUTTON_WHEEL_UP:
			_distance = clamp(_distance * 0.9, 0.2, 300.0)
			_update_camera()
		elif event.button_index == BUTTON_WHEEL_DOWN:
			_distance = clamp(_distance * 1.1, 0.2, 300.0)
			_update_camera()


func _process(_delta) -> void:
	if not visible:
		return
	_place_label(_source_label, _source_holder, _source_top)
	_place_label(_target_label, _target_holder, _target_top)


func _place_label(label: Label, holder: Spatial, top: Vector3) -> void:
	if holder == null or _camera.is_position_behind(top):
		label.visible = false
		return
	var screen = _camera.unproject_position(top)
	var label_size = label.get_minimum_size()
	label.visible = true
	label.rect_position = screen - Vector2(label_size.x * 0.5, label_size.y + 4.0)


func _model_aabb(node: Node) -> AABB:
	var result = AABB()
	var found = false
	var stack = [node]
	while not stack.empty():
		var n = stack.pop_back()
		if n is MeshInstance and n.mesh != null:
			var box = n.get_transformed_aabb()
			if found:
				result = result.merge(box)
			else:
				result = box
				found = true
		for c in n.get_children():
			stack.append(c)
	if not found:
		return AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1.8, 1))
	return result


# Puts the two models next to each other (source left, target right) and updates the label anchors.
func _layout_models() -> void:
	var source_box = AABB()
	var target_box = AABB()
	if _source_holder != null:
		_source_holder.translation = Vector3.ZERO
		source_box = _model_aabb(_source_holder)
	if _target_holder != null:
		_target_holder.translation = Vector3.ZERO
		target_box = _model_aabb(_target_holder)

	var source_half = max(source_box.size.x, source_box.size.z) * 0.5
	var target_half = max(target_box.size.x, target_box.size.z) * 0.5
	if _source_holder != null and _target_holder != null:
		var separation = max(1.6, source_half + target_half + 0.8)
		_source_holder.translation = Vector3(-separation * 0.5, 0, 0)
		_target_holder.translation = Vector3(separation * 0.5, 0, 0)

	if _source_holder != null:
		_source_top = _source_holder.translation + Vector3(source_box.position.x + source_box.size.x * 0.5, source_box.end.y + 0.1, source_box.position.z + source_box.size.z * 0.5)
	if _target_holder != null:
		_target_top = _target_holder.translation + Vector3(target_box.position.x + target_box.size.x * 0.5, target_box.end.y + 0.1, target_box.position.z + target_box.size.z * 0.5)


func _frame_camera() -> void:
	var box = _model_aabb(_world)
	_focus = box.position + box.size * 0.5
	var radius = max(box.size.length() * 0.5, 0.5)
	_distance = max(radius / tan(deg2rad(_camera.fov * 0.5)) * 1.15, 0.5)
	_update_camera()


# ================================================================== models

func _load_model(path: String) -> Node:
	if path == "" or not ResourceLoader.exists(path):
		return null
	var res = load(path)
	if res is PackedScene:
		return res.instance()
	return null


func _find_best_skeleton(root: Node) -> Skeleton:
	var best : Skeleton = null
	var stack = [root]
	while not stack.empty():
		var n = stack.pop_back()
		if n is Skeleton:
			if best == null or n.get_bone_count() > best.get_bone_count():
				best = n
		for c in n.get_children():
			stack.append(c)
	return best


func _find_best_player(root: Node) -> AnimationPlayer:
	var best : AnimationPlayer = null
	var stack = [root]
	while not stack.empty():
		var n = stack.pop_back()
		if n is AnimationPlayer:
			if best == null or n.get_animation_list().size() > best.get_animation_list().size():
				best = n
		for c in n.get_children():
			stack.append(c)
	return best


func _remove_model(is_source: bool) -> void:
	var holder = _source_holder if is_source else _target_holder
	if holder != null:
		if holder.get_parent() != null:
			holder.get_parent().remove_child(holder)
		holder.free()
	if is_source:
		_source_holder = null
		_source_skel = null
		_source_player = null
		_source_path = ""
	else:
		_target_holder = null
		_target_skel = null
		_target_player = null
		_target_path = ""


func _set_model(is_source: bool, path: String) -> void:
	path = path.strip_edges()
	_free_retargeting()
	_remove_model(is_source)
	var edit = _source_edit if is_source else _target_edit
	edit.text = path
	if path == "":
		_after_models_changed(is_source)
		return

	var model = _load_model(path)
	if model == null:
		_log_error("Could not load model: " + path)
		_after_models_changed(is_source)
		return

	var holder := Spatial.new()
	holder.name = "SourceHolder" if is_source else "TargetHolder"
	_world.add_child(holder)
	holder.add_child(model)

	var skeleton = _find_best_skeleton(model)
	var player = _find_best_player(model)
	if skeleton == null:
		_log_error("No Skeleton found in " + path.get_file())
	if player == null and not is_source:
		# the target model doesn't need its own AnimationPlayer
		player = AnimationPlayer.new()
		player.name = "AnimationPlayer"
		model.add_child(player)
	elif player == null and is_source:
		_log_warn("No AnimationPlayer found in " + path.get_file())

	if is_source:
		_source_holder = holder
		_source_skel = skeleton
		_source_player = player
		_source_path = path
	else:
		_target_holder = holder
		_target_skel = skeleton
		_target_player = player
		_target_path = path
		if not _export_dir_touched:
			_last_export_dir = path.get_base_dir()
	_after_models_changed(is_source)


func _after_models_changed(changed_source: bool) -> void:
	_layout_models()
	_frame_camera()
	_rebuild_retargeting()
	if changed_source:
		_refresh_animation_list()
	elif _current_anim != "":
		_preview(_current_anim)
	_update_export_button()


# ================================================================== retargeting

func _free_retargeting() -> void:
	if _retargeting != null:
		if _retargeting.get_parent() != null:
			_retargeting.get_parent().remove_child(_retargeting)
		_retargeting.free()
		_retargeting = null
	_retarget_ready = false


func _apply_options() -> void:
	if _retargeting == null:
		return
	_retargeting.retarget_rotation = _rotation_check.pressed
	_retargeting.retarget_position = _position_check.pressed
	_retargeting.retarget_scale = _scale_check.pressed
	_retargeting.root_motion = _root_motion_check.pressed
	_retargeting.fixate_in_place = _in_place_check.pressed


func _rebuild_retargeting() -> void:
	_free_retargeting()
	if _source_skel == null or _source_player == null or _target_skel == null or _target_player == null:
		if _source_holder == null:
			_log_info("Pick a source model that has animations.")
		elif _target_holder == null:
			_log_info("Pick a target model to retarget the animations to.")
		return

	var mapping : Dictionary = {}
	var mapping_text : String = _mapping_edit.text.strip_edges()
	if mapping_text != "":
		var parsed : JSONParseResult = JSON.parse(mapping_text)
		if parsed.error == OK and parsed.result is Dictionary:
			mapping = parsed.result.duplicate()
		else:
			_log_warn("The bone mapping is not a valid JSON dictionary and was ignored.")

	var node = AnimationRetargetingClass.new()
	_world.add_child(node)
	node.source_skeleton_node_path = node.get_path_to(_source_skel)
	node.source_animationplayer_node_path = node.get_path_to(_source_player)
	node.retarget_skeleton_node_path = node.get_path_to(_target_skel)
	node.retarget_animationplayer_node_path = node.get_path_to(_target_player)
	node.source_skeleton_scale = _source_scale.value
	node.retarget_skeleton_scale = _target_scale.value
	if not mapping.empty():
		node.custom_bone_mapping = mapping
	_retargeting = node
	_apply_options()

	if not node.calculate_retargeting_data():
		_log_warn("No matching bones found between the two skeletons. Try a bone mapping under Retargeter Options.")
		return

	_retarget_ready = true
	var matched : int = node.retarget_mapping.size()
	var total : int = _source_skel.get_bone_count()
	_log_ok("Success! The retargeter is ready to transfer animation from the source, %s, to the target, %s. (%d of %d source bones matched)" % [_source_path.get_file(), _target_path.get_file(), matched, total])
	if total > 0 and matched * 2 < total:
		_log_warn("Less than half of the source bones were found on the target. Bone names probably differ; use a bone mapping.")


func _on_rebuild_requested(_value) -> void:
	_log.clear()
	_rebuild_retargeting()
	_preview(_current_anim)
	_update_export_button()


func _on_option_toggled(_pressed) -> void:
	_apply_options()
	_preview(_current_anim)


# ================================================================== animation list / preview

func _refresh_animation_list() -> void:
	_all_anims = []
	if _source_player != null:
		for n in _source_player.get_animation_list():
			_all_anims.append(str(n))
		_all_anims.sort()
	_current_anim = ""
	_fill_list()
	if _anim_list.get_item_count() > 0:
		_anim_list.select(0)
		_on_anim_selected(0, true)
	elif _source_player != null:
		_log_warn("The source model has no animations.")


func _fill_list() -> void:
	_anim_list.clear()
	var filter = _search.text.strip_edges().to_lower()
	var icon = null
	if editor != null:
		icon = editor.get_base_control().get_icon("Animation", "EditorIcons")
	for n in _all_anims:
		if filter == "" or n.to_lower().find(filter) != -1:
			_anim_list.add_item(n, icon)


func _on_search_changed(_text) -> void:
	_fill_list()
	_update_export_button()


func _on_anim_selected(index: int, selected: bool) -> void:
	if selected:
		_preview(_anim_list.get_item_text(index))
	_update_export_button()


func _preview(anim_id: String) -> void:
	if anim_id == "" or _source_player == null or not _source_player.has_animation(anim_id):
		return
	_current_anim = anim_id
	var source_anim : Animation = _source_player.get_animation(anim_id)
	_play_on(_source_player, source_anim.duplicate())
	if _retarget_ready and _target_player != null:
		var retargeted : Animation = _retargeting._retarget_animation_track(source_anim)
		_play_on(_target_player, retargeted)


func _play_on(player: AnimationPlayer, anim: Animation) -> void:
	anim.loop = true
	player.stop()
	if player.has_animation(PREVIEW_ANIM):
		player.remove_animation(PREVIEW_ANIM)
	player.add_animation(PREVIEW_ANIM, anim)
	player.play(PREVIEW_ANIM)


# ================================================================== export

func _export_ids() -> Array:
	var ids = []
	for i in _anim_list.get_selected_items():
		ids.append(_anim_list.get_item_text(i))
	if ids.empty():
		for i in range(_anim_list.get_item_count()):
			ids.append(_anim_list.get_item_text(i))
	return ids


func _update_export_button() -> void:
	var selected = _anim_list.get_selected_items().size()
	if selected > 0:
		_export_button.text = "Export Animations (%d)" % selected
	elif _anim_list.get_item_count() > 0:
		_export_button.text = "Export All Animations (%d)" % _anim_list.get_item_count()
	else:
		_export_button.text = "Export Animations"
	_export_button.disabled = not _retarget_ready or _anim_list.get_item_count() == 0


func _safe_file_name(p_name: String) -> String:
	for c in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		p_name = p_name.replace(c, "_")
	return p_name


func _build_export_dialog() -> void:
	_export_dialog = ConfirmationDialog.new()
	_export_dialog.window_title = "Export Animation"
	_export_dialog.get_ok().text = "Export"
	var box := VBoxContainer.new()
	box.rect_min_size = Vector2(460, 0)
	_export_dialog.add_child(box)

	box.add_child(_make_label("Where do you want to save it?"))
	_dlg_dir = _add_path_row(box, "dir")
	_dlg_dir.connect("text_changed", self, "_on_export_dir_edited")

	_dlg_name_label = _make_label("What should it be named? (leave empty to keep the original name)")
	box.add_child(_dlg_name_label)
	_dlg_name = LineEdit.new()
	_dlg_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dlg_name.connect("text_changed", self, "_on_export_name_edited")
	box.add_child(_dlg_name)

	_dlg_info = Label.new()
	# No autowrap here: an auto-wrapping Label inside a dialog makes the dialog stretch to the full screen height.
	_dlg_info.clip_text = true
	_dlg_info.rect_min_size = Vector2(460, 0)
	box.add_child(_dlg_info)

	_export_dialog.connect("confirmed", self, "_on_export_confirmed")
	add_child(_export_dialog)


# Name that is actually used for one animation: what the user typed, else the original animation name.
func _export_file_name(id: String, custom_name: String) -> String:
	var file_name : String = id
	if custom_name != "":
		file_name = custom_name
	file_name = _safe_file_name(file_name)
	if file_name.get_extension().to_lower() != "anim":
		file_name += ".anim"
	return file_name


func _update_export_dialog_info() -> void:
	if _export_dialog == null or _pending_ids.empty():
		return
	var dir_text : String = _dlg_dir.text.strip_edges()
	var base : String = dir_text.trim_suffix("/")
	var custom : String = ""
	if _pending_ids.size() == 1:
		custom = _dlg_name.text.strip_edges()
	var file_check := File.new()
	var existing = 0
	for id in _pending_ids:
		if file_check.file_exists(base + "/" + _export_file_name(id, custom)):
			existing += 1
	if existing > 0:
		_dlg_info.text = "Warning: %d file(s) already exist there and will be overwritten." % existing
	elif _pending_ids.size() == 1:
		_dlg_info.text = "Will be saved as: " + base + "/" + _export_file_name(_pending_ids[0], custom)
	else:
		_dlg_info.text = "%d animations will be saved with their original names." % _pending_ids.size()


func _on_export_pressed() -> void:
	if not _retarget_ready:
		_log_error("Pick a source and a target model first.")
		return
	var ids = _export_ids()
	if ids.empty():
		_log_error("There are no animations to export.")
		return

	_pending_ids = ids
	_dlg_dir.text = _last_export_dir
	_dlg_name.text = ""
	if ids.size() == 1:
		# Greyed-out hint: the original name is used when the field is left empty.
		_dlg_name.placeholder_text = _export_file_name(ids[0], "")
		_dlg_name.editable = true
		_dlg_name_label.text = "What should it be named? (leave empty to keep the original name)"
	else:
		_dlg_name.placeholder_text = "(original names are used)"
		_dlg_name.editable = false
		_dlg_name_label.text = "Name: %d animations selected, each keeps its original name." % ids.size()
	_update_export_dialog_info()
	_export_dialog.rect_size = Vector2(500, 10)
	_export_dialog.popup_centered(Vector2(500, 10))
	_dlg_name.grab_focus()


func _on_export_confirmed() -> void:
	var ids = _pending_ids
	var dir_text : String = _dlg_dir.text.strip_edges()
	if not dir_text.begins_with("res://"):
		_log_error("The export folder has to be inside the project (res://...).")
		return
	_last_export_dir = dir_text
	var base : String = dir_text.trim_suffix("/")      # "res://" becomes "res:/", so base + "/" + file is valid
	if dir_text != "res://":
		var dir := Directory.new()
		if not dir.dir_exists(base):
			dir.make_dir_recursive(base)

	var custom : String = ""
	if ids.size() == 1:
		custom = _dlg_name.text.strip_edges()
	var saved = 0
	var overwritten = 0
	var failed = 0
	var file_check := File.new()
	for id in ids:
		if not _source_player.has_animation(id):
			continue
		var out : Animation = _retargeting._retarget_animation_track(_source_player.get_animation(id))
		var file_path : String = base + "/" + _export_file_name(id, custom)
		if file_check.file_exists(file_path):
			overwritten += 1
		if ResourceSaver.save(file_path, out) == OK:
			saved += 1
		else:
			failed += 1
			_log_error("Could not save " + file_path)

	if editor != null:
		editor.get_resource_filesystem().scan()
	if saved > 0:
		var note = ""
		if overwritten > 0:
			note = " (%d existing file(s) overwritten)" % overwritten
		_log_ok("Exported %d animation(s) to %s%s" % [saved, dir_text, note])
	if failed > 0:
		_log_warn("%d animation(s) failed to export." % failed)


# ================================================================== paths / dialogs / small ui helpers

func _on_path_entered(path: String, is_source: bool) -> void:
	_log.clear()
	_set_model(is_source, path)


func _on_swap_pressed() -> void:
	var a = _source_path
	var b = _target_path
	_log.clear()
	_set_model(true, b)
	_set_model(false, a)


func _on_browse_pressed(kind: String) -> void:
	_pending_browse = kind
	_file_dialog.clear_filters()
	if kind == "dir":
		_file_dialog.mode = FileDialog.MODE_OPEN_DIR
	else:
		_file_dialog.mode = FileDialog.MODE_OPEN_FILE
		for filter in MODEL_FILTERS:
			_file_dialog.add_filter(filter)
	_file_dialog.popup_centered_ratio(0.6)


func _on_file_chosen(path: String) -> void:
	if _pending_browse == "source":
		_log.clear()
		_set_model(true, path)
	elif _pending_browse == "target":
		_log.clear()
		_set_model(false, path)
	elif _pending_browse == "dir":
		_dlg_dir.text = path
		_export_dir_touched = true
		_last_export_dir = path
		_update_export_dialog_info()


func _on_export_dir_edited(_text) -> void:
	_export_dir_touched = true
	_update_export_dialog_info()


func _on_export_name_edited(_text) -> void:
	_update_export_dialog_info()


func _make_label(p_text: String) -> Label:
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


func _add_check(parent: Node, p_text: String, pressed: bool) -> CheckBox:
	var check := CheckBox.new()
	check.text = p_text
	check.pressed = pressed
	parent.add_child(check)
	return check


func _add_path_row(parent: Node, kind: String) -> LineEdit:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	var button := Button.new()
	button.text = "..."
	button.connect("pressed", self, "_on_browse_pressed", [kind])
	row.add_child(button)
	return edit


# A header button that folds / unfolds the box below it.
func _add_section(parent: Node, title: String, start_open: bool) -> VBoxContainer:
	var header := Button.new()
	header.flat = true
	header.toggle_mode = true
	header.pressed = start_open
	header.align = Button.ALIGN_LEFT
	header.text = ("v  " if start_open else ">  ") + title
	parent.add_child(header)
	var body := VBoxContainer.new()
	body.visible = start_open
	parent.add_child(body)
	header.connect("toggled", self, "_on_section_toggled", [header, body, title])
	return body


func _on_section_toggled(open: bool, header: Button, body: Control, title: String) -> void:
	header.text = ("v  " if open else ">  ") + title
	body.visible = open


func _clean(text: String) -> String:
	return text.replace("[", "(").replace("]", ")")


func _log_info(text: String) -> void:
	_log.append_bbcode("[color=#cfcfcf]" + _clean(text) + "[/color]\n")


func _log_ok(text: String) -> void:
	_log.append_bbcode("[color=#8fdc8f]" + _clean(text) + "[/color]\n")


func _log_warn(text: String) -> void:
	_log.append_bbcode("[color=#ffcc55]Warning: " + _clean(text) + "[/color]\n")


func _log_error(text: String) -> void:
	_log.append_bbcode("[color=#ff7777]Error: " + _clean(text) + "[/color]\n")
