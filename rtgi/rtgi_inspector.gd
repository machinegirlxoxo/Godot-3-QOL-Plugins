tool
extends EditorInspectorPlugin
# Adds an "RTGI" section to the Environment inspector (WorldEnvironment -> Environment), in the SSAO group.

const RTGIPanel = preload("res://addons/rtgi/rtgi_panel.gd")

var plugin
var _placed = false
var _object = null

func can_handle(object):
	return object is Environment

func parse_begin(object):
	_placed = false
	_object = object

# "ssao_edge_sharpness" is the last SSAO property, so the RTGI section shows up right in the SSAO group.
func parse_property(object, type, path, hint, hint_text, usage):
	if path == "ssao_edge_sharpness" and not _placed:
		_add_panel(object)
	return false

# Fallback if that property wasn't found: put the section at the end of the Environment.
func parse_end():
	if not _placed and _object:
		_add_panel(_object)

func _add_panel(object):
	_placed = true
	var p = RTGIPanel.new()
	p.setup(plugin, object)
	add_custom_control(p)
