tool
extends EditorPlugin
# Adds the "RTGI" option to Environment resources (the WorldEnvironment node), next to SSR / SSAO.
# All scene edits live here (the plugin outlives the inspector panels) and run deferred.

const Inspector = preload("res://addons/rtgi/rtgi_inspector.gd")
const Util = preload("res://addons/rtgi/rtgi_util.gd")

var _inspector

# Anti-aliasing: MSAA 4x + FXAA (project settings), enabled once if the project has neither.
func _enable_aa():
	var changed = false
	if int(ProjectSettings.get_setting("rendering/quality/filters/msaa")) == 0:
		ProjectSettings.set_setting("rendering/quality/filters/msaa", 2)
		changed = true
	if not bool(ProjectSettings.get_setting("rendering/quality/filters/use_fxaa")):
		ProjectSettings.set_setting("rendering/quality/filters/use_fxaa", true)
		changed = true
	if changed:
		ProjectSettings.save()

func _enter_tree():
	_enable_aa()
	_inspector = Inspector.new()
	_inspector.plugin = self
	add_inspector_plugin(_inspector)

func _exit_tree():
	if _inspector:
		remove_inspector_plugin(_inspector)
		_inspector = null

func _refresh(panel):
	if is_instance_valid(panel):
		panel.refresh()

# Create (on = true) or remove (on = false) the RTGI node next to `world_env`.
func set_rtgi_enabled(world_env, on, panel):
	if not is_instance_valid(world_env):
		return
	var parent = world_env.get_parent()
	var root = get_editor_interface().get_edited_scene_root()
	if parent == null or root == null:
		_refresh(panel)
		return
	var ur = get_undo_redo()
	var existing = Util.find_rtgi(parent)
	if on and existing == null:
		# Create the node and load rtgi.gdns as its script (the manual step, automated).
		var node = Spatial.new()
		node.name = Util.NODE_NAME
		node.set_script(load(Util.GDNS_PATH))
		# Configure it before it enters the tree so its first frame already sees the right grid.
		Util.apply_look(node)
		var fit = Util.compute_fit(parent, null)
		if not fit.empty():
			Util.apply_fit(node, fit, parent)
		ur.create_action("Enable RTGI")
		ur.add_do_method(parent, "add_child", node)
		ur.add_do_method(node, "set_owner", root)
		ur.add_do_reference(node)
		ur.add_undo_method(parent, "remove_child", node)
		ur.commit_action()
	elif not on and existing != null:
		ur.create_action("Disable RTGI")
		ur.add_do_method(parent, "remove_child", existing)
		ur.add_undo_method(parent, "add_child", existing)
		ur.add_undo_method(existing, "set_owner", root)
		ur.add_undo_reference(existing)
		ur.commit_action()
	_refresh(panel)

# Create (on = true) or remove (on = false) the Godot 4 style SSAO node next to `world_env`.
# Turning it on also switches off the Environment's built-in (Godot 3) SSAO so the two don't stack.
func set_ssao_enabled(world_env, on, panel):
	if not is_instance_valid(world_env):
		return
	var parent = world_env.get_parent()
	var root = get_editor_interface().get_edited_scene_root()
	if parent == null or root == null:
		_refresh(panel)
		return
	var ur = get_undo_redo()
	var existing = Util.find_ssao(parent)
	if on and existing == null:
		var node = Spatial.new()
		node.name = Util.SSAO_NODE_NAME
		node.set_script(load(Util.SSAO_SCRIPT_PATH))
		ur.create_action("Enable Godot 4 SSAO")
		ur.add_do_method(parent, "add_child", node)
		ur.add_do_method(node, "set_owner", root)
		ur.add_do_reference(node)
		ur.add_undo_method(parent, "remove_child", node)
		var env = world_env.environment
		if env and env.ssao_enabled:
			ur.add_do_property(env, "ssao_enabled", false)
			ur.add_undo_property(env, "ssao_enabled", true)
		ur.commit_action()
	elif not on and existing != null:
		ur.create_action("Disable Godot 4 SSAO")
		ur.add_do_method(parent, "remove_child", existing)
		ur.add_undo_method(parent, "add_child", existing)
		ur.add_undo_method(existing, "set_owner", root)
		ur.add_undo_reference(existing)
		ur.commit_action()
	_refresh(panel)

func fit_rtgi(world_env, panel):
	if not is_instance_valid(world_env):
		return
	var parent = world_env.get_parent()
	var node = Util.find_rtgi(parent)
	if node == null:
		return
	var fit = Util.compute_fit(parent, node)
	if fit.empty():
		return
	var ur = get_undo_redo()
	ur.create_action("Fit RTGI To Scene")
	ur.add_do_method(self, "apply_fit", node, fit, parent)
	ur.add_undo_method(self, "apply_fit", node, Util.current_fit(node, parent), parent)
	ur.commit_action()
	node.call("reset")
	_refresh(panel)

# GI quality preset (0 Low, 1 High, 2 Custom) on the RTGI node next to `world_env`.
func set_rtgi_quality(world_env, preset, panel):
	if not is_instance_valid(world_env):
		return
	var node = Util.find_rtgi(world_env.get_parent())
	if node == null or not ("quality_preset" in node):
		_refresh(panel)
		return
	var ur = get_undo_redo()
	ur.create_action("Set RTGI Quality")
	ur.add_do_property(node, "quality_preset", preset)
	ur.add_undo_property(node, "quality_preset", node.quality_preset)
	ur.commit_action()
	_refresh(panel)

# ---- keep RTGI's temporary editor materials out of saved scenes -------------------------------
# With "run_in_editor" the RTGI node swaps every SpatialMaterial for a runtime ShaderMaterial. If the scene is
# saved (or run, which saves first) in that state, the temporary materials get written to the .tscn and the file
# no longer parses ("Unexpected identifier: 'shader_param'"). The editor calls this right before saving, so we put
# the original materials back first and let RTGI re-apply its own right afterwards.
func save_external_data():
	var root = get_editor_interface().get_edited_scene_root()
	if root == null:
		return
	var touched = _restore_originals(root)
	if touched:
		call_deferred("_reapply_rtgi", root)

func _restore_originals(n):
	var touched = false
	if n is MeshInstance and n.mesh != null:
		for s in range(n.mesh.get_surface_count()):
			var key = "_rtgi_orig_" + str(s)
			if n.has_meta(key):
				var orig = n.get_meta(key)
				n.set_surface_material(s, orig if orig is Material else null)
				n.remove_meta(key)
				touched = true
	for c in n.get_children():
		if _restore_originals(c):
			touched = true
	return touched

func _reapply_rtgi(root):
	if not is_instance_valid(root):
		return
	var node = Util.find_rtgi(root)
	if node == null:
		node = _find_by_script(root)
	if node and node.has_method("rebuild"):
		node.call("rebuild")

func _find_by_script(n):
	if n.has_method("rebuild") and "run_in_editor" in n:
		return n
	for c in n.get_children():
		var r = _find_by_script(c)
		if r:
			return r
	return null

# Target of undo/redo actions.
func apply_fit(node, fit, parent):
	if is_instance_valid(node):
		Util.apply_fit(node, fit, parent)
