tool
extends EditorPlugin

const InspectorScript = preload("res://addons/camera_preview/camera_inspector.gd")

var _inspector


func _enter_tree() -> void:
	_inspector = InspectorScript.new()
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	if _inspector:
		remove_inspector_plugin(_inspector)
		_inspector = null
