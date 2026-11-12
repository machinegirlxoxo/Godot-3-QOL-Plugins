tool
extends EditorInspectorPlugin
# Adds a checkbox at the top of the Inspector for 3D nodes: "Ignore distance LOD".
# It is the same thing as putting the node in the group "texture_quality_ignore", just easier to reach.
# The setting covers the node and everything under it, and is saved with the scene.

const IGNORE_GROUP = "texture_quality_ignore"

var _undo_redo


func setup(undo_redo) -> void:
	_undo_redo = undo_redo


func can_handle(object) -> bool:
	return object is Spatial


func parse_begin(object) -> void:
	var box = CheckBox.new()
	box.text = "Ignore distance LOD (Texture Quality)"
	box.hint_tooltip = "Textures used by this node and its children always keep the best tier the quality level allows.\nSame as adding the node to the group \"%s\"." % IGNORE_GROUP
	box.pressed = object.is_in_group(IGNORE_GROUP)
	if not box.pressed and _parent_ignored(object):
		box.text += " - parent already ignored"
	box.connect("toggled", self, "_on_toggled", [object])
	add_custom_control(box)


func _parent_ignored(node) -> bool:
	var n = node.get_parent()
	while n != null:
		if n.is_in_group(IGNORE_GROUP):
			return true
		n = n.get_parent()
	return false


func _on_toggled(pressed: bool, node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if _undo_redo == null:
		if pressed:
			node.add_to_group(IGNORE_GROUP, true)
		else:
			node.remove_from_group(IGNORE_GROUP)
		return
	# Going through UndoRedo also marks the scene as modified, so the change is saved and can be undone.
	_undo_redo.create_action("Texture Quality: ignore distance LOD")
	if pressed:
		_undo_redo.add_do_method(node, "add_to_group", IGNORE_GROUP, true)
		_undo_redo.add_undo_method(node, "remove_from_group", IGNORE_GROUP)
	else:
		_undo_redo.add_do_method(node, "remove_from_group", IGNORE_GROUP)
		_undo_redo.add_undo_method(node, "add_to_group", IGNORE_GROUP, true)
	_undo_redo.commit_action()
