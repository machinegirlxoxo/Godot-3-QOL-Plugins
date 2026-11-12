tool
extends EditorPlugin

# Godot 3.5+
# Transfers a vertex-painted region from one static MeshInstance to another.
# Geometry is joined as separate surfaces; this is not a watertight CSG Boolean.

const PAINT_THRESHOLD = 0.5

var _toolbar = null
var _merge_button = null
var _cancel_button = null
var _confirm_button = null
var _brush_size = null

var _target_dialog = null
var _target_option = null
var _target_nodes = []
var _message_dialog = null

var _painting = false
var _awaiting_target = false
var _source = null
var _original_source_mesh = null
var _original_source_override = null
var _source_surfaces = []
var _weights = []
var _world_vertices = []
var _hidden_nodes = []
var _preview_material = null
var _last_mouse_position = Vector2(-10000, -10000)


func _enter_tree():
	_build_toolbar()
	_build_dialogs()
	set_input_event_forwarding_always_enabled()


func _exit_tree():
	_cancel_paint()
	if _toolbar != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
		_toolbar.free()
		_toolbar = null
	if _target_dialog != null:
		_target_dialog.free()
		_target_dialog = null
	if _message_dialog != null:
		_message_dialog.free()
		_message_dialog = null


func _build_toolbar():
	_toolbar = HBoxContainer.new()
	_toolbar.name = "PaintedMeshMergeToolbar"

	_merge_button = Button.new()
	_merge_button.text = "Merge Mesh"
	_merge_button.hint_tooltip = "Paint part of the selected MeshInstance, then transfer it to another mesh."
	_merge_button.connect("pressed", self, "_begin_paint")
	_toolbar.add_child(_merge_button)

	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.visible = false
	_cancel_button.connect("pressed", self, "_cancel_paint")
	_toolbar.add_child(_cancel_button)

	_confirm_button = Button.new()
	_confirm_button.text = "Confirm"
	_confirm_button.visible = false
	_confirm_button.connect("pressed", self, "_show_target_dialog")
	_toolbar.add_child(_confirm_button)

	var brush_label = Label.new()
	brush_label.text = "Brush"
	brush_label.visible = false
	_toolbar.add_child(brush_label)

	_brush_size = SpinBox.new()
	_brush_size.min_value = 0.01
	_brush_size.max_value = 10.0
	_brush_size.step = 0.01
	_brush_size.value = 0.25
	_brush_size.suffix = " m"
	_brush_size.visible = false
	_brush_size.rect_min_size = Vector2(90, 0)
	_toolbar.add_child(_brush_size)
	_toolbar.set_meta("brush_label", brush_label)

	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)


func _build_dialogs():
	_target_dialog = ConfirmationDialog.new()
	_target_dialog.window_title = "Merge Painted Mesh"
	_target_dialog.rect_min_size = Vector2(420, 0)
	var box = VBoxContainer.new()
	_target_dialog.add_child(box)
	var hint = Label.new()
	hint.text = "Choose the mesh that receives the painted geometry:"
	box.add_child(hint)
	_target_dialog.get_ok().text = "Merge"
	_target_option = OptionButton.new()
	_target_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_option.clip_text = true
	_target_option.rect_min_size = Vector2(0, 0)
	box.add_child(_target_option)
	_target_dialog.connect("confirmed", self, "_on_target_confirmed")
	_target_dialog.connect("popup_hide", self, "_on_target_dialog_canceled")
	get_editor_interface().get_base_control().add_child(_target_dialog)

	_message_dialog = AcceptDialog.new()
	_message_dialog.window_title = "Painted Mesh Merge"
	get_editor_interface().get_base_control().add_child(_message_dialog)

	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded;
