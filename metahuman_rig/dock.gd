tool
extends VBoxContainer

const RigLogic = preload("rig_logic.gd")
const Binder = preload("rig_binder.gd")
const FaceBoard = preload("face_board.gd")
const Shapes = preload("control_shapes.gd")
const Board3D = preload("face_board_3d.gd")
const BodyRig = preload("body_rig.gd")

var editor_interface: EditorInterface

var rig = RigLogic.new()
var binder = Binder.new()
var skeleton: Skeleton

var _status := Label.new()
var _tabs := TabContainer.new()
var _board := FaceBoard.new()
var _raw_box := VBoxContainer.new()
var _raw_rows := {}
var _raw_filter := LineEdit.new()
var _bone_tree := Tree.new()
var _bone_filter := LineEdit.new()
var _hide_driven := CheckBox.new()
var _bone_sliders := []
var _bone_edit := {}
var _selected_bone := -1
var _file_dialog: EditorFileDialog
var _dialog_mode := ""
var _updating_ui := false
var _loaded_path := ""
var _auto := CheckBox.new()
var board3d = null
var body_rig = null
var _body_status := Label.new()
var _body_box := VBoxContainer.new()
var _open_dialog: ConfirmationDialog
var _add_btn: Button
var _msg_dialog: AcceptDialog
var _pending_glb := ""
var _pending_json := ""
var _prefer_root: Node = null
var _opening := false
var _b3_show := CheckBox.new()
var _b3 := {"size": 4.0, "right": 0.0, "up": 0.0, "fwd": 0.0, "yaw": 0.0}
var undo_redo = null          # the editor's UndoRedo (set by the plugin): face pose edits are registered there, so Ctrl+Z / Ctrl+Y work
var _face_pending := false    # a face edit (drag, slider ...) is in progress and not yet in the undo history
var _face_before := {}        # face state from before that edit
var _face_idle := 0.0
var _face_restoring := false  # true while an undo / redo writes the face state back
var _face_skip_do := false
var _face_state_dirty := false  # the rig changed since its state was last copied into the scene (board3d.face_state)
var _face_center := Vector3.ZERO
var _face_size := 0.2


func _init() -> void:
	name = "MetaHuman Rig"
	rect_min_size = Vector2(320, 400)

	_status.autowrap = true
	_status.text = "Load a .rig.json exported with export_metahuman_rig.py"
	add_child(_status)

	var row := HBoxContainer.new()
	add_child(row)
	row.add_child(_button("Load rig…", "_on_load_pressed"))
	row.add_child(_button("Bind scene", "_on_bind_pressed"))
	row.add_child(_button("Reset face", "_on_reset_pressed"))
	add_child(_button("Open selected .glb with MetaHuman Rig…", "_open_selected_glb"))
	_auto.text = "Auto-load rig when a scene opens"
	_auto.pressed = true
	add_child(_auto)
	var row2 := HBoxContainer.new()
	add_child(row2)
	row2.add_child(_button("Save pose…", "_on_save_pose_pressed"))
	row2.add_child(_button("Load pose…", "_on_load_pose_pressed"))

	_tabs.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_tabs)

	_board.name = "Face board"
	_board.size_flags_vertical = SIZE_EXPAND_FILL
	_board.connect("gui_value_changed", self, "_on_gui_value_changed")
	_tabs.add_child(_board)

	var raw_page := VBoxContainer.new()
	raw_page.name = "Raw controls"
	_raw_filter.placeholder_text = "filter…"
	_raw_filter.connect("text_changed", self, "_on_raw_filter")
	raw_page.add_child(_raw_filter)
	var raw_scroll := ScrollContainer.new()
	raw_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_raw_box.size_flags_horizontal = SIZE_EXPAND_FILL
	raw_scroll.add_child(_raw_box)
	raw_page.add_child(raw_scroll)
	_tabs.add_child(raw_page)

	var b3_page := VBoxContainer.new()
	b3_page.name = "3D board"
	_b3_show.text = "Show face board in the 3D viewport"
	_b3_show.pressed = true
	_b3_show.connect("toggled", self, "_on_b3_show")
	b3_page.add_child(_b3_show)
	var hint := Label.new()
	hint.autowrap = true
	hint.text = "Keep the character (any node) selected so the 3D viewport sends your clicks to the board. Drag a pad to pose, double-click to reset. The board is a real node in your scene (MetaHumanFaceBoard3D): select it and use the normal move / rotate / scale gizmo, or parent it under the head. The sliders below re-place it next to the face."
	b3_page.add_child(hint)
	_add_b3_slider(b3_page, "size", "Size", 1.0, 14.0, 0.05)
	_add_b3_slider(b3_page, "right", "Right", -4.0, 4.0, 0.05)
	_add_b3_slider(b3_page, "up", "Up", -4.0, 4.0, 0.05)
	_add_b3_slider(b3_page, "fwd", "Forward", -4.0, 4.0, 0.05)
	_add_b3_slider(b3_page, "yaw", "Rotate", -180.0, 180.0, 1.0)
	b3_page.add_child(_button("Reset: place next to face", "_place_board3d"))
	b3_page.add_child(_button("Remove board from scene", "_remove_board3d"))
	_tabs.add_child(b3_page)

	var bone_page := VBoxContainer.new()
	bone_page.name = "Bones"
	_bone_filter.placeholder_text = "filter bones…"
	_bone_filter.connect("text_changed", self, "_on_bone_filter")
	bone_page.add_child(_bone_filter)
	_hide_driven.text = "Hide bones driven by the face rig"
	_hide_driven.pressed = true
	_hide_driven.connect("toggled", self, "_on_hide_driven")
	bone_page.add_child(_hide_driven)
	_bone_tree.size_flags_vertical = SIZE_EXPAND_FILL
	_bone_tree.hide_root = true
	_bone_tree.rect_min_size = Vector2(0, 160)
	_bone_tree.connect("item_selected", self, "_on_bone_selected")
	bone_page.add_child(_bone_tree)
	var labels := ["Rot X", "Rot Y", "Rot Z", "Move X", "Move Y", "Move Z"]
	for k in range(6):
		var h := HBoxContainer.new()
		var l := Label.new()
		l.text = labels[k]
		l.rect_min_size = Vector2(52, 0)
		h.add_child(l)
		var s := HSlider.new()
		s.size_flags_horizontal = SIZE_EXPAND_FILL
		if k < 3:
			s.min_value = -180
			s.max_value = 180
			s.step = 0.1
		else:
			s.min_value = -0.5
			s.max_value = 0.5
			s.step = 0.001
		s.connect("value_changed", self, "_on_bone_slider", [k])
		h.add_child(s)
		bone_page.add_child(h)
		_bone_sliders.append(s)
	bone_page.add_child(_button("Reset selected bone", "_on_bone_reset"))
	_tabs.add_child(bone_page)

	var body_page := VBoxContainer.new()
	body_page.name = "Body"
	_body_status.autowrap = true
	_body_status.text = "No body rig yet. Export from Blender with 'Body control rig (FK/IK)' ticked, then drag the .glb into the scene."
	body_page.add_child(_body_status)
	var body_row := HBoxContainer.new()
	body_row.add_child(_button("Load body.json…", "_on_load_body_pressed"))
	body_row.add_child(_button("Reset pose", "_on_body_reset"))
	body_page.add_child(body_row)
	var body_row2 := HBoxContainer.new()
	body_row2.add_child(_button("Select rig node", "_on_body_select_node"))
	body_row2.add_child(_button("Reset IK + torso handles", "_on_body_reset_handles"))
	body_page.add_child(body_row2)
	var body_hint := Label.new()
	body_hint.autowrap = true
	body_hint.text = "IK: select a hand / foot / pole handle (children of MetaHumanBodyRig) and use the normal move / rotate / scale gizmo (scaling a hand / foot handle scales that bone). 0 = FK, 1 = IK. FK: select MetaHumanBodyRig and edit fk/<joint> in the Inspector (degrees). Both can be keyed in an AnimationPlayer or the Cinematic tab."
	body_page.add_child(body_hint)
	var body_scroll := ScrollContainer.new()
	body_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_body_box.size_flags_horizontal = SIZE_EXPAND_FILL
	body_scroll.add_child(_body_box)
	body_page.add_child(body_scroll)
	_tabs.add_child(body_page)

	binder_connect()


