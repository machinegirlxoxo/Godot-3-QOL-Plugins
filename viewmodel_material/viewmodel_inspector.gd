tool
extends EditorInspectorPlugin
# Adds checkboxes at the top of a MeshInstance's inspector:
#   [x] Use Z-Clip / FOV Override   (master toggle: swaps surface materials for ViewmodelMaterial and back)
#       [x] Use Z Clip Scale
#       [x] Use FOV Override
# Turning the master toggle off restores the original materials.

const ViewmodelMaterialScript = preload("res://addons/viewmodel_material/viewmodel_material.gd")

var undo_redo : UndoRedo


func can_handle(object) -> bool:
	return object is MeshInstance


func parse_begin(object) -> void:
	var mesh_instance : MeshInstance = object
	var box := VBoxContainer.new()

	var master := CheckBox.new()
	master.text = "Use Z-Clip / FOV Override"
	master.hint_tooltip = "Replaces the surface materials with ViewmodelMaterial. Uncheck to restore the originals."
	master.pressed = _is_enabled(mesh_instance)
	master.connect("toggled", self, "_on_master_toggled", [mesh_instance])
	box.add_child(master)

	var z_check := CheckBox.new()
	z_check.text = "    Use Z Clip Scale"
	z_check.pressed = _all_flag(mesh_instance, "use_z_clip_scale")
	z_check.disabled = not master.pressed
	z_check.connect("toggled", self, "_on_flag_toggled", [mesh_instance, "use_z_clip_scale"])
	box.add_child(z_check)

	var fov_check := CheckBox.new()
	fov_check.text = "    Use FOV Override"
	fov_check.pressed = _all_flag(mesh_instance, "use_fov_override")
	fov_check.disabled = not master.pressed
	fov_check.connect("toggled", self, "_on_flag_toggled", [mesh_instance, "use_fov_override"])
	box.add_child(fov_check)

	if master.pressed and mesh_instance.cast_shadow != GeometryInstance.SHADOW_CASTING_SETTING_OFF:
		var warning := Label.new()
		warning.text = "Cast Shadow is on. With FOV override this can draw a big black shadow."
		warning.autowrap = true
		box.add_child(warning)
		var fix_button := Button.new()
		fix_button.text = "Turn Off Cast Shadow"
		fix_button.connect("pressed", self, "_on_turn_off_shadow_pressed", [mesh_instance])
		box.add_child(fix_button)

	add_custom_control(box)


func _is_viewmodel(p_material) -> bool:
	return p_material != null and p_material.get_script() == ViewmodelMaterialScript


func _is_enabled(mesh_instance : MeshInstance) -> bool:
	var mesh : Mesh = mesh_instance.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return false
	for i in mesh.get_surface_count():
		if not _is_viewmodel(mesh_instance.get_surface_material(i)):
			return false
	return true


func _all_flag(mesh_instance : MeshInstance, p_property : String) -> bool:
	if not _is_enabled(mesh_instance):
		return false
	for i in mesh_instance.mesh.get_surface_count():
		if not mesh_instance.get_surface_material(i).get(p_property):
			return false
	return true


func _on_master_toggled(p_pressed : bool, mesh_instance : MeshInstance) -> void:
	var mesh : Mesh = mesh_instance.mesh
	if mesh == null:
		return
	if p_pressed == _is_enabled(mesh_instance):
		return
	if undo_redo:
		undo_redo.create_action("Toggle Viewmodel Material")

	if p_pressed:
		mesh_instance.set_meta("vm_prev_cast_shadow", mesh_instance.cast_shadow)
		for i in mesh.get_surface_count():
			var current : Material = mesh_instance.get_surface_material(i)
			var source : Material = current
			if source == null:
				source = mesh.surface_get_material(i)
			var new_material = ViewmodelMaterialScript.new()
			if source is SpatialMaterial:
				new_material.copy_from_spatial(source)
			else:
				# No SpatialMaterial on the mesh: start from a default one so every parameter gets set.
				new_material.copy_from_spatial(SpatialMaterial.new())
			if current != null:
				new_material.set_meta("vm_original", current)
			new_material.use_z_clip_scale = true
			new_material.z_clip_scale = 0.3
			new_material.use_fov_override = true
			new_material.fov_override = 60.0
			_do_undo_method(mesh_instance, "set_surface_material", [i, new_material], [i, current])
		# Spot/omni shadow passes would use the modified projection, so stop casting shadows.
		_do_undo_property(mesh_instance, "cast_shadow", GeometryInstance.SHADOW_CASTING_SETTING_OFF, mesh_instance.cast_shadow)
	else:
		for i in mesh.get_surface_count():
			var current : Material = mesh_instance.get_surface_material(i)
			var original : Material = null
			if current != null and current.has_meta("vm_original"):
				original = current.get_meta("vm_original")
			_do_undo_method(mesh_instance, "set_surface_material", [i, original], [i, current])
		var previous : int = GeometryInstance.SHADOW_CASTING_SETTING_ON
		if mesh_instance.has_meta("vm_prev_cast_shadow"):
			previous = mesh_instance.get_meta("vm_prev_cast_shadow")
		_do_undo_property(mesh_instance, "cast_shadow", previous, mesh_instance.cast_shadow)

	_finish(mesh_instance)


func _on_flag_toggled(p_pressed : bool, mesh_instance : MeshInstance, p_property : String) -> void:
	if not _is_enabled(mesh_instance):
		return
	if undo_redo:
		undo_redo.create_action("Toggle " + p_property)
	for i in mesh_instance.mesh.get_surface_count():
		var material : Material = mesh_instance.get_surface_material(i)
		_do_undo_property(material, p_property, p_pressed, material.get(p_property))
	_finish(mesh_instance)


func _do_undo_method(p_object : Object, p_method : String, p_do_args : Array, p_undo_args : Array) -> void:
	if undo_redo:
		undo_redo.add_do_method(p_object, p_method, p_do_args[0], p_do_args[1])
		undo_redo.add_undo_method(p_object, p_method, p_undo_args[0], p_undo_args[1])
	else:
		p_object.callv(p_method, p_do_args)


func _do_undo_property(p_object : Object, p_property : String, p_do_value, p_undo_value) -> void:
	if undo_redo:
		undo_redo.add_do_property(p_object, p_property, p_do_value)
		undo_redo.add_undo_property(p_object, p_property, p_undo_value)
	else:
		p_object.set(p_property, p_do_value)


func _finish(mesh_instance : MeshInstance) -> void:
	if undo_redo:
		# Refresh the inspector (and the checkboxes) after do and after undo.
		undo_redo.add_do_method(mesh_instance, "property_list_changed_notify")
		undo_redo.add_undo_method(mesh_instance, "property_list_changed_notify")
		undo_redo.commit_action()
	else:
		mesh_instance.property_list_changed_notify()


func _on_turn_off_shadow_pressed(mesh_instance : MeshInstance) -> void:
	if undo_redo:
		undo_redo.create_action("Turn Off Cast Shadow")
		undo_redo.add_do_property(mesh_instance, "cast_shadow", GeometryInstance.SHADOW_CASTING_SETTING_OFF)
		undo_redo.add_undo_property(mesh_instance, "cast_shadow", mesh_instance.cast_shadow)
		undo_redo.add_do_method(mesh_instance, "property_list_changed_notify")
		undo_redo.add_undo_method(mesh_instance, "property_list_changed_notify")
		undo_redo.commit_action()
	else:
		mesh_instance.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
		mesh_instance.property_list_changed_notify()
