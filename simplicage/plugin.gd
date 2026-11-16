tool
extends EditorPlugin


func _enter_tree():
	var icon = get_editor_interface().get_base_control().get_icon("Spatial", "EditorIcons")
	add_custom_type("Physicator", "Spatial", preload("simplicage.gd"), icon)


func _exit_tree():
	remove_custom_type("Physicator")