func binder_connect() -> void:
	rig.connect("outputs_changed", self, "_on_outputs_changed")


# ---------------------------------------------------------------- face undo / redo
# Every finished face edit (a drag on the 2D or the 3D board, a raw slider, Reset face, Load pose) becomes ONE entry in the
# editor's undo history, next to the scene edits: Ctrl+Z / Ctrl+Y (and Edit > Undo / Redo) step through them in order.
# A drag is finished when the mouse button is up and the controls have been still for a moment.

func _face_state() -> Dictionary:
	return {"gui": Array(rig.gui_values), "raw": Array(rig.raw_override)}


func _same_face_state(a: Dictionary, b: Dictionary) -> bool:
	if a.empty() or b.empty():
		return true
	for k in ["gui", "raw"]:
		var x: Array = a[k]
		var y: Array = b[k]
		if x.size() != y.size():
			return false
		for i in range(x.size()):
			if abs(float(x[i]) - float(y[i])) > 1e-6:
				return false
	return true


# Called BEFORE a change is written to the rig: remembers the state the whole edit started from.
func _begin_face_edit() -> void:
	if _face_restoring or not rig.loaded:
		return
	if not _face_pending:
		_face_pending = true
		_face_before = _face_state()
	_face_idle = 0.0


func _process(delta: float) -> void:
	if _face_state_dirty and not _face_pending and not Input.is_mouse_button_pressed(BUTTON_LEFT):
		commit_face_state()
	if not _face_pending:
		return
	if Input.is_mouse_button_pressed(BUTTON_LEFT):
		_face_idle = 0.0
		return
	_face_idle += delta
	if _face_idle > 0.2:
		flush_face_edit()


# Puts a finished edit into the undo history right now (the plugin calls this before the editor handles Ctrl+Z).
func flush_face_edit(action_name := "Face pose") -> void:
	if not _face_pending:
		return
	_face_pending = false
	var before := _face_before
	_face_before = {}
	if not rig.loaded:
		return
	var after := _face_state()
	if undo_redo == null or _same_face_state(before, after):
		return
	_face_skip_do = true          # the edit is already on the rig: committing must not apply it a second time
	undo_redo.create_action(action_name)
	undo_redo.add_do_method(self, "_restore_face_state", after)
	undo_redo.add_undo_method(self, "_restore_face_state", before)
	undo_redo.commit_action()
	_face_skip_do = false


# Undo / redo: writes a whole face state back (only the controls that differ) and refreshes both boards.
func _restore_face_state(state: Dictionary) -> void:
	if _face_skip_do or not rig.loaded or state.empty():
		return
	var g: Array = state["gui"]
	var r: Array = state["raw"]
	if g.size() != rig.gui_values.size() or r.size() != rig.raw_count:
		return
	_face_restoring = true
	_face_pending = false
	for i in range(g.size()):
		if abs(rig.gui_values[i] - float(g[i])) > 1e-7:
			rig.set_gui_value(i, float(g[i]))
	for i in range(r.size()):
		if abs(rig.raw_override[i] - float(r[i])) > 1e-7:
			rig.set_raw_override(i, float(r[i]))
		if _raw_rows.has(i) and abs(_raw_rows[i].value - float(r[i])) > 1e-7:
			_raw_rows[i].value = float(r[i])
	_board.sync_from(rig)
	if board3d != null and is_instance_valid(board3d):
		board3d.sync_from(rig)
	_face_restoring = false
	_mark_dirty()


# ---------------------------------------------------------------- face pose kept with the scene
# The RigLogic state lives in this dock, not in the scene, so it used to be lost whenever the scene was closed or another
# scene was opened (the bones / blend shapes kept their saved values, but the rig started again from zero and the next
# edit overwrote them). The pose is now copied into MetaHumanFaceBoard3D.face_state, which is saved with the scene, and
# loaded back into the rig whenever the rig is bound to a scene.

func commit_face_state() -> void:
	if not _face_state_dirty:          # nothing was edited since the scene's copy was made (also protects it from a freshly reset rig)
		return
	_face_state_dirty = false
	if not rig.loaded or board3d == null or not is_instance_valid(board3d):
		return
	if skeleton == null or not is_instance_valid(skeleton):
		return
	var gui := {}
	for i in range(rig.gui_names.size()):
		if abs(rig.gui_values[i]) > 1e-6:
			gui[rig.gui_names[i]] = rig.gui_values[i]
	var raw := {}
	for i in range(rig.raw_count):
		if abs(rig.raw_override[i]) > 1e-6:
			raw[rig.raw_names[i]] = rig.raw_override[i]
	var st := {"gui": gui, "raw": raw}
	if st.hash() != board3d.face_state.hash():
		board3d.face_state = st          # the scene was already marked as changed by the edit itself


