tool
extends EditorPlugin
# Adds a "Megascans" tab next to 2D / 3D / Script in the editor's main screen.

const Browser = preload("res://addons/megascans_link/browser.gd")

var _browser


func _enter_tree() -> void:
	_browser = Browser.new()
	_browser.editor = get_editor_interface()
	get_editor_interface().get_editor_viewport().add_child(_browser)
	make_visible(false)


func _exit_tree() -> void:
	if _browser != null:
		_browser.queue_free()
		_browser = null


func has_main_screen() -> bool:
	return true


func make_visible(visible: bool) -> void:
	if _browser == null:
		return
	_browser.visible = visible
	if visible:
		_browser.on_shown()


func get_plugin_name() -> String:
	return "Megascans"


func get_plugin_icon() -> Texture:
	return get_editor_interface().get_base_control().get_icon("MeshInstance", "EditorIcons")
