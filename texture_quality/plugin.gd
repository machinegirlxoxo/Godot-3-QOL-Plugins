tool
extends EditorPlugin

const AUTOLOAD = "TextureQuality"
const ImportPluginScript = preload("res://addons/texture_quality/import_plugin.gd")
const MenuScript = preload("res://addons/texture_quality/editor_menu.gd")
const AutoImportScript = preload("res://addons/texture_quality/auto_import.gd")
const NodeToggleScript = preload("res://addons/texture_quality/node_toggle.gd")
const CONVERT_MENU = "Texture Quality: Convert All Textures"

var _import_plugin
var _menu
var _auto
var _inspector


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/texture_quality/texture_quality.gd")
	_register_settings()

	_import_plugin = ImportPluginScript.new()
	add_import_plugin(_import_plugin)

	# Menu in the 3D editor's top toolbar (next to Transform / View).
	_menu = MenuScript.new()
	_menu.setup(get_editor_interface().get_editor_settings())
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)

	# "Ignore distance LOD" checkbox in the Inspector for 3D nodes.
	_inspector = NodeToggleScript.new()
	_inspector.setup(get_undo_redo())
	add_inspector_plugin(_inspector)

	# Converts images that were imported before the plugin was enabled (Project > Tools, run by hand).
	_auto = AutoImportScript.new()
	_auto.setup(_import_plugin, get_editor_interface(), get_tree())
	add_tool_menu_item(CONVERT_MENU, self, "_on_convert_all")
	if bool(ProjectSettings.get_setting("texture_quality/auto_convert_existing")):
		_auto.call_deferred("convert_all")

	# New images: Godot imports them with the built-in importer first; switch them over right away.
	var fs = get_editor_interface().get_resource_filesystem()
	if not fs.is_connected("resources_reimported", self, "_on_resources_reimported"):
		fs.connect("resources_reimported", self, "_on_resources_reimported")


func _exit_tree() -> void:
	var fs = get_editor_interface().get_resource_filesystem()
	if fs != null and fs.is_connected("resources_reimported", self, "_on_resources_reimported"):
		fs.disconnect("resources_reimported", self, "_on_resources_reimported")
	if _inspector != null:
		remove_inspector_plugin(_inspector)
		_inspector = null
	remove_tool_menu_item(CONVERT_MENU)
	if _auto != null:
		_auto.cancel()
		_auto = null
	if _import_plugin != null:
		remove_import_plugin(_import_plugin)
		_import_plugin = null
	if _menu != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)
		_menu.queue_free()
		_menu = null
	remove_autoload_singleton(AUTOLOAD)


func _on_resources_reimported(resources) -> void:
	if _auto == null or not bool(ProjectSettings.get_setting("texture_quality/convert_new_textures")):
		return
	_auto.call_deferred("convert_files", resources)


func _on_convert_all(_ud) -> void:
	if _auto != null:
		_auto.convert_all()


# Shows the plugin's options under Project Settings > General > Texture Quality.
func _register_settings() -> void:
	_setting("texture_quality/distance_lod", true, TYPE_BOOL)
	_setting("texture_quality/near_distance", 5.0, TYPE_REAL, PROPERTY_HINT_RANGE, "0,2000,0.5,or_greater")
	_setting("texture_quality/far_distance", 60.0, TYPE_REAL, PROPERTY_HINT_RANGE, "0,5000,0.5,or_greater")
	_setting("texture_quality/lod_nodes_per_frame", 128, TYPE_INT, PROPERTY_HINT_RANGE, "8,2048,1,or_greater")
	_setting("texture_quality/convert_new_textures", true, TYPE_BOOL)
	_setting("texture_quality/auto_convert_existing", false, TYPE_BOOL)


func _setting(name: String, default, type: int, hint: int = PROPERTY_HINT_NONE, hint_string: String = "") -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.set_initial_value(name, default)
	ProjectSettings.add_property_info({"name": name, "type": type, "hint": hint, "hint_string": hint_string})