# Called right after the rig was bound (and reset): puts the pose saved in the scene back into the rig.
func _restore_face_from_scene() -> void:
	if not rig.loaded:
		return
	_face_restoring = true
	if board3d != null and is_instance_valid(board3d):
		var st: Dictionary = board3d.face_state
		var gui: Dictionary = st.get("gui", {})
		for n in gui:
			var i: int = rig.gui_index(n)
			if i >= 0:
				rig.set_gui_value(i, float(gui[n]))
		var raw: Dictionary = st.get("raw", {})
		for n in raw:
			var k: int = rig.raw_names.find(n)
			if k >= 0:
				rig.set_raw_override(k, float(raw[n]))
	for k in _raw_rows:                      # the sliders may still show the previous scene's values
		if abs(_raw_rows[k].value - rig.raw_override[k]) > 1e-7:
			_raw_rows[k].value = rig.raw_override[k]
	_face_restoring = false
	_face_pending = false
	_board.sync_from(rig)
	if board3d != null and is_instance_valid(board3d):
		board3d.sync_from(rig)
	_face_state_dirty = false


func _add_b3_slider(page: Node, key: String, label: String, lo: float, hi: float, step: float) -> void:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.rect_min_size = Vector2(52, 0)
	h.add_child(l)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.value = _b3[key]
	sl.size_flags_horizontal = SIZE_EXPAND_FILL
	sl.connect("value_changed", self, "_on_b3_slider", [key])
	h.add_child(sl)
	page.add_child(h)


func _button(text: String, method: String) -> Button:
	var b := Button.new()
	b.text = text
	b.connect("pressed", self, method)
	return b


func _enter_tree() -> void:
	set_process(true)
	if editor_interface and not _file_dialog:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.connect("file_selected", self, "_on_file_selected")
		editor_interface.get_base_control().add_child(_file_dialog)
	call_deferred("auto_setup")


func _exit_tree() -> void:
	_free_board3d()
	for d in [_open_dialog, _msg_dialog]:
		if d != null and is_instance_valid(d):
			d.queue_free()
	_open_dialog = null
	_msg_dialog = null
	if _file_dialog:
		_file_dialog.queue_free()
		_file_dialog = null


# ---------------------------------------------------------------- loading

func _on_load_pressed() -> void:
	_dialog_mode = "load_rig"
	_file_dialog.mode = EditorFileDialog.MODE_OPEN_FILE
	_file_dialog.clear_filters()
	_file_dialog.add_filter("*.rig.json ; MetaHuman rig data")
	_file_dialog.popup_centered_ratio(0.6)


func _on_file_selected(path: String) -> void:
	match _dialog_mode:
		"load_rig":
			_load_rig(path)
		"save_pose":
			_save_pose(path)
		"load_pose":
			_load_pose(path)
		"load_body":
			_setup_body_from(path)


func _load_rig(path: String) -> void:
	_status.text = "Loading rig data…"
	if not rig.load_files(path):
		_status.text = "Error: " + rig.error
		return
	_loaded_path = path
	_board.base_font = _editor_font()
	_board.build(rig)
	_build_raw_rows()
	_status.text = "Rig loaded: %d GUI controls, %d raw, %d joints. Press 'Bind scene'." % [
		rig.gui_names.size(), rig.raw_count, rig.joint_names.size()]
	_on_bind_pressed()
	var art: Dictionary = rig.art if typeof(rig.art) == TYPE_DICTIONARY else {}
	if art.get("segs", []).size() >= 4 and not art.has("dots"):
		_status.text += "\nThis .rig.json has no dot sizes (exported with an older add-on), so every dot is drawn the same size. Re-export from Blender with the updated add-on (restart Blender after installing it)."
	elif art.has("dots") and art["dots"].size() == 0:
		_status.text += "\nThe export found no dot sizes in the Blender face board; see Blender's system console for details."


func _on_bind_pressed() -> void:
	if not rig.loaded or not editor_interface:
		return
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		_status.text = "Open a scene containing your MetaHuman first."
		return
	var best: Skeleton = null
	var best_count := 0
	var sel := editor_interface.get_selection().get_selected_nodes()
	var candidates := []
	var cand_info := []
	_collect_skeletons(root, candidates)
	for s in candidates:
		if _prefer_root != null and is_instance_valid(_prefer_root) and not _prefer_root.is_a_parent_of(s):
			continue
		var c := 0
		for j in rig.joint_names:
			if s.find_bone(j) >= 0:
				c += 1
		cand_info.append("%s: %d/%d joints" % [s.name, c, rig.joint_names.size()])
		if s in sel:
			c += 1
		if c > best_count:
			best_count = c
			best = s
	if best == null:
		_status.text = "No Skeleton in this scene matches the rig's joint names."
		return
	# NOTE: the skeleton that was bound before is left alone. It usually belongs to the scene that was just left (the editor
	# keeps it alive), and resetting its bones is what made the model "jump back" when switching scenes.
	if skeleton and is_instance_valid(skeleton):
		commit_face_state()              # copy the pose into its scene before the rig is reset and rebound (also for 'Bind scene' on the same scene)
	skeleton = best
	_make_editable(skeleton, root)
	binder.bind(rig, skeleton, root)
	rig.reset_state()
	_face_pending = false
	_board.sync_from(rig)
	_build_bone_tree()
	_status.text = binder.status_text()
	if binder.matched_channels == 0:
		_status.text += "\nNo blend shape names matched; only joints will move."
	if binder.matched_joints < rig.joint_names.size() / 2:
		_status.text += "\nOnly %d of %d rig joints exist in the GLB: the face armature was probably not exported. Re-export from Blender and read its export message." % [binder.matched_joints, rig.joint_names.size()]
	if cand_info.size() > 1:
		_status.text += "\nSkeletons in scene: " + PoolStringArray(cand_info).join(" | ")
	_ensure_board3d(root)
	_ensure_body_rig(root)           # before the pose is restored: it tells the face rig which joints the body owns
	_restore_face_from_scene()


func _collect_skeletons(n: Node, out: Array) -> void:
	if n is Skeleton:
		out.append(n)
	for c in n.get_children():
		_collect_skeletons(c, out)


# ---------------------------------------------------------------- face

func _on_gui_value_changed(index: int, value: float) -> void:
	if not rig.loaded:
		return
	_begin_face_edit()
	rig.set_gui_value(index, value)
	if board3d != null and is_instance_valid(board3d):
		board3d.sync_from(rig)


func _on_gui_value_changed_3d(index: int, value: float) -> void:
	if not rig.loaded:
		return
	_begin_face_edit()
	rig.set_gui_value(index, value)
	_board.sync_from(rig)


