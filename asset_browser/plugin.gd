tool
extends EditorPlugin
# Adds an "AssetBrowser" tab next to 2D / 3D / Script. Inside it there is one sub-tab per marketplace.

const Shell = preload("res://addons/asset_browser/shell.gd")

var _shell


func _enter_tree() -> void:
	_shell = Shell.new()
	_shell.editor = get_editor_interface()
	get_editor_interface().get_editor_viewport().add_child(_shell)
	make_visible(false)


func _exit_tree() -> void:
	if _shell != null:
		_shell.queue_free()
		_shell = null


func has_main_screen() -> bool:
	return true


func make_visible(visible: bool) -> void:
	if _shell == null:
		return
	_shell.visible = visible
	if visible:
		_shell.on_shown()


func get_plugin_name() -> String:
	return "AssetBrowser"


func get_plugin_icon() -> Texture:
	return get_editor_interface().get_base_control().get_icon("Environment", "EditorIcons")
