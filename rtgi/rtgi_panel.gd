tool
extends VBoxContainer
# The "RTGI" section shown in the Environment inspector (next to SSAO).
# Built once and never freed/re-parented by us. Anything that changes the scene is delegated to
# the plugin via call_deferred, so it never runs inside this control's own signal handler
# (the inspector may rebuild and free this control while the scene changes).

const Util = preload("res://addons/rtgi/rtgi_util.gd")

var plugin
var env
var world_env
var chk
var extra
var hint
var quality_opt
var quality_info
var ssao_chk
var ssao_extra
var mb_chk
var mb_extra
var mb_quality_opt

func setup(p_plugin, p_env):
	plugin = p_plugin
	env = p_env

func _enter_tree():
	if get_child_count() == 0:
		_build()
	refresh()

func _build():
	var title = Label.new()
	title.text = "RTGI"
	add_child(title)

	hint = Label.new()
	hint.text = "Use this Environment on a WorldEnvironment node\n(not the scene root) to enable RTGI."
	add_child(hint)

	var row = HBoxContainer.new()
	var lab = Label.new()
	lab.text = "Enabled"
	lab.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(lab)
	chk = CheckBox.new()
	row.add_child(chk)
	add_child(row)
	chk.connect("toggled", self, "_on_enabled")

	extra = VBoxContainer.new()
	var qrow = HBoxContainer.new()
	var qlab = Label.new()
	qlab.text = "GI Quality"
	qlab.size_flags_horizontal = SIZE_EXPAND_FILL
	qrow.add_child(qlab)
	quality_opt = OptionButton.new()
	quality_opt.add_item("Low Quality", 0)
	quality_opt.add_item("High Quality", 1)
	quality_opt.add_item("Custom", 2)
	quality_opt.connect("item_selected", self, "_on_quality")
	qrow.add_child(quality_opt)
	extra.add_child(qrow)
	quality_info = Label.new()
	quality_info.autowrap = true
	extra.add_child(quality_info)
	var b1 = Button.new()
	b1.text = "Fit Probe Grid To Scene"
	b1.connect("pressed", self, "_on_fit")
	extra.add_child(b1)
	var b2 = Button.new()
	b2.text = "Select RTGI Node (all settings)"
	b2.connect("pressed", self, "_on_select")
	extra.add_child(b2)
	add_child(extra)

	# Godot 4 style SSAO (separate node, independent of RTGI)
	var st = Label.new()
	st.text = "Godot 4 SSAO"
	add_child(st)
	var srow = HBoxContainer.new()
	var slab = Label.new()
	slab.text = "Enabled"
	slab.size_flags_horizontal = SIZE_EXPAND_FILL
	srow.add_child(slab)
	ssao_chk = CheckBox.new()
	srow.add_child(ssao_chk)
	add_child(srow)
	ssao_chk.connect("toggled", self, "_on_ssao_enabled")

	ssao_extra = VBoxContainer.new()
	var sb = Button.new()
	sb.text = "Select SSAO Node (all settings)"
	sb.connect("pressed", self, "_on_select_ssao")
	ssao_extra.add_child(sb)
	add_child(ssao_extra)

	# Per-pixel motion blur (separate node, independent of RTGI / SSAO)
	var mt = Label.new()
	mt.text = "Per-pixel Motion Blur"
	add_child(mt)
	var mrow = HBoxContainer.new()
	var mlab = Label.new()
	mlab.text = "Enabled"
	mlab.size_flags_horizontal = SIZE_EXPAND_FILL
	mrow.add_child(mlab)
	mb_chk = CheckBox.new()
	mrow.add_child(mb_chk)
	add_child(mrow)
	mb_chk.connect("toggled", self, "_on_mb_enabled")

	mb_extra = VBoxContainer.new()
	var mqrow = HBoxContainer.new()
	var mqlab = Label.new()
	mqlab.text = "Quality"
	mqlab.size_flags_horizontal = SIZE_EXPAND_FILL
	mqrow.add_child(mqlab)
	mb_quality_opt = OptionButton.new()
	mb_quality_opt.add_item("Low", 0)
	mb_quality_opt.add_item("Medium", 1)
	mb_quality_opt.add_item("High", 2)
	mb_quality_opt.add_item("Custom", 3)
	mb_quality_opt.connect("item_selected", self, "_on_mb_quality")
	mqrow.add_child(mb_quality_opt)
	mb_extra.add_child(mqrow)
	var mb = Button.new()
	mb.text = "Select Motion Blur Node (all settings)"
	mb.connect("pressed", self, "_on_select_mb")
	mb_extra.add_child(mb)
	add_child(mb_extra)