func _on_outputs_changed(joints: Array, channels: Array) -> void:
	if skeleton and is_instance_valid(skeleton):
		binder.apply(joints, channels)
		_face_state_dirty = true
		if _face_restoring:                # loading the saved pose into the rig is not an edit
			return
		if editor_interface and editor_interface.has_method("mark_scene_as_unsaved"):
			editor_interface.mark_scene_as_unsaved()


func _on_reset_pressed() -> void:
	if not rig.loaded:
		return
	_begin_face_edit()
	rig.reset_all()
	_board.sync_from(rig)
	if board3d != null and is_instance_valid(board3d):
		board3d.sync_from(rig)
	_face_restoring = true          # the raw sliders below must not start another edit
	for k in _raw_rows:
		_raw_rows[k].value = 0
	_face_restoring = false
	flush_face_edit("Reset face")


func _save_pose(path: String) -> void:
	var d := {"gui": {}, "raw": {}}
	for i in range(rig.gui_names.size()):
		if abs(rig.gui_values[i]) > 1e-5:
			d["gui"][rig.gui_names[i]] = rig.gui_values[i]
	for i in range(rig.raw_count):
		if rig.raw_override[i] > 1e-5:
			d["raw"][rig.raw_names[i]] = rig.raw_override[i]
	var f := File.new()
	if f.open(path, File.WRITE) == OK:
		f.store_string(JSON.print(d, "  "))
		f.close()


func _load_pose(path: String) -> void:
	var f := File.new()
	if not rig.loaded or f.open(path, File.READ) != OK:
		return
	var parsed = JSON.parse(f.get_as_text())
	f.close()
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return
	_begin_face_edit()
	rig.reset_all()
	for n in parsed.result.get("gui", {}):
		var i: int = rig.gui_index(n)
		if i >= 0:
			rig.set_gui_value(i, parsed.result["gui"][n])
	for n in parsed.result.get("raw", {}):
		var i: int = rig.raw_names.find(n)
		if i >= 0:
			rig.set_raw_override(i, parsed.result["raw"][n])
			if _raw_rows.has(i):
				_raw_rows[i].value = parsed.result["raw"][n]
	_board.sync_from(rig)
	if board3d != null and is_instance_valid(board3d):
		board3d.sync_from(rig)
	flush_face_edit("Load face pose")


func _on_save_pose_pressed() -> void:
	_dialog_mode = "save_pose"
	_file_dialog.mode = EditorFileDialog.MODE_SAVE_FILE
	_file_dialog.clear_filters()
	_file_dialog.add_filter("*.json ; Face pose")
	_file_dialog.popup_centered_ratio(0.6)


func _on_load_pose_pressed() -> void:
	_dialog_mode = "load_pose"
	_file_dialog.mode = EditorFileDialog.MODE_OPEN_FILE
	_file_dialog.clear_filters()
	_file_dialog.add_filter("*.json ; Face pose")
	_file_dialog.popup_centered_ratio(0.6)


# ---------------------------------------------------------------- raw controls

func _build_raw_rows() -> void:
	for c in _raw_box.get_children():
		c.queue_free()
	_raw_rows.clear()
	for i in range(rig.raw_count):
		var h := HBoxContainer.new()
		h.name = "r%d" % i
		var l := Label.new()
		l.text = rig.raw_names[i].replace("CTRL_expressions.", "")
		l.rect_min_size = Vector2(130, 0)
		l.clip_text = true
		h.add_child(l)
		var s := HSlider.new()
		s.min_value = 0
		s.max_value = 1
		s.step = 0.01
		s.size_flags_horizontal = SIZE_EXPAND_FILL
		s.connect("value_changed", self, "_on_raw_slider", [i])
		h.add_child(s)
		_raw_box.add_child(h)
		_raw_rows[i] = s


func _on_raw_slider(v: float, i: int) -> void:
	if rig.loaded:
		_begin_face_edit()
		rig.set_raw_override(i, v)


func _on_raw_filter(text: String) -> void:
	var t := text.to_lower()
	for i in range(rig.raw_count):
		var row: Node = _raw_box.get_child(i)
		row.visible = t == "" or rig.raw_names[i].to_lower().find(t) >= 0


# ---------------------------------------------------------------- bones

func _on_hide_driven(_p) -> void:
	_build_bone_tree()


func _on_bone_filter(_t) -> void:
	_build_bone_tree()


func _build_bone_tree() -> void:
	_bone_tree.clear()
	_selected_bone = -1
	if not skeleton or not is_instance_valid(skeleton):
		return
	var root := _bone_tree.create_item()
	var items := {}
	var filter := _bone_filter.text.to_lower()
	var driven := {}
	if _hide_driven.pressed:
		for j in range(rig.joint_names.size()):
			if rig.joint_driven[j] == 1:
				driven[rig.joint_names[j]] = true
	for b in range(skeleton.get_bone_count()):
		var n := skeleton.get_bone_name(b)
		if driven.has(n) or n.begins_with("CTRL_"):
			continue
		if filter != "" and n.to_lower().find(filter) < 0:
			continue
		var parent_item: TreeItem = root
		var p := skeleton.get_bone_parent(b)
		while p >= 0:
			if items.has(p):
				parent_item = items[p]
				break
			p = skeleton.get_bone_parent(p)
		var it := _bone_tree.create_item(parent_item)
		it.set_text(0, n)
		it.set_metadata(0, b)
		items[b] = it


func _on_bone_selected() -> void:
	var it := _bone_tree.get_selected()
	if not it:
		return
	_selected_bone = it.get_metadata(0)
	var v: Array = _bone_edit.get(_selected_bone, [0, 0, 0, 0, 0, 0])
	_updating_ui = true
	for k in range(6):
		_bone_sliders[k].value = v[k]
	_updating_ui = false


func _on_bone_slider(_value: float, _k: int) -> void:
	if _updating_ui or _selected_bone < 0 or not skeleton:
		return
	var v := []
	for k in range(6):
		v.append(_bone_sliders[k].value)
	_bone_edit[_selected_bone] = v
	var r := Vector3(deg2rad(v[0]), deg2rad(v[1]), deg2rad(v[2]))
	skeleton.set_bone_pose(_selected_bone, Transform(Binder.euler_xyz(r), Vector3(v[3], v[4], v[5])))
	if editor_interface and editor_interface.has_method("mark_scene_as_unsaved"):
		editor_interface.mark_scene_as_unsaved()


func _on_bone_reset() -> void:
	if _selected_bone < 0:
		return
	_bone_edit.erase(_selected_bone)
	for k in range(6):
		_bone_sliders[k].value = 0
	skeleton.set_bone_pose(_selected_bone, Transform())


# ---------------------------------------------------------------- automation

