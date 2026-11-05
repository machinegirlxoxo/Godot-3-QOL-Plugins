tool
extends EditorPlugin

const AUTOLOAD = "TextureQuality"
const ImportPluginScript = preload("res://addons/texture_quality/import_plugin.gd")
const MenuScript = preload("res://addons/texture_quality/editor_menu.gd")

var _import_plugin
var _menu


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/texture_quality/texture_quality.gd")

	_import_plugin = ImportPluginScript.new()
	add_import_plugin(_import_plugin)

	# Menu in the 3D editor's top toolbar (next to Transform / View).
	_menu = MenuScript.new()
	_menu.setup(get_editor_interface().get_editor_settings())
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)


func _exit_tree() -> void:
	if _import_plugin != null:
		remove_import_plugin(_import_plugin)
		_import_plugin = null
	if _menu != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)
		_menu.queue_free()
		_menu = null
	remove_autoload_singleton(AUTOLOAD)
