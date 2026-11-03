tool
extends EditorPlugin

const ViewmodelMaterialScript = preload("res://addons/viewmodel_material/viewmodel_material.gd")
const InspectorScript = preload("res://addons/viewmodel_material/viewmodel_inspector.gd")

var _inspector


func _enter_tree() -> void:
	var icon : Texture = get_editor_interface().get_base_control().get_icon("ShaderMaterial", "EditorIcons")
	add_custom_type("ViewmodelMaterial", "ShaderMaterial", ViewmodelMaterialScript, icon)
	_inspector = InspectorScript.new()
	_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	remove_custom_type("ViewmodelMaterial")
	if _inspector:
		remove_inspector_plugin(_inspector)
		_inspector = null