func on_scene_changed(root) -> void:
	# First of all: the rig and board3d still belong to the scene that was just left, so its pose goes into that scene now.
	flush_face_edit()
	commit_face_state()
	if root == null:                       # the last scene was closed
		board3d = null
		if body_rig != null:
			body_rig = null
			_build_body_tab()
		return
	if board3d != null and (not is_instance_valid(board3d) or board3d.get_parent() != root):
		board3d = null
	if body_rig != null and (not is_instance_valid(body_rig) or not body_rig.is_inside_tree() or not root.is_a_parent_of(body_rig)):
		body_rig = null
		_build_body_tab()
	if _auto.pressed and not _opening:
		call_deferred("auto_setup")


func auto_setup() -> void:
	if not editor_interface:
		return
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	var skels := []
	_collect_skeletons(root, skels)
	if skels.empty():
		_status.text = "No Skeleton in the open scene. Drag the exported .glb into the scene (the GLB must contain the face armature)."
		return
	_ensure_body_rig(root)
	# already bound to a skeleton of this scene?
	if rig.loaded and skeleton and is_instance_valid(skeleton) and skeleton in skels:
		return
	var path := find_rig_for(root, skels)
	if path == "":
		_status.text = "No matching .rig.json found (looked next to the GLB and in the project). Use 'Load rig…'."
		return
	if rig.loaded and path == _loaded_path:
		_on_bind_pressed()
	else:
		_load_rig(path)


# Looks for <glb name>.rig.json next to the instanced GLB, then scans the project.
func find_rig_for(root: Node, skels: Array) -> String:
	for s in skels:
		var n: Node = s
		while n != null:
			var fn: String = n.filename
			if fn != "":
				var guess := fn.get_basename() + ".rig.json"
				if File.new().file_exists(guess):
					return guess
			n = n.get_parent()
	var best := ""
	var best_count := 0
	for path in scan_rig_files("res://"):
		var f := File.new()
		if f.open(path, File.READ) != OK:
			continue
		var parsed = JSON.parse(f.get_as_text())
		f.close()
		if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
			continue
		var names: Array = parsed.result.get("joint_names", [])
		for s in skels:
			var c := 0
			for j in names:
				if s.find_bone(j) >= 0:
					c += 1
			if c > best_count:
				best_count = c
				best = path
	return best if best_count >= 10 else ""


func scan_rig_files(dir_path: String) -> Array:
	var out := []
	var d := Directory.new()
	if d.open(dir_path) != OK:
		return out
	d.list_dir_begin(true, true)
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			if n != "addons" and not n.begins_with("."):
				out += scan_rig_files(dir_path.plus_file(n))
		elif n.ends_with(".rig.json"):
			out.append(dir_path.plus_file(n))
		n = d.get_next()
	d.list_dir_end()
	return out


# Imported GLB scenes are read-only unless "Editable Children" is on; poses would not be saved.
func _make_editable(skel: Node, root: Node) -> void:
	var n: Node = skel
	while n != null and n != root:
		if n.filename != "" and n.get_parent() != null:
			root.set_editable_instance(n, true)
		n = n.get_parent()


# ---------------------------------------------------------------- body control rig (FK + IK)

func _find_script_node(n: Node, script: Script):
	if n.get_script() == script:
		return n
	for c in n.get_children():
		var f = _find_script_node(c, script)
		if f != null:
			return f
	return null


# <glb>.body.json next to the instanced GLB, or next to the loaded <name>.rig.json.
func _find_body_json(skels: Array) -> String:
	var guesses := []
	for s in skels:
		var n: Node = s
		while n != null:
			var fn: String = n.filename
			if fn != "":
				guesses.append(fn.get_basename() + ".body.json")
			n = n.get_parent()
	if _loaded_path != "":
		var b := _loaded_path.get_basename()
		if b.ends_with(".rig"):
			b = b.substr(0, b.length() - 4)
		guesses.append(b + ".body.json")
	var f := File.new()
	for g in guesses:
		if f.file_exists(g):
			return g
	return ""


func _ensure_body_rig(root: Node) -> void:
	if body_rig != null and is_instance_valid(body_rig) and body_rig.is_inside_tree():
		return
	body_rig = _find_script_node(root, BodyRig)
	if body_rig == null:
		var skels := []
		_collect_skeletons(root, skels)
		var path := _find_body_json(skels)
		if path == "":
			_body_status.text = "No <name>.body.json next to the GLB. Re-export from Blender with 'Body control rig (FK/IK)' ticked, or use 'Load body.json…'."
			return
		_create_body_rig(root, path)
	if body_rig == null:
		return
	if body_rig.skeleton == null or not is_instance_valid(body_rig.skeleton):
		body_rig.setup()
	if body_rig.skeleton != null and body_rig.handles_missing():
		body_rig.ensure_handles(root)
		_mark_dirty()
	_build_body_tab()


func _create_body_rig(root: Node, path: String) -> void:
	var node = BodyRig.new()
	node.name = "MetaHumanBodyRig"
	node.body_path = path
	var skel = node.find_skeleton_in(root)
	if skel == null:
		_body_status.text = "Body rig file found (%s) but no Skeleton in this scene has the body joints. The GLB must contain the body armature." % path.get_file()
		node.free()
		return
	_make_editable(skel, root)
	var parent: Node = skel.get_parent() if skel.get_parent() != null else root
	parent.add_child(node)       # next to the skeleton, so the IK handles move with the character
	node.owner = root
	node.skeleton_path = node.get_path_to(skel)
	body_rig = node
	body_rig.setup()
	body_rig.ensure_handles(root)
	_mark_dirty()


func _setup_body_from(path: String) -> void:
	var root := editor_interface.get_edited_scene_root() if editor_interface else null
	if root == null:
		_body_status.text = "Open a scene containing your MetaHuman first."
		return
	var existing = _find_script_node(root, BodyRig)
	if existing != null:
		existing.body_path = path
		existing.spec = {}
		body_rig = existing
		body_rig.setup()
		body_rig.ensure_handles(root)
		_mark_dirty()
	else:
		_create_body_rig(root, path)
	_build_body_tab()


func _on_load_body_pressed() -> void:
	_dialog_mode = "load_body"
	_file_dialog.mode = EditorFileDialog.MODE_OPEN_FILE
	_file_dialog.clear_filters()
	_file_dialog.add_filter("*.body.json ; MetaHuman body rig data")
	_file_dialog.popup_centered_ratio(0.6)


