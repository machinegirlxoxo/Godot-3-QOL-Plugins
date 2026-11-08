tool
extends EditorPlugin

const CinematicPanelScript = preload("res://addons/cinematic_editor/cinematic_panel.gd")

var _panel


const AUTOLOAD_NAME = "Cutscenes"
const AUTOLOAD_PATH = "res://addons/cinematic_editor/cutscenes.gd"


func _enter_tree() -> void:
	# Global helper: Cutscenes.start_cutscene("name") / Cutscenes.end_cutscene() from any script
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_panel = CinematicPanelScript.new()
	_panel.editor = get_editor_interface()
	_panel.undo_redo = get_undo_redo()
	get_editor_interface().get_editor_viewport().add_child(_panel)
	connect("scene_changed", self, "_on_scene_changed")
	make_visible(false)


func _exit_tree() -> void:
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)
	if _panel != null:
		_panel.queue_free()
		_panel = null


func _on_scene_changed(_root) -> void:
	if _panel != null:
		_panel.on_scene_changed()


func has_main_screen() -> bool:
	return true


# While the Cinematic tab is open, tell Godot we are happy to show 3D nodes. Otherwise selecting a node
# (in the scene tree or from the Nodes list) would jump to the 3D tab.
func handles(object) -> bool:
	return _panel != null and _panel.visible and object is Spatial


func edit(_object) -> void:
	pass


func make_visible(visible: bool) -> void:
	if _panel == null:
		return
	_panel.visible = visible
	if visible:
		_panel.on_shown()


func get_plugin_name() -> String:
	return "Cinematic"


func get_plugin_icon() -> Texture:
	return get_editor_interface().get_base_control().get_icon("Animation", "EditorIcons")
