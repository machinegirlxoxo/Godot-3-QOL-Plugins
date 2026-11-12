tool
extends EditorPlugin

const Hub = preload("hub.gd")

var hub


func _enter_tree():
	hub = Hub.new()
	hub.editor_plugin = self
	hub.size_flags_vertical = Control.SIZE_EXPAND_FILL
	get_editor_interface().get_editor_viewport().add_child(hub)
	make_visible(false)


func _exit_tree():
	if hub:
		hub.queue_free()
		hub = null


func has_main_screen():
	return true


func make_visible(visible):
	if hub:
		hub.visible = visible
		if visible:
			hub.on_shown()


func get_plugin_name():
	return "QOL"


func get_plugin_icon():
	return get_editor_interface().get_base_control().get_icon("Favorites", "EditorIcons")