func _build_body_tab() -> void:
	for c in _body_box.get_children():
		_body_box.remove_child(c)
		c.queue_free()
	if body_rig == null or not is_instance_valid(body_rig):
		return
	_body_status.text = body_rig.status_text()
	var lt := Label.new()
	lt.text = "Layers (tick = visible)"
	_body_box.add_child(lt)
	var allrow := HBoxContainer.new()
	allrow.add_child(_body_button("Show all", "_on_body_layers_all", [true], "Show every control"))
	allrow.add_child(_body_button("Hide all", "_on_body_layers_all", [false], "Hide every control (they keep working)"))
	_body_box.add_child(allrow)
	_layer_checks.clear()
	for layer in body_rig.layer_names():
		var cb := CheckBox.new()
		cb.text = "%s  (%d)" % [layer, body_rig.layer_count(layer)]
		cb.pressed = body_rig.is_layer_visible(layer)
		var c: Color = Shapes.layer_color(layer, "l")
		cb.add_color_override("font_color", c)
		cb.add_color_override("font_color_hover", c)
		cb.add_color_override("font_color_pressed", c)
		cb.connect("toggled", self, "_on_body_layer_toggled", [layer])
		_layer_checks[layer] = cb
		_body_box.add_child(cb)
	var ncb := CheckBox.new()
	ncb.text = "Show names in 3D viewport"
	ncb.hint_tooltip = "Writes the name of every visible control next to it (keep any node selected so the viewport redraws)"
	ncb.pressed = body_rig.show_names
	ncb.connect("toggled", self, "_on_body_show_names")
	_body_box.add_child(ncb)
	var lcb := CheckBox.new()
	lcb.text = "Link head skeleton to body"
	lcb.hint_tooltip = "A separate head / face skeleton follows the body skeleton (neck and head joints are matched by name)"
	lcb.pressed = body_rig.link_head_skeleton
	lcb.connect("toggled", self, "_on_body_link_head")
	_body_box.add_child(lcb)
	var wrow := HBoxContainer.new()
	var wl := Label.new()
	wl.text = "Line width"
	wrow.add_child(wl)
	var ws := HSlider.new()
	ws.min_value = 0.002
	ws.max_value = 0.03
	ws.step = 0.001
	ws.value = body_rig.line_width
	ws.size_flags_horizontal = SIZE_EXPAND_FILL
	ws.connect("value_changed", self, "_on_body_line_width")
	wrow.add_child(ws)
	_body_box.add_child(wrow)
	for key in body_rig.limb_keys():
		var title := Label.new()
		title.text = key.replace("_", " ")
		_body_box.add_child(title)
		var row := HBoxContainer.new()
		var s := HSlider.new()
		s.min_value = 0.0
		s.max_value = 1.0
		s.step = 0.01
		s.value = body_rig.get_ik_weight(key)
		s.size_flags_horizontal = SIZE_EXPAND_FILL
		s.hint_tooltip = "0 = FK, 1 = IK"
		s.connect("value_changed", self, "_on_body_ik_slider", [key])
		row.add_child(s)
		_body_box.add_child(row)
		var row2 := HBoxContainer.new()
		row2.add_child(_body_button("Select IK", "_on_body_select_handle", [key, true], "Select the hand / foot IK handle"))
		row2.add_child(_body_button("Select pole", "_on_body_select_handle", [key, false], "Select the elbow / knee pole handle"))
		_body_box.add_child(row2)
		var row3 := HBoxContainer.new()
		row3.add_child(_body_button("IK ← FK", "_on_body_snap", [key, true], "Move the IK handle and pole to where the FK pose has the hand / foot"))
		row3.add_child(_body_button("FK ← IK", "_on_body_snap", [key, false], "Copy the current IK pose into the FK controls of this limb"))
		_body_box.add_child(row3)


var _layer_checks := {}


func _on_body_layers_all(on: bool) -> void:
	if body_rig == null or not is_instance_valid(body_rig):
		return
	body_rig.set_all_layers_visible(on)
	for l in _layer_checks:
		if is_instance_valid(_layer_checks[l]):
			_layer_checks[l].set_pressed_no_signal(on)
	_mark_dirty()


func _on_body_layer_toggled(on: bool, layer: String) -> void:
	if body_rig == null or not is_instance_valid(body_rig):
		return
	body_rig.set_layer_visible(layer, on)
	_mark_dirty()


func _on_body_show_names(v: bool) -> void:
	if body_rig != null and is_instance_valid(body_rig):
		body_rig.show_names = v
		_mark_dirty()


func _on_body_link_head(v: bool) -> void:
	if body_rig != null and is_instance_valid(body_rig):
		body_rig.link_head_skeleton = v
		_body_status.text = body_rig.status_text()
		_mark_dirty()


func _on_body_line_width(v: float) -> void:
	if body_rig == null or not is_instance_valid(body_rig):
		return
	body_rig.line_width = v
	_mark_dirty()


