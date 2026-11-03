tool
extends VBoxContainer
# Live preview of a Camera, drawn in its own Viewport that shares the edited scene's World.
# A helper Camera inside that viewport copies the inspected camera every frame.

var _source : Camera
var _container : ViewportContainer
var _viewport : Viewport
var _preview_camera : Camera
var _aspect : float = 9.0 / 16.0


func setup(p_camera : Camera) -> void:
	_source = p_camera

	var title := Label.new()
	title.text = "Camera Preview"
	add_child(title)

	_container = ViewportContainer.new()
	_container.stretch = true
	_container.rect_min_size = Vector2(0, 120)
	_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_container)

	_viewport = Viewport.new()
	_viewport.world = _source.get_world()
	_viewport.gui_disable_input = true
	_viewport.physics_object_picking = false
	_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	_container.add_child(_viewport)

	_preview_camera = Camera.new()
	_viewport.add_child(_preview_camera)
	_preview_camera.current = true

	var width : float = ProjectSettings.get_setting("display/window/size/width")
	var height : float = ProjectSettings.get_setting("display/window/size/height")
	if width > 0.0 and height > 0.0:
		_aspect = height / width

	set_process(true)


func _process(_delta : float) -> void:
	if not is_instance_valid(_source) or not _source.is_inside_tree():
		_viewport.render_target_update_mode = Viewport.UPDATE_DISABLED
		return

	if not is_visible_in_tree():
		_viewport.render_target_update_mode = Viewport.UPDATE_DISABLED
		return
	_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS

	# Keep the preview at the game's aspect ratio, filling the inspector width.
	var wanted_height : float = max(_container.rect_size.x * _aspect, 40.0)
	if abs(_container.rect_min_size.y - wanted_height) > 0.5:
		_container.rect_min_size.y = wanted_height

	_preview_camera.transform = _source.global_transform
	_preview_camera.projection = _source.projection
	_preview_camera.fov = _source.fov
	_preview_camera.size = _source.size
	_preview_camera.near = _source.near
	_preview_camera.far = _source.far
	_preview_camera.keep_aspect = _source.keep_aspect
	_preview_camera.cull_mask = _source.cull_mask
	_preview_camera.environment = _source.environment
	_preview_camera.h_offset = _source.h_offset
	_preview_camera.v_offset = _source.v_offset
	_preview_camera.frustum_offset = _source.frustum_offset