# Re-read the scene and update the widgets (no nodes are created or freed here).
func refresh():
	var root = plugin.get_editor_interface().get_edited_scene_root()
	world_env = Util.find_world_env(root, env) if root else null
	var ok = world_env != null and world_env.get_parent() != null
	hint.visible = not ok
	chk.disabled = not ok
	var has = ok and Util.find_rtgi(world_env.get_parent()) != null
	if chk.pressed != has:
		chk.disconnect("toggled", self, "_on_enabled")
		chk.pressed = has
		chk.connect("toggled", self, "_on_enabled")
	extra.visible = has
	if has:
		var rn = Util.find_rtgi(world_env.get_parent())
		if rn and "quality_preset" in rn:
			quality_opt.disabled = false
			quality_opt.select(int(rn.quality_preset))
			quality_info.text = rn.get_quality_info()
		else:
			quality_opt.disabled = true
			quality_info.text = "Rebuild/replace the RTGI library to use quality presets."

	ssao_chk.disabled = not ok
	var has_ssao = ok and Util.find_ssao(world_env.get_parent()) != null
	if ssao_chk.pressed != has_ssao:
		ssao_chk.disconnect("toggled", self, "_on_ssao_enabled")
		ssao_chk.pressed = has_ssao
		ssao_chk.connect("toggled", self, "_on_ssao_enabled")
	ssao_extra.visible = has_ssao

	mb_chk.disabled = not ok
	var has_mb = ok and Util.find_motion_blur(world_env.get_parent()) != null
	if mb_chk.pressed != has_mb:
		mb_chk.disconnect("toggled", self, "_on_mb_enabled")
		mb_chk.pressed = has_mb
		mb_chk.connect("toggled", self, "_on_mb_enabled")
	mb_extra.visible = has_mb
	if has_mb:
		var mbn = Util.find_motion_blur(world_env.get_parent())
		if mbn != null and ("quality" in mbn):
			mb_quality_opt.select(mb_quality_opt.get_item_index(mbn.quality))

func _on_enabled(on):
	if world_env == null:
		return
	plugin.call_deferred("set_rtgi_enabled", world_env, on, self)

func _on_quality(idx):
	if world_env:
		plugin.call_deferred("set_rtgi_quality", world_env, idx, self)

func _on_fit():
	if world_env:
		plugin.call_deferred("fit_rtgi", world_env, self)

func _on_select():
	if world_env:
		var node = Util.find_rtgi(world_env.get_parent())
		if node:
			plugin.get_editor_interface().call_deferred("edit_node", node)

func _on_ssao_enabled(on):
	if world_env == null:
		return
	plugin.call_deferred("set_ssao_enabled", world_env, on, self)

func _on_select_ssao():
	if world_env:
		var node = Util.find_ssao(world_env.get_parent())
		if node:
			plugin.get_editor_interface().call_deferred("edit_node", node)

func _on_mb_enabled(on):
	if world_env == null:
		return
	plugin.call_deferred("set_motion_blur_enabled", world_env, on, self)

func _on_mb_quality(idx):
	if world_env and idx < 3:
		plugin.call_deferred("set_motion_blur_quality", world_env, mb_quality_opt.get_item_id(idx), self)

func _on_select_mb():
	if world_env:
		var node = Util.find_motion_blur(world_env.get_parent())
		if node:
			plugin.get_editor_interface().call_deferred("edit_node", node)