func _body_button(text: String, method: String, binds: Array, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.hint_tooltip = tip
	b.connect("pressed", self, method, binds)
	return b


func _on_body_ik_slider(v: float, key: String) -> void:
	if body_rig == null or not is_instance_valid(body_rig):
		return
	body_rig.set_ik_weight(key, v)
	_mark_dirty()


func _on_body_snap(key: String, ik_to_fk: bool) -> void:
	if body_rig == null or not is_instance_valid(body_rig):
		return
	if ik_to_fk:
		body_rig.snap_ik_to_fk(key)
	else:
		body_rig.snap_fk_to_ik(key)
	_mark_dirty()


func _on_body_select_handle(key: String, ik: bool) -> void:
	if body_rig == null or not is_instance_valid(body_rig) or editor_interface == null:
		return
	for l in body_rig.limbs:
		if l["key"] == key:
			var n = body_rig.get_node_or_null(l["target"] if ik else l["pole"])
			if n != null:
				var sel := editor_interface.get_selection()
				sel.clear()
				sel.add_node(n)


func _on_body_select_node() -> void:
	if body_rig != null and is_instance_valid(body_rig) and editor_interface:
		var sel := editor_interface.get_selection()
		sel.clear()
		sel.add_node(body_rig)


func _on_body_reset() -> void:
	if body_rig != null and is_instance_valid(body_rig):
		body_rig.reset_pose()
		_build_body_tab()
		_mark_dirty()


func _on_body_reset_handles() -> void:
	if body_rig != null and is_instance_valid(body_rig):
		var root := editor_interface.get_edited_scene_root() if editor_interface else null
		body_rig.ensure_handles(root)
		body_rig.reset_handles()
		_mark_dirty()


# ---------------------------------------------------------------- 3D face board

func forward_3d_input(camera: Camera, event: InputEvent) -> bool:
	if board3d != null and is_instance_valid(board3d) and board3d.handle_input(camera, event):
		return true
	return _pick_body_control(camera, event)


# Left click on a body control shape (hand / foot cube, pole diamond, FK ring) selects its node, so the normal
# move / rotate gizmo works on it. FK rings create their rotate handle on first click.
func _pick_body_control(camera: Camera, event: InputEvent) -> bool:
	if body_rig == null or not is_instance_valid(body_rig) or editor_interface == null:
		return false
	if not (event is InputEventMouseButton) or event.button_index != BUTTON_LEFT or not event.pressed:
		return false
	# The move / rotate gizmo of the selected control belongs to the editor: a click inside its area is a gizmo drag,
	# never a new selection (the neighbouring controls under the gizmo used to steal it). Click empty space first to
	# pick a control that sits inside the gizmo's area.
	if _click_in_selected_gizmo(camera, event.position):
		return false
	var hit: Dictionary = body_rig.pick(camera.project_ray_origin(event.position), camera.project_ray_normal(event.position))
	if hit.empty():
		return false
	var node = hit.get("node", null)
	if node == null and hit.has("joint"):
		node = body_rig.fk_handle_for(hit["joint"], editor_interface.get_edited_scene_root())
	if node == null:
		return false
	var sel = editor_interface.get_selection()
	sel.clear()
	sel.add_node(node)
	return true


func _click_in_selected_gizmo(camera: Camera, pos: Vector2) -> bool:
	var nodes: Array = editor_interface.get_selection().get_selected_nodes()
	if nodes.size() != 1:
		return false
	var n = nodes[0]
	if not (n is Spatial) or n == body_rig or not body_rig.is_a_parent_of(n) or not n.is_inside_tree():
		return false
	var o: Vector3 = n.global_transform.origin
	if camera.is_position_behind(o):
		return false
	var radius := 80.0
	var es = editor_interface.get_editor_settings()
	if es != null and es.has_setting("editors/3d/manipulator_gizmo_size"):
		radius = float(es.get_setting("editors/3d/manipulator_gizmo_size"))
	# the arrows / rotate rings reach well past the nominal size
	return camera.unproject_position(o).distance_to(pos) < radius * 1.9


func _free_board3d() -> void:
	board3d = null


# The board is a real node of the scene (owner = scene root): it is saved with the scene, can be selected
# and moved / rotated / scaled with the normal editor gizmo, or parented under the head.
func _find_board3d(n: Node):
	if n.get_script() == Board3D:
		return n
	for c in n.get_children():
		var f = _find_board3d(c)
		if f != null:
			return f
	return null


func _ensure_board3d(root: Node) -> void:
	if not rig.loaded or not _b3_show.pressed:
		_hide_board3d()
		return
	var fresh := false
	if board3d == null or not is_instance_valid(board3d) or not board3d.is_inside_tree():
		board3d = _find_board3d(root)
		if board3d == null:
			board3d = Board3D.new()
			root.add_child(board3d)
			board3d.owner = root
			fresh = true
			_mark_dirty()
		if not board3d.is_connected("gui_value_changed", self, "_on_gui_value_changed_3d"):
			board3d.connect("gui_value_changed", self, "_on_gui_value_changed_3d")
	if not board3d.is_connected("pose_changed", self, "_on_board_pose_changed"):
		board3d.connect("pose_changed", self, "_on_board_pose_changed")
	board3d.visible = true
	board3d.build(rig, _editor_font())
	board3d.sync_from(rig)
	_link_board3d_to_rig(root)
	if fresh:
		_place_board3d()


# The board remembers the rig file and the skeleton, so the cutscene's face animation also plays in the running game.
func _link_board3d_to_rig(root: Node) -> void:
	var changed := false
	if _loaded_path != "" and board3d.rig_path != _loaded_path:
		board3d.rig_path = _loaded_path
		changed = true
	if skeleton and is_instance_valid(skeleton) and board3d.is_inside_tree() and skeleton.is_inside_tree():
		var sp: NodePath = board3d.get_path_to(skeleton)
		if board3d.skeleton_path != sp:
			board3d.skeleton_path = sp
			changed = true
	if changed:
		_mark_dirty()


# The pose was changed by an animation / the Inspector (not by dragging a dot): refresh the dock's 2D board.
func _on_board_pose_changed() -> void:
	if rig.loaded:
		_board.sync_from(rig)


func _mark_dirty() -> void:
	if editor_interface and editor_interface.has_method("mark_scene_as_unsaved"):
		editor_interface.call("mark_scene_as_unsaved")


func _hide_board3d() -> void:
	if board3d != null and is_instance_valid(board3d) and board3d.visible:
		board3d.visible = false
		_mark_dirty()


func _remove_board3d() -> void:
	if board3d != null and is_instance_valid(board3d):
		board3d.queue_free()
		_mark_dirty()
	board3d = null
	_b3_show.pressed = false


func _on_b3_show(pressed: bool) -> void:
	if not pressed:
		_hide_board3d()
	elif editor_interface and rig.loaded:
		var root := editor_interface.get_edited_scene_root()
		if root != null:
			_ensure_board3d(root)


func _on_b3_slider(v: float, key: String) -> void:
	_b3[key] = v
	_place_board3d()


func _compute_face_frame() -> void:
	_face_center = Vector3.ZERO
	_face_size = 0.2
	if not skeleton or not is_instance_valid(skeleton):
		return
	var xf: Transform = skeleton.global_transform
	var have := false
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	for j in range(rig.joint_names.size()):
		var jn: String = rig.joint_names[j]
		if not jn.begins_with("FACIAL_"):
			continue
		var b := skeleton.find_bone(jn)
		if b < 0:
			continue
		var p: Vector3 = xf.xform(skeleton.get_bone_global_pose(b).origin)
		if not have:
			lo = p
			hi = p
			have = true
		else:
			lo = Vector3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
			hi = Vector3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
	if have and max(hi.x - lo.x, hi.y - lo.y) > 1e-5:
		_face_center = (lo + hi) * 0.5
		_face_size = max(hi.x - lo.x, hi.y - lo.y)
		return
	# no facial joints in this skeleton: fall back to the head bone, assuming a DNA (cm) rig
	var hb := skeleton.find_bone("head")
	if hb < 0:
		hb = skeleton.find_bone("Head")
	_face_size = 20.0 * xf.basis.get_scale().x
	if hb >= 0:
		_face_center = xf.xform(skeleton.get_bone_global_pose(hb).origin) + Vector3(0, _face_size * 0.5, 0)
	else:
		_face_center = xf.origin


func _editor_font():
	if editor_interface == null:
		return null
	var base = editor_interface.get_base_control()
	if base != null and base.has_font("main", "EditorFonts"):
		return base.get_font("main", "EditorFonts")
	return null


func _place_board3d() -> void:
	if board3d == null or not is_instance_valid(board3d) or not board3d.is_inside_tree():
		return
	if not skeleton or not is_instance_valid(skeleton):
		return
	_compute_face_frame()
	var base: Basis = skeleton.global_transform.basis.orthonormalized()
	var w: float = _face_size * _b3["size"]
	board3d.set_world_width(w)
	# default: to the right of the face (seen from the front, the face looks along +Z), slightly in front of it
	var off := Vector3(_face_size * 0.75 + w * 0.5 + _face_size * _b3["right"], _face_size * _b3["up"], _face_size * 0.4 + _face_size * _b3["fwd"])
	board3d.global_transform = Transform(base * Basis(Vector3.UP, deg2rad(_b3["yaw"])), _face_center + base.xform(off))


# ---------------------------------------------------------------- open a .glb with the rig (file system menu)

func _open_selected_glb() -> void:
	if editor_interface == null:
		return
	var path: String = editor_interface.get_current_path()
	if path.get_extension().to_lower() in ["glb", "gltf"]:
		open_glb_with_rig(path)
	else:
		_alert("Open with MetaHuman Rig", "Select a .glb file in the FileSystem dock first.")


func _alert(title: String, text: String) -> void:
	if _msg_dialog == null or not is_instance_valid(_msg_dialog):
		_msg_dialog = AcceptDialog.new()
		editor_interface.get_base_control().add_child(_msg_dialog)
	_msg_dialog.window_title = title
	_msg_dialog.dialog_text = text
	_msg_dialog.popup_centered()


# Returns "" when the files next to the glb look like an exported MetaHuman rig, else the reason.
func _check_metahuman(glb: String, json_path: String) -> String:
	var f := File.new()
	if not f.file_exists(json_path):
		return "There is no %s next to the GLB.\nExport the character with the Blender 'Godot (MetaHuman)' add-on." % json_path.get_file()
	if not f.file_exists(glb.get_basename() + ".rig.bin"):
		return "%s is missing (it has to sit next to the GLB)." % (glb.get_basename() + ".rig.bin").get_file()
	if f.open(json_path, File.READ) != OK:
		return "Could not read %s." % json_path.get_file()
	var parsed = JSON.parse(f.get_as_text())
	f.close()
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return "%s is not valid JSON." % json_path.get_file()
	for k in ["raw_count", "psd_count", "gui_names", "gui_ranges", "gui_rows", "joint_names", "blendshapes"]:
		if not parsed.result.has(k):
			return "%s is not a MetaHuman rig file (missing '%s')." % [json_path.get_file(), k]
	return ""


func open_glb_with_rig(glb: String) -> void:
	if editor_interface == null:
		return
	var json_path := glb.get_basename() + ".rig.json"
	var why := _check_metahuman(glb, json_path)
	if why != "":
		_alert("Not a MetaHuman rig", "%s\n\n%s" % [glb.get_file(), why])
		return
	_pending_glb = glb
	_pending_json = json_path
	if _open_dialog == null or not is_instance_valid(_open_dialog):
		_open_dialog = ConfirmationDialog.new()
		_open_dialog.window_title = "Open with MetaHuman Rig"
		_open_dialog.get_ok().text = "New scene"
		_open_dialog.connect("confirmed", self, "_open_new_scene")
		_add_btn = _open_dialog.add_button("Add to current scene", false, "add")
		_open_dialog.connect("custom_action", self, "_on_open_custom")
		editor_interface.get_base_control().add_child(_open_dialog)
	_add_btn.disabled = editor_interface.get_edited_scene_root() == null
	_open_dialog.dialog_text = "%s is a MetaHuman rig.\n\nOpen it in a new scene, or add it to the current scene?" % glb.get_file()
	_open_dialog.popup_centered()


func _on_open_custom(action: String) -> void:
	if action == "add":
		_open_dialog.hide()
		_add_to_scene()


# Instance the glb and check that it really holds the rig's joints.
func _instance_checked():
	var ps = load(_pending_glb)
	if not (ps is PackedScene):
		_alert("Open with MetaHuman Rig", "Could not load %s as a scene (is it imported?)." % _pending_glb.get_file())
		return null
	var inst: Node = ps.instance()
	var f := File.new()
	var names := []
	if f.open(_pending_json, File.READ) == OK:
		var parsed = JSON.parse(f.get_as_text())
		f.close()
		if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
			names = parsed.result.get("joint_names", [])
	var skels := []
	_collect_skeletons(inst, skels)
	var best := 0
	for sk in skels:
		var c := 0
		for j in names:
			if sk.find_bone(j) >= 0:
				c += 1
		if c > best:
			best = c
	if best < 10:
		inst.free()
		_alert("Not a MetaHuman rig", "%s does not contain the rig's facial joints (%d found).\nExport it again from Blender and read the export message." % [_pending_glb.get_file(), best])
		return null
	return inst


func _unique_path(path: String) -> String:
	var d := Directory.new()
	if not d.file_exists(path):
		return path
	var i := 2
	while d.file_exists("%s_%d.%s" % [path.get_basename(), i, path.get_extension()]):
		i += 1
	return "%s_%d.%s" % [path.get_basename(), i, path.get_extension()]


func _open_new_scene() -> void:
	var inst = _instance_checked()
	if inst == null:
		return
	var root := Spatial.new()
	root.name = _pending_glb.get_file().get_basename().replace(".", "_")
	root.add_child(inst)
	inst.owner = root
	var ps := PackedScene.new()
	var err := ps.pack(root)
	root.free()
	var out := _unique_path(_pending_glb.get_basename() + "_rig.tscn")
	if err == OK:
		err = ResourceSaver.save(out, ps)
	if err != OK:
		_alert("Open with MetaHuman Rig", "Could not create the scene %s (error %d)." % [out, err])
		return
	_opening = true
	editor_interface.get_resource_filesystem().scan()
	editor_interface.open_scene_from_path(out)
	yield(get_tree().create_timer(0.4), "timeout")
	var scene_root := editor_interface.get_edited_scene_root()
	if scene_root != null and scene_root.get_child_count() > 0:
		_finish_open(scene_root, scene_root.get_child(0))
	_opening = false


func _add_to_scene() -> void:
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		_open_new_scene()
		return
	var inst = _instance_checked()
	if inst == null:
		return
	root.add_child(inst, true)
	inst.owner = root
	_mark_dirty()
	_finish_open(root, inst)


func _finish_open(root: Node, inst: Node) -> void:
	var sel := editor_interface.get_selection()
	sel.clear()
	sel.add_node(inst)
	_prefer_root = inst
	_load_rig(_pending_json)    # loads the json, binds skeleton + blend shapes, adds the 3D face board
	_prefer_root = null
