tool
extends EditorInspectorPlugin

const CameraPreviewScript = preload("res://addons/camera_preview/camera_preview.gd")


func can_handle(object) -> bool:
	return object is Camera


func parse_begin(object) -> void:
	var camera : Camera = object
	if not camera.is_inside_tree():
		return
	var preview = CameraPreviewScript.new()
	preview.setup(camera)
	add_custom_control(preview)