void fragment() {
    ALBEDO = mix(vec3(0.28, 0.30, 0.34), vec3(1.0, 0.08, 0.025), COLOR.r);
}
"""
	_preview_material = ShaderMaterial.new()
	_preview_material.shader = shader


func _show_message(message):
	_message_dialog.dialog_text = message
	_message_dialog.popup_centered_minsize()


func _get_selected_mesh_instance():
	var selected = get_editor_interface().get_selection().get_selected_nodes()
	for node in selected:
		if node is MeshInstance and node.mesh != null:
			return node
	return null


func _begin_paint():
	if _painting:
		return
	var mesh_instance = _get_selected_mesh_instance()
	if mesh_instance == null:
		_show_message("Select a MeshInstance with a mesh in the 3D scene tree first.")
		return
	var problem = _mesh_problem(mesh_instance.mesh)
	if problem != "":
		_show_message("\"%s\" can't be used: %s\nThis tool supports static triangle meshes only (no blend shapes or non-triangle surfaces)." % [mesh_instance.name, problem])
		return

	_source = mesh_instance
	_original_source_mesh = _source.mesh
	_original_source_override = _source.material_override
	_source_surfaces.clear()
	_weights.clear()
	_world_vertices.clear()
	var source_xf = _source.global_transform

	for surface_index in range(_original_source_mesh.get_surface_count()):
		var arrays = _original_source_mesh.surface_get_arrays(surface_index)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		var material = _source.get_active_material(surface_index)
		_source_surfaces.append({
			"arrays": _duplicate_arrays(arrays),
			"material": material,
			"primitive": _original_source_mesh.surface_get_primitive_type(surface_index)
		})
		var surface_weights = PoolRealArray()
		surface_weights.resize(vertices.size())
		for i in range(vertices.size()):
			surface_weights[i] = 0.0
		_weights.append(surface_weights)

		# Cache world-space positions once so painting doesn't re-transform every vertex on each mouse event.
		var world_vertices = PoolVector3Array()
		world_vertices.resize(vertices.size())
		for i in range(vertices.size()):
			world_vertices[i] = source_xf.xform(vertices[i])
		_world_vertices.append(world_vertices)

	_source.mesh = _build_preview_mesh()
	_source.material_override = _preview_material
	_hide_other_nodes(get_editor_interface().get_edited_scene_root())
	_painting = true
	_awaiting_target = false
	_merge_button.visible = false
	_cancel_button.visible = true
	_confirm_button.visible = true
	for child in _toolbar.get_children():
		if child is Label or child == _brush_size:
			child.visible = true
	_show_message("Paint the area to transfer by dragging the left mouse button over the selected mesh. Brush size is measured in world units. Press Confirm when finished.")
	update_overlays()


# Hides every 3D node except the one being painted (and restores them in _restore_hidden_nodes).
func _hide_other_nodes(node):
	if node == null:
		return
	if node is Spatial and node != _source:
		if node.is_a_parent_of(_source):
			# Ancestors must stay visible or they would hide the source too,
			# so stop them from rendering without hiding their children.
			if node is VisualInstance and node.layers != 0:
				_hidden_nodes.append({"node": node, "layers": node.layers})
				node.layers = 0
		else:
			if node.visible:
				_hidden_nodes.append({"node": node, "visible": true})
				node.visible = false
			return
	for child in node.get_children():
		_hide_other_nodes(child)


func _restore_hidden_nodes():
	for entry in _hidden_nodes:
		var node = entry["node"]
		if not is_instance_valid(node):
			continue
		if entry.has("layers"):
			node.layers = entry["layers"]
		if entry.has("visible"):
			node.visible = true
	_hidden_nodes.clear()


# Returns "" if the mesh is supported, otherwise a human-readable reason.
func _mesh_problem(mesh):
	if mesh == null or mesh.get_surface_count() == 0:
		return "the mesh has no surfaces."
	if mesh.get_blend_shape_count() > 0:
		return "the mesh has %d blend shape(s) (shape keys)." % mesh.get_blend_shape_count()
	for surface_index in range(mesh.get_surface_count()):
		var primitive = mesh.surface_get_primitive_type(surface_index)
		if primitive != Mesh.PRIMITIVE_TRIANGLES:
			return "surface %d is not made of triangles (primitive type %d)." % [surface_index, primitive]
		var arrays = mesh.surface_get_arrays(surface_index)
		if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].size() < 3:
			return "surface %d has fewer than 3 vertices." % surface_index
		# Skinned meshes are supported as long as the skin data is consistent.
		var bones = arrays[Mesh.ARRAY_BONES]
		var skin_weights = arrays[Mesh.ARRAY_WEIGHTS]
		var vertex_total = arrays[Mesh.ARRAY_VERTEX].size()
		if bones != null and bones.size() > 0:
			if skin_weights == null or skin_weights.size() != bones.size() or bones.size() % vertex_total != 0:
				return "surface %d has inconsistent bone indices/weights." % surface_index
		elif skin_weights != null and skin_weights.size() > 0:
			return "surface %d has bone weights but no bone indices." % surface_index
	return ""


func _duplicate_arrays(source_arrays):
	var result = []
	result.resize(Mesh.ARRAY_MAX)
	for i in range(Mesh.ARRAY_MAX):
		if source_arrays[i] != null:
			result[i] = source_arrays[i]
	return result


func _build_preview_mesh():
	var result = ArrayMesh.new()
	for surface_index in range(_source_surfaces.size()):
		var data = _source_surfaces[surface_index]
		var arrays = _duplicate_arrays(data["arrays"])
		var colors = PoolColorArray()
		for weight in _weights[surface_index]:
			colors.append(Color(weight, 0.0, 0.0, 1.0))
		arrays[Mesh.ARRAY_COLOR] = colors
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var new_surface_index = result.get_surface_count() - 1
		if data["material"] != null:
			result.surface_set_material(new_surface_index, data["material"])
	return result


func _input_hit_position(camera, screen_position):
	var ray_from = camera.project_ray_origin(screen_position)
	var ray_direction = camera.project_ray_normal(screen_position)
	var closest_point = null
	var closest_distance = INF

	for surface_index in range(_source_surfaces.size()):
		var arrays = _source_surfaces[surface_index]["arrays"]
		var vertices = _world_vertices[surface_index]
		var indices = arrays[Mesh.ARRAY_INDEX]
		var index_count = indices.size() if indices != null and indices.size() > 0 else vertices.size()
		for tri_start in range(0, index_count - 2, 3):
			var ia = indices[tri_start] if indices != null and indices.size() > 0 else tri_start
			var ib = indices[tri_start + 1] if indices != null and indices.size() > 0 else tri_start + 1
			var ic = indices[tri_start + 2] if indices != null and indices.size() > 0 else tri_start + 2
			var a = vertices[ia]
			var b = vertices[ib]
			var c = vertices[ic]
			var hit = Geometry.ray_intersects_triangle(ray_from, ray_direction, a, b, c)
			if hit != null:
				var distance = ray_from.distance_to(hit)
				if distance < closest_distance:
					closest_distance = distance
					closest_point = hit
	return closest_point


func _paint_at(camera, screen_position):
	var hit_position = _input_hit_position(camera, screen_position)
	if hit_position == null:
		return false
	var radius = float(_brush_size.value)
	var changed = false
	for surface_index in range(_source_surfaces.size()):
		var vertices = _world_vertices[surface_index]
		var weights = _weights[surface_index]
		for vertex_index in range(vertices.size()):
			if vertices[vertex_index].distance_to(hit_position) <= radius:
				if weights[vertex_index] < 1.0:
					weights[vertex_index] = 1.0
					changed = true
		_weights[surface_index] = weights
	if changed:
		_source.mesh = _build_preview_mesh()
		_last_mouse_position = screen_position
		update_overlays()
	return true


func forward_spatial_gui_input(camera, event):
	if not _painting or _awaiting_target:
		return false
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.alt:
			return false
		if event.pressed:
			_last_mouse_position = event.position
			_paint_at(camera, event.position)
			return true
		return true
	if event is InputEventMouseMotion:
		_last_mouse_position = event.position
		if (event.button_mask & BUTTON_MASK_LEFT) and not event.alt:
			_paint_at(camera, event.position)
			return true
		update_overlays()
	return false


func forward_spatial_draw_over_viewport(overlay):
	if not _painting or _awaiting_target:
		return
	if _last_mouse_position.x > -1000:
		overlay.draw_arc(_last_mouse_position, 12.0, 0.0, PI * 2.0, 48, Color(1.0, 0.15, 0.05, 0.95), 2.0, true)


func _show_target_dialog():
	if not _painting:
		return
	_target_nodes.clear()
	_target_option.clear()
	var scene_root = get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		_collect_mesh_instances(scene_root)
	if _target_nodes.empty():
		_show_message("No other MeshInstance with a mesh was found in the current scene.")
		return
	var name_counts = {}
	for i in range(_target_nodes.size()):
		var node_name = str(_target_nodes[i].name)
		name_counts[node_name] = name_counts.get(node_name, 0) + 1
		var label = node_name
		if name_counts[node_name] > 1:
			label = "%s (%d)" % [node_name, name_counts[node_name]]
		_target_option.add_item(label, i)
	_target_option.select(0)
	_awaiting_target = true
	# Fixed size so a long name can never stretch the dialog off-screen.
	_target_dialog.popup_centered(Vector2(420, 110))


func _collect_mesh_instances(node):
	if node is MeshInstance and node != _source and node.mesh != null:
		_target_nodes.append(node)
	for child in node.get_children():
		_collect_mesh_instances(child)


func _on_target_dialog_canceled():
	_awaiting_target = false


func _on_target_confirmed():
	_awaiting_target = false
	if _target_option.get_selected_id() < 0:
		_show_message("Choose a target mesh first.")
		return
	var target = _target_nodes[_target_option.get_selected_id()]
	if target == null or not is_instance_valid(target):
		_show_message("The chosen target no longer exists.")
		return
	var target_problem = _mesh_problem(target.mesh)
	if target_problem != "":
		_show_message("Target \"%s\" can't be used: %s" % [target.name, target_problem])
		return
	_perform_merge(target)


func _perform_merge(target):
	var painted_count = 0
	for surface_weights in _weights:
		for weight in surface_weights:
			if weight >= PAINT_THRESHOLD:
				painted_count += 1
	if painted_count == 0:
		_show_message("Nothing has been painted yet. Paint some vertices before confirming.")
		return

	var original_target_mesh = target.mesh
	var source_to_target = target.global_transform.affine_inverse() * _source.global_transform
	var remaining_source_mesh = _build_clipped_mesh(false, Transform())
	var selected_piece_mesh = _build_clipped_mesh(true, source_to_target)
	var merged_target_mesh = _copy_mesh(original_target_mesh, target)
	_append_mesh_surfaces(merged_target_mesh, selected_piece_mesh)

	if merged_target_mesh.get_surface_count() == 0:
		_show_message("The merge produced no geometry.")
		return

	# Restore the source's preview material before applying the final mesh resources.
	_source.material_override = _original_source_override
	var undo_redo = get_undo_redo()
	undo_redo.create_action("Merge Painted Mesh Region")
	undo_redo.add_do_property(_source, "mesh", remaining_source_mesh)
	undo_redo.add_undo_property(_source, "mesh", _original_source_mesh)
	undo_redo.add_do_property(target, "mesh", merged_target_mesh)
	undo_redo.add_undo_property(target, "mesh", original_target_mesh)
	undo_redo.commit_action()
	_finish_paint_state()
	get_editor_interface().get_selection().clear()
	get_editor_interface().get_selection().add_node(target)


func _copy_mesh(mesh, instance):
	var result = ArrayMesh.new()
	for surface_index in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_index)
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _duplicate_arrays(arrays))
		var material = instance.get_active_material(surface_index)
		if material != null:
			result.surface_set_material(result.get_surface_count() - 1, material)
	return result


func _append_mesh_surfaces(destination, source_mesh):
	for surface_index in range(source_mesh.get_surface_count()):
		var arrays = source_mesh.surface_get_arrays(surface_index)
		destination.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _duplicate_arrays(arrays))
		var material = source_mesh.surface_get_material(surface_index)
		if material != null:
			destination.surface_set_material(destination.get_surface_count() - 1, material)


func _build_clipped_mesh(keep_painted, transform_to_output):
	var result = ArrayMesh.new()
	for surface_index in range(_source_surfaces.size()):
		var data = _source_surfaces[surface_index]
		var source_arrays = data["arrays"]
		var vertex_count = source_arrays[Mesh.ARRAY_VERTEX].size()
		var has_normals = source_arrays[Mesh.ARRAY_NORMAL] != null and source_arrays[Mesh.ARRAY_NORMAL].size() == vertex_count
		var has_uv = source_arrays[Mesh.ARRAY_TEX_UV] != null and source_arrays[Mesh.ARRAY_TEX_UV].size() == vertex_count
		var has_uv2 = source_arrays[Mesh.ARRAY_TEX_UV2] != null and source_arrays[Mesh.ARRAY_TEX_UV2].size() == vertex_count
		var has_colors = source_arrays[Mesh.ARRAY_COLOR] != null and source_arrays[Mesh.ARRAY_COLOR].size() == vertex_count
		var tangent_source = source_arrays[Mesh.ARRAY_TANGENT]
		var has_tangents = tangent_source != null and tangent_source.size() == vertex_count * 4
		var bones_source = source_arrays[Mesh.ARRAY_BONES]
		var skin_weights_source = source_arrays[Mesh.ARRAY_WEIGHTS]
		var has_skin = bones_source != null and skin_weights_source != null and bones_source.size() > 0 and bones_source.size() == skin_weights_source.size() and bones_source.size() % vertex_count == 0

		var out_arrays = []
		out_arrays.resize(Mesh.ARRAY_MAX)
		out_arrays[Mesh.ARRAY_VERTEX] = PoolVector3Array()
		if has_normals:
			out_arrays[Mesh.ARRAY_NORMAL] = PoolVector3Array()
		if has_uv:
			out_arrays[Mesh.ARRAY_TEX_UV] = PoolVector2Array()
		if has_uv2:
			out_arrays[Mesh.ARRAY_TEX_UV2] = PoolVector2Array()
		if has_colors:
			out_arrays[Mesh.ARRAY_COLOR] = PoolColorArray()
		if has_tangents:
			out_arrays[Mesh.ARRAY_TANGENT] = PoolRealArray()
		if has_skin:
			if typeof(bones_source) == TYPE_INT_ARRAY:
				out_arrays[Mesh.ARRAY_BONES] = PoolIntArray()
			else:
				out_arrays[Mesh.ARRAY_BONES] = PoolRealArray()
			out_arrays[Mesh.ARRAY_WEIGHTS] = PoolRealArray()

		var indices = source_arrays[Mesh.ARRAY_INDEX]
		var index_count = indices.size() if indices != null and indices.size() > 0 else vertex_count
		for tri_start in range(0, index_count - 2, 3):
			var ia = indices[tri_start] if indices != null and indices.size() > 0 else tri_start
			var ib = indices[tri_start + 1] if indices != null and indices.size() > 0 else tri_start + 1
			var ic = indices[tri_start + 2] if indices != null and indices.size() > 0 else tri_start + 2
			var polygon = [
				_read_vertex(source_arrays, _weights[surface_index], ia, has_normals, has_uv, has_uv2, has_colors, has_tangents, has_skin),
				_read_vertex(source_arrays, _weights[surface_index], ib, has_normals, has_uv, has_uv2, has_colors, has_tangents, has_skin),
				_read_vertex(source_arrays, _weights[surface_index], ic, has_normals, has_uv, has_uv2, has_colors, has_tangents, has_skin)
			]
			var clipped = _clip_polygon(polygon, keep_painted)
			if clipped.size() >= 3:
				for fan_index in range(1, clipped.size() - 1):
					_append_vertex(out_arrays, clipped[0], transform_to_output, has_normals, has_uv, has_uv2, has_colors, has_tangents)
					_append_vertex(out_arrays, clipped[fan_index], transform_to_output, has_normals, has_uv, has_uv2, has_colors, has_tangents)
					_append_vertex(out_arrays, clipped[fan_index + 1], transform_to_output, has_normals, has_uv, has_uv2, has_colors, has_tangents)

		if out_arrays[Mesh.ARRAY_VERTEX].size() > 0:
			result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arrays)
			if data["material"] != null:
				result.surface_set_material(result.get_surface_count() - 1, data["material"])
	return result


func _read_vertex(arrays, weights, index, has_normals, has_uv, has_uv2, has_colors, has_tangents, has_skin):
	var vertex = {
		"p": arrays[Mesh.ARRAY_VERTEX][index],
		"w": weights[index]
	}
	if has_normals:
		vertex["n"] = arrays[Mesh.ARRAY_NORMAL][index]
	if has_uv:
		vertex["uv"] = arrays[Mesh.ARRAY_TEX_UV][index]
	if has_uv2:
		vertex["uv2"] = arrays[Mesh.ARRAY_TEX_UV2][index]
	if has_colors:
		vertex["color"] = arrays[Mesh.ARRAY_COLOR][index]
	if has_tangents:
		var tangents = arrays[Mesh.ARRAY_TANGENT]
		vertex["tan"] = Vector3(tangents[index * 4], tangents[index * 4 + 1], tangents[index * 4 + 2])
		vertex["tan_sign"] = tangents[index * 4 + 3]
	if has_skin:
		var bones = arrays[Mesh.ARRAY_BONES]
		var skin_weights = arrays[Mesh.ARRAY_WEIGHTS]
		var stride = int(bones.size() / arrays[Mesh.ARRAY_VERTEX].size())
		var vertex_bones = []
		var vertex_skin_weights = []
		for k in range(stride):
			vertex_bones.append(bones[index * stride + k])
			vertex_skin_weights.append(skin_weights[index * stride + k])
		vertex["bones"] = vertex_bones
		vertex["skin_weights"] = vertex_skin_weights
	return vertex


func _clip_polygon(polygon, keep_painted):
	var output = []
	for i in range(polygon.size()):
		var a = polygon[i]
		var b = polygon[(i + 1) % polygon.size()]
		var a_inside = a["w"] >= PAINT_THRESHOLD if keep_painted else a["w"] < PAINT_THRESHOLD
		var b_inside = b["w"] >= PAINT_THRESHOLD if keep_painted else b["w"] < PAINT_THRESHOLD
		if a_inside and b_inside:
			output.append(b)
		elif a_inside and not b_inside:
			output.append(_interpolate_vertex(a, b, _threshold_lerp(a["w"], b["w"])))
		elif not a_inside and b_inside:
			output.append(_interpolate_vertex(a, b, _threshold_lerp(a["w"], b["w"])))
			output.append(b)
	return output


func _threshold_lerp(a_weight, b_weight):
	if is_equal_approx(a_weight, b_weight):
		return 0.5
	return clamp((PAINT_THRESHOLD - a_weight) / (b_weight - a_weight), 0.0, 1.0)


func _interpolate_vertex(a, b, t):
	var result = {
		"p": a["p"].linear_interpolate(b["p"], t),
		"w": lerp(a["w"], b["w"], t)
	}
	if a.has("n"):
		result["n"] = a["n"].linear_interpolate(b["n"], t).normalized()
	if a.has("uv"):
		result["uv"] = a["uv"].linear_interpolate(b["uv"], t)
	if a.has("uv2"):
		result["uv2"] = a["uv2"].linear_interpolate(b["uv2"], t)
	if a.has("color"):
		result["color"] = a["color"].linear_interpolate(b["color"], t)
	if a.has("tan"):
		result["tan"] = a["tan"].linear_interpolate(b["tan"], t).normalized()
		result["tan_sign"] = lerp(a["tan_sign"], b["tan_sign"], t)
	if a.has("bones"):
		# Bone indices can't be blended, so new cut vertices copy the nearer original vertex.
		var nearest = a if t < 0.5 else b
		result["bones"] = nearest["bones"]
		result["skin_weights"] = nearest["skin_weights"]
	return result


func _append_vertex(arrays, vertex, transform_to_output, has_normals, has_uv, has_uv2, has_colors, has_tangents):
	var output_transform = transform_to_output
	var position = vertex["p"]
	if output_transform != Transform():
		position = output_transform.xform(position)
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	vertices.append(position)
	arrays[Mesh.ARRAY_VERTEX] = vertices

	if has_normals:
		var normal = vertex["n"]
		if output_transform != Transform():
			normal = output_transform.basis.inverse().transposed().xform(normal).normalized()
		else:
			normal = normal.normalized()
		var normals = arrays[Mesh.ARRAY_NORMAL]
		normals.append(normal)
		arrays[Mesh.ARRAY_NORMAL] = normals
	if has_uv:
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		uvs.append(vertex["uv"])
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if has_uv2:
		var uvs2 = arrays[Mesh.ARRAY_TEX_UV2]
		uvs2.append(vertex["uv2"])
		arrays[Mesh.ARRAY_TEX_UV2] = uvs2
	if has_colors:
		var colors = arrays[Mesh.ARRAY_COLOR]
		colors.append(vertex["color"])
		arrays[Mesh.ARRAY_COLOR] = colors
	if has_tangents:
		var tangent = vertex["tan"]
		if output_transform != Transform():
			tangent = output_transform.basis.xform(tangent).normalized()
		var tangents = arrays[Mesh.ARRAY_TANGENT]
		tangents.append(tangent.x)
		tangents.append(tangent.y)
		tangents.append(tangent.z)
		tangents.append(vertex["tan_sign"])
		arrays[Mesh.ARRAY_TANGENT] = tangents
	if vertex.has("bones"):
		var out_bones = arrays[Mesh.ARRAY_BONES]
		for bone_value in vertex["bones"]:
			out_bones.append(bone_value)
		arrays[Mesh.ARRAY_BONES] = out_bones
		var out_skin_weights = arrays[Mesh.ARRAY_WEIGHTS]
		for weight_value in vertex["skin_weights"]:
			out_skin_weights.append(weight_value)
		arrays[Mesh.ARRAY_WEIGHTS] = out_skin_weights


func _cancel_paint():
	if _painting and is_instance_valid(_source):
		_source.mesh = _original_source_mesh
		_source.material_override = _original_source_override
	_finish_paint_state()


func _finish_paint_state():
	_restore_hidden_nodes()
	_painting = false
	_awaiting_target = false
	_source = null
	_original_source_mesh = null
	_original_source_override = null
	_source_surfaces.clear()
	_weights.clear()
	_world_vertices.clear()
	_merge_button.visible = true
	_cancel_button.visible = false
	_confirm_button.visible = false
	for child in _toolbar.get_children():
		if child is Label or child == _brush_size:
			child.visible = false
	update_overlays()
