tool
extends VBoxContainer
# The "Cinematic" main-screen tab. Everything is stored as an Animation inside an AnimationPlayer
# that belongs to a CinematicDirector node in the scene you are editing.
#
# Layout: [ Editor view | Result ]  on top, transport + key list below, tools on the right.
#   Editor view  a free-fly camera you move around the scene (cameras are drawn as outlines).
#   Result       what the cutscene camera really sees, with subtitles.
#
# Keyboard in the Editor view (like Blender): G / R / S move / rotate / scale the selected node(s) with the
# mouse, X / Y / Z lock the axis (press again = local axis, Shift+X/Y/Z = lock to the plane without that axis),
# click or Enter confirms, Esc or right click cancels, Ctrl snaps. I keys the selected node (or camera).

const DirectorScript = preload("res://addons/cinematic_editor/cinematic_director.gd")

# A "cut" between two camera poses is a hold key placed this many seconds before the new pose, so the
# camera sits still and then jumps (constant interpolation for just that one segment).
const CUT_GAP = 0.002
const INTERP_LINEAR = 0
const INTERP_CUBIC = 1
const INTERP_CUT = 2               # "constant": hold this pose until the next key, then jump (a cut)
# Effects that can be hidden from the timeline: [category, label]
const FX_LIST = [["fov", "FOV"], ["shake", "Camera shake"], ["shakify", "Shakify"], ["dialogue", "Dialogue"], ["audio", "Audio"]]
const PKG_META = "cinematic_package"   # metadata on the root of a saved cutscene package (.tscn)
const PKG_STUB = "cine_stub"           # marks a placeholder parent node inside a package
const AUD_META = "cine_audio"      # per-audio-key extras (loop, length when looping), kept in the Animation's metadata
const SRC_META = "cine_src"        # per-key pose + interpolation list, kept in the Animation's metadata
# Camera outlines are drawn on visual layer 20, which the Result view never renders.
const GIZMO_LAYER = 1 << 19
# Saturated axis colours (same family as the Godot 4 editor gizmo).
const GZ_COLORS = [Color(0.96, 0.20, 0.32), Color(0.53, 0.84, 0.01), Color(0.16, 0.55, 0.96)]
const GZ_HOT = Color(1.0, 0.9, 0.25)
const SEL_BOX_COLOR = Color(1.0, 0.6, 0.1)
const LAYOUT_FILE = "user://cinematic_editor_layout.cfg"   # remembers the order of the sidebar categories

var editor: EditorInterface
var undo_redo: UndoRedo

var _root: Node
var _director: Node
var _player: AnimationPlayer
var _anim: Animation
var _anim_name = ""
var _time = 0.0
var _syncing = false
var _aspect = 9.0 / 16.0           # height / width of the game window
var _proj_w = 1920.0
var _cameras = []                  # [{label, path}]

# editor-view (free-fly) camera state
var _edit_pos = Vector3(0, 3, 6)
var _edit_yaw = 0.0
var _edit_pitch = -0.25
var _edit_rmb = false
var _edit_mmb = false
var _edit_dist = 6.0               # distance from the editor camera to its orbit point (middle mouse)
var _edit_goal = null              # {pos, dist}: smooth "focus" (F) target
var _fly_speed = 4.0               # metres / second while flying with right mouse + WASD
var _bounds_cache = {}             # node instance id -> {t, box}: local bounds of a picked node
var _tv = 0                        # vertices written to the filled gizmo this frame
var _play_shown = 0
var _cards_box: VBoxContainer      # all other categories, reorderable by dragging their handle
var _cards = {}                    # title -> card
var _card_drag = null
var _gz_buttons = {}               # gizmo mode -> its toolbar button
var _edit_root_id = 0

# UI
var _no_scene_label: Label
var _setup_box: VBoxContainer
var _main_box: HSplitContainer
var _right_scroll: ScrollContainer
var _inspector_btn: Button
var _cut_opt: OptionButton
var _new_dialog: ConfirmationDialog   # asks for the name of a new cutscene
var _new_name_edit: LineEdit
var _new_name_warn: Label
var _len_spin: SpinBox
var _loop_check: CheckBox
var _play_btn: Button
var _time_label: Label
var _sheet: Control               # the dope sheet (rows of keys on a time grid)
var _rows = []                     # [{kind: summary|node|track, label, track, node}]
var _track_node = {}               # track index -> node path string
var _sel = []                      # selected keys: [{track, t}]
var _clip = []                     # copied keys (Ctrl+C), pasted at the playhead with Ctrl+V
var _sel_track = -1                # channel (track) selected by clicking its name
var _view_fit = true               # dope sheet shows the whole cutscene until you zoom / pan
var _view_t0 = 0.0                 # time at the left edge of the key area
var _view_pps = 100.0              # pixels per second
var _scroll_y = 0.0
var _drag = null
var _last_snap = {}                # state of the cutscene after the last edit (the 'before' of the next one)
var _last_snap_name = ""
var _committing = false
var _res_pane = {}
var _edit_pane = {}
var _viewport: Viewport            # Result
var _edit_viewport: Viewport       # Editor view
var _preview_cam: Camera
var _edit_cam: Camera
var _gizmo: ImmediateGeometry
var _tgizmo: ImmediateGeometry     # move / rotate / scale handles of the selected node
var _gz_mode = 4                   # 0 off, 1 move, 2 rotate, 3 scale, 4 all
var _gz_local = false
var _gz_hover = -1                 # 0..2 = X / Y / Z handle, 3 = uniform scale centre
var _gz_drag = null
var _modal = null                  # running G / R / S operation, see "modal transform" below
var _preview_msg: Label
var _subtitle_label: Label
var _sub_sig = ""
var _pv_chosen_check: CheckBox
var _cam_opt: OptionButton
var _interp_opt: OptionButton
var _into_check: CheckBox
var _move_dur_spin: SpinBox
var _sel_label: Label
var _picked = []                   # nodes picked in the Nodes list (paths from the scene root); the editor's own selection is not touched
var _node_filter: LineEdit
var _node_list: Tree               # column 0 = node, column 1 = eye button (show / hide the node)
var _node_tree_root: TreeItem
var _list_syncing = false
var _eye_on: Texture
var _eye_off: Texture
var _xform_box: VBoxContainer
var _xform_card: Control          # the Transform card (hidden while nothing is selected)
var _mh_page: Control              # the "MetaHuman" sidebar tab (only shown while the scene has a face board)
var _mh_holder: Control
var _mh_board = null               # the 2D face board inside that tab (face_board.gd of the MetaHuman Rig add-on)
var _face_track_anim = null
var _face_track_count = -1
var _face_tracks = []
var _mh_node = null                # the MetaHumanFaceBoard3D node of the scene
var _mh_rig_id = 0
var _mh_busy = false
var _mh_dirty = false
var _mh_timer = 0.0
var _mh_tab_hidden = true          # last state given to the tab (set_tab_hidden is only called when it changes)
var _mh_missing = 0                # consecutive scans that found no face board
var _mh_panning = false
var _mh_pan = Vector2()
var _face_label: Label
var _face_auto: CheckBox
var _face_count = -1               # number of face controls the inspector was built with
var _face_drag = null              # the face board whose dot is being dragged in the Editor view
var _ap_card: Control              # the Animation card
var _xf_spins = []                 # [position, rotation, scale] -> each one [x, y, z] SpinBox
var _xf_last = []                  # last values shown in the spin boxes
var _xf_syncing = false
var _ap_none: Label
var _ap_box: VBoxContainer
var _ap_player_opt: OptionButton
var _ap_anim_opt: OptionButton
var _ap_info: Label
var _ap_players = []               # paths (from the scene root) of the AnimationPlayers in the dropdown
var _tabs: TabContainer            # sidebar tabs: Nodes | Composition
var _ins_box: VBoxContainer        # property inspector of the selected node (Nodes tab)
var _ins_filter: LineEdit
var _ins_rows = []                 # [{row, prop, kind, ctl, last}]
var _ins_node_id = 0
var _ins_open = {}                 # category -> folded open?
var _ins_previews = []             # [{mat, rect}]: the material preview pictures in the inspector
var _ins_prev_pending = false
var _checker: Texture
var _ins_syncing = false
var _fov_spin: SpinBox
var _fov_dur_spin: SpinBox
var _shake_amount: SpinBox
var _shake_dur: SpinBox
var _sk_preset: OptionButton
var _sk_influence: SpinBox
var _sk_scale: SpinBox
var _sk_speed: SpinBox
var _sk_dur: SpinBox
var _sk_fade_in: SpinBox
var _sk_fade_out: SpinBox
var _speaker_edit: LineEdit
var _text_edit: LineEdit
var _text_dur: SpinBox
var _font_path_edit: LineEdit
var _font_size_spin: SpinBox
var _sub_color_btn: ColorPickerButton
var _audio_path_edit: LineEdit
var _audio_stream: AudioStream
var _audio_sub_check: CheckBox
var _audio_loop_check: CheckBox
var _key_menu: PopupMenu           # right-click menu of an audio key in the timeline
var _test_player: AudioStreamPlayer
var _file_dialog: FileDialog
var _file_purpose = ""
var _status: Label
var _fx_hidden = {}                # category -> true while its rows are hidden in the timeline
var _fx_checks = {}                # category -> the "Timeline" check box in the sidebar
var _fx_menu: MenuButton
var _fx_syncing = false
var _save_dialog: FileDialog
var _pkg_dialog: FileDialog


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_ui()
	editor.get_selection().connect("selection_changed", self, "_on_editor_selection_changed")
	var w = float(ProjectSettings.get_setting("display/window/size/width"))
	var h = float(ProjectSettings.get_setting("display/window/size/height"))
	if w > 0.0 and h > 0.0:
		_aspect = h / w
		_proj_w = w
	connect("visibility_changed", self, "_on_visibility_changed")
	_on_visibility_changed()


# "I" keys the selected node (or the camera) like Blender, G / R / S transform it with the mouse,
# unless you are typing in a text box.
func _input(ev: InputEvent) -> void:
	if _mh_pan_input(ev):
		get_tree().set_input_as_handled()
		return
	if _mh_dirty and ev is InputEventMouseButton and ev.button_index == BUTTON_LEFT and not ev.pressed:
		_mh_dirty = false
		if _face_auto != null and _face_auto.pressed and _mh_node != null and is_instance_valid(_mh_node):
			_key_face_pose(_mh_node)
	if _card_drag != null and ev is InputEventMouseButton and ev.button_index == BUTTON_LEFT and not ev.pressed:
		_end_card_drag()
		return
	if _modal != null:
		if _modal_input(ev):
			get_tree().set_input_as_handled()
		return
	if not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	if ev.control or ev.alt or ev.shift or ev.meta or ev.command:
		return
	if ev.scancode != KEY_SPACE and ev.scancode != KEY_I and ev.scancode != KEY_F and ev.scancode != KEY_G and ev.scancode != KEY_R and ev.scancode != KEY_S and ev.scancode != KEY_A:
		return
	if not is_visible_in_tree() or _root == null:
		return
	var f = get_focus_owner()
	if f is LineEdit or f is TextEdit:
		return
	if ev.scancode == KEY_SPACE:
		if _focus_in_popup(f):
			return
		_on_play_pressed()                        # Space = play / pause, like in most editors
	elif ev.scancode == KEY_I:
		_on_key_selected()
	elif ev.scancode == KEY_F:
		_focus_selected()
	elif ev.scancode == KEY_A:
		if _edit_rmb:
			return
		_set_gz_mode(4)
	else:
		# G / R / S only work with the mouse over the Editor view (and not while flying with RMB + WASD)
		if _edit_rmb or not _mouse_in_edit_view():
			return
		_modal_begin({KEY_G: "move", KEY_R: "rot", KEY_S: "scale"}[ev.scancode], ev.scancode)
	get_tree().set_input_as_handled()


# True when the focused control lives inside a dialog / popup (file chooser, colour picker ...), where Space belongs to that window.
func _focus_in_popup(f) -> bool:
	var n = f
	while n != null:
		if n is Popup or n is WindowDialog:
			return true
		n = n.get_parent()
	return false


func on_shown() -> void:
	_refresh_scene()


func on_scene_changed() -> void:
	_gz_drag = null
	_modal = null
	_ins_node_id = 0
	_picked = []
	if is_inside_tree() and visible:
		_refresh_scene()


func _on_visibility_changed() -> void:
	var showing = is_visible_in_tree()
	if not showing and _modal != null:
		_modal_cancel(false)
	var mode = Viewport.UPDATE_ALWAYS if showing else Viewport.UPDATE_DISABLED
	if _viewport != null:
		_viewport.render_target_update_mode = mode
	if _edit_viewport != null:
		_edit_viewport.render_target_update_mode = mode
	if _tgizmo != null:
		_tgizmo.visible = showing
	if _gizmo != null:
		_gizmo.visible = showing       # the outlines must never show up in the normal 3D editor
	if not showing and _test_player != null:
		_test_player.stop()


# ------------------------------------------------------------------------ UI

func _label(text: String, parent: Node = null) -> Label:
	var l = Label.new()
	l.text = text
	if parent != null:
		parent.add_child(l)
	return l


func _button(text: String, parent: Node, method: String, binds: Array = []) -> Button:
	var b = Button.new()
	b.text = text
	b.connect("pressed", self, method, binds)
	parent.add_child(b)
	return b


func _spin(parent: Node, min_v: float, max_v: float, step: float, value: float) -> SpinBox:
	var s = SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(s)
	return s


func _heading(text: String, parent: Node) -> void:
	parent.add_child(HSeparator.new())
	var l = _label(text, parent)
	l.add_color_override("font_color", Color(0.6, 0.8, 1.0))


# A dimmed, wrapped helper text.
func _hint(text: String, parent: Node) -> Label:
	var l = _label(text, parent)
	l.autowrap = true
	l.modulate = Color(1, 1, 1, 0.55)
	return l


# Two label+field pairs per row, so all the numbers line up.
func _grid(parent: Node) -> GridContainer:
	var g = GridContainer.new()
	g.columns = 4
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_constant_override("hseparation", 8)
	parent.add_child(g)
	return g


const FORM_LABEL_W = 96.0


# One line of a card: the name on the left (right-aligned, like Blender's panels), the value editor on the right.
# Returns the line; add the editor(s) to it.
func _form(parent: Node, label_text: String, tip: String = "") -> HBoxContainer:
	var row = HBoxContainer.new()
	row.add_constant_override("separation", 8)
	var lab = _label(label_text, row)
	lab.align = Label.ALIGN_RIGHT
	lab.valign = Label.VALIGN_CENTER
	lab.clip_text = true
	lab.rect_min_size = Vector2(FORM_LABEL_W, 26)
	lab.modulate = Color(1, 1, 1, 0.85)
	if tip != "":
		lab.hint_tooltip = tip
		lab.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(row)
	return row


# A line with one editor that fills the value side.
func _form_ctl(parent: Node, label_text: String, ctl: Control, tip: String = "") -> Control:
	var row = _form(parent, label_text, tip)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctl)
	return ctl


func _form_spin(parent: Node, label_text: String, mn: float, mx: float, st: float, v: float) -> SpinBox:
	var row = _form(parent, label_text)
	return _spin(row, mn, mx, st, v)


func _arrow_icon(open: bool) -> Texture:
	var c = editor.get_base_control()
	return c.get_icon("GuiTreeArrowDown" if open else "GuiTreeArrowRight", "EditorIcons")


# First of these editor icons that exists in this Godot version (or null).
func _icon(names: Array) -> Texture:
	var c = editor.get_base_control()
	for n in names:
		if c.has_icon(n, "EditorIcons"):
			return c.get_icon(n, "EditorIcons")
	return null


# A button that shows an editor icon (falls back to text if the icon is missing in this version).
func _icon_button(names: Array, fallback: String, tip: String, parent: Node, method: String, binds: Array = []) -> Button:
	var b = Button.new()
	var ic = _icon(names)
	if ic != null:
		b.icon = ic
	else:
		b.text = fallback
	b.hint_tooltip = tip
	b.connect("pressed", self, method, binds)
	parent.add_child(b)
	return b


# A rounded card with a clickable header (with a real dropdown arrow) that folds its contents.
# fx_cat != "": the header also gets a "Timeline" check box that shows / hides that effect in the timeline.
func _section(title: String, parent: Node, open: bool, fx_cat: String = "", drag: bool = true) -> VBoxContainer:
	var card = PanelContainer.new()
	card.set_meta("cine_title", title)
	_cards[title] = card
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.04)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 8
	card.add_stylebox_override("panel", sb)
	parent.add_child(card)
	var outer = VBoxContainer.new()
	outer.add_constant_override("separation", 6)
	card.add_child(outer)
	var head_row = HBoxContainer.new()
	outer.add_child(head_row)
	var head = Button.new()
	head.flat = true
	head.align = Button.ALIGN_LEFT
	head.text = title
	head.icon = _arrow_icon(open)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_color_override("font_color", Color(0.92, 0.92, 0.96))
	head.add_color_override("font_color_hover", Color(1, 1, 1))
	head.add_color_override("font_color_pressed", Color(0.92, 0.92, 0.96))
	head_row.add_child(head)
	var body = VBoxContainer.new()
	body.add_constant_override("separation", 6)
	body.visible = open
	outer.add_child(body)
	head.connect("pressed", self, "_toggle_section", [head, body])
	if fx_cat != "":
		var cb = CheckBox.new()
		cb.text = "Timeline"
		cb.pressed = not _fx_hidden.get(fx_cat, false)
		cb.hint_tooltip = "Show these keys in the timeline (untick to hide the row)."
		cb.modulate = Color(1, 1, 1, 0.8)
		cb.connect("toggled", self, "_on_fx_check", [fx_cat])
		head_row.add_child(cb)
		_fx_checks[fx_cat] = cb
	if drag:                                      # the grip (::::) sits at the right end of the header
		var handle = Button.new()
		handle.flat = true
		var hic = _icon(["TripleBar", "GuiTabMenu"])
		if hic != null:
			handle.icon = hic
		else:
			handle.text = "::"
		handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
		handle.hint_tooltip = "Hold and drag to reorder this category"
		handle.connect("button_down", self, "_begin_card_drag", [card])
		head_row.add_child(handle)
	return body


# ---- reordering the categories: hold the handle and drag
func _begin_card_drag(card: Control) -> void:
	_card_drag = card
	card.modulate = Color(1, 1, 1, 0.65)


func _end_card_drag() -> void:
	if _card_drag == null:
		return
	if is_instance_valid(_card_drag):
		_card_drag.modulate = Color(1, 1, 1, 1)
	_card_drag = null
	_save_card_order()


func _update_card_drag() -> void:
	if _card_drag == null:
		return
	if not is_instance_valid(_card_drag) or not Input.is_mouse_button_pressed(BUTTON_LEFT):
		_end_card_drag()
		return
	var my = get_global_mouse_position().y
	var sr = _right_scroll.get_global_rect()
	if my < sr.position.y + 28.0:
		_right_scroll.scroll_vertical = int(max(0, _right_scroll.scroll_vertical - 14))
	elif my > sr.end.y - 28.0:
		_right_scroll.scroll_vertical = _right_scroll.scroll_vertical + 14
	var idx = _card_drag.get_index()
	if idx > 0:
		var p = _cards_box.get_child(idx - 1)
		if my < p.get_global_rect().position.y + p.rect_size.y * 0.5:
			_cards_box.move_child(_card_drag, idx - 1)
			return
	if idx < _cards_box.get_child_count() - 1:
		var nx = _cards_box.get_child(idx + 1)
		if my > nx.get_global_rect().position.y + nx.rect_size.y * 0.5:
			_cards_box.move_child(_card_drag, idx + 1)


func _save_card_order() -> void:
	var titles = []
	for c in _cards_box.get_children():
		titles.append(str(c.get_meta("cine_title")))
	var cf = ConfigFile.new()
	cf.set_value("layout", "cards", titles)
	cf.save(LAYOUT_FILE)


func _load_card_order() -> void:
	var cf = ConfigFile.new()
	if cf.load(LAYOUT_FILE) != OK:
		return
	var titles = cf.get_value("layout", "cards", [])
	var at = 0
	for t in titles:
		if _cards.has(t) and _cards[t].get_parent() == _cards_box:
			_cards_box.move_child(_cards[t], at)
			at += 1


func _toggle_section(head: Button, body: Control) -> void:
	body.visible = not body.visible
	head.icon = _arrow_icon(body.visible)


# ------------------------------------------------------------ timeline effects filter

func _track_cat(idx: int) -> String:
	var p = str(_anim.track_get_path(idx))
	var d = _director_path("")
	if p == d + ":subtitle":
		return "dialogue"
	if p == d + ":shake":
		return "shake"
	if p == d + ":shakify" or p == d + ":shakify_setup":
		return "shakify"
	if _anim.track_get_type(idx) == Animation.TYPE_AUDIO:
		return "audio"
	if p.ends_with(":fov"):
		return "fov"
	return ""


func _track_hidden(idx: int) -> bool:
	var c = _track_cat(idx)
	if c != "" and _fx_hidden.get(c, false):
		return true
	return _anim != null and idx < _anim.get_track_count() and not _anim.track_is_enabled(idx)


# Hiding an effect also DISABLES its tracks, so it is muted in the preview and in the game too.
# (The enabled flag is saved with the cutscene.)  commit = false: used while another edit is in progress.
func _set_fx_visible(cat: String, vis: bool, commit: bool = true) -> void:
	if vis:
		_fx_hidden.erase(cat)
	else:
		_fx_hidden[cat] = true
	var label = cat
	for fx in FX_LIST:
		if fx[0] == cat:
			label = fx[1]
	if _anim != null and _director != null:
		for idx in range(_anim.get_track_count()):
			if _track_cat(idx) == cat:
				_anim.track_set_enabled(idx, vis)
	_fx_syncing = true
	if _fx_checks.has(cat):
		_fx_checks[cat].pressed = vis
	if _fx_menu != null:
		for i in range(FX_LIST.size()):
			if FX_LIST[i][0] == cat:
				_fx_menu.get_popup().set_item_checked(i, vis)
	_fx_syncing = false
	_update_fx_menu()
	if not vis and commit:
		_reset_fx_state(cat)
	_refresh_keys()
	if commit and _anim != null:
		_seek(_time)
		_mark_changed("%s %s" % ["Show" if vis else "Hide", label])
		if vis:
			_say("%s shown again." % label)
		else:
			_say("%s hidden. It is switched off in the cutscene too (tick it again to turn it back on)." % label)


# A disabled track stops writing its property, so put the leftovers of the effect back to "off".
func _reset_fx_state(cat: String) -> void:
	if _director == null or _anim == null:
		return
	if cat == "dialogue":
		_director.set_subtitle("")
	elif cat == "shake":
		_director.shake = 0.0
	elif cat == "shakify":
		_director.shakify = 0.0
		_director.shakify_setup = []
	elif cat == "audio":
		_silence_audio()
	elif cat == "fov":
		for idx in range(_anim.get_track_count()):
			if _track_cat(idx) == "fov" and _anim.track_get_key_count(idx) > 0:
				var cam = _root.get_node_or_null(str(_anim.track_get_path(idx)).split(":")[0])
				if cam is Camera:
					cam.fov = _anim.track_get_key_value(idx, 0)


# Reads the hidden / shown state back from the cutscene (a category is hidden when all its tracks are disabled).
func _load_fx_state() -> void:
	_fx_hidden = {}
	if _anim != null and _director != null:
		for fx in FX_LIST:
			var total = 0
			var off = 0
			for idx in range(_anim.get_track_count()):
				if _track_cat(idx) == fx[0]:
					total += 1
					if not _anim.track_is_enabled(idx):
						off += 1
			if total > 0 and off == total:
				_fx_hidden[fx[0]] = true
	_fx_syncing = true
	for i in range(FX_LIST.size()):
		var cat = FX_LIST[i][0]
		var vis = not _fx_hidden.get(cat, false)
		if _fx_checks.has(cat):
			_fx_checks[cat].pressed = vis
		if _fx_menu != null:
			_fx_menu.get_popup().set_item_checked(i, vis)
	_fx_syncing = false
	_update_fx_menu()


func _update_fx_menu() -> void:
	if _fx_menu != null:
		_fx_menu.text = "Effects" if _fx_hidden.empty() else "Effects (%d hidden)" % _fx_hidden.size()


func _on_fx_check(pressed: bool, cat: String) -> void:
	if _fx_syncing:
		return
	_set_fx_visible(cat, pressed)


func _on_fx_menu(id: int) -> void:
	if id == 100 or id == 101:
		for fx in FX_LIST:
			_set_fx_visible(fx[0], id == 100)
	elif id >= 0 and id < FX_LIST.size():
		var cat = FX_LIST[id][0]
		_set_fx_visible(cat, _fx_hidden.get(cat, false))


# ------------------------------------------------------------ cutscene packages
# A package is a normal .tscn: a root holding (a) a Cinematic director with ONLY this cutscene, and
# (b) a copy of every node the cutscene uses, in the same place in the tree.  Assets (meshes, textures,
# audio, scripts) stay referenced by their res:// path, so they come along automatically.

func _on_export_package() -> void:
	if _anim == null or _director == null:
		_say("Create or pick a cutscene first.")
		return
	var dir = Directory.new()
	if not dir.dir_exists("res://cutscenes"):
		dir.make_dir_recursive("res://cutscenes")
	_save_dialog.current_path = "res://cutscenes/%s.tscn" % _anim_name
	_popup_centered(_save_dialog, editor.get_base_control().rect_size * 0.7)


func _on_import_package() -> void:
	if _root == null or _director == null or _player == null:
		_say("Open a scene with a Cinematic director first.")
		return
	_pkg_dialog.current_dir = "res://cutscenes" if Directory.new().dir_exists("res://cutscenes") else "res://"
	_popup_centered(_pkg_dialog, editor.get_base_control().rect_size * 0.7)


func _on_package_save_path(path: String) -> void:
	if not path.ends_with(".tscn"):
		path += ".tscn"
	_export_package(path)


func _on_package_picked(path: String) -> void:
	_import_package(path)


# Node names from `top` (exclusive) down to `n`, e.g. "Cinematic" or "World/Cam".
func _chain_path(n: Node, top: Node) -> String:
	var names = []
	var cur = n
	while cur != null and cur != top:
		names.push_front(str(cur.name))
		cur = cur.get_parent()
	return PoolStringArray(names).join("/")


func _add_unit(node, units: Array) -> void:
	if node == null or node == _root or node == _director or _director.is_a_parent_of(node):
		return
	# an instanced scene (a character, a prop) is copied whole, so its mesh, skeleton, scripts come too
	var unit = node
	var par = node.get_parent()
	while par != null and par != _root:
		if par.filename != "":
			unit = par
		par = par.get_parent()
	if not units.has(unit):
		units.append(unit)


func _package_units() -> Array:
	var units = []
	for idx in range(_anim.get_track_count()):
		var np = str(_anim.track_get_path(idx)).split(":")[0]
		_add_unit(_root.get_node_or_null(np), units)
		if _anim.track_get_type(idx) == Animation.TYPE_VALUE:       # camera cuts store camera paths as values
			for k in range(_anim.track_get_key_count(idx)):
				var v = _anim.track_get_key_value(idx, k)
				if v is NodePath and str(v) != "":
					_add_unit(_director.get_node_or_null(v), units)
	# a unit inside another unit is already part of that copy
	var out = []
	for u in units:
		var nested = false
		for v in units:
			if v != u and v.is_a_parent_of(u):
				nested = true
		if not nested:
			out.append(u)
	return out


# The parent inside the package for `n`: its ancestors are created as empty placeholders ("stubs").
func _pack_parent(pack_root: Node, n: Node) -> Node:
	var chain = []
	var cur = n.get_parent()
	while cur != null and cur != _root:
		chain.push_front(cur)
		cur = cur.get_parent()
	var parent = pack_root
	for orig in chain:
		var ex = parent.get_node_or_null(NodePath(str(orig.name)))
		if ex == null:
			ex = Spatial.new() if orig is Spatial else Node.new()
			ex.name = orig.name
			if orig is Spatial:
				ex.transform = orig.transform
			ex.set_meta(PKG_STUB, true)
			parent.add_child(ex)
		parent = ex
	return parent


func _own_all(n: Node, o: Node) -> void:
	for c in n.get_children():
		c.owner = o
		if c.filename == "":
			_own_all(c, o)


func _no_current_cameras(n: Node) -> void:
	for c in n.get_children():
		if c is Camera:
			c.current = false
		if c.filename == "":
			_no_current_cameras(c)


func _gather_assets(path: String) -> Array:
	var out = []
	for d in ResourceLoader.get_dependencies(path):
		var dp = str(d).split("::")[0]
		if dp.begins_with("res://addons/cinematic_editor") or out.has(dp):
			continue
		out.append(dp)
	return out


func _export_package(path: String) -> void:
	var pack_root = Spatial.new()
	pack_root.name = "CutscenePackage"
	var units = _package_units()
	var node_names = []
	for u in units:
		var parent = _pack_parent(pack_root, u)
		var copy = u.duplicate(15)          # signals + groups + scripts + instancing
		copy.name = u.name
		parent.add_child(copy)
		node_names.append(_chain_path(u, _root))
	# the director with just this cutscene
	var d = DirectorScript.new()
	d.name = _director.name
	for prop in ["show_subtitles", "subtitle_font", "subtitle_color", "shake_scale", "shakify_seed", "shakify_global_scale"]:
		d.set(prop, _director.get(prop))
	d.autoplay_cutscene = _anim_name if _director.autoplay_cutscene == _anim_name else ""
	var pl = AnimationPlayer.new()
	pl.name = _player.name
	d.add_child(pl)
	pl.root_node = _player.root_node
	var a = _anim.duplicate(true)
	if _anim.has_meta(SRC_META):
		a.set_meta(SRC_META, _anim.get_meta(SRC_META).duplicate(true))
	if _anim.has_meta(AUD_META):
		a.set_meta(AUD_META, _anim.get_meta(AUD_META).duplicate(true))
	pl.add_animation(_anim_name, a)
	for c in _director.get_children():
		if c is AnimationPlayer or c is CanvasLayer:
			continue
		var cc = c.duplicate(15)
		cc.name = c.name
		d.add_child(cc)
	_pack_parent(pack_root, _director).add_child(d)
	_own_all(pack_root, pack_root)
	_no_current_cameras(pack_root)
	var meta = {"version": 1, "cutscene": _anim_name, "nodes": node_names, "assets": []}
	pack_root.set_meta(PKG_META, meta)
	var ps = PackedScene.new()
	var err = ps.pack(pack_root)
	if err == OK:
		err = ResourceSaver.save(path, ps)
	if err == OK:                                  # second pass: remember which asset files the package uses
		meta["assets"] = _gather_assets(path)
		pack_root.set_meta(PKG_META, meta)
		ps = PackedScene.new()
		err = ps.pack(pack_root)
		if err == OK:
			err = ResourceSaver.save(path, ps)
	pack_root.free()
	if err != OK:
		_say("Could not save the package (error %d)." % err)
		return
	editor.get_resource_filesystem().scan()
	_say("Saved %s: cutscene '%s', %d node group(s), %d asset file(s)." % [path, _anim_name, node_names.size(), meta["assets"].size()])


func _unstub(n: Node) -> void:
	if n.has_meta(PKG_STUB):
		n.remove_meta(PKG_STUB)
	for c in n.get_children():
		_unstub(c)


func _merge_children(src: Node, dst: Node, skip, report: Dictionary) -> void:
	for c in src.get_children():
		if c == skip:
			continue
		var ex = dst.get_node_or_null(NodePath(str(c.name)))
		if ex == null:
			src.remove_child(c)
			dst.add_child(c)
			c.owner = _root
			if c.filename == "":
				_own_all(c, _root)
			_unstub(c)
			report["added"].append(str(c.name))
		elif c.has_meta(PKG_STUB):
			_merge_children(c, ex, null, report)
		else:
			report["kept"].append(str(c.name))


func _import_package(path: String) -> void:
	if _root == null or _director == null or _player == null:
		_say("Open a scene with a Cinematic director first.")
		return
	var ps = load(path)
	if not (ps is PackedScene):
		_say("That file is not a scene.")
		return
	var inst = ps.instance()
	if inst == null or not inst.has_meta(PKG_META):
		_say("That scene is not a cutscene package (use 'Save cutscene package...' to make one).")
		if inst != null:
			inst.free()
		return
	var meta = inst.get_meta(PKG_META)
	var pkg_dir = null
	for c in inst.get_children():
		if c.get_script() == DirectorScript:
			pkg_dir = c
	var pkg_player = null
	if pkg_dir != null:
		for c in pkg_dir.get_children():
			if c is AnimationPlayer:
				pkg_player = c
	if pkg_player == null or pkg_player.get_animation_list().size() == 0:
		_say("The package has no cutscene in it.")
		inst.free()
		return
	var cname = str(meta.get("cutscene", ""))
	if not pkg_player.has_animation(cname):
		cname = pkg_player.get_animation_list()[0]
	var anim = pkg_player.get_animation(cname).duplicate(true)
	if pkg_player.get_animation(cname).has_meta(SRC_META):
		anim.set_meta(SRC_META, pkg_player.get_animation(cname).get_meta(SRC_META).duplicate(true))
	if pkg_player.get_animation(cname).has_meta(AUD_META):
		anim.set_meta(AUD_META, pkg_player.get_animation(cname).get_meta(AUD_META).duplicate(true))
	# if the director has another name / place in this scene, point the tracks at it
	var old_dir = _chain_path(pkg_dir, inst)
	var new_dir = _chain_path(_director, _root)
	if old_dir != new_dir:
		for i in range(anim.get_track_count()):
			var tp = str(anim.track_get_path(i))
			if tp == old_dir or tp.begins_with(old_dir + ":") or tp.begins_with(old_dir + "/"):
				anim.track_set_path(i, NodePath(new_dir + tp.substr(old_dir.length())))
	# nodes (cameras, animated nodes, players...) that this scene does not have yet
	var report = {"added": [], "kept": []}
	_merge_children(inst, _root, pkg_dir, report)
	for c in pkg_dir.get_children():                 # extras under the director, e.g. the Voice player
		if c is AnimationPlayer or c is CanvasLayer:
			continue
		if _director.get_node_or_null(NodePath(str(c.name))) == null:
			pkg_dir.remove_child(c)
			_director.add_child(c)
			c.owner = _root
			if c.filename == "":
				_own_all(c, _root)
	var nm = cname
	var n = 2
	while _player.has_animation(nm):
		nm = "%s_%d" % [cname, n]
		n += 1
	_player.add_animation(nm, anim)
	inst.free()
	var missing = []
	for ap in meta.get("assets", []):
		if not ResourceLoader.exists(str(ap)):
			missing.append(str(ap))
	_anim_name = nm
	_last_snap = {}
	_refresh_cutscenes()
	_refresh_cameras()
	for i in range(_cut_opt.get_item_count()):
		if _cut_opt.get_item_text(i) == nm:
			_cut_opt.select(i)
			_use_cutscene(nm)
			break
	if editor.has_method("mark_scene_as_unsaved"):
		editor.mark_scene_as_unsaved()
	var msg = "Imported cutscene '%s': %d node(s) added, %d already in the scene (kept)." % [nm, report["added"].size(), report["kept"].size()]
	if not missing.empty():
		msg += "  Missing %d asset file(s), e.g. %s" % [missing.size(), missing[0]]
	_say(msg + "  Save the scene to keep it.")


# ------------------------------------------------------------ timeline length

func _set_length(v: float, commit: bool) -> void:
	if _anim == null:
		return
	v = clamp(v, 0.1, 3600.0)
	_anim.length = v
	_syncing = true
	_len_spin.value = v
	_syncing = false
	_sheet.update()
	if commit:
		_mark_changed("Cutscene length")
		_say("Cutscene length is now %.1fs" % v)


func _on_extend(amount: float) -> void:
	if _anim == null:
		_say("Create or pick a cutscene first.")
		return
	_set_length(_anim.length + amount, true)


# A bare Viewport has NO shadow atlas (size 0), so Spot and Omni light shadows are never drawn in it.
# Give it the same shadow / antialiasing settings the project uses, so the cinematic views look like the game.
func _setup_viewport(vp: Viewport) -> void:
	vp.own_world = false
	vp.usage = Viewport.USAGE_3D
	vp.hdr = true
	var atlas = 4096
	if ProjectSettings.has_setting("rendering/quality/shadow_atlas/size"):
		atlas = int(ProjectSettings.get_setting("rendering/quality/shadow_atlas/size"))
	vp.shadow_atlas_size = atlas if atlas > 0 else 4096
	var quads = [2, 2, 3, 4]       # the engine defaults: 4x4, 4x4, 16x16, 64x64 shadow slots
	for i in range(4):
		var key = "rendering/quality/shadow_atlas/quadrant_%d_subdiv" % i
		if ProjectSettings.has_setting(key):
			quads[i] = int(ProjectSettings.get_setting(key))
	vp.shadow_atlas_quad_0 = quads[0]
	vp.shadow_atlas_quad_1 = quads[1]
	vp.shadow_atlas_quad_2 = quads[2]
	vp.shadow_atlas_quad_3 = quads[3]
	if ProjectSettings.has_setting("rendering/quality/filters/msaa"):
		vp.msaa = int(ProjectSettings.get_setting("rendering/quality/filters/msaa"))


# One pane = title row + a dark holder + a "frame" (resized by code) with a ViewportContainer in it.
func _make_pane(title: String, parent: Node) -> Dictionary:
	var box = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(box)
	var header = HBoxContainer.new()
	box.add_child(header)
	var t = _label(title, header)
	t.add_color_override("font_color", Color(0.6, 0.8, 1.0))
	var holder = Control.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.rect_min_size = Vector2(120, 140)
	holder.rect_clip_content = true
	box.add_child(holder)
	var bg = ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.09)
	bg.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	holder.add_child(bg)
	var frame = Control.new()
	holder.add_child(frame)
	var vc = ViewportContainer.new()
	vc.stretch = true
	frame.add_child(vc)
	vc.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	var vp = Viewport.new()
	vp.gui_disable_input = true
	vp.physics_object_picking = false
	vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
	_setup_viewport(vp)
	vc.add_child(vp)
	return {"header": header, "holder": holder, "frame": frame, "container": vc, "viewport": vp}


func _build_ui() -> void:
	_no_scene_label = _label("Open a 3D scene to start a cutscene.", self)
	_no_scene_label.align = Label.ALIGN_CENTER

	_setup_box = VBoxContainer.new()
	add_child(_setup_box)
	_label("This scene has no cutscene director yet.", _setup_box)
	_button("Add Cinematic to this scene", _setup_box, "_on_add_director")

	_main_box = HSplitContainer.new()
	_main_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_main_box)

	# ---- left: transport, the two views, timeline, keys
	var left = VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_box.add_child(left)

	var top = HBoxContainer.new()
	left.add_child(top)
	_cut_opt = OptionButton.new()
	_cut_opt.connect("item_selected", self, "_on_cutscene_selected")
	_cut_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_cut_opt)
	_icon_button(["Add"], "New", "New cutscene", top, "_on_new_cutscene")
	_icon_button(["Remove", "Close"], "Delete", "Delete this cutscene", top, "_on_delete_cutscene")
	_label("Length (s)", top)
	_len_spin = SpinBox.new()
	_len_spin.min_value = 0.1
	_len_spin.max_value = 3600
	_len_spin.step = 0.1
	_len_spin.value = 10
	_len_spin.connect("value_changed", self, "_on_length_changed")
	top.add_child(_len_spin)
	_loop_check = CheckBox.new()
	_loop_check.text = "Loop"
	_loop_check.connect("toggled", self, "_on_loop_toggled")
	top.add_child(_loop_check)
	_inspector_btn = _button("Hide inspector", top, "_on_toggle_inspector")

	var views = HBoxContainer.new()
	views.size_flags_vertical = Control.SIZE_EXPAND_FILL
	views.size_flags_stretch_ratio = 3.0
	left.add_child(views)

	# editor view (left)
	_edit_pane = _make_pane("Editor view", views)
	_edit_viewport = _edit_pane["viewport"]
	_edit_cam = Camera.new()
	_edit_cam.fov = 70.0
	_edit_cam.near = 0.05
	_edit_cam.far = 2000.0
	_edit_viewport.add_child(_edit_cam)
	_edit_cam.current = true
	_gizmo = ImmediateGeometry.new()
	var mat = SpatialMaterial.new()
	mat.flags_unshaded = true
	mat.vertex_color_use_as_albedo = true
	mat.flags_no_depth_test = true
	_gizmo.material_override = mat
	_gizmo.layers = GIZMO_LAYER
	_gizmo.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
	_edit_viewport.add_child(_gizmo)
	_tgizmo = ImmediateGeometry.new()
	# The transform gizmo and the selection box are solid, flat-coloured triangles (not 1px lines).
	var tmat = SpatialMaterial.new()
	tmat.flags_unshaded = true
	tmat.vertex_color_use_as_albedo = true
	tmat.vertex_color_is_srgb = true
	tmat.flags_transparent = true
	tmat.flags_no_depth_test = true
	tmat.params_cull_mode = SpatialMaterial.CULL_DISABLED
	tmat.render_priority = 100
	_tgizmo.material_override = tmat
	_tgizmo.layers = GIZMO_LAYER
	_tgizmo.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
	_edit_viewport.add_child(_tgizmo)
	var gz_group = ButtonGroup.new()
	var gz_names = ["Off", "All", "Move", "Rotate", "Scale"]
	var gz_modes = [0, 4, 1, 2, 3]
	var gz_icons = [["GuiVisibilityHidden", "Close"], ["Transform", "Object"], ["ToolMove"], ["ToolRotate"], ["ToolScale"]]
	var gz_tips = ["No gizmo", "All: move + rotate  [A]", "Move handles", "Rotate handles", "Scale handles"]
	for gi in range(5):
		var gb = Button.new()
		var gic = _icon(gz_icons[gi])
		if gic != null:
			gb.icon = gic
		else:
			gb.text = gz_names[gi]
		gb.toggle_mode = true
		gb.group = gz_group
		gb.pressed = gz_modes[gi] == _gz_mode
		gb.hint_tooltip = "%s  (drag a handle; hold Ctrl to snap). Or hover the view and press G / R / S, then X / Y / Z." % gz_tips[gi]
		gb.connect("pressed", self, "_on_gz_mode", [gz_modes[gi]])
		_gz_buttons[gz_modes[gi]] = gb
		_edit_pane["header"].add_child(gb)
	var gl = CheckBox.new()
	gl.text = "Local"
	gl.hint_tooltip = "Move / rotate along the node's own axes instead of the world axes."
	gl.connect("toggled", self, "_on_gz_local")
	_edit_pane["header"].add_child(gl)
	_edit_pane["container"].connect("gui_input", self, "_on_edit_gui_input")

	# result view (right)
	_res_pane = _make_pane("Result", views)
	_pv_chosen_check = CheckBox.new()
	_pv_chosen_check.text = "show chosen camera"
	_pv_chosen_check.hint_tooltip = "Off: the result follows the cutscene.  On: it shows the selected / chosen camera instead (handy while placing a camera before cutting to it)."
	_res_pane["header"].add_child(_pv_chosen_check)
	_viewport = _res_pane["viewport"]
	_preview_cam = Camera.new()
	_viewport.add_child(_preview_cam)
	_preview_cam.current = true
	_preview_msg = Label.new()
	_preview_msg.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	_preview_msg.align = Label.ALIGN_CENTER
	_preview_msg.valign = Label.VALIGN_CENTER
	_preview_msg.text = "Add a Camera to the scene to see a preview."
	_res_pane["frame"].add_child(_preview_msg)
	_subtitle_label = Label.new()
	_subtitle_label.anchor_left = 0.05
	_subtitle_label.anchor_right = 0.95
	_subtitle_label.anchor_top = 0.78
	_subtitle_label.anchor_bottom = 0.96
	_subtitle_label.align = Label.ALIGN_CENTER
	_subtitle_label.valign = Label.VALIGN_BOTTOM
	_subtitle_label.autowrap = true
	_subtitle_label.add_color_override("font_color_shadow", Color(0, 0, 0, 0.9))
	_subtitle_label.add_constant_override("shadow_offset_x", 2)
	_subtitle_label.add_constant_override("shadow_offset_y", 2)
	_res_pane["frame"].add_child(_subtitle_label)

	var transport = HBoxContainer.new()
	left.add_child(transport)
	_icon_button(["PlayStart", "PlayStartBackwards"], "|<", "Back to the start", transport, "_on_to_start")
	_play_btn = _icon_button(["Play"], "Play", "Play / pause", transport, "_on_play_pressed")
	_icon_button(["Stop"], "Stop", "Stop and go back to the start", transport, "_on_stop")
	_time_label = _label("0:00.00", transport)
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	transport.add_child(spacer)
	_label("Length", transport).modulate = Color(1, 1, 1, 0.6)
	for amt in [1.0, 5.0, 10.0]:
		var lb = _button("+%ds" % int(amt), transport, "_on_extend", [amt])
		lb.hint_tooltip = "Make the cutscene %d second(s) longer. You can also drag the orange end marker on the ruler." % int(amt)
	_fx_menu = MenuButton.new()
	_fx_menu.hint_tooltip = "Show or hide effect rows in the timeline"
	transport.add_child(_fx_menu)
	var pop = _fx_menu.get_popup()
	pop.set("hide_on_checkable_item_selection", false)
	for i in range(FX_LIST.size()):
		pop.add_check_item(FX_LIST[i][1], i)
		pop.set_item_checked(i, true)
	pop.add_separator()
	pop.add_item("Show all", 100)
	pop.add_item("Hide all", 101)
	pop.connect("id_pressed", self, "_on_fx_menu")
	_update_fx_menu()
	_button("Fit", transport, "_on_fit_view").hint_tooltip = "Show the whole cutscene in the timeline"
	var prev_btn = _button("<>", transport, "_on_prev_key")
	prev_btn.text = "< key"
	prev_btn.hint_tooltip = "Jump to the previous key"
	var next_btn = _button("key >", transport, "_on_next_key")
	next_btn.hint_tooltip = "Jump to the next key"

	_sheet = Control.new()
	_sheet.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sheet.size_flags_stretch_ratio = 2.0
	_sheet.rect_min_size = Vector2(200, 170)
	_sheet.rect_clip_content = true
	_sheet.focus_mode = Control.FOCUS_CLICK
	_sheet.connect("draw", self, "_sheet_draw")
	_sheet.connect("gui_input", self, "_sheet_input")
	left.add_child(_sheet)
	var key_row = HBoxContainer.new()
	left.add_child(key_row)
	_button("Delete selected key / track", key_row, "_on_delete_key")
	_button("Clear all keys on this cutscene", key_row, "_on_clear_all")
	_button("Loop audio [L]", key_row, "_toggle_audio_loop").hint_tooltip = "Turn looping on / off for the selected audio key(s). Drag the white handle at the end of an audio bar to set its length."
	_button("Copy keys", key_row, "_on_copy_keys").hint_tooltip = "Copy the selected keys (Ctrl+C in the timeline)."
	_button("Paste keys", key_row, "_on_paste_keys").hint_tooltip = "Paste the copied keys so the first one lands on the playhead (Ctrl+V in the timeline)."
	var pkg_save = _button("Save cutscene package...", key_row, "_on_export_package")
	pkg_save.hint_tooltip = "Saves this cutscene together with every node it uses (cameras, animated nodes, audio players) as a .tscn you can import into any scene."
	var pkg_load = _button("Import package...", key_row, "_on_import_package")
	pkg_load.hint_tooltip = "Adds a saved cutscene package to this scene: its nodes, cameras and the cutscene itself."

	# ---- right: tools (the "inspector" the button above hides)
	_right_scroll = ScrollContainer.new()
	_right_scroll.rect_min_size = Vector2(310, 0)
	_right_scroll.scroll_horizontal_enabled = false
	_main_box.add_child(_right_scroll)
	var right = VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_constant_override("separation", 8)
	_right_scroll.add_child(right)

	_status = _label("", right)
	_status.autowrap = true
	_status.add_color_override("font_color", Color(0.75, 0.9, 0.75))

	# Two tabs: "Nodes" (node list + the inspector of the selected node) and "Composition" (cutscene tools,
	# every category a card that can be reordered by dragging its handle).
	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.tab_align = TabContainer.ALIGN_LEFT
	right.add_child(_tabs)
	var nodes_page = VBoxContainer.new()
	nodes_page.name = "Nodes"
	nodes_page.add_constant_override("separation", 8)
	_tabs.add_child(nodes_page)
	_cards_box = VBoxContainer.new()
	_cards_box.name = "Composition"
	_cards_box.add_constant_override("separation", 8)
	_tabs.add_child(_cards_box)

	# ---- Camera shots
	var sec = _section("Camera shots", _cards_box, true)
	var cam_row = _form(sec, "Camera")
	_cam_opt = OptionButton.new()
	_cam_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cam_row.add_child(_cam_opt)
	_button("Refresh", cam_row, "_refresh_cameras")
	_button("Cut to this camera", sec, "_on_cut_camera")

	# ---- Camera movement
	sec = _section("Camera movement", _cards_box, true)
	var view_row = HBoxContainer.new()
	sec.add_child(view_row)
	var b1 = _button("Camera -> View", view_row, "_on_camera_to_view")
	b1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b1.hint_tooltip = "Move the camera to where the Editor view is."
	var b2 = _button("View -> Camera", view_row, "_on_view_to_camera")
	b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b2.hint_tooltip = "Move the Editor view to the camera (look through it)."

	_interp_opt = OptionButton.new()
	_interp_opt.add_item("Smooth (linear)")
	_interp_opt.add_item("Smooth (cubic)")
	_interp_opt.add_item("Constant (hold, then cut)")
	_interp_opt.hint_tooltip = "How the camera travels from THIS key to the NEXT one.\nSmooth: it tweens.  Constant: it stays on this pose, then jumps (cuts) when the next key arrives.\nCubic/linear is shared by the whole track. Also used by 'Key transform' below."
	_form_ctl(sec, "Interpolation", _interp_opt)
	_into_check = CheckBox.new()
	_into_check.text = "On"
	_into_check.pressed = true
	_into_check.hint_tooltip = "On: when you key a pose, the dropdown decides how the camera travels from the PREVIOUS key to this new one (Constant = it waits, then cuts to the new pose).\nOff: the dropdown only decides how the camera leaves the key you are adding (towards a key you add later)."
	_form_ctl(sec, "Move into key", _into_check, "Applies to the move INTO the new key")

	var key_btn = _button("Key camera pose   [I]", sec, "_on_key_camera_pose")
	key_btn.hint_tooltip = "Keys the camera's current pose at the playhead. Shortcut: I (while the Cinematic tab is open)."
	_button("Apply to selected pose key(s)", sec, "_on_apply_interp")
	sec.add_child(HSeparator.new())
	_move_dur_spin = _form_spin(sec, "Over (s)", 0.05, 600, 0.05, 2.0)
	_button("Move camera to Editor view over time", sec, "_on_move_to_view")

	# ---- Nodes (every part is a card you can fold, like the Composition tab)
	_sel_label = _label("Nothing selected", nodes_page)
	_sel_label.autowrap = true
	_sel_label.modulate = Color(1, 1, 1, 0.7)

	sec = _section("Node list", nodes_page, true, "", false)
	var nf_row = HBoxContainer.new()
	sec.add_child(nf_row)
	_node_filter = LineEdit.new()
	_node_filter.placeholder_text = "Filter nodes..."
	_node_filter.clear_button_enabled = true
	_node_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_node_filter.connect("text_changed", self, "_on_node_filter")
	nf_row.add_child(_node_filter)
	_button("Refresh", nf_row, "_refresh_node_list")
	_eye_on = _icon(["GuiVisibilityVisible", "Visible"])
	_eye_off = _icon(["GuiVisibilityHidden", "Hidden"])
	_node_list = Tree.new()
	_node_list.rect_min_size = Vector2(0, 170)
	_node_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_node_list.columns = 2
	_node_list.hide_root = true
	_node_list.hide_folding = true
	_node_list.select_mode = Tree.SELECT_MULTI
	_node_list.set_column_expand(0, true)
	_node_list.set_column_expand(1, false)
	_node_list.set_column_min_width(1, 28)
	_node_list.connect("multi_selected", self, "_on_node_list_selected")
	_node_list.connect("button_pressed", self, "_on_node_eye_pressed")
	sec.add_child(_node_list)

	# position / rotation / scale of the first selected node
	sec = _section("Transform", nodes_page, true, "", false)
	_xform_card = sec.get_parent().get_parent()
	_xform_box = VBoxContainer.new()
	_xform_box.add_constant_override("separation", 6)
	sec.add_child(_xform_box)
	var attr_names = ["Position", "Rotation", "Scale"]
	var attr_tips = ["Position", "Rotation (degrees)", "Scale"]
	var attr_props = ["translation", "rotation_degrees", "scale"]
	var attr_steps = [0.001, 0.01, 0.001]
	var axis_names = ["X", "Y", "Z"]
	for a in range(3):
		var xf_row = HBoxContainer.new()
		xf_row.add_constant_override("separation", 8)
		_xform_box.add_child(xf_row)
		var xf_lab = _label(attr_names[a], xf_row)
		xf_lab.align = Label.ALIGN_RIGHT
		xf_lab.valign = Label.VALIGN_TOP
		xf_lab.rect_min_size = Vector2(FORM_LABEL_W, 26)
		xf_lab.modulate = Color(1, 1, 1, 0.85)
		xf_lab.hint_tooltip = attr_tips[a]
		xf_lab.mouse_filter = Control.MOUSE_FILTER_STOP
		var xf_col = VBoxContainer.new()
		xf_col.add_constant_override("separation", 2)
		xf_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		xf_row.add_child(xf_col)
		var spins = []
		for ax in range(3):
			var sp = _spin(xf_col, -1000000, 1000000, attr_steps[a], 1.0 if a == 2 else 0.0)
			sp.allow_greater = true
			sp.allow_lesser = true
			sp.prefix = axis_names[ax]
			sp.connect("value_changed", self, "_on_xform_edited", [attr_props[a], ax])
			spins.append(sp)
		_xf_spins.append(spins)
		var xf_key = _icon_button(["KeyValue", "Key"], "Key", "Key position, rotation and scale at the playhead (one transform key)", xf_row, "_on_key_transform")
		xf_key.flat = true
		xf_key.size_flags_vertical = 0   # 0 = shrink to the top of the row
	_xform_box.visible = false
	_xform_card.visible = false
	_button("Key transform (pos, rot, scale)", sec, "_on_key_transform")

	# MetaHuman tab: the face board itself + key buttons. Hidden unless the scene has a MetaHumanFaceBoard3D.
	_mh_page = VBoxContainer.new()
	_mh_page.name = "MetaHuman"
	_mh_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.add_child(_mh_page)
	_face_label = _hint("", _mh_page)
	var face_key = _button("Key face pose  [I]", _mh_page, "_on_key_face_pose")
	face_key.hint_tooltip = "Keys every face control that is in use (or already animated) at the playhead."
	_face_auto = CheckBox.new()
	_face_auto.text = "Auto-key when I release a dot"
	_face_auto.hint_tooltip = "Drag a yellow dot on the board (here or in the Editor view); the pose is keyed when you let go."
	_mh_page.add_child(_face_auto)
	_button("Reset face (all controls to 0)", _mh_page, "_on_reset_face")
	_mh_holder = VBoxContainer.new()
	_mh_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mh_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mh_page.add_child(_mh_holder)
	_tabs.set_tab_hidden(_mh_page.get_index(), true)

	# AnimationPlayers found on the selected node
	sec = _section("Animation to play", nodes_page, true, "", false)
	_ap_card = sec.get_parent().get_parent()
	_ap_none = Label.new()
	_ap_none.visible = false
	sec.add_child(_ap_none)
	_ap_box = VBoxContainer.new()
	_ap_box.add_constant_override("separation", 4)
	sec.add_child(_ap_box)
	_ap_player_opt = OptionButton.new()
	_ap_player_opt.hint_tooltip = "AnimationPlayer found on / under the selected node."
	_ap_player_opt.connect("item_selected", self, "_on_ap_player_selected")
	_form_ctl(_ap_box, "Player", _ap_player_opt)
	_ap_anim_opt = OptionButton.new()
	_ap_anim_opt.connect("item_selected", self, "_on_ap_anim_selected")
	_form_ctl(_ap_box, "Animation", _ap_anim_opt)
	_ap_info = _hint("", _ap_box)
	var ap_btns = HBoxContainer.new()
	_ap_box.add_child(ap_btns)
	var ap_play = _button("Key: play animation", ap_btns, "_on_key_play_animation")
	ap_play.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ap_play.hint_tooltip = "Adds a key at the playhead that starts the chosen animation."
	var ap_stop = _button("Key: stop", ap_btns, "_on_key_stop_animation")
	ap_stop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ap_stop.hint_tooltip = "Adds a key at the playhead that stops that AnimationPlayer."
	_ap_box.visible = false
	_ap_card.visible = false

	sec = _section("Properties", nodes_page, true, "", false)
	_ins_filter = LineEdit.new()
	_ins_filter.placeholder_text = "Filter properties..."
	_ins_filter.clear_button_enabled = true
	_ins_filter.connect("text_changed", self, "_on_ins_filter")
	sec.add_child(_ins_filter)
	_ins_box = VBoxContainer.new()
	_ins_box.add_constant_override("separation", 2)
	sec.add_child(_ins_box)
	_rebuild_inspector()

	# ---- FOV
	var fx = _cards_box
	sec = _section("FOV", fx, false, "fov")
	_fov_spin = _form_spin(sec, "Target", 1, 179, 0.5, 60)
	_fov_dur_spin = _form_spin(sec, "Over (s)", 0.05, 600, 0.05, 1.0)
	var fov_btns = HBoxContainer.new()
	sec.add_child(fov_btns)
	_button("Key FOV now", fov_btns, "_on_key_fov_now").size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button("Add FOV change", fov_btns, "_on_fov_change").size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# ---- Camera shake
	sec = _section("Camera shake", fx, false, "shake")
	_shake_amount = _form_spin(sec, "Strength", 0.05, 5, 0.05, 1.0)
	_shake_dur = _form_spin(sec, "Time (s)", 0.1, 60, 0.1, 0.6)
	_button("Add shake", sec, "_on_add_shake")

	# ---- Shakify
	sec = _section("Shakify (handheld)", fx, false, "shakify")
	_sk_preset = OptionButton.new()
	for pr in DirectorScript.SHAKIFY_PRESETS:
		_sk_preset.add_item(pr["name"])
	_sk_preset.hint_tooltip = "The kind of camera motion. Handheld / Breathing are gentle, Walk / Jog / Run add footstep bobbing."
	_form_ctl(sec, "Preset", _sk_preset)
	_sk_influence = _form_spin(sec, "Influence", 0.0, 3.0, 0.05, 1.0)
	_sk_scale = _form_spin(sec, "Scale", 0.05, 10.0, 0.05, 1.0)
	_sk_speed = _form_spin(sec, "Speed", 0.1, 5.0, 0.05, 1.0)
	_sk_dur = _form_spin(sec, "Time (s)", 0.1, 3600, 0.1, 3.0)
	_sk_fade_in = _form_spin(sec, "Fade in", 0.0, 60, 0.05, 0.3)
	_sk_fade_out = _form_spin(sec, "Fade out", 0.0, 60, 0.05, 0.5)
	_button("Add Shakify at playhead", sec, "_on_add_shakify", [false])
	_button("Shakify the whole cutscene", sec, "_on_add_shakify", [true])

	# ---- Dialogue
	sec = _section("Dialogue / subtitles", fx, false, "dialogue")
	_speaker_edit = LineEdit.new()
	_speaker_edit.placeholder_text = "Speaker (optional)"
	_form_ctl(sec, "Speaker", _speaker_edit)
	_text_edit = LineEdit.new()
	_text_edit.placeholder_text = "What is said"
	_form_ctl(sec, "Text", _text_edit)
	_text_dur = _form_spin(sec, "Shown for (s)", 0, 60, 0.1, 0.0)
	_text_dur.hint_tooltip = "0 = automatic length"
	_button("Add subtitle", sec, "_on_add_subtitle")

	# ---- Subtitle look
	sec = _section("Subtitle look", fx, false)
	var font_row = _form(sec, "Font")
	_font_path_edit = LineEdit.new()
	_font_path_edit.editable = false
	_font_path_edit.text = "Default font"
	_font_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	font_row.add_child(_font_path_edit)
	_button("Font...", font_row, "_on_choose_font")
	_button("Reset", font_row, "_on_reset_font")
	_font_size_spin = _form_spin(sec, "Size", 8, 200, 1, 32)
	_font_size_spin.connect("value_changed", self, "_on_font_size_changed")
	_sub_color_btn = ColorPickerButton.new()
	_sub_color_btn.rect_min_size = Vector2(40, 24)
	_sub_color_btn.color = Color(1, 1, 1)
	_sub_color_btn.connect("color_changed", self, "_on_sub_color_changed")
	_sub_color_btn.connect("popup_closed", self, "_on_sub_color_done")
	_form_ctl(sec, "Color", _sub_color_btn)

	# ---- Audio
	sec = _section("Audio (voice lines)", fx, false, "audio")
	var audio_row = _form(sec, "File")
	_audio_path_edit = LineEdit.new()
	_audio_path_edit.editable = false
	_audio_path_edit.placeholder_text = "no audio file chosen"
	_audio_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	audio_row.add_child(_audio_path_edit)
	_button("Browse...", audio_row, "_on_choose_audio")
	_button("Play / stop", sec, "_on_test_audio")
	_audio_sub_check = CheckBox.new()
	_audio_sub_check.text = "Add dialogue text"
	_audio_sub_check.pressed = true
	_form_ctl(sec, "Subtitle", _audio_sub_check, "Also add the dialogue text as a subtitle")
	_audio_loop_check = CheckBox.new()
	_audio_loop_check.text = "Loop"
	_audio_loop_check.hint_tooltip = "Off: the audio plays once. On: it repeats until the length you drag in the timeline (or the end of the cutscene).\nYou can change this later: select the audio key in the timeline and press L, or right-click it."
	_form_ctl(sec, "Loop", _audio_loop_check, "Repeat the audio")
	_button("Add audio at playhead", sec, "_on_add_audio")

	_load_card_order()

	# shared helpers that live under the panel
	_test_player = AudioStreamPlayer.new()
	add_child(_test_player)
	_file_dialog = FileDialog.new()
	_file_dialog.mode = FileDialog.MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.connect("file_selected", self, "_on_file_selected")
	add_child(_file_dialog)
	_save_dialog = FileDialog.new()
	_save_dialog.mode = FileDialog.MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_RESOURCES
	_save_dialog.window_title = "Save cutscene package"
	_save_dialog.add_filter("*.tscn ; Cutscene package")
	_save_dialog.connect("file_selected", self, "_on_package_save_path")
	add_child(_save_dialog)
	_pkg_dialog = FileDialog.new()
	_pkg_dialog.mode = FileDialog.MODE_OPEN_FILE
	_pkg_dialog.access = FileDialog.ACCESS_RESOURCES
	_pkg_dialog.window_title = "Import cutscene package"
	_pkg_dialog.add_filter("*.tscn ; Cutscene package")
	_pkg_dialog.connect("file_selected", self, "_on_package_picked")
	add_child(_pkg_dialog)
	_build_new_dialog()
	_key_menu = PopupMenu.new()
	_key_menu.add_check_item("Loop this audio   [L]", 0)
	_key_menu.add_item("Reset audio length", 1)
	_key_menu.connect("id_pressed", self, "_on_key_menu")
	add_child(_key_menu)


func _say(text: String) -> void:
	_status.text = text


func _on_toggle_inspector() -> void:
	_right_scroll.visible = not _right_scroll.visible
	_inspector_btn.text = "Hide inspector" if _right_scroll.visible else "Show inspector"


# --------------------------------------------------------------- scene state

func _find_director(node: Node):
	for c in node.get_children():
		if c.get_script() == DirectorScript:
			return c
		var deeper = _find_director(c)
		if deeper != null:
			return deeper
	return null


func _refresh_scene() -> void:
	_root = editor.get_edited_scene_root()
	_no_scene_label.text = "Open a 3D scene to start a cutscene."
	if _root != null and not (_root is Spatial):
		_no_scene_label.text = "The Cinematic tab needs a 3D scene (the root node must be a Spatial)."
		_root = null
	_director = null
	_player = null
	_anim = null
	if _root != null:
		_director = _find_director(_root)
		if _director != null:
			_player = _director.get_node_or_null("Player")
			if _player == null:
				for c in _director.get_children():
					if c is AnimationPlayer:
						_player = c
						break
	# Track paths are relative to the scene root (_root). If the Cinematic node sits deeper than directly under it
	# (e.g. under "head"), the player's default root "../.." points at the wrong node and the game cannot find
	# any track ("Node not found: head/MetaHumanFaceBoard3D..."), so point it at the scene root explicitly.
	if _root != null and _player != null:
		var want = _player.get_path_to(_root)
		if _player.root_node != want:
			_player.root_node = want
			if editor.has_method("mark_scene_as_unsaved"):
				editor.mark_scene_as_unsaved()
	_no_scene_label.visible = _root == null
	_setup_box.visible = _root != null and (_director == null or _player == null)
	_main_box.visible = _director != null and _player != null
	if _main_box.visible:
		_viewport.world = _root.get_world()
		_edit_viewport.world = _root.get_world()
		_refresh_cutscenes()
		_refresh_cameras()
		_sync_look_ui()
		_refresh_node_list()
		_refresh_mh_tab(true)
		_on_selection_changed()
		if _root.get_instance_id() != _edit_root_id:
			_edit_root_id = _root.get_instance_id()
			_reset_edit_view()
	_say("")


func _on_add_director() -> void:
	if _root == null:
		return
	var director = DirectorScript.new()
	director.name = "Cinematic"
	var player = AnimationPlayer.new()
	player.name = "Player"
	director.add_child(player)
	player.root_node = NodePath("../..")     # track paths are relative to the scene root
	var voice = AudioStreamPlayer.new()
	voice.name = "Voice"
	director.add_child(voice)
	var anim = Animation.new()
	anim.length = 10.0
	player.add_animation("cutscene_1", anim)
	undo_redo.create_action("Add Cinematic")
	undo_redo.add_do_method(_root, "add_child", director)
	undo_redo.add_do_method(director, "set_owner", _root)
	undo_redo.add_do_method(player, "set_owner", _root)
	undo_redo.add_do_method(voice, "set_owner", _root)
	undo_redo.add_do_reference(director)
	undo_redo.add_undo_method(_root, "remove_child", director)
	undo_redo.commit_action()
	_refresh_scene()


# Records an undo step for the cutscene (Ctrl+Z / Ctrl+Y in the editor, or in the timeline).
# The cutscene is stored as a snapshot before / after the edit; undoing puts the snapshot back.
func _mark_changed(label: String) -> void:
	var recorded = false
	if _anim != null and _last_snap_name == _anim_name and not _last_snap.empty():
		var after = _snap()
		if str(after) != str(_last_snap):
			var before = _last_snap
			_committing = true                      # commit_action() runs the "do" call at once; skip it, the edit is already made
			undo_redo.create_action(label)
			undo_redo.add_do_method(self, "_apply_snap", _anim_name, after)
			undo_redo.add_undo_method(self, "_apply_snap", _anim_name, before)
			undo_redo.commit_action()
			_committing = false
			_last_snap = after
			recorded = true
	elif _anim != null:
		_last_snap = _snap()
		_last_snap_name = _anim_name
	if not recorded and editor.has_method("mark_scene_as_unsaved"):
		editor.mark_scene_as_unsaved()


func _snap() -> Dictionary:
	var tracks = []
	for i in range(_anim.get_track_count()):
		var type = _anim.track_get_type(i)
		var tr = {"type": type, "path": _anim.track_get_path(i), "interp": _anim.track_get_interpolation_type(i),
				"wrap": _anim.track_get_interpolation_loop_wrap(i), "enabled": _anim.track_is_enabled(i), "keys": []}
		if type == Animation.TYPE_VALUE:
			tr["update"] = _anim.value_track_get_update_mode(i)
		for k in range(_anim.track_get_key_count(i)):
			var key = {"t": _anim.track_get_key_time(i, k)}
			if type == Animation.TYPE_AUDIO:
				key["stream"] = _anim.audio_track_get_key_stream(i, k)
				key["so"] = _anim.audio_track_get_key_start_offset(i, k)
				key["eo"] = _anim.audio_track_get_key_end_offset(i, k)
			else:
				key["v"] = _anim.track_get_key_value(i, k)
				key["tr"] = _anim.track_get_key_transition(i, k)
			tr["keys"].append(key)
		tracks.append(tr)
	var meta = null
	if _anim.has_meta(SRC_META):
		meta = _anim.get_meta(SRC_META).duplicate(true)
	var aud = null
	if _anim.has_meta(AUD_META):
		aud = _anim.get_meta(AUD_META).duplicate(true)
	return {"length": _anim.length, "loop": _anim.loop, "tracks": tracks, "meta": meta, "aud": aud}


# Puts a snapshot back into the cutscene (this is what undo / redo call).
func _apply_snap(cutscene_name: String, snap: Dictionary) -> void:
	if _committing or _player == null or not _player.has_animation(cutscene_name):
		return
	var a = _player.get_animation(cutscene_name)
	while a.get_track_count() > 0:
		a.remove_track(0)
	a.length = snap["length"]
	a.loop = snap["loop"]
	for tr in snap["tracks"]:
		var i = a.add_track(tr["type"])
		a.track_set_path(i, tr["path"])
		a.track_set_interpolation_type(i, tr["interp"])
		a.track_set_interpolation_loop_wrap(i, tr["wrap"])
		a.track_set_enabled(i, tr["enabled"])
		if tr["type"] == Animation.TYPE_VALUE:
			a.value_track_set_update_mode(i, tr["update"])
		for key in tr["keys"]:
			if tr["type"] == Animation.TYPE_AUDIO:
				a.audio_track_insert_key(i, key["t"], key["stream"], key["so"], key["eo"])
			elif tr["type"] == Animation.TYPE_TRANSFORM:
				a.transform_track_insert_key(i, key["t"], key["v"]["location"], key["v"]["rotation"], key["v"]["scale"])
			else:
				a.track_insert_key(i, key["t"], key["v"], key["tr"])
	if a.has_meta(SRC_META):
		a.remove_meta(SRC_META)
	if snap["meta"] != null:
		a.set_meta(SRC_META, snap["meta"].duplicate(true))
	if a.has_meta(AUD_META):
		a.remove_meta(AUD_META)
	if snap.get("aud", null) != null:
		a.set_meta(AUD_META, snap["aud"].duplicate(true))
	if cutscene_name != _anim_name:                 # the edit was on another cutscene: switch to it
		for n in range(_cut_opt.get_item_count()):
			if _cut_opt.get_item_text(n) == cutscene_name:
				_cut_opt.select(n)
				_use_cutscene(cutscene_name, false)
				break
	_anim = a
	_last_snap = snap
	_last_snap_name = cutscene_name
	_sel = []
	_sel_track = -1
	_syncing = true
	_len_spin.value = a.length
	_loop_check.pressed = a.loop
	_syncing = false
	_load_fx_state()
	_refresh_keys()
	_seek(_time)
	_say("Cutscene restored.")


func _do_undo() -> void:
	if undo_redo.has_method("undo"):
		undo_redo.undo()


func _do_redo() -> void:
	if undo_redo.has_method("redo"):
		undo_redo.redo()


# ---------------------------------------------------------------- cutscenes

func _refresh_cutscenes() -> void:
	var previous = _anim_name
	_cut_opt.clear()
	var names = Array(_player.get_animation_list())
	names.sort()
	for n in names:
		_cut_opt.add_item(n)
	var pick = names.find(previous)
	if pick == -1:
		pick = 0
	if names.empty():
		_anim = null
		_anim_name = ""
		_refresh_keys()
		return
	_cut_opt.select(pick)
	_use_cutscene(names[pick], names[pick] != previous)


func _use_cutscene(cutscene_name: String, go_to_start: bool = true) -> void:
	_drag = null
	if go_to_start:
		_sel = []
		_sel_track = -1
		_view_fit = true
	_anim_name = cutscene_name
	_anim = _player.get_animation(cutscene_name)
	_syncing = true
	_len_spin.value = _anim.length
	_loop_check.pressed = _anim.loop
	_syncing = false
	if go_to_start:
		_time = 0.0
		_seek(0.0)
	else:
		_set_slider(_time)
	_load_fx_state()
	_refresh_keys()
	_last_snap = _snap()
	_last_snap_name = cutscene_name


func _on_cutscene_selected(index: int) -> void:
	_use_cutscene(_cut_opt.get_item_text(index))


func _build_new_dialog() -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.window_title = "New cutscene"
	_new_dialog.get_ok().text = "Create"
	var box = VBoxContainer.new()
	box.add_constant_override("separation", 6)
	box.rect_min_size = Vector2(320, 0)
	_new_dialog.add_child(box)
	_label("What should the new cutscene be called?", box)
	_new_name_edit = LineEdit.new()
	_new_name_edit.placeholder_text = "cutscene name"
	_new_name_edit.connect("text_changed", self, "_on_new_name_changed")
	_new_name_edit.connect("text_entered", self, "_on_new_name_entered")
	box.add_child(_new_name_edit)
	_new_name_warn = _label("", box)
	_new_name_warn.add_color_override("font_color", Color(1.0, 0.45, 0.4))
	_new_dialog.connect("confirmed", self, "_on_new_dialog_confirmed")
	add_child(_new_dialog)


# Shows a dialog in the middle of the editor window. (popup_centered() centres it inside this tab's
# parent, which put the windows in the top-left corner.)
func _popup_centered(dlg: Control, wanted: Vector2) -> void:
	var base = editor.get_base_control()
	var min_size = dlg.get_combined_minimum_size()
	var sz = Vector2(max(wanted.x, min_size.x), max(wanted.y, min_size.y))
	var pos = base.rect_global_position + ((base.rect_size - sz) * 0.5).floor()
	dlg.popup(Rect2(pos, sz))


# Opens the name window (the name is asked for here, not in the toolbar).
func _on_new_cutscene() -> void:
	if _player == null:
		_say("Add a Cinematic to this scene first.")
		return
	var n = 1
	while _player.has_animation("cutscene_%d" % n):
		n += 1
	_new_name_edit.text = "cutscene_%d" % n
	_on_new_name_changed(_new_name_edit.text)
	_popup_centered(_new_dialog, Vector2(380, 0))
	_new_name_edit.grab_focus()
	_new_name_edit.select_all()


# "" when the name can be used, otherwise what is wrong with it.
func _new_name_problem(cutscene_name: String) -> String:
	if cutscene_name == "":
		return "Enter a name."
	for bad in ["/", ":", ",", "["]:
		if cutscene_name.find(bad) != -1:
			return "The name can't contain  /  :  ,  [ "
	if _player != null and _player.has_animation(cutscene_name):
		return "A cutscene with that name already exists."
	return ""


func _on_new_name_changed(text: String) -> void:
	var problem = _new_name_problem(text.strip_edges())
	_new_dialog.get_ok().disabled = problem != ""
	_new_name_warn.text = "" if text.strip_edges() == "" else problem


func _on_new_name_entered(text: String) -> void:
	if _new_name_problem(text.strip_edges()) == "":
		_new_dialog.hide()
		_create_cutscene(text.strip_edges())


func _on_new_dialog_confirmed() -> void:
	var cutscene_name = _new_name_edit.text.strip_edges()
	if _new_name_problem(cutscene_name) == "":
		_create_cutscene(cutscene_name)


func _create_cutscene(cutscene_name: String) -> void:
	if _player == null or _new_name_problem(cutscene_name) != "":
		return
	var anim = Animation.new()
	anim.length = 10.0
	_player.add_animation(cutscene_name, anim)
	_anim_name = cutscene_name
	_mark_changed("New cutscene")
	_refresh_cutscenes()


func _on_delete_cutscene() -> void:
	if _anim == null:
		return
	_player.remove_animation(_anim_name)
	_last_snap = {}
	_anim_name = ""
	_mark_changed("Delete cutscene")
	_refresh_cutscenes()


func _on_length_changed(value: float) -> void:
	if _syncing or _anim == null:
		return
	_anim.length = value
	_mark_changed("Cutscene length")


func _on_loop_toggled(pressed: bool) -> void:
	if _syncing or _anim == null:
		return
	_anim.loop = pressed
	_mark_changed("Cutscene loop")


# ---------------------------------------------------------------- transport

func _fmt_time(t: float) -> String:
	return "%d:%05.2f" % [int(t) / 60, fmod(t, 60.0)]


func _seek(t: float) -> void:
	if _anim == null or _player == null:
		return
	_time = clamp(t, 0.0, _anim.length)
	_player.assigned_animation = _anim_name
	_player.seek(_time, true)
	if not _player.is_playing():
		_silence_audio()            # Godot starts audio on every seek; scrubbing should stay quiet
		_scrub_anim_players()
	_drive_face_tracks(_time)
	_set_slider(_time)


func _silence_audio() -> void:
	if _anim == null or _root == null:
		return
	for i in range(_anim.get_track_count()):
		if _anim.track_get_type(i) == Animation.TYPE_AUDIO:
			var n = _root.get_node_or_null(str(_anim.track_get_path(i)))
			if n != null and n.has_method("stop"):
				n.stop()


func _set_slider(t: float) -> void:
	_time_label.text = _fmt_time(t)
	if _sheet != null:
		_sheet.update()


func _key_times() -> Array:
	var times = []
	if _anim == null:
		return times
	for idx in range(_anim.get_track_count()):
		if _anim.track_get_type(idx) == Animation.TYPE_TRANSFORM:
			for e in _get_src(idx):
				times.append(e["t"])
		else:
			for k in range(_anim.track_get_key_count(idx)):
				times.append(_anim.track_get_key_time(idx, k))
	times.sort()
	return times


func _on_prev_key() -> void:
	var found = -1.0
	for t in _key_times():
		if t < _time - 0.005:
			found = t
	if found >= 0.0:
		_seek(found)


func _on_next_key() -> void:
	for t in _key_times():
		if t > _time + 0.005:
			_seek(t)
			return


func _on_to_start() -> void:
	_seek(0.0)


func _on_play_pressed() -> void:
	if _anim == null:
		return
	if _player.is_playing():
		_player.stop(false)                 # pause, keep the position
		_scrub_anim_players()
		return
	var start = _time
	if start >= _anim.length - 0.01:
		start = 0.0
	_player.play(_anim_name)
	_player.seek(start)


func _set_play_visual(playing: bool) -> void:
	if int(playing) == _play_shown:
		return
	_play_shown = int(playing)
	var ic = _icon(["Pause"] if playing else ["Play"])
	if ic != null:
		_play_btn.icon = ic
		_play_btn.text = ""
	else:
		_play_btn.icon = null
		_play_btn.text = "Pause" if playing else "Play"


func _on_stop() -> void:
	if _player == null:
		return
	_player.stop(true)
	_seek(0.0)


func _process(delta: float) -> void:
	if not visible or _director == null or _player == null or not is_instance_valid(_director):
		return
	var playing = _player.is_playing()
	if playing:
		_time = _player.current_animation_position
		_set_slider(_time)
		_drive_face_tracks(_time)
	_set_play_visual(playing)
	_update_card_drag()
	_move_edit_camera(delta)
	_refresh_xform_fields()
	_mh_timer += delta
	if _mh_timer > 0.5:
		_mh_timer = 0.0
		_refresh_mh_tab(true)
	_ins_refresh()
	_update_preview()
	_sheet.update()


# ------------------------------------------------------------ editor view

func _edit_basis() -> Basis:
	return Basis(Vector3(0, 1, 0), _edit_yaw) * Basis(Vector3(1, 0, 0), _edit_pitch)


func _look_from(xf: Transform, back: float) -> void:
	var b = xf.basis.orthonormalized()
	var e = b.get_euler()
	_edit_pitch = clamp(e.x, -1.55, 1.55)
	_edit_yaw = e.y
	_edit_pos = xf.origin + b.z * back
	_edit_dist = back if back > 0.5 else 5.0
	_edit_goal = null


func _reset_edit_view() -> void:
	_edit_yaw = 0.0
	_edit_pitch = -0.25
	_edit_pos = Vector3(0, 3, 6)
	_edit_dist = 6.7
	_edit_goal = null
	if not _cameras.empty():
		var cam = _root.get_node_or_null(_cameras[0]["path"])
		if cam is Camera:
			_look_from(cam.global_transform, 3.0)


func _on_edit_gui_input(ev: InputEvent) -> void:
	if _face_board_input(ev):
		accept_event()
		return
	if ev is InputEventMouseButton:
		if ev.button_index == BUTTON_RIGHT:
			_edit_rmb = ev.pressed
			if ev.pressed:
				_edit_goal = null
		elif ev.button_index == BUTTON_MIDDLE:
			_edit_mmb = ev.pressed
			if ev.pressed:
				_edit_goal = null
		elif ev.button_index == BUTTON_LEFT:
			if ev.pressed:
				if not _edit_rmb and not _edit_mmb:
					_gz_begin(ev.position)
					if _gz_drag == null:                       # not on a handle: pick whatever is under the mouse
						_pick_at(ev.position, ev.shift or ev.control)
			else:
				_gz_end()
		elif ev.button_index == BUTTON_WHEEL_UP and ev.pressed:
			if _edit_rmb:
				_fly_speed = clamp(_fly_speed * 1.25, 0.2, 200.0)
				_say("Fly speed %.1f m/s" % _fly_speed)
			else:
				_zoom_edit(0.85)
		elif ev.button_index == BUTTON_WHEEL_DOWN and ev.pressed:
			if _edit_rmb:
				_fly_speed = clamp(_fly_speed / 1.25, 0.2, 200.0)
				_say("Fly speed %.1f m/s" % _fly_speed)
			else:
				_zoom_edit(1.0 / 0.85)
		accept_event()
	elif ev is InputEventMouseMotion:
		if _gz_drag != null:
			_gz_update(ev.position, ev.control)
		elif _edit_rmb:
			# free look: turn on the spot (WASD / QE then fly, see _move_edit_camera)
			_edit_yaw -= ev.relative.x * 0.005
			_edit_pitch = clamp(_edit_pitch - ev.relative.y * 0.005, -1.55, 1.55)
		elif _edit_mmb:
			var b = _edit_basis()
			if ev.shift:
				# Shift + middle mouse: pan (scaled so the scene follows the mouse)
				var h = max(_edit_pane["container"].rect_size.y, 1.0)
				var k = 2.0 * tan(deg2rad(_edit_cam.fov) * 0.5) * _edit_dist / h
				_edit_pos += (-b.x * ev.relative.x + b.y * ev.relative.y) * k
			else:
				# Middle mouse: orbit around the point in front of the camera
				var pivot = _edit_pos - b.z * _edit_dist
				_edit_yaw -= ev.relative.x * 0.005
				_edit_pitch = clamp(_edit_pitch - ev.relative.y * 0.005, -1.55, 1.55)
				_edit_pos = pivot + _edit_basis().z * _edit_dist
		else:
			_gz_hover = _gz_pick(ev.position)


# Wheel: move towards / away from the orbit point.
func _zoom_edit(factor: float) -> void:
	_edit_goal = null
	var b = _edit_basis()
	var pivot = _edit_pos - b.z * _edit_dist
	_edit_dist = clamp(_edit_dist * factor, 0.05, 2000.0)
	_edit_pos = pivot + b.z * _edit_dist


func _move_edit_camera(delta: float) -> void:
	if _edit_rmb:
		var b = _edit_basis()
		var dir = Vector3()
		if Input.is_key_pressed(KEY_W):
			dir -= b.z
		if Input.is_key_pressed(KEY_S):
			dir += b.z
		if Input.is_key_pressed(KEY_A):
			dir -= b.x
		if Input.is_key_pressed(KEY_D):
			dir += b.x
		if Input.is_key_pressed(KEY_E):
			dir += Vector3(0, 1, 0)
		if Input.is_key_pressed(KEY_Q):
			dir -= Vector3(0, 1, 0)
		if dir != Vector3():
			_edit_goal = null
			var speed = _fly_speed
			if Input.is_key_pressed(KEY_SHIFT):
				speed *= 3.0
			_edit_pos += dir.normalized() * speed * delta
	if _edit_goal != null:
		var k = 1.0 - exp(-14.0 * delta)
		_edit_pos = _edit_pos.linear_interpolate(_edit_goal["pos"], k)
		_edit_dist = lerp(_edit_dist, _edit_goal["dist"], k)
		if _edit_pos.distance_to(_edit_goal["pos"]) < 0.002 and abs(_edit_dist - _edit_goal["dist"]) < 0.002:
			_edit_pos = _edit_goal["pos"]
			_edit_dist = _edit_goal["dist"]
			_edit_goal = null
	_edit_cam.transform = Transform(_edit_basis(), _edit_pos)


# F: fly the Editor view to the selected node(s) and orbit around them from then on.
func _focus_selected() -> void:
	if _root == null or _edit_cam == null:
		return
	var box = null
	for n in _selected_nodes():
		if not (n is Spatial) or n == _director or not n.is_inside_tree():
			continue
		var bb = _world_bounds(n)
		if bb == null:
			var o = n.global_transform.origin
			bb = AABB(o - Vector3(0.5, 0.5, 0.5), Vector3(1, 1, 1))
		box = bb if box == null else box.merge(bb)
	if box == null:
		_say("Nothing to focus: click a node in the Editor view or the Nodes list first.")
		return
	var center = box.position + box.size * 0.5
	var radius = max(box.size.length() * 0.5, 0.25)
	var dist = clamp(radius / sin(deg2rad(_edit_cam.fov) * 0.5) * 1.1, 0.4, 2000.0)
	_edit_goal = {"pos": center + _edit_basis().z * dist, "dist": dist}


# ------------------------------------------------------------------ picking in the Editor view

# Visible geometry under this node (and the node itself), capped so a huge scene cannot stall the editor.
func _collect_geo(n: Node, out: Array) -> void:
	if out.size() > 600 or n == _director:
		return
	if n is GeometryInstance and n.is_inside_tree() and n.is_visible_in_tree():
		out.append(n)
	for c in n.get_children():
		_collect_geo(c, out)


# Bounds of a node's visible geometry in world space (an AABB around the transformed boxes), or null.
func _world_bounds(n: Node):
	var geos = []
	_collect_geo(n, geos)
	var box = null
	for g in geos:
		var ab: AABB = g.get_aabb()
		var xf: Transform = g.global_transform
		for i in range(8):
			var p = xf.xform(ab.get_endpoint(i))
			if box == null:
				box = AABB(p, Vector3.ZERO)
			else:
				box = box.expand(p)
	return box


# Bounds in the node's own space, so the selection box turns with the node. Cached for half a second.
func _cached_local_bounds(n: Spatial):
	var id = n.get_instance_id()
	var now = OS.get_ticks_msec()
	var e = _bounds_cache.get(id)
	if e == null or now - e["t"] > 500:
		e = {"t": now, "box": _local_bounds(n)}
		_bounds_cache[id] = e
	return e["box"]


func _local_bounds(n: Spatial):
	var geos = []
	_collect_geo(n, geos)
	if geos.empty():
		return null
	var gt: Transform = n.global_transform
	if abs(gt.basis.determinant()) < 0.0000001:
		return null
	var inv = gt.affine_inverse()
	var box = null
	for g in geos:
		var ab: AABB = g.get_aabb()
		var rel: Transform = inv * g.global_transform
		for i in range(8):
			var p = rel.xform(ab.get_endpoint(i))
			if box == null:
				box = AABB(p, Vector3.ZERO)
			else:
				box = box.expand(p)
	return box


# A mesh inside an instanced scene selects the instance (the node you also see in the Nodes list).
func _selectable(n: Node):
	while n != null and n != _root and n.owner != _root:
		n = n.get_parent()
	return n if n != _root else null


func _is_marker(n: Node) -> bool:
	if n is Camera or n is Light or n is Listener or n is AudioStreamPlayer3D or n.get_class() == "Position3D":
		return true
	# an empty Spatial used as a marker (a container with children is picked through its children)
	return n.get_class() == "Spatial" and n.get_child_count() == 0


func _walk_pick(n: Node, geos: Array, markers: Array) -> void:
	if n == _director:
		return
	if n != _root and n is Spatial and n.is_inside_tree():
		if n is GeometryInstance:
			if n.is_visible_in_tree():
				geos.append(n)
		elif _is_marker(n) and n.is_visible_in_tree():
			markers.append(n)
	for c in n.get_children():
		_walk_pick(c, geos, markers)


# Distance along the ray (o + d * t) where it enters the box, or -1 when it misses (slab test).
func _ray_box(o: Vector3, d: Vector3, box: AABB) -> float:
	var tmin = 0.0
	var tmax = INF
	for i in range(3):
		var lo = box.position[i]
		var hi = lo + box.size[i]
		if abs(d[i]) < 0.000000001:
			if o[i] < lo or o[i] > hi:
				return -1.0
		else:
			var inv = 1.0 / d[i]
			var t1 = (lo - o[i]) * inv
			var t2 = (hi - o[i]) * inv
			if t1 > t2:
				var tmp = t1
				t1 = t2
				t2 = tmp
			tmin = max(tmin, t1)
			tmax = min(tmax, t2)
			if tmin > tmax:
				return -1.0
	return tmin


# A camera is picked by clicking any line of its outline (the pyramid drawn in the Editor view).
func _pick_camera(pos: Vector2):
	var best = null
	var best_d = 9.0
	for c in _cameras:
		var cam = _root.get_node_or_null(c["path"])
		if not (cam is Camera) or not cam.is_inside_tree():
			continue
		for sg in _cam_outline(cam):
			if _edit_cam.is_position_behind(sg[0]) or _edit_cam.is_position_behind(sg[1]):
				continue
			var d = _seg_dist(pos, _edit_cam.unproject_position(sg[0]), _edit_cam.unproject_position(sg[1]))
			if d < best_d:
				best_d = d
				best = cam
	return best


# The node under the mouse: small things (cameras, lights, markers) by their pivot, meshes by a real ray test.
func _pick_node(pos: Vector2):
	var cam_hit = _pick_camera(pos)
	if cam_hit != null:
		return _selectable(cam_hit)
	var ro = _edit_cam.project_ray_origin(pos)
	var rd = _edit_cam.project_ray_normal(pos)
	var geos = []
	var markers = []
	_walk_pick(_root, geos, markers)
	var best_marker = null
	var best_px = 14.0
	for m in markers:
		var d = _scr(m.global_transform.origin).distance_to(pos)
		if d < best_px:
			best_px = d
			best_marker = m
	if best_marker != null:
		return _selectable(best_marker)
	var best = null
	var best_d = INF
	for g in geos:
		var gxf: Transform = g.global_transform
		if abs(gxf.basis.determinant()) < 0.0000001:
			continue
		var inv = gxf.affine_inverse()
		var lo = inv.xform(ro)
		var ld = inv.basis.xform(rd)
		var t_box = _ray_box(lo, ld, g.get_aabb())
		if t_box < 0.0:
			continue
		var hit_local = lo + ld * t_box
		if g is MeshInstance and g.mesh != null:
			# refine with the real triangles (skipped for very dense meshes, where the box is used)
			var faces = g.mesh.get_faces()
			if faces.size() > 0 and faces.size() <= 120000:
				hit_local = null
				var bd = INF
				for i in range(0, faces.size(), 3):
					var th = Geometry.ray_intersects_triangle(lo, ld, faces[i], faces[i + 1], faces[i + 2])
					if th != null:
						var dd = lo.distance_squared_to(th)
						if dd < bd:
							bd = dd
							hit_local = th
				if hit_local == null:
					continue
		var dist = ro.distance_to(gxf.xform(hit_local))
		if dist < best_d:
			best_d = dist
			best = g
	if best == null:
		return null
	return _selectable(best)


# Click in the Editor view: picks the node (Shift / Ctrl adds or removes it), clicking empty space deselects.
func _pick_at(pos: Vector2, additive: bool) -> void:
	if _root == null or _edit_cam == null:
		return
	var hit = _pick_node(pos)
	if hit == null:
		if not additive:
			_picked = []
			var sel = editor.get_selection()
			if not sel.get_selected_nodes().empty():
				sel.clear()               # this also refreshes the panel through selection_changed
			_on_selection_changed()
		return
	var path = str(_root.get_path_to(hit))
	var list = []
	if additive:
		for n in _selected_nodes():
			list.append(str(_root.get_path_to(n)))
		if list.has(path):
			list.erase(path)
		else:
			list.append(path)
	else:
		list = [path]
	_picked = list
	_on_selection_changed()


func _edit_view_transform() -> Transform:
	return Transform(_edit_basis(), _edit_pos)


# ------------------------------------------------------------------ modal transform (G / R / S, like Blender)
# G / R / S start moving / rotating / scaling the selected node(s) with the mouse. While it runs:
#   X / Y / Z        lock to that world axis; press again for the node's own (local) axis; a third time = free
#   Shift + X / Y / Z  lock to the plane WITHOUT that axis (move / scale)
#   left click / Enter  confirm        Esc / right click  cancel        Ctrl  snap
#   G / R / S again  switch operation
# Holding the key also works: hold G, move the mouse (press X in the meantime), let go of G to confirm.

const MODAL_NAMES = {"move": "Move", "rot": "Rotate", "scale": "Scale"}
const MODAL_HOLD_MS = 350          # a key held longer than this confirms when it is released


func _mouse_in_edit_view() -> bool:
	if _edit_pane.empty():
		return false
	var c = _edit_pane["container"]
	return Rect2(Vector2(), c.rect_size).has_point(c.get_local_mouse_position())


func _modal_begin(kind: String, key: int) -> bool:
	if _root == null or _edit_cam == null:
		return false
	var picked = []
	for n in _selected_nodes():
		if n is Spatial and n != _director and n.is_inside_tree():
			picked.append(n)
	var entries = []
	var pivot = Vector3()
	for n in picked:
		var child_of_picked = false
		for m in picked:
			if m != n and m.is_a_parent_of(n):
				child_of_picked = true          # it follows its parent already
				break
		if child_of_picked:
			continue
		entries.append({"node": n, "old": n.transform, "gxf": n.global_transform})
		pivot += n.global_transform.origin
	if entries.empty():
		_say("Select a 3D node first (click it in the Editor view or pick it in the Nodes list), then press G / R / S.")
		return false
	pivot = pivot / float(entries.size())
	var pos = _edit_pane["container"].get_local_mouse_position()
	var ps = _scr(pivot)
	_modal = {"kind": kind, "entries": entries, "pivot": pivot, "axis": -1, "local": false, "plane": false,
		"start": pos, "cur": pos, "key": key, "t0": OS.get_ticks_msec(), "moved": false, "snap": false,
		"psc": ps, "d0": ps.distance_to(pos), "prev": pos - ps, "acc": 0.0, "base": null, "info": ""}
	_gz_drag = null
	_gz_hover = -1
	_modal_rebase()
	_modal_say()
	return true


func _modal_dir(i: int) -> Vector3:
	if _modal["local"]:
		return _gz_axis(_modal["entries"][0]["gxf"].basis.orthonormalized(), i)
	return [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)][i]


func _nearest_axis(b: Basis, dir: Vector3) -> int:
	var best = 0
	var bd = -1.0
	for i in range(3):
		var d = abs(_gz_axis(b, i).dot(dir))
		if d > bd:
			bd = d
			best = i
	return best


# Where the mouse "was" when the operation (or its axis lock) started, so nothing jumps when you press X / Y / Z.
func _modal_rebase() -> void:
	var m = _modal
	m["base"] = null
	if m["kind"] != "move":
		return
	var o = m["pivot"]
	if m["axis"] >= 0 and not m["plane"]:
		m["base"] = _gz_line_t(o, _modal_dir(m["axis"]), m["start"])
	elif m["axis"] >= 0:
		m["base"] = _gz_plane_pt(o, _modal_dir(m["axis"]), m["start"])
	else:
		m["base"] = _gz_plane_pt(o, _edit_cam.global_transform.basis.z, m["start"])


# Puts every node back to where it was and applies the whole operation again for the current mouse position.
func _modal_apply() -> void:
	var m = _modal
	var entries = m["entries"]
	var pos = m["cur"]
	var pivot = m["pivot"]
	var axis = m["axis"]
	var snap = m["snap"]
	var cam_z = _edit_cam.global_transform.basis.z
	for e in entries:
		if is_instance_valid(e["node"]):
			e["node"].transform = e["old"]
	if m["kind"] == "move":
		if m["base"] == null:
			return
		var delta = Vector3()
		if axis >= 0 and not m["plane"]:
			var dir = _modal_dir(axis)
			var dt = _gz_line_t(pivot, dir, pos) - m["base"]
			if snap:
				dt = stepify(dt, 0.25)
			delta = dir * dt
		else:
			var nrm = _modal_dir(axis) if axis >= 0 else cam_z
			var hit = _gz_plane_pt(pivot, nrm, pos)
			if hit == null:
				return
			delta = hit - m["base"]
			if snap:
				delta = Vector3(stepify(delta.x, 0.25), stepify(delta.y, 0.25), stepify(delta.z, 0.25))
		for e in entries:
			if is_instance_valid(e["node"]):
				var g = e["gxf"]
				e["node"].global_transform = Transform(g.basis, g.origin + delta)
		m["info"] = "dX %.3f   dY %.3f   dZ %.3f m" % [delta.x, delta.y, delta.z]
	elif m["kind"] == "rot":
		var av = cam_z                                 # free rotation turns around the view direction
		if axis >= 0 and not m["plane"]:
			av = _modal_dir(axis)
		var sgn = 1.0 if av.dot(cam_z) >= 0.0 else -1.0
		var ang = -m["acc"] * sgn
		if snap:
			ang = stepify(ang, deg2rad(15.0))
		var r = Basis(av, ang)
		for e in entries:
			if is_instance_valid(e["node"]):
				var g2 = e["gxf"]
				e["node"].global_transform = Transform(r * g2.basis, pivot + r.xform(g2.origin - pivot))
		m["info"] = "%.1f degrees" % rad2deg(ang)
	else:
		var dist = m["psc"].distance_to(pos)
		var k = max(1.0 + (dist - m["d0"]) / max(m["d0"], 30.0), 0.01)
		if snap:
			k = max(stepify(k, 0.1), 0.1)
		for e in entries:
			var n = e["node"]
			if not is_instance_valid(n):
				continue
			var sc = e["old"].basis.get_scale()
			var gb = e["gxf"].basis.orthonormalized()
			var off = e["gxf"].origin - pivot
			var new_off = off
			if axis < 0:
				sc = sc * k
				new_off = off * k
			else:
				var dirs = [_modal_dir(axis)]
				if m["plane"]:
					dirs = [_modal_dir((axis + 1) % 3), _modal_dir((axis + 2) % 3)]
				for dv in dirs:
					var li = _nearest_axis(gb, dv)
					sc[li] = sc[li] * k
					new_off += dv * dv.dot(off) * (k - 1.0)
			n.scale = sc
			if entries.size() > 1:
				n.global_transform = Transform(n.global_transform.basis, pivot + new_off)
		m["info"] = "x %.3f" % k


func _modal_label() -> String:
	var m = _modal
	var text = MODAL_NAMES[m["kind"]]
	if m["axis"] >= 0:
		var a = ["X", "Y", "Z"][m["axis"]]
		text += ("  without %s" % a) if m["plane"] else ("  along %s" % a)
		text += " (local)" if m["local"] else " (global)"
	return text


func _modal_say() -> void:
	_say("%s    %s     -    click / Enter confirm   Esc / right click cancel   X Y Z axis (Shift = plane, twice = local)   Ctrl snap" % [_modal_label(), _modal["info"]])


func _modal_axis_key(i: int, shift: bool) -> void:
	var m = _modal
	if m["axis"] == i and m["plane"] == shift:
		if not m["local"]:
			m["local"] = true
		else:
			m["axis"] = -1
			m["local"] = false
			m["plane"] = false
	else:
		m["axis"] = i
		m["plane"] = shift
		m["local"] = false
	_modal_rebase()
	_modal_apply()
	_modal_say()


func _modal_motion(ctrl: bool) -> void:
	var m = _modal
	var pos = _edit_pane["container"].get_local_mouse_position()
	if pos.distance_to(m["start"]) > 3.0:
		m["moved"] = true
	# rotation follows the angle of the mouse around the pivot on screen, summed up so you can turn past 180
	var v = pos - m["psc"]
	if v.length() > 2.0:
		var pv = m["prev"]
		if pv.length() > 2.0:
			m["acc"] += atan2(pv.cross(v), pv.dot(v))
		m["prev"] = v
	m["cur"] = pos
	m["snap"] = ctrl
	_modal_apply()
	_modal_say()


# Returns true when the event was used (it is then kept away from the rest of the editor).
func _modal_input(ev: InputEvent) -> bool:
	if ev is InputEventMouseMotion:
		_modal_motion(ev.control)
		return true
	if ev is InputEventMouseButton:
		if ev.pressed:
			if ev.button_index == BUTTON_LEFT:
				_modal_confirm()
			elif ev.button_index == BUTTON_RIGHT:
				_modal_cancel()
		return true
	if not (ev is InputEventKey):
		return false
	var k = ev.scancode
	if not ev.pressed:
		if k == _modal["key"] and _modal["moved"] and OS.get_ticks_msec() - _modal["t0"] > MODAL_HOLD_MS:
			_modal_confirm()                               # the key was held while moving: letting go confirms
			return true
		return false
	if ev.echo:
		return true
	if ev.control or ev.alt or ev.meta or ev.command:
		return false
	if k == KEY_ESCAPE:
		_modal_cancel()
	elif k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_SPACE:
		_modal_confirm()
	elif k == KEY_X:
		_modal_axis_key(0, ev.shift)
	elif k == KEY_Y:
		_modal_axis_key(1, ev.shift)
	elif k == KEY_Z:
		_modal_axis_key(2, ev.shift)
	elif k == KEY_G or k == KEY_R or k == KEY_S:
		var kind = {KEY_G: "move", KEY_R: "rot", KEY_S: "scale"}[k]
		if kind != _modal["kind"]:
			_modal_cancel(false)
			_modal_begin(kind, k)
	else:
		return false
	return true


func _modal_confirm() -> void:
	var m = _modal
	_modal = null
	var changed = []
	for e in m["entries"]:
		if is_instance_valid(e["node"]) and e["node"].transform != e["old"]:
			changed.append(e)
	if changed.empty():
		_say("%s: nothing changed." % MODAL_NAMES[m["kind"]])
		return
	var label = changed[0]["node"].name if changed.size() == 1 else "%d nodes" % changed.size()
	undo_redo.create_action("%s %s" % [MODAL_NAMES[m["kind"]], label])
	for e in changed:
		undo_redo.add_do_property(e["node"], "transform", e["node"].transform)
		undo_redo.add_undo_property(e["node"], "transform", e["old"])
	undo_redo.commit_action()
	if editor.has_method("mark_scene_as_unsaved"):
		editor.mark_scene_as_unsaved()
	_refresh_xform_fields(true)
	_say("%s: %s %s. Press I to key it at %s." % [MODAL_NAMES[m["kind"]], label, m["info"], _fmt_time(_time)])


func _modal_cancel(say: bool = true) -> void:
	var m = _modal
	_modal = null
	if m == null:
		return
	for e in m["entries"]:
		if is_instance_valid(e["node"]):
			e["node"].transform = e["old"]
	if say:
		_say("%s cancelled." % MODAL_NAMES[m["kind"]])


# The locked axis (or the two plane axes) drawn as long coloured lines through the pivot.
func _draw_modal_guide() -> void:
	var m = _modal
	var p = m["pivot"]
	for j in range(3):
		if j == m["axis"] and m["plane"]:
			continue
		if j != m["axis"] and not m["plane"]:
			continue
		var dir = _modal_dir(j)
		_ribbon(p - dir * 100.0, p + dir * 100.0, GZ_COLORS[j], 1.6)


# ------------------------------------------------------------------ transform gizmo (Editor view)
# One gizmo with everything: arrows + plane squares (move), rings (rotate, the grey one turns around the view),
# small cubes on the axes (scale per axis) and the centre cube (scale all). Move / Rotate / Scale show just one part.

# Switches the gizmo (G move, R rotate, S scale, A all) and keeps the toolbar buttons in sync.
func _set_gz_mode(mode: int) -> void:
	if _gz_buttons.has(mode):
		_gz_buttons[mode].pressed = true
	_on_gz_mode(mode)


func _on_gz_mode(mode: int) -> void:
	_gz_mode = mode
	_gz_drag = null
	_gz_hover = -1


func _on_gz_local(pressed: bool) -> void:
	_gz_local = pressed


func _gz_node():
	if _gz_mode == 0 or _director == null or _edit_cam == null:
		return null
	var n = _xform_node()
	if n != null and n.is_inside_tree():
		return n
	return null


func _gz_axis(b: Basis, i: int) -> Vector3:
	return [b.x, b.y, b.z][i]


func _gz_frame(n) -> Dictionary:
	var xf = n.global_transform
	var lb = xf.basis.orthonormalized()
	var b = lb if _gz_local else Basis()
	var d = (xf.origin - _edit_cam.global_transform.origin).length()
	return {"o": xf.origin, "b": b, "lb": lb, "s": max(d, 0.1) * 0.28}


func _gz_handles(f: Dictionary) -> Array:
	var out = []
	var b = f["b"]
	var lb = f["lb"]
	var m = _gz_mode
	if m == 1 or m == 4:
		for i in range(3):
			out.append({"type": "move", "axis": i, "dir": _gz_axis(b, i), "col": GZ_COLORS[i]})
		for i in range(3):
			out.append({"type": "plane", "axis": i, "dir": _gz_axis(b, i), "a1": _gz_axis(b, (i + 1) % 3), "a2": _gz_axis(b, (i + 2) % 3), "col": GZ_COLORS[i]})
	if m == 2 or m == 4:
		for i in range(3):
			out.append({"type": "rot", "axis": i, "dir": _gz_axis(b, i), "a1": _gz_axis(b, (i + 1) % 3), "a2": _gz_axis(b, (i + 2) % 3), "col": GZ_COLORS[i], "r": 0.8})
		var cb = _edit_cam.global_transform.basis
		out.append({"type": "rot", "axis": 3, "dir": cb.z, "a1": cb.x, "a2": cb.y, "col": Color(0.85, 0.85, 0.9), "r": 0.97})
	if m == 3:
		for i in range(3):
			out.append({"type": "scale", "axis": i, "dir": _gz_axis(lb, i), "col": GZ_COLORS[i]})
		out.append({"type": "uscale", "axis": 3, "col": Color(0.9, 0.9, 0.9)})
	return out


func _gz_ring_pts(f: Dictionary, h: Dictionary) -> Array:
	var pts = []
	for j in range(49):
		var t = TAU * float(j) / 48.0
		pts.append(f["o"] + (h["a1"] * cos(t) + h["a2"] * sin(t)) * f["s"] * h["r"])
	return pts


func _gz_plane_corners(f: Dictionary, h: Dictionary) -> Array:
	var s = f["s"]
	var o = f["o"]
	var a1 = h["a1"]
	var a2 = h["a2"]
	return [o + (a1 * 0.3 + a2 * 0.3) * s, o + (a1 * 0.44 + a2 * 0.3) * s, o + (a1 * 0.44 + a2 * 0.44) * s, o + (a1 * 0.3 + a2 * 0.44) * s]


func _tri(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	_tgizmo.set_color(col)
	_tgizmo.add_vertex(a)
	_tgizmo.set_color(col)
	_tgizmo.add_vertex(b)
	_tgizmo.set_color(col)
	_tgizmo.add_vertex(c)
	_tv += 3


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_tri(a, b, c, col)
	_tri(a, c, d, col)


# World size of one screen pixel at distance 1 from the Editor camera.
func _px() -> float:
	var h = max(_edit_pane["container"].rect_size.y, 1.0)
	return 2.0 * tan(deg2rad(_edit_cam.fov) * 0.5) / h


# A line that is always `width_px` pixels wide on screen and faces the camera.
func _ribbon(a: Vector3, b: Vector3, col: Color, width_px: float) -> void:
	var v = (a + b) * 0.5 - _edit_cam.global_transform.origin
	var side = (b - a).cross(v)
	if side.length() < 0.000001:
		return
	side = side.normalized() * (width_px * 0.5 * _px() * v.length())
	_quad(a + side, a - side, b - side, b + side, col)


func _cone(base_c: Vector3, tip: Vector3, r: float, col: Color) -> void:
	var ax = (tip - base_c).normalized()
	var p1 = ax.cross(Vector3(0, 1, 0))
	if p1.length() < 0.1:
		p1 = ax.cross(Vector3(1, 0, 0))
	p1 = p1.normalized()
	var p2 = ax.cross(p1).normalized()
	var n = 14
	for i in range(n):
		var a0 = TAU * float(i) / n
		var a1 = TAU * float(i + 1) / n
		var q0 = base_c + (p1 * cos(a0) + p2 * sin(a0)) * r
		var q1 = base_c + (p1 * cos(a1) + p2 * sin(a1)) * r
		_tri(q0, q1, tip, col)
		_tri(q1, q0, base_c, col)


func _fcube(c: Vector3, r: float, col: Color) -> void:
	var v = []
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				v.append(c + Vector3(x, y, z) * r)
	for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		_quad(v[f[0]], v[f[1]], v[f[2]], v[f[3]], col)


# The orange box around a selected node (turns with the node, like the Godot editor's selection box).
func _draw_sel_box(n: Spatial) -> void:
	var box = _cached_local_bounds(n)
	if box == null:
		return
	var xf: Transform = n.global_transform
	var corners = []
	for i in range(8):
		corners.append(xf.xform(box.position + Vector3(box.size.x * ((i >> 2) & 1), box.size.y * ((i >> 1) & 1), box.size.z * (i & 1))))
	for i in range(8):
		for j in range(i + 1, 8):
			var x = i ^ j
			if x == 1 or x == 2 or x == 4:
				_ribbon(corners[i], corners[j], SEL_BOX_COLOR, 1.8)


func _draw_xform_gizmo() -> void:
	if _tgizmo == null:
		return
	_tgizmo.clear()
	var sel = []
	for n in _selected_nodes():
		if n is Spatial and n != _director and n.is_inside_tree():
			sel.append(n)
	var gn = _gz_node()
	if sel.empty() and gn == null:
		return
	_tv = 0
	_tgizmo.begin(Mesh.PRIMITIVE_TRIANGLES)
	for n in sel:
		_draw_sel_box(n)
	if gn != null and _modal == null:
		_draw_handles(gn)
	if _modal != null and _modal["axis"] >= 0:
		_draw_modal_guide()
	if _tv == 0:                                   # nothing drawn: write one invisible triangle so begin / end stay valid
		_tri(Vector3(), Vector3(), Vector3(), Color(0, 0, 0, 0))
	_tgizmo.end()


# Solid, saturated handles like the Godot 4 gizmo: thin cone-tipped arrows, small filled plane squares and thin rings.
func _draw_handles(n: Spatial) -> void:
	var f = _gz_frame(n)
	var s = f["s"]
	var o = f["o"]
	var hs = _gz_handles(f)
	for pass_type in ["plane", "rot", "move", "scale", "uscale"]:
		for hi in range(hs.size()):
			var h = hs[hi]
			if h["type"] != pass_type:
				continue
			var col = h["col"]
			var hot = _gz_hover == hi or (_gz_drag != null and _gz_drag["hi"] == hi)
			if hot:
				col = GZ_HOT
			if pass_type == "move":
				var ax = h["dir"]
				_ribbon(o, o + ax * 0.85 * s, col, 3.5 if hot else 2.5)
				_cone(o + ax * 0.8 * s, o + ax * s, 0.07 * s, col)
			elif pass_type == "plane":
				var c = _gz_plane_corners(f, h)
				_quad(c[0], c[1], c[2], c[3], Color(col.r, col.g, col.b, 1.0 if hot else 0.9))
			elif pass_type == "rot":
				var pts = _gz_ring_pts(f, h)
				var rc = col
				var w = 3.0 if hot else 2.0
				if h["axis"] == 3 and not hot:
					rc = Color(col.r, col.g, col.b, 0.6)
					w = 1.4
				for j in range(48):
					_ribbon(pts[j], pts[j + 1], rc, w)
			elif pass_type == "scale":
				_ribbon(o, o + h["dir"] * 0.85 * s, col, 2.5)
				_fcube(o + h["dir"] * 0.85 * s, 0.045 * s, col)
			else:
				_fcube(o, 0.06 * s, col if hot else Color(0.85, 0.85, 0.85, 1.0))


func _scr(p: Vector3) -> Vector2:
	if _edit_cam.is_position_behind(p):
		return Vector2(-100000, -100000)
	return _edit_cam.unproject_position(p)


func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var l = ab.length_squared()
	if l < 0.0001:
		return p.distance_to(a)
	var t = clamp((p - a).dot(ab) / l, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# Screen distance from the mouse to a handle, or a huge number when the mouse is not on it.
func _gz_dist(h: Dictionary, f: Dictionary, pos: Vector2) -> float:
	var t = h["type"]
	var o = f["o"]
	var big = 1000000.0
	if t == "move":
		var d = _seg_dist(pos, _scr(o), _scr(o + h["dir"] * f["s"]))
		return d if d < 12.0 else big
	if t == "scale":
		var d2 = _scr(o + h["dir"] * 0.85 * f["s"]).distance_to(pos)
		return d2 if d2 < 12.0 else big
	if t == "uscale":
		var d3 = _scr(o).distance_to(pos)
		return d3 if d3 < 12.0 else big
	if t == "plane":
		var poly = PoolVector2Array()
		var centre = Vector2()
		for c in _gz_plane_corners(f, h):
			var sp = _scr(c)
			poly.append(sp)
			centre += sp * 0.25
		if Geometry.is_point_in_polygon(pos, poly) or centre.distance_to(pos) < 11.0:
			return centre.distance_to(pos)           # the nearest square wins when two overlap on screen
		return big
	var pts = _gz_ring_pts(f, h)
	var best = big
	for j in range(48):
		best = min(best, _seg_dist(pos, _scr(pts[j]), _scr(pts[j + 1])))
	return best if best < 9.0 else big


# Index of the handle under the mouse, or -1. Small handles win over the big rings.
func _gz_pick(pos: Vector2) -> int:
	var n = _gz_node()
	if n == null:
		return -1
	var f = _gz_frame(n)
	var hs = _gz_handles(f)
	for t in ["uscale", "scale", "plane", "move", "rot"]:
		var best = -1
		var bd = 1000000.0
		for i in range(hs.size()):
			if hs[i]["type"] != t:
				continue
			var d = _gz_dist(hs[i], f, pos)
			if d < bd:
				bd = d
				best = i
		if best != -1 and bd < 900000.0:
			return best
	return -1


# Position along the line (o + dir * t) that is closest to the mouse ray.
func _gz_line_t(o: Vector3, dir: Vector3, pos: Vector2) -> float:
	var ro = _edit_cam.project_ray_origin(pos)
	var rd = _edit_cam.project_ray_normal(pos)
	var w0 = o - ro
	var a = dir.dot(dir)
	var b = dir.dot(rd)
	var c = rd.dot(rd)
	var dd = dir.dot(w0)
	var e = rd.dot(w0)
	var den = a * c - b * b
	if abs(den) < 0.00001:
		return 0.0
	return (b * e - c * dd) / den


# Where the mouse ray hits the plane through o with this normal (null if it does not).
func _gz_plane_pt(o: Vector3, normal: Vector3, pos: Vector2):
	var ro = _edit_cam.project_ray_origin(pos)
	var rd = _edit_cam.project_ray_normal(pos)
	return Plane(normal, normal.dot(o)).intersects_ray(ro, rd)


func _gz_plane_vec(o: Vector3, normal: Vector3, pos: Vector2):
	var hit = _gz_plane_pt(o, normal, pos)
	if hit == null:
		return null
	var v = hit - o
	return v.normalized() if v.length() > 0.0001 else null


func _gz_begin(pos: Vector2) -> void:
	var hi = _gz_pick(pos)
	if hi == -1:
		return
	var n = _gz_node()
	var f = _gz_frame(n)
	var h = _gz_handles(f)[hi]
	var d = {"hi": hi, "h": h, "node": n, "old": n.transform, "gxf": n.global_transform, "o": f["o"], "t0": 0.0, "v0": null, "d0": 1.0}
	var t = h["type"]
	if t == "move" or t == "scale":
		d["t0"] = _gz_line_t(f["o"], h["dir"], pos)
	elif t == "plane":
		d["v0"] = _gz_plane_pt(f["o"], h["dir"], pos)
		if d["v0"] == null:
			return
	elif t == "rot":
		d["v0"] = _gz_plane_vec(f["o"], h["dir"], pos)
		if d["v0"] == null:
			return
	else:
		d["d0"] = max(_scr(f["o"]).distance_to(pos), 4.0)
	_gz_drag = d


func _gz_update(pos: Vector2, snap: bool) -> void:
	var d = _gz_drag
	var n = d["node"]
	if not is_instance_valid(n):
		_gz_drag = null
		return
	var h = d["h"]
	var t = h["type"]
	var gxf: Transform = d["gxf"]
	if t == "uscale":
		var k = clamp(_scr(d["o"]).distance_to(pos) / d["d0"], 0.01, 100.0)
		if snap:
			k = max(stepify(k, 0.1), 0.1)
		n.scale = d["old"].basis.get_scale() * k
	elif t == "move":
		var dt = _gz_line_t(d["o"], h["dir"], pos) - d["t0"]
		if snap:
			dt = stepify(dt, 0.25)
		n.global_transform = Transform(gxf.basis, gxf.origin + h["dir"] * dt)
	elif t == "plane":
		var hit = _gz_plane_pt(d["o"], h["dir"], pos)
		if hit == null:
			return
		var delta = hit - d["v0"]
		var m1 = delta.dot(h["a1"])
		var m2 = delta.dot(h["a2"])
		if snap:
			m1 = stepify(m1, 0.25)
			m2 = stepify(m2, 0.25)
		n.global_transform = Transform(gxf.basis, gxf.origin + h["a1"] * m1 + h["a2"] * m2)
	elif t == "rot":
		var v = _gz_plane_vec(d["o"], h["dir"], pos)
		if v == null:
			return
		var ang = atan2(h["dir"].dot(d["v0"].cross(v)), d["v0"].dot(v))
		if snap:
			ang = stepify(ang, deg2rad(15.0))
		n.global_transform = Transform(Basis(h["dir"], ang) * gxf.basis, gxf.origin)
	elif t == "scale":
		if abs(d["t0"]) < 0.001:
			return
		var k2 = clamp(_gz_line_t(d["o"], h["dir"], pos) / d["t0"], 0.01, 100.0)
		if snap:
			k2 = max(stepify(k2, 0.1), 0.1)
		var sc = d["old"].basis.get_scale()
		sc[h["axis"]] = sc[h["axis"]] * k2
		n.scale = sc


func _gz_end() -> void:
	if _gz_drag == null:
		return
	var n = _gz_drag["node"]
	var old = _gz_drag["old"]
	_gz_drag = null
	if not is_instance_valid(n):
		return
	var nw = n.transform
	if nw == old:
		return
	undo_redo.create_action("Gizmo: transform %s" % n.name)
	undo_redo.add_do_property(n, "transform", nw)
	undo_redo.add_undo_property(n, "transform", old)
	undo_redo.commit_action()
	if editor.has_method("mark_scene_as_unsaved"):
		editor.mark_scene_as_unsaved()
	_say("%s transformed. Press 'Key transform' to key it at %s." % [n.name, _fmt_time(_time)])


# The outline of a camera (its little pyramid) as world-space segments [a, b]. Used for drawing and for picking.
func _cam_outline(cam: Camera) -> Array:
	var xf = cam.global_transform.orthonormalized()
	var d = 1.4
	var hh = cam.size * 0.5
	if cam.projection == Camera.PROJECTION_PERSPECTIVE:
		hh = tan(deg2rad(cam.fov) * 0.5) * d
	var hw = hh / _aspect
	var corners = [Vector3(-hw, -hh, -d), Vector3(hw, -hh, -d), Vector3(hw, hh, -d), Vector3(-hw, hh, -d)]
	var out = []
	for i in range(4):
		out.append([xf.xform(Vector3()), xf.xform(corners[i])])
		out.append([xf.xform(corners[i]), xf.xform(corners[(i + 1) % 4])])
	var up_a = Vector3(-hw * 0.35, hh, -d)
	var up_b = Vector3(hw * 0.35, hh, -d)
	var up_c = Vector3(0, hh * 1.4, -d)
	out.append([xf.xform(up_a), xf.xform(up_b)])
	out.append([xf.xform(up_b), xf.xform(up_c)])
	out.append([xf.xform(up_c), xf.xform(up_a)])
	return out


# Draws every camera in the scene as a little frustum; the one the cutscene is using is yellow, selected ones orange.
func _draw_gizmos(active) -> void:
	_gizmo.clear()
	if _cameras.empty():
		return
	var selected = _selected_nodes()
	_gizmo.begin(Mesh.PRIMITIVE_LINES)
	for c in _cameras:
		var cam = _root.get_node_or_null(c["path"])
		if not (cam is Camera) or not cam.is_inside_tree():
			continue
		var col = Color(1.0, 0.8, 0.2) if cam == active else Color(0.55, 0.8, 1.0)
		if selected.has(cam):
			col = Color(1.0, 0.45, 0.0)
		for sg in _cam_outline(cam):
			_gizmo_line(sg[0], sg[1], Transform(), col)
	_gizmo.end()


func _gizmo_line(a: Vector3, b: Vector3, xf: Transform, col: Color) -> void:
	_gizmo.set_color(col)
	_gizmo.add_vertex(xf.xform(a))
	_gizmo.set_color(col)
	_gizmo.add_vertex(xf.xform(b))


func _on_camera_to_view() -> void:
	var cam = _target_camera()
	if cam == null:
		_say("Select a Camera or pick one in the camera list.")
		return
	undo_redo.create_action("Place camera at editor view")
	undo_redo.add_do_property(cam, "global_transform", _edit_view_transform())
	undo_redo.add_undo_property(cam, "global_transform", cam.global_transform)
	undo_redo.commit_action()
	_say("%s moved to the Editor view. Press 'Key camera pose' to record it at the playhead." % cam.name)


func _on_view_to_camera() -> void:
	var cam = _target_camera()
	if cam == null:
		_say("Select a Camera or pick one in the camera list.")
		return
	_look_from(cam.global_transform, 0.0)
	_say("Editor view is now looking through %s." % cam.name)


# ------------------------------------------------------------------ preview

# Letterboxes a pane's frame inside its holder. aspect = height / width, or <= 0 to fill.
func _fit_frame(pane: Dictionary, aspect: float) -> void:
	var avail = pane["holder"].rect_size
	var s = avail
	if aspect > 0.0:
		var w = min(avail.x, avail.y / aspect)
		s = Vector2(w, w * aspect)
	pane["frame"].rect_position = ((avail - s) * 0.5).floor()
	pane["frame"].rect_size = s.floor()


func _update_preview() -> void:
	_fit_frame(_res_pane, _aspect)
	_fit_frame(_edit_pane, -1.0)

	var active = _director.get_active_camera_node()
	_draw_gizmos(active)
	_draw_xform_gizmo()

	var src = null
	if _pv_chosen_check.pressed:
		src = _target_camera()
	else:
		src = active
	if src == null and not _cameras.empty():
		src = _root.get_node_or_null(_cameras[0]["path"])
	_preview_msg.visible = src == null

	# subtitle (a faded draft of the line you are typing is shown while no real subtitle is active)
	var shown = _director.subtitle
	var draft = false
	if shown == "" and _text_edit.text.strip_edges() != "":
		draft = true
		var sp = _speaker_edit.text.strip_edges()
		shown = _text_edit.text.strip_edges() if sp == "" else "%s: %s" % [sp, _text_edit.text.strip_edges()]
	_subtitle_label.text = shown
	_subtitle_label.modulate = Color(1, 1, 1, 0.55) if draft else Color(1, 1, 1, 1)
	_style_subtitle(_res_pane["frame"].rect_size.x / max(_proj_w, 1.0))

	if src == null or not (src is Camera):
		return
	_preview_cam.transform = src.global_transform * _director.get_shakify_offset(_time)
	_preview_cam.projection = src.projection
	_preview_cam.fov = src.fov
	_preview_cam.size = src.size
	_preview_cam.near = src.near
	_preview_cam.far = src.far
	_preview_cam.keep_aspect = src.keep_aspect
	_preview_cam.cull_mask = src.cull_mask & ~GIZMO_LAYER
	_preview_cam.environment = src.environment
	_preview_cam.h_offset = src.h_offset
	_preview_cam.v_offset = src.v_offset
	_preview_cam.frustum_offset = src.frustum_offset


# Uses the director's font / color, scaled down to the size of the Result pane.
func _style_subtitle(ratio: float) -> void:
	var f = _director.subtitle_font
	_subtitle_label.add_color_override("font_color", _director.subtitle_color)
	var sz = 0
	if f is DynamicFont:
		sz = f.size
	var id = 0
	if f != null:
		id = f.get_instance_id()
	var sig = "%d|%d|%d" % [id, sz, int(ratio * 100.0)]
	if sig == _sub_sig:
		return
	_sub_sig = sig
	if f == null:
		_subtitle_label.add_font_override("font", null)
	elif f is DynamicFont:
		var scaled = f.duplicate()
		scaled.size = int(max(6, round(sz * ratio)))
		_subtitle_label.add_font_override("font", scaled)
	else:
		_subtitle_label.add_font_override("font", f)


# ------------------------------------------------------------ track helpers

func _node_path_str(node: Node, prop: String = "") -> String:
	var p = str(_root.get_path_to(node))
	return p if prop == "" else p + ":" + prop


func _director_path(prop: String) -> String:
	return _node_path_str(_director, prop)


func _get_track(path: String, type: int, discrete: bool = false) -> int:
	var np = NodePath(path)
	var idx = -1
	for i in range(_anim.get_track_count()):
		if _anim.track_get_type(i) == type and _anim.track_get_path(i) == np:
			idx = i
			break
	if idx == -1:
		idx = _anim.add_track(type)
		_anim.track_set_path(idx, np)
		if type == Animation.TYPE_VALUE:
			if discrete:
				_anim.value_track_set_update_mode(idx, Animation.UPDATE_DISCRETE)
				_anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_NEAREST)
			else:
				_anim.value_track_set_update_mode(idx, Animation.UPDATE_CONTINUOUS)
				_anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_LINEAR)
	var fx_cat = _track_cat(idx)
	if fx_cat != "" and _fx_hidden.get(fx_cat, false):
		_set_fx_visible(fx_cat, true, false)     # keying a hidden effect shows it again
	return idx


func _extend(t: float) -> void:
	if t > _anim.length:
		_anim.length = t
		_syncing = true
		_len_spin.value = t
		_syncing = false


func _put_value(path: String, t: float, value, discrete: bool = false) -> void:
	var idx = _get_track(path, Animation.TYPE_VALUE, discrete)
	var k = _anim.track_find_key(idx, t, true)
	if k != -1:
		_anim.track_remove_key(idx, k)
	_anim.track_insert_key(idx, t, value)
	_extend(t)


# ---- transform keys with a per-key interpolation
# Godot only stores linear/cubic per *track*. So the plugin keeps its own list of keys for every transform
# track (time, pose, interpolation) in the Animation's metadata and "bakes" it into the real track:
# a key set to Constant gets a hold key right before the next key, so the pose stays put and then jumps.

func _src_dict() -> Dictionary:
	if _anim.has_meta(SRC_META):
		return _anim.get_meta(SRC_META)
	return {}


func _get_src(idx: int) -> Array:
	var d = _src_dict()
	var key = str(_anim.track_get_path(idx))
	if d.has(key):
		return d[key].duplicate(true)
	return _bootstrap_src(idx)


func _set_src(idx: int, src: Array) -> void:
	var d = _src_dict()
	d[str(_anim.track_get_path(idx))] = src
	_anim.set_meta(SRC_META, d)


func _drop_src(idx: int) -> void:
	var d = _src_dict()
	d.erase(str(_anim.track_get_path(idx)))
	_anim.set_meta(SRC_META, d)


# For tracks made before this list existed: read the real keys (and fold hold keys back into a Constant).
func _bootstrap_src(idx: int) -> Array:
	var out = []
	var n = _anim.track_get_key_count(idx)
	var itype = _anim.track_get_interpolation_type(idx)
	var mode = INTERP_LINEAR
	if itype == Animation.INTERPOLATION_CUBIC:
		mode = INTERP_CUBIC
	elif itype == Animation.INTERPOLATION_NEAREST:
		mode = INTERP_CUT
	for k in range(n):
		var t = _anim.track_get_key_time(idx, k)
		if k + 1 < n and _anim.track_get_key_time(idx, k + 1) - t <= CUT_GAP * 1.5:
			if not out.empty():
				out[out.size() - 1]["m"] = INTERP_CUT
			continue
		var v = _anim.track_get_key_value(idx, k)
		out.append({"t": t, "o": v["location"], "q": v["rotation"], "s": v["scale"], "m": mode})
	return out


# ---- audio key extras: Loop and (when looping) the length. Not looping: the length is Godot's own end offset.
func _aud_dict() -> Dictionary:
	if _anim.has_meta(AUD_META):
		return _anim.get_meta(AUD_META)
	return {}


func _aud_find(list: Array, t: float) -> int:
	for i in range(list.size()):
		if abs(list[i]["t"] - t) < 0.0005:
			return i
	return -1


func _aud_get(idx: int, t: float) -> Dictionary:
	var d = _aud_dict()
	var key = str(_anim.track_get_path(idx))
	if d.has(key):
		var i = _aud_find(d[key], t)
		if i != -1:
			return d[key][i].duplicate()
	return {"t": t, "loop": false, "dur": 0.0}


func _aud_put(idx: int, t: float, loop: bool, dur: float) -> void:
	var d = _aud_dict()
	var key = str(_anim.track_get_path(idx))
	var list = []
	if d.has(key):
		list = d[key]
	var i = _aud_find(list, t)
	if i != -1:
		list.remove(i)
	if loop or dur > 0.0:
		list.append({"t": t, "loop": loop, "dur": dur})
	if list.empty():
		d.erase(key)
	else:
		d[key] = list
	_anim.set_meta(AUD_META, d)


func _aud_drop(idx: int, t: float) -> void:
	_aud_put(idx, t, false, 0.0)


# How long the audio key plays in the timeline, and whether it loops.
func _aud_info(idx: int, k: int, t: float) -> Dictionary:
	var stream = _anim.audio_track_get_key_stream(idx, k)
	var length = 0.0
	if stream != null and stream.has_method("get_length"):
		length = stream.get_length()
	var ex = _aud_get(idx, t)
	var eff = 0.0
	if ex["loop"]:
		if ex["dur"] > 0.0:
			eff = ex["dur"]
		else:
			eff = max(_anim.length - t, 0.0)          # loops until the cutscene ends
	else:
		eff = max(length - _anim.audio_track_get_key_start_offset(idx, k) - _anim.audio_track_get_key_end_offset(idx, k), 0.0)
	return {"L": length, "loop": ex["loop"], "dur": ex["dur"], "eff": eff}


func _sort_src(a, b) -> bool:
	return a["t"] < b["t"]


func _rebake(idx: int, src: Array) -> void:
	while _anim.track_get_key_count(idx) > 0:
		_anim.track_remove_key(idx, 0)
	var cubic = 0
	var linear = 0
	for i in range(src.size()):
		var e = src[i]
		if i > 0 and src[i - 1]["m"] == INTERP_CUT:
			var p = src[i - 1]
			var ht = e["t"] - CUT_GAP
			if ht > p["t"] + CUT_GAP * 0.5:
				_anim.transform_track_insert_key(idx, ht, p["o"], p["q"], p["s"])
		_anim.transform_track_insert_key(idx, e["t"], e["o"], e["q"], e["s"])
		if e["m"] == INTERP_CUBIC:
			cubic += 1
		elif e["m"] == INTERP_LINEAR:
			linear += 1
	var kind = Animation.INTERPOLATION_CUBIC if cubic > linear else Animation.INTERPOLATION_LINEAR
	_anim.track_set_interpolation_type(idx, kind)
	_set_src(idx, src)


# mode: -1 = use the "Interpolation" dropdown, otherwise INTERP_LINEAR / INTERP_CUBIC / INTERP_CUT.
# The key is placed at time t (the playhead) and its mode describes the way to the NEXT key.
func _put_transform(node: Spatial, t: float, mode: int = -1) -> void:
	var into = -1                  # mode to give the PREVIOUS key, i.e. the move that arrives at this key
	if mode == -1:
		mode = _interp_opt.selected
		if _into_check.pressed:
			into = mode
	var idx = _get_track(_node_path_str(node), Animation.TYPE_TRANSFORM)
	var src = _get_src(idx)
	for i in range(src.size() - 1, -1, -1):
		if abs(src[i]["t"] - t) < 0.0005:
			src.remove(i)
	var xf: Transform = node.transform
	src.append({"t": t, "o": xf.origin, "q": Quat(xf.basis.orthonormalized()), "s": xf.basis.get_scale(), "m": mode})
	src.sort_custom(self, "_sort_src")
	if into != -1:
		for i in range(1, src.size()):
			if abs(src[i]["t"] - t) < 0.0005:
				src[i - 1]["m"] = into
	_rebake(idx, src)
	_extend(t)


func _finish_edit(message: String, reapply: bool) -> void:
	_refresh_keys()
	_mark_changed(message)
	if reapply:
		_seek(_time)
	_say(message)


func _ready_to_key() -> bool:
	if _anim == null:
		_say("Create or pick a cutscene first.")
		return false
	return true


# ------------------------------------------------------------------ cameras

func _collect_cameras(node: Node, out: Array) -> void:
	if node is Camera:
		out.append({"label": str(_root.get_path_to(node)), "path": str(_root.get_path_to(node))})
	for c in node.get_children():
		_collect_cameras(c, out)


func _refresh_cameras() -> void:
	_cameras = []
	_cam_opt.clear()
	if _root == null:
		return
	_collect_cameras(_root, _cameras)
	for c in _cameras:
		_cam_opt.add_item(c["label"])


func _chosen_camera():
	if _cam_opt.selected < 0 or _cam_opt.selected >= _cameras.size():
		return null
	return _root.get_node_or_null(_cameras[_cam_opt.selected]["path"])


func _selected_nodes() -> Array:
	var out = []
	if _root == null:
		return out
	if not _picked.empty():                       # picked in the Nodes list
		for path in _picked:
			var pn = _root.get_node_or_null(NodePath(str(path)))
			if pn != null:
				out.append(pn)
		if not out.empty():
			return out
	for n in editor.get_selection().get_selected_nodes():
		if n == _root or _root.is_a_parent_of(n):
			out.append(n)
	return out


func _selected_camera():
	for n in _selected_nodes():
		if n is Camera:
			return n
	return null


func _target_camera():
	var c = _selected_camera()
	return c if c != null else _chosen_camera()


func _on_cut_camera() -> void:
	if not _ready_to_key():
		return
	var cam = _chosen_camera()
	if cam == null:
		_say("There is no camera to cut to. Add a Camera node to the scene.")
		return
	_put_value(_director_path("active_camera"), _time, _director.get_path_to(cam), true)
	_finish_edit("Cut to %s at %s" % [cam.name, _fmt_time(_time)], true)


# ---------------------------------------------------------- camera movement

func _on_key_camera_pose() -> void:
	if not _ready_to_key():
		return
	var cam = _target_camera()
	if cam == null:
		_say("Select a Camera or pick one in the camera list.")
		return
	_put_transform(cam, _time)
	_finish_edit("Keyed %s pose at %s, next: %s" % [cam.name, _fmt_time(_time), _interp_opt.get_item_text(_interp_opt.selected)], false)


func _on_apply_interp() -> void:
	if _anim == null:
		return
	var by_track = _selected_times(true)
	if by_track.empty():
		_say("Click a pose key (a camera / transform key) in the timeline first.")
		return
	var any_last = false
	for idx in by_track:
		var src = _get_src(idx)
		for i in range(src.size()):
			if _has_time(by_track[idx], src[i]["t"]):
				src[i]["m"] = _interp_opt.selected
				if i == src.size() - 1:
					any_last = true
		_rebake(idx, src)
	_finish_edit("Pose key(s): next is now %s" % _interp_opt.get_item_text(_interp_opt.selected), true)
	if any_last:
		_say("The last pose key has no key after it yet, so nothing changes until you add one: this only affects the move to the key AFTER it.")


# Keys the camera's current pose at the playhead, then the Editor view's pose `Over (s)` later.
func _on_move_to_view() -> void:
	if not _ready_to_key():
		return
	var cam = _target_camera()
	if cam == null:
		_say("Select a Camera or pick one in the camera list.")
		return
	var smooth = INTERP_CUBIC if _interp_opt.selected == INTERP_CUBIC else INTERP_LINEAR
	_put_transform(cam, _time, smooth)                       # where the move starts (tweens to the end)
	var end_t = _time + _move_dur_spin.value
	cam.global_transform = _edit_view_transform()            # where it ends
	_put_transform(cam, end_t)                               # dropdown = what happens after the move
	var how = _interp_opt.get_item_text(_interp_opt.selected)
	_finish_edit("%s moves to the Editor view by %s (after that: %s)" % [cam.name, _fmt_time(end_t), how], true)


# ----------------------------------------------------------- selected nodes

func _on_selection_changed() -> void:
	if _sel_label == null:
		return
	var nodes = _selected_nodes()
	_bounds_cache.clear()
	_sync_list_selection()
	_refresh_anim_ui()
	_refresh_xform_fields(true)
	_refresh_mh_tab()
	if nodes.empty():
		_sel_label.text = "Nothing selected in the scene tree."
		_rebuild_inspector()
		return
	var n = nodes[0]
	_sel_label.text = "%s (%s)%s" % [n.name, n.get_class(), "" if nodes.size() == 1 else "  +%d more" % (nodes.size() - 1)]
	if n.get_instance_id() != _ins_node_id:
		_rebuild_inspector()


# ------------------------------------------------------------------ property inspector (Nodes tab)
# The properties of the first selected node, grouped by class. Every row has a key button that keys the
# value at the playhead. Shown: bool, int, float, enum, Vector2, Vector3 and Color properties (the keyable ones).
# Position / rotation / scale of 3D nodes stay in the transform box above, keyed as one transform.
# A MeshInstance also shows its materials (one section per surface) so colours, roughness, emission ... can be
# edited and keyed. A material that is shared (it comes from the mesh or a .tres file) first needs a unique copy,
# because only a material that belongs to the node can be animated.

const INS_TYPES = [TYPE_BOOL, TYPE_INT, TYPE_REAL, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_COLOR]
const INS_SKIP_COMMON = ["script", "name", "owner", "filename", "process_priority", "pause_mode", "editor_description", "resource_name", "resource_path", "resource_local_to_scene"]
const INS_SKIP_SPATIAL = ["transform", "global_transform", "translation", "rotation", "rotation_degrees", "scale"]


func _ins_node():
	if _ins_node_id == 0:
		return null
	var o = instance_from_id(_ins_node_id)
	if o == null or not is_instance_valid(o) or not (o is Node):
		return null
	return o


func _ins_target(e: Dictionary):
	var o = instance_from_id(e["tid"])
	if o == null or not is_instance_valid(o):
		return null
	return o


func _on_ins_filter(_text) -> void:
	_rebuild_inspector()


func _ins_toggle(head: Button, body: Control, cat: String) -> void:
	body.visible = not body.visible
	head.icon = _arrow_icon(body.visible)
	_ins_open[cat] = body.visible


func _rebuild_inspector() -> void:
	if _ins_box == null:
		return
	for c in _ins_box.get_children():
		_ins_box.remove_child(c)
		c.queue_free()
	_ins_rows = []
	_ins_previews = []
	_ins_node_id = 0
	var nodes = _selected_nodes()
	if nodes.empty():
		_hint("Select a node (Editor view, Nodes list or scene tree) to see its properties here.", _ins_box)
		return
	var n = nodes[0]
	_ins_node_id = n.get_instance_id()
	var filter = _ins_filter.text.strip_edges().to_lower()
	var made = _ins_props(n, "", filter, _ins_box, true)
	if n is MeshInstance:
		_ins_materials(n, filter)
	elif made == 0:
		_hint("No keyable properties%s." % (" match the filter" if filter != "" else ""), _ins_box)


# Rows for the keyable properties of `target` (the node, or one of its materials). `sub` is the property path
# from the node to the target ("" = the node itself, "material/0" = its first surface material).
# With `by_class` the rows are grouped in folding sections per class; otherwise they go in one flat list.
# Returns how many rows were made.
func _ins_props(target: Object, sub: String, filter: String, parent: Control, by_class: bool) -> int:
	var cat = ""
	var body = parent if not by_class else null
	var group = ""
	var gprefix = ""
	var gbody = null
	var made = 0
	var sections = 0
	for p in target.get_property_list():
		var usage = p["usage"]
		if (usage & PROPERTY_USAGE_CATEGORY) != 0:
			cat = str(p["name"])
			if by_class:
				body = null
			group = ""
			gprefix = ""
			gbody = null
			continue
		if (usage & PROPERTY_USAGE_GROUP) != 0:
			group = str(p["name"])
			gprefix = str(p.get("hint_string", ""))
			gbody = null
			continue
		if (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var pname = str(p["name"])
		if INS_SKIP_COMMON.has(pname) or (target is Spatial and INS_SKIP_SPATIAL.has(pname)):
			continue
		if not INS_TYPES.has(p["type"]):
			continue
		if filter != "" and pname.to_lower().find(filter) == -1:
			continue
		if body == null:
			var open = true if filter != "" else _ins_open.get(cat, true)
			body = _ins_category(cat if cat != "" else target.get_class(), open, parent)
			sections += 1
		var holder = body
		var shown = pname
		if group != "":
			if gbody == null:
				var gkey = "g:%s:%s:%s" % [sub, cat, group]
				gbody = _ins_group(group, filter != "" or _ins_open.get(gkey, false), body, gkey)
			holder = gbody
			if gprefix != "" and pname.begins_with(gprefix):
				shown = pname.substr(gprefix.length())
		_ins_add_row(target, sub, p, holder, shown)
		made += 1
	return made


# A property category (a class) as the dark centred bar of Godot's own inspector: class icon + class name.
# Click it to fold the category.
func _ins_category(cat: String, open: bool, parent: Control) -> VBoxContainer:
	var base = editor.get_base_control()
	var bar = _ed_color("prop_category", Color(0.21, 0.22, 0.26))
	var head = Button.new()
	head.align = Button.ALIGN_CENTER
	head.text = cat
	head.icon = _class_icon(cat)
	head.focus_mode = Control.FOCUS_NONE
	head.hint_tooltip = "Click to fold / unfold"
	if base.has_font("bold", "EditorFonts"):
		head.add_font_override("font", base.get_font("bold", "EditorFonts"))
	head.add_stylebox_override("normal", _flat_box(bar, 4))
	head.add_stylebox_override("hover", _flat_box(bar.lightened(0.08), 4))
	head.add_stylebox_override("pressed", _flat_box(bar, 4))
	head.add_stylebox_override("focus", StyleBoxEmpty.new())
	parent.add_child(head)
	var body = VBoxContainer.new()
	body.add_constant_override("separation", 2)
	body.visible = open
	parent.add_child(body)
	head.connect("pressed", self, "_ins_toggle_plain", [body, cat])
	return body


# A folding group inside a category (Transform, Visibility, Albedo ...): small arrow + name, rows indented below.
# Returns the box the rows go in.
func _ins_group(title: String, open: bool, parent: Control, key: String) -> VBoxContainer:
	var head = Button.new()
	head.flat = true
	head.align = Button.ALIGN_LEFT
	head.text = title
	head.icon = _arrow_icon(open)
	head.focus_mode = Control.FOCUS_NONE
	parent.add_child(head)
	var margin = MarginContainer.new()
	margin.add_constant_override("margin_left", 12)
	margin.visible = open
	parent.add_child(margin)
	var body = VBoxContainer.new()
	body.add_constant_override("separation", 2)
	margin.add_child(body)
	head.connect("pressed", self, "_ins_toggle", [head, margin, key])
	return body


func _ins_toggle_plain(body: Control, key: String) -> void:
	body.visible = not body.visible
	_ins_open[key] = body.visible


func _flat_box(col: Color, pad: int = 4) -> StyleBoxFlat:
	var sb = StyleBoxFlat.new()
	sb.bg_color = col
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	return sb


# A colour of the editor's own theme (falls back to `fallback` in versions that lack it).
func _ed_color(name: String, fallback: Color) -> Color:
	var base = editor.get_base_control()
	if base.has_color(name, "Editor"):
		return base.get_color(name, "Editor")
	return fallback


func _ins_enum_items(ob: OptionButton, hint: String) -> void:
	var idx = 0
	for part in hint.split(","):
		var nm = part
		var id = idx
		if ":" in part:
			nm = part.get_slice(":", 0)
			id = int(part.get_slice(":", 1))
		ob.add_item(nm.strip_edges(), id)
		idx = id + 1


func _ins_add_row(target: Object, sub: String, p: Dictionary, parent: Control, shown: String = "") -> void:
	var pname = str(p["name"])
	var t = p["type"]
	var val = target.get(pname)
	var hint = int(p.get("hint", 0))
	var hint_str = str(p.get("hint_string", ""))
	var row = VBoxContainer.new()
	row.add_constant_override("separation", 2)
	parent.add_child(row)
	var line = HBoxContainer.new()
	line.add_constant_override("separation", 8)
	row.add_child(line)
	var is_vec = not (t == TYPE_BOOL or t == TYPE_INT or t == TYPE_REAL or t == TYPE_COLOR)
	var lab = _label((shown if shown != "" else pname).capitalize(), line)
	lab.hint_tooltip = pname
	lab.mouse_filter = Control.MOUSE_FILTER_STOP
	lab.clip_text = true
	lab.align = Label.ALIGN_RIGHT
	lab.valign = Label.VALIGN_TOP if is_vec else Label.VALIGN_CENTER
	lab.rect_min_size = Vector2(FORM_LABEL_W, 28)
	lab.modulate = Color(1, 1, 1, 0.85)
	var e = {"row": row, "tid": target.get_instance_id(), "sub": sub, "prop": pname, "kind": "", "ctl": null, "last": val}
	if t == TYPE_BOOL:
		var cb = CheckBox.new()
		cb.text = "On"
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cb.pressed = val
		cb.connect("toggled", self, "_ins_set", [e])
		line.add_child(cb)
		e["kind"] = "bool"
		e["ctl"] = cb
	elif t == TYPE_INT and hint == PROPERTY_HINT_ENUM:
		var ob = OptionButton.new()
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ob.clip_text = true
		_ins_enum_items(ob, hint_str)
		var at = ob.get_item_index(int(val))
		if at >= 0:
			ob.select(at)
		ob.connect("item_selected", self, "_ins_enum", [e, ob])
		line.add_child(ob)
		e["kind"] = "enum"
		e["ctl"] = ob
	elif t == TYPE_INT or t == TYPE_REAL:
		var mn = -1000000.0
		var mx = 1000000.0
		var st = 1.0 if t == TYPE_INT else 0.001
		var ranged = false
		var more = false
		var less = false
		if hint == PROPERTY_HINT_RANGE:
			var parts = hint_str.split(",")
			if parts.size() >= 2:
				mn = float(parts[0])
				mx = float(parts[1])
				ranged = mx > mn
			if parts.size() >= 3 and float(parts[2]) > 0.0:
				st = float(parts[2])
			for part in parts:
				var flag = part.strip_edges()
				if flag == "or_greater":
					more = true
				elif flag == "or_lesser":
					less = true
		if ranged:
			# metallic, roughness, normal scale ...: a slider with the number next to it (type to enter exact values)
			var box = HBoxContainer.new()
			box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			box.add_constant_override("separation", 6)
			line.add_child(box)
			var sl = HSlider.new()
			sl.min_value = mn
			sl.max_value = mx
			sl.step = st
			sl.allow_greater = more
			sl.allow_lesser = less
			sl.value = float(val)
			sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			sl.rect_min_size = Vector2(40, 20)
			sl.connect("value_changed", self, "_ins_slider_moved", [e])
			box.add_child(sl)
			var ed = LineEdit.new()
			ed.rect_min_size = Vector2(56, 0)
			ed.align = LineEdit.ALIGN_CENTER
			ed.text = _ins_fmt(float(val), t == TYPE_INT)
			ed.connect("text_entered", self, "_ins_slider_typed", [e])
			ed.connect("focus_exited", self, "_ins_slider_blur", [e])
			box.add_child(ed)
			e["kind"] = "slider"
			e["ctl"] = sl
			e["edit"] = ed
			e["int"] = t == TYPE_INT
		else:
			var sp = _spin(line, mn, mx, st, float(val))
			sp.allow_greater = true
			sp.allow_lesser = true
			sp.connect("value_changed", self, "_ins_set", [e])
			e["kind"] = "num"
			e["ctl"] = sp
	elif t == TYPE_COLOR:
		var cp = ColorPickerButton.new()
		cp.edit_alpha = true
		cp.color = val
		cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cp.rect_min_size = Vector2(40, 24)
		cp.connect("color_changed", self, "_ins_set", [e])
		line.add_child(cp)
		e["kind"] = "color"
		e["ctl"] = cp
	else:
		var dims = 2 if t == TYPE_VECTOR2 else 3
		var col = VBoxContainer.new()                  # vectors: the fields stacked on the value side
		col.add_constant_override("separation", 2)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(col)
		var spins = []
		for ax in range(dims):
			var vs = _spin(col, -1000000, 1000000, 0.001, val[ax])
			vs.allow_greater = true
			vs.allow_lesser = true
			vs.prefix = ["X", "Y", "Z"][ax]
			vs.connect("value_changed", self, "_ins_set_axis", [e, ax])
			spins.append(vs)
		e["kind"] = "vec"
		e["ctl"] = spins
	var kb = _icon_button(["KeyValue", "Key"], "Key", "Key '%s' at the playhead" % pname, line, "_on_key_prop", [e])
	kb.flat = true
	if is_vec:
		kb.size_flags_vertical = 0
	_ins_rows.append(e)


func _ins_fmt(v: float, is_int: bool) -> String:
	return str(int(round(v))) if is_int else str(stepify(v, 0.001))


func _ins_slider_moved(v: float, e: Dictionary) -> void:
	var ed = e.get("edit")
	if ed != null and is_instance_valid(ed) and not ed.has_focus():
		ed.text = _ins_fmt(v, e["int"])
	_ins_set(v, e)


func _ins_slider_typed(text: String, e: Dictionary) -> void:
	var sl = e["ctl"]
	var ed = e["edit"]
	if not is_instance_valid(sl) or not is_instance_valid(ed):
		return
	if text.strip_edges().is_valid_float():
		sl.value = float(text)
	ed.text = _ins_fmt(sl.value, e["int"])
	ed.release_focus()


func _ins_slider_blur(e: Dictionary) -> void:
	if is_instance_valid(e["edit"]):
		_ins_slider_typed(e["edit"].text, e)


func _ins_set(value, e: Dictionary) -> void:
	if _ins_syncing:
		return
	var tg = _ins_target(e)
	if tg == null:
		return
	var prop = e["prop"]
	var old = tg.get(prop)
	if typeof(old) == TYPE_INT:
		value = int(value)
	elif typeof(old) == TYPE_REAL:
		value = float(value)
	if old == value:
		return
	var who = str(tg.name) if tg is Node else (str(_ins_node().name) if _ins_node() != null else "material")
	undo_redo.create_action("Edit %s of %s" % [prop, who], UndoRedo.MERGE_ENDS)
	undo_redo.add_do_property(tg, prop, value)
	undo_redo.add_undo_property(tg, prop, old)
	undo_redo.commit_action()
	if editor.has_method("mark_scene_as_unsaved"):
		editor.mark_scene_as_unsaved()
	e["last"] = tg.get(prop)
	if tg is Material:
		_ins_schedule_previews()
	_say("%s of %s edited. Press its key button to key it at %s." % [prop, who, _fmt_time(_time)])


func _ins_set_axis(value: float, e: Dictionary, axis: int) -> void:
	if _ins_syncing:
		return
	var tg = _ins_target(e)
	if tg == null:
		return
	var nv = tg.get(e["prop"])
	nv[axis] = value
	_ins_set(nv, e)


func _ins_enum(index: int, e: Dictionary, ob: OptionButton) -> void:
	_ins_set(ob.get_item_id(index), e)


# Keeps the shown values in step with the node / material (animation scrubbing, gizmo drags, undo ...).
func _ins_refresh() -> void:
	if _ins_rows.empty():
		return
	_ins_syncing = true
	for r in _ins_rows:
		if not r["row"].is_visible_in_tree():
			continue
		var tg = _ins_target(r)
		if tg == null:
			continue
		var v = tg.get(r["prop"])
		if v == r["last"]:
			continue
		r["last"] = v
		var ctl = r["ctl"]
		var kind = r["kind"]
		if kind == "bool":
			ctl.pressed = v
		elif kind == "enum":
			var at = ctl.get_item_index(int(v))
			if at >= 0:
				ctl.select(at)
		elif kind == "slider":
			ctl.value = float(v)
			if not r["edit"].has_focus():
				r["edit"].text = _ins_fmt(float(v), r["int"])
		elif kind == "num":
			if not ctl.get_line_edit().has_focus():
				ctl.value = float(v)
		elif kind == "color":
			ctl.color = v
		else:
			for ax in range(ctl.size()):
				if not ctl[ax].get_line_edit().has_focus():
					ctl[ax].value = v[ax]
	_ins_syncing = false


# Key button of a property row. Node properties are keyed on every selected node that has them; a material
# property is keyed on the mesh it belongs to (path like  MeshInstance:material/0:albedo_color).
func _on_key_prop(e: Dictionary) -> void:
	if not _ready_to_key():
		return
	var prop = e["prop"]
	var discrete = e["kind"] == "bool" or e["kind"] == "enum"
	if e["sub"] != "":
		var owner_node = _ins_node()
		var tg = _ins_target(e)
		if owner_node == null or tg == null:
			_say("Select a node first.")
			return
		_put_value(_node_path_str(owner_node, "%s:%s" % [e["sub"], prop]), _time, tg.get(prop), discrete)
		_finish_edit("Keyed %s of %s (%s) at %s" % [prop, owner_node.name, e["sub"], _fmt_time(_time)], false)
		return
	var count = 0
	var first = ""
	for n in _selected_nodes():
		if n == _director or not (prop in n):
			continue
		_put_value(_node_path_str(n, prop), _time, n.get(prop), discrete)
		if count == 0:
			first = str(n.name)
		count += 1
	if count == 0:
		_say("Select a node first.")
		return
	_finish_edit("Keyed %s of %s at %s" % [prop, first if count == 1 else "%d nodes" % count, _fmt_time(_time)], false)


# ---- materials of a MeshInstance

func _ins_materials(n: MeshInstance, filter: String) -> void:
	if n.mesh == null:
		_hint("This MeshInstance has no mesh.", _ins_box)
		return
	if n.material_override == null:
		var orow = _form(_ins_box, "Override", "A Material Override replaces the material of every surface of this node.")
		var ob = _button("Add material override", orow, "_ins_mat_new", [-1])
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var oic = _icon(["Add"])
		if oic != null:
			ob.icon = oic
	if n.material_override != null:
		_ins_material_section(n, -1, n.material_override, n.material_override, filter)
		return
	var count = n.get_surface_material_count()
	if count == 0:
		_hint("This mesh has no surfaces.", _ins_box)
	for i in range(count):
		_ins_material_section(n, i, n.get_active_material(i), n.get_surface_material(i), filter)


# surf = -1: the node's Material Override. `active` is the material in use, `own` the one that belongs to the node
# (null when the surface still uses the mesh's material).
# Looks like Godot's material editor: a "Material" header row (tinted name cell + resource button), the sphere
# preview, then the properties in folding groups.
func _ins_material_section(n: MeshInstance, surf: int, active, own, filter: String) -> void:
	var title = "Material override" if surf < 0 else "Surface %d" % surf
	var key = "mat:%s" % title
	var open = filter != "" or _ins_open.get(key, true)
	var cls = active.get_class() if active != null else "Material"

	var holder = VBoxContainer.new()
	holder.add_constant_override("separation", 2)
	_ins_box.add_child(holder)

	var head = HBoxContainer.new()
	head.add_constant_override("separation", 0)
	holder.add_child(head)
	var name_cell = PanelContainer.new()
	name_cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_cell.size_flags_stretch_ratio = 0.9
	name_cell.add_stylebox_override("panel", _flat_box(_ed_color("prop_subsection", Color(0.30, 0.25, 0.36)).lightened(0.12), 8))
	head.add_child(name_cell)
	var name_lab = _label(title, name_cell)
	name_lab.clip_text = true
	name_lab.valign = Label.VALIGN_CENTER
	var res_btn = Button.new()
	res_btn.text = cls
	res_btn.icon = _class_icon(cls)
	res_btn.align = Button.ALIGN_LEFT
	res_btn.clip_text = true
	res_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res_btn.size_flags_stretch_ratio = 1.3
	res_btn.hint_tooltip = "Click to fold / unfold"
	head.add_child(res_btn)

	var body = VBoxContainer.new()
	body.add_constant_override("separation", 2)
	body.visible = open
	holder.add_child(body)
	res_btn.connect("pressed", self, "_ins_toggle_plain", [body, key])

	_ins_mat_tools(surf, active, own, body)
	if active == null:
		_hint("No material on this surface.", body)
		return
	_ins_preview(active, body)
	if own == null:
		_hint("This material belongs to the mesh and may be shared by other nodes. Make a unique copy for this node to edit and key it.", body)
		return
	if own.resource_path != "":
		_hint("This material is a shared file (%s): changes affect every node that uses it." % own.resource_path.get_file(), body)
	var sub = "material_override" if surf < 0 else "material/%d" % surf
	var made = _ins_props(own, sub, filter, body, false)
	if made == 0:
		_hint("No keyable properties%s." % (" match the filter" if filter != "" else " (this material type is not supported)"), body)


# New / Unique copy / Remove buttons of a material section.
func _ins_mat_tools(surf: int, active, own, parent: Control) -> void:
	var row = HBoxContainer.new()
	parent.add_child(row)
	var nb = _button("New", row, "_ins_mat_new", [surf])
	nb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nb.hint_tooltip = "Give this surface a new material of its own (replaces the one it has now)."
	var add_ic = _icon(["Add"])
	if add_ic != null:
		nb.icon = add_ic
	if active != null and (own == null or own.resource_path != ""):
		var cb = _button("Unique copy", row, "_ins_mat_copy", [surf])
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cb.hint_tooltip = "Copy the material so this node has its own, editable version."
		var copy_ic = _icon(["Duplicate", "ActionCopy"])
		if copy_ic != null:
			cb.icon = copy_ic
	var rb = _button("Remove", row, "_ins_mat_remove", [surf])
	rb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rb.disabled = own == null
	rb.hint_tooltip = "Remove this node's own material." if own != null else "Nothing to remove: this surface uses the mesh's material."
	var rem_ic = _icon(["Remove", "Close"])
	if rem_ic != null:
		rb.icon = rem_ic


func _ins_mat_remove(surf: int) -> void:
	_ins_mat_assign(surf, null, "Remove material")


# The sphere picture of a material on a checkerboard, made by the editor's own resource previewer.
func _ins_preview(mat: Material, parent: Control) -> void:
	var holder = Control.new()
	holder.rect_min_size = Vector2(0, 120)
	holder.rect_clip_content = true
	parent.add_child(holder)
	var checker = TextureRect.new()
	checker.texture = _checker_texture()
	checker.expand = true
	checker.stretch_mode = TextureRect.STRETCH_TILE
	checker.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	holder.add_child(checker)
	var pic = TextureRect.new()
	pic.expand = true
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	holder.add_child(pic)
	_ins_previews.append({"mat": mat, "rect": pic})
	var prev = editor.get_resource_previewer()
	if prev != null:
		prev.queue_edited_resource_preview(mat, self, "_ins_preview_ready", pic)


func _ins_preview_ready(_path, preview, _thumb, pic) -> void:
	if pic != null and is_instance_valid(pic) and preview != null:
		pic.texture = preview


# After an edit: redo the pictures (once the editing pauses).
func _ins_schedule_previews() -> void:
	if _ins_prev_pending or _ins_previews.empty() or not is_inside_tree():
		return
	_ins_prev_pending = true
	get_tree().create_timer(0.35).connect("timeout", self, "_ins_run_previews")


func _ins_run_previews() -> void:
	_ins_prev_pending = false
	var prev = editor.get_resource_previewer()
	if prev == null:
		return
	for e in _ins_previews:
		if e["mat"] != null and is_instance_valid(e["rect"]):
			prev.queue_edited_resource_preview(e["mat"], self, "_ins_preview_ready", e["rect"])


func _checker_texture() -> Texture:
	if _checker == null:
		var img = Image.new()
		img.create(16, 16, false, Image.FORMAT_RGBA8)
		img.lock()
		for y in range(16):
			for x in range(16):
				var light = ((x / 8) + (y / 8)) % 2 == 0
				img.set_pixel(x, y, Color(0.36, 0.36, 0.38) if light else Color(0.27, 0.27, 0.29))
		img.unlock()
		var t = ImageTexture.new()
		t.create_from_image(img, Texture.FLAG_REPEAT)
		_checker = t
	return _checker


# Gives the surface (or the Material Override when surf = -1) a material of its own and refreshes the inspector.
func _ins_mat_assign(surf: int, mat: Material, label: String) -> void:
	var n = _ins_node()
	if n == null or not (n is MeshInstance):
		return
	undo_redo.create_action("%s on %s" % [label, n.name])
	if surf < 0:
		undo_redo.add_do_property(n, "material_override", mat)
		undo_redo.add_undo_property(n, "material_override", n.material_override)
	else:
		undo_redo.add_do_method(n, "set_surface_material", surf, mat)
		undo_redo.add_undo_method(n, "set_surface_material", surf, n.get_surface_material(surf))
	undo_redo.commit_action()
	if editor.has_method("mark_scene_as_unsaved"):
		editor.mark_scene_as_unsaved()
	_rebuild_inspector()


func _ins_mat_copy(surf: int) -> void:
	var n = _ins_node()
	if n == null or not (n is MeshInstance):
		return
	var src = n.material_override if surf < 0 else n.get_active_material(surf)
	if src == null:
		return
	_ins_mat_assign(surf, src.duplicate(), "Unique material")


func _ins_mat_new(surf: int) -> void:
	_ins_mat_assign(surf, SpatialMaterial.new(), "New material")


# ------------------------------------------------------------------ node list

func _class_icon(cls: String) -> Texture:
	var c = editor.get_base_control()
	if c.has_icon(cls, "EditorIcons"):
		return c.get_icon(cls, "EditorIcons")
	return c.get_icon("Spatial", "EditorIcons")


func _on_node_filter(_text) -> void:
	_refresh_node_list()


# Lists every Spatial node you can see in the scene tree (nodes inside instanced scenes only when they are
# editable). The Cinematic node itself is left out.
func _refresh_node_list() -> void:
	if _node_list == null:
		return
	_list_syncing = true
	_node_list.clear()
	_node_tree_root = _node_list.create_item()
	if _root != null:
		var filter = _node_filter.text.strip_edges().to_lower()
		_add_node_rows(_root, 0, filter)
	_list_syncing = false
	_sync_list_selection()


func _add_node_rows(n: Node, depth: int, filter: String) -> void:
	if n == _director:
		return
	if n is Spatial and (n == _root or n.owner == _root):
		var cls = n.get_class()
		if filter == "" or str(n.name).to_lower().find(filter) != -1 or cls.to_lower().find(filter) != -1:
			var indent = ""
			if filter == "":
				for i in range(depth):
					indent += "   "
			var players = []
			_find_players(n, players)
			var text = indent + str(n.name)
			if not players.empty():
				text += "   [anim]"
			var item = _node_list.create_item(_node_tree_root)
			item.set_text(0, text)
			item.set_icon(0, _class_icon(cls))
			item.set_metadata(0, str(_root.get_path_to(n)))
			item.set_tooltip(0, "%s  (%s)" % [str(_root.get_path_to(n)), cls])
			item.set_selectable(1, false)
			var eye = _eye_on if n.visible else _eye_off
			if eye != null:
				item.add_button(1, eye, 0, false, "Show / hide this node")
	for c in n.get_children():
		_add_node_rows(c, depth + 1, filter)


func _node_items() -> Array:
	var out = []
	if _node_tree_root == null:
		return out
	var it = _node_tree_root.get_children()
	while it != null:
		out.append(it)
		it = it.get_next()
	return out


# Makes the list highlight what is selected in the scene tree.
func _sync_list_selection() -> void:
	if _node_list == null or _node_tree_root == null:
		return
	_list_syncing = true
	var wanted = {}
	if _root != null:
		for n in _selected_nodes():
			wanted[str(_root.get_path_to(n))] = true
	var first = null
	for it in _node_items():
		if wanted.has(str(it.get_metadata(0))):
			it.select(0)
			if first == null:
				first = it
		else:
			it.deselect(0)
	if first != null:
		_node_list.scroll_to_item(first)
	_list_syncing = false


# Clicking in the list picks nodes inside this tab only. (Selecting them in the editor would make Godot
# jump to the 3D tab.) Every button below works on the picked nodes.
func _on_node_list_selected(_item = null, _column = 0, _state = true) -> void:
	if _root == null or _list_syncing:
		return
	_picked = []
	for it in _node_items():
		if it.is_selected(0):
			_picked.append(str(it.get_metadata(0)))
	_on_selection_changed()


# The eye of a row in the Nodes list.
func _on_node_eye_pressed(item: TreeItem, _column: int, _id: int) -> void:
	_toggle_node_visible(_row_node(str(item.get_metadata(0))))


# ---- show / hide (the eye icons in the Nodes list and the timeline)

# The node a timeline row / list entry stands for (paths are relative to the scene root).
func _row_node(path: String) -> Node:
	if _root == null:
		return null
	if path == "":
		return _root
	return _root.get_node_or_null(path)


func _toggle_node_visible(n: Node) -> void:
	if n == null or not ("visible" in n):
		return
	var old = n.visible
	undo_redo.create_action("%s %s" % ["Hide" if old else "Show", n.name])
	undo_redo.add_do_property(n, "visible", not old)
	undo_redo.add_undo_property(n, "visible", old)
	undo_redo.add_do_method(self, "_refresh_eyes")
	undo_redo.add_undo_method(self, "_refresh_eyes")
	undo_redo.commit_action()
	_say("%s %s." % [n.name, "hidden" if old else "shown"])


# Redraws every eye (Nodes list buttons and the timeline).
func _refresh_eyes() -> void:
	if _node_list != null and _root != null:
		for it in _node_items():
			var n = _row_node(str(it.get_metadata(0)))
			if n != null and "visible" in n:
				var eye = _eye_on if n.visible else _eye_off
				if eye != null and it.get_button_count(1) > 0:
					it.set_button(1, 0, eye)
	if _sheet != null:
		_sheet.update()


# Selecting something in the scene tree takes over again from the list.
func _on_editor_selection_changed() -> void:
	_picked = []
	_on_selection_changed()


# ------------------------------------------------------------------ edit position / rotation / scale

# The node whose transform the spin boxes edit: the first selected 3D node.
func _xform_node():
	for n in _selected_nodes():
		if n is Spatial and n != _director:
			return n
	return null


func _refresh_xform_fields(force: bool = false) -> void:
	if _xform_box == null:
		return
	var n = _xform_node()
	_xform_box.visible = n != null
	if _xform_card != null:
		_xform_card.visible = _xform_box.visible
	if n == null:
		_xf_last = []
		return
	var vals = [n.translation, n.rotation_degrees, n.scale]
	if not force and _xf_last.size() == 3 and _xf_last[0] == vals[0] and _xf_last[1] == vals[1] and _xf_last[2] == vals[2]:
		return
	_xf_last = vals
	_xf_syncing = true
	for a in range(3):
		for ax in range(3):
			var sp = _xf_spins[a][ax]
			if sp.get_line_edit().has_focus():
				continue                       # do not fight the number you are typing
			sp.value = vals[a][ax]
	_xf_syncing = false


func _on_xform_edited(value: float, prop: String, axis: int) -> void:
	if _xf_syncing:
		return
	var n = _xform_node()
	if n == null:
		return
	var old = n.get(prop)
	var nv = old
	nv[axis] = value                          # only the box you touched changes, the rest stays exact
	if nv == old:
		return
	undo_redo.create_action("Edit %s of %s" % [prop, n.name], UndoRedo.MERGE_ENDS)
	undo_redo.add_do_property(n, prop, nv)
	undo_redo.add_undo_property(n, prop, old)
	undo_redo.commit_action()
	_xf_last = [n.translation, n.rotation_degrees, n.scale]
	if editor.has_method("mark_scene_as_unsaved"):
		editor.mark_scene_as_unsaved()
	_say("%s of %s edited. Press 'Key transform' to key it at %s." % [prop, n.name, _fmt_time(_time)])


# ------------------------------------------------------------------ MetaHuman face board
# The face board (MetaHumanFaceBoard3D, from the MetaHuman Rig add-on) is an ordinary node of the scene:
#  * it is drawn in the Editor view (so it can be picked and its dots dragged) but never in the Result view,
#    because its quad is on the same visual layer as this tab's gizmos (GIZMO_LAYER), which the Result camera skips;
#  * every face control is a float property  face/<control>  of that node, so it also shows up in the Properties
#    list below (group "Face controls") and any of them can be keyed one by one;
#  * "Key face pose" keys all controls in use at once, "I" does the same while the board is selected.

func _face_node():
	for n in _selected_nodes():
		if n is Spatial and n != _director and n.has_method("get_face_pose"):
			return n
	return null


func _find_face_boards(n: Node, out: Array, only_visible: bool = true) -> void:
	if n is Spatial and n.has_method("get_face_pose") and n.has_method("handle_input") and (n.is_visible_in_tree() or not only_visible):
		out.append(n)
	for c in n.get_children():
		_find_face_boards(c, out, only_visible)


# Shows / hides the MetaHuman tab and keeps its 2D board in step with the scene's MetaHumanFaceBoard3D.
func _refresh_mh_tab(rescan: bool = false) -> void:
	if _mh_page == null:
		return
	if rescan or _mh_node == null or not is_instance_valid(_mh_node) or not _mh_node.is_inside_tree():
		var old = _mh_node
		_mh_node = null
		if _root != null:
			var found = []
			_find_face_boards(_root, found, false)
			if not found.empty():
				_mh_node = found[0]
		if old != _mh_node:
			_mh_detach(old)
			_mh_rig_id = 0
	if _mh_node == null:
		_mh_missing += 1
		# hide only after a few empty scans, and never touch the tab state otherwise (calling
		# set_tab_hidden over and over made Godot jump back to the first tab)
		if _mh_missing >= 3 and not _mh_tab_hidden:
			_mh_tab_hidden = true
			if _tabs.current_tab == _mh_page.get_index():
				_tabs.current_tab = 0
			_tabs.set_tab_hidden(_mh_page.get_index(), true)
		return
	_mh_missing = 0
	if _mh_tab_hidden:
		_mh_tab_hidden = false
		_tabs.set_tab_hidden(_mh_page.get_index(), false)
	if not (_mh_node.has_method("get_face_control_count") and _mh_node.has_method("get_apply_status") and _mh_node.has_method("set_gui_value")):
		_face_label.text = "The face board in this scene runs an older MetaHuman Rig script. Install the updated metahuman_rig add-on, then restart Godot (or reload the scene) so the board picks it up."
		return
	var count = _mh_node.get_face_control_count()
	var rig = _mh_node.rig
	var rid = rig.get_instance_id() if rig != null else 0
	var board_ok = count == 0 or _mh_board != null
	if count != _face_count or rid != _mh_rig_id or not board_ok:
		_mh_rebuild(rig, count)
		_face_count = count            # only after a rebuild went through, so a failed one is retried
		_mh_rig_id = rid
		if _face_node() == _mh_node:
			_rebuild_inspector()          # the face/... properties exist now


func _mh_detach(n) -> void:
	if n != null and is_instance_valid(n) and n.is_connected("gui_value_changed", self, "_on_mh_node_changed"):
		n.disconnect("gui_value_changed", self, "_on_mh_node_changed")
		n.disconnect("pose_changed", self, "_on_mh_node_pose")
	if _mh_board != null and is_instance_valid(_mh_board):
		_mh_board.queue_free()
	_mh_board = null


func _mh_rebuild(rig, count: int) -> void:
	if _mh_board != null and is_instance_valid(_mh_board):
		_mh_board.queue_free()
	_mh_board = null
	if not _mh_node.is_connected("gui_value_changed", self, "_on_mh_node_changed"):
		_mh_node.connect("gui_value_changed", self, "_on_mh_node_changed")
		_mh_node.connect("pose_changed", self, "_on_mh_node_pose")
	if count == 0 or rig == null:
		_face_label.text = "The face board has no rig yet. Open the MetaHuman Rig dock (it loads the .rig.json by itself) and keep 'Show face board in the 3D viewport' ticked."
		return
	_face_label.text = "%d face controls. Drag the yellow dots here or on the board in the Editor view, then key the pose.\n%s" % [count, _mh_node.get_apply_status()]
	var path = "res://addons/metahuman_rig/face_board.gd"
	if not ResourceLoader.exists(path):
		_face_label.text += "\n(MetaHuman Rig add-on not found at %s: the board is not drawn here.)" % path
		_mh_board = null
		return
	_mh_board = load(path).new()
	_mh_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mh_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mh_board.rect_min_size = Vector2(0, 360)
	_mh_board.connect("gui_value_changed", self, "_on_mh_gui")
	_mh_holder.add_child(_mh_board)
	_mh_board.build(rig)
	_mh_board.sync_from(rig)


# Middle mouse drag over the MetaHuman tab's board pans it (the board is a ScrollContainer).
func _mh_pan_input(ev: InputEvent) -> bool:
	# Mouse wheel over the board zooms it (about the mouse position).
	if ev is InputEventMouseButton and ev.pressed and (ev.button_index == BUTTON_WHEEL_UP or ev.button_index == BUTTON_WHEEL_DOWN):
		if _mh_board != null and is_instance_valid(_mh_board) and _mh_board.is_visible_in_tree() and _mh_board.get_global_rect().has_point(ev.global_position) and _mh_board.has_method("set_zoom"):
			var f = 1.1 if ev.button_index == BUTTON_WHEEL_UP else 1.0 / 1.1
			_mh_board.set_zoom(_mh_board.zoom * f, ev.global_position - _mh_board.get_global_rect().position)
			return true
		return false
	if ev is InputEventMouseButton and ev.button_index == BUTTON_MIDDLE:
		if ev.pressed:
			if _mh_board != null and is_instance_valid(_mh_board) and _mh_board.is_visible_in_tree() and _mh_board.get_global_rect().has_point(ev.global_position):
				_mh_panning = true
				_mh_pan = Vector2(_mh_board.scroll_horizontal, _mh_board.scroll_vertical)
				return true
			return false
		if _mh_panning:
			_mh_panning = false
			return true
		return false
	if _mh_panning and ev is InputEventMouseMotion:
		if _mh_board == null or not is_instance_valid(_mh_board):
			_mh_panning = false
			return false
		var hb = _mh_board.get_h_scrollbar()
		var vb = _mh_board.get_v_scrollbar()
		_mh_pan -= ev.relative
		_mh_pan.x = clamp(_mh_pan.x, 0.0, max(0.0, hb.max_value - hb.page))
		_mh_pan.y = clamp(_mh_pan.y, 0.0, max(0.0, vb.max_value - vb.page))
		_mh_board.scroll_horizontal = int(round(_mh_pan.x))
		_mh_board.scroll_vertical = int(round(_mh_pan.y))
		return true
	return false


# a dot of the embedded board was dragged
func _on_mh_gui(index: int, value: float) -> void:
	if _mh_node == null or not is_instance_valid(_mh_node):
		return
	_mh_busy = true
	_mh_node.set_gui_value(index, value)
	_mh_busy = false
	_mh_dirty = true
	_mh_status_line(index, value)


func _mh_status_line(index: int, value: float) -> void:
	var nm = ""
	if _mh_node.rig != null and index >= 0 and index < _mh_node.rig.gui_names.size():
		nm = str(_mh_node.rig.gui_names[index])
	_face_label.text = "%s = %.2f -> moved %d joints.\n%s" % [nm, value, _mh_node.last_joints, _mh_node.get_apply_status()]


# the board changed from somewhere else (dragged in the Editor view, animation, Inspector)
func _on_mh_node_changed(_index = 0, _value = 0.0) -> void:
	_mh_sync()


func _on_mh_node_pose() -> void:
	_mh_sync()


func _mh_sync() -> void:
	if _mh_busy or _mh_board == null or not is_instance_valid(_mh_board) or _mh_node == null or _mh_node.rig == null:
		return
	_mh_board.sync_from(_mh_node.rig)


# A click on a dot of a face board is taken before the transform gizmo / node picking; the board then follows the
# mouse until the button is released. Returns true when the board used the event.
func _face_board_input(ev: InputEvent) -> bool:
	if _edit_cam == null or _root == null:
		return false
	if _face_drag != null:
		if not is_instance_valid(_face_drag):
			_face_drag = null
			return false
		var used = _face_drag.handle_input(_edit_cam, ev)
		if ev is InputEventMouseButton and ev.button_index == BUTTON_LEFT and not ev.pressed:
			var done = _face_drag
			_face_drag = null
			if _face_auto != null and _face_auto.pressed:
				_key_face_pose(done)
		return used
	if not (ev is InputEventMouseButton) or ev.button_index != BUTTON_LEFT or not ev.pressed:
		return false
	if _edit_rmb or _edit_mmb or _gz_drag != null or _gz_pick(ev.position) >= 0:
		return false
	var boards = []
	_find_face_boards(_root, boards)
	for b in boards:
		if b.handle_input(_edit_cam, ev):
			_face_drag = b
			return true
	return false


func _mh_target():
	var n = _face_node()
	return n if n != null else _mh_node


func _on_key_face_pose() -> void:
	var n = _mh_target()
	if n == null:
		_say("There is no face board in this scene.")
		return
	_key_face_pose(n)


func _on_reset_face() -> void:
	var n = _mh_target()
	if n == null:
		return
	n.reset_face()
	_say("Face reset. Key it to bring the face back to neutral at %s." % _fmt_time(_time))


# Face poses are keyed as value tracks  <board>:face/<control>.  Godot's AnimationPlayer has to write those into the
# board through a script-defined property, which does not always reach the rig (so the face never moved). This reads
# the tracks itself and sets the controls on the board directly, at the scrub / playback time.
func _drive_face_tracks(t: float) -> void:
	if _anim == null or _root == null:
		return
	var count = _anim.get_track_count()
	if _face_track_anim != _anim or _face_track_count != count:
		_face_track_anim = _anim
		_face_track_count = count
		_face_tracks = []
		for i in range(count):
			if _anim.track_get_type(i) != Animation.TYPE_VALUE or not _anim.track_is_enabled(i):
				continue
			var tp = _anim.track_get_path(i)
			if tp.get_subname_count() < 1:
				continue
			var prop = str(tp.get_concatenated_subnames())
			if not prop.begins_with("face/"):
				continue
			var node = _root.get_node_or_null(NodePath(str(tp).split(":")[0]))
			if node != null and node.has_method("get_face_pose"):
				_face_tracks.append([i, node, prop])
	if _face_tracks.empty():
		return
	for e in _face_tracks:
		if is_instance_valid(e[1]) and _anim.track_get_key_count(e[0]) > 0:
			e[1].set(e[2], float(_anim.value_track_interpolate(e[0], t)))


# Keys every control that is in use (not 0) and every control that already has a track in this cutscene
# (so going back to 0 is keyed too). A control that gets its first key after 0 s also gets a 0 key at the
# start, so the face does not begin in that expression.
func _key_face_pose(board) -> void:
	if not _ready_to_key():
		return
	var pose: Dictionary = board.get_face_pose()
	if pose.empty():
		_say("The face board has no rig yet.")
		return
	var count = 0
	for prop in pose:
		var v = float(pose[prop])
		var path = _node_path_str(board, str(prop))
		var existing = _anim.find_track(NodePath(path))
		if existing == -1 and abs(v) < 0.00001:
			continue
		_put_value(path, _time, v)
		if existing == -1 and _time > 0.0005:
			_put_value(path, 0.0, 0.0)
		count += 1
	if count == 0:
		_say("Nothing to key: every face control is at 0 and none is animated yet.")
		return
	_face_track_anim = null           # new tracks: rescan them
	_finish_edit("Keyed face pose (%d controls) of %s at %s" % [count, board.name, _fmt_time(_time)], false)


# ------------------------------------------------------------------ AnimationPlayers of a node

func _find_players(n: Node, out: Array) -> void:
	if n is AnimationPlayer and n != _player:
		out.append(n)
	for c in n.get_children():
		if c == _director:
			continue
		_find_players(c, out)


func _chosen_anim_player():
	if _root == null or _ap_player_opt == null:
		return null
	var i = _ap_player_opt.selected
	if i < 0 or i >= _ap_players.size():
		return null
	var p = _root.get_node_or_null(NodePath(_ap_players[i]))
	return p if p is AnimationPlayer else null


# Looks at the first selected node: if it has AnimationPlayer(s), shows a dropdown with their animations.
func _refresh_anim_ui() -> void:
	if _ap_box == null:
		return
	var prev_player = ""
	if _ap_player_opt.selected >= 0 and _ap_player_opt.selected < _ap_players.size():
		prev_player = _ap_players[_ap_player_opt.selected]
	var prev_anim = ""
	if _ap_anim_opt.selected >= 0:
		prev_anim = _ap_anim_opt.get_item_text(_ap_anim_opt.selected)
	_ap_players = []
	_ap_player_opt.clear()
	_ap_anim_opt.clear()
	_ap_info.text = ""
	var node = null
	for n in _selected_nodes():
		if n != _director:
			node = n
			break
	var found = []
	if node != null:
		_find_players(node, found)
	_ap_box.visible = not found.empty()
	if _ap_card != null:
		_ap_card.visible = _ap_box.visible
	_ap_none.visible = false
	if node == null:
		_ap_none.text = "Select a node to see its AnimationPlayer."
		return
	if found.empty():
		_ap_none.text = "%s has no AnimationPlayer." % node.name
		return
	for p in found:
		_ap_players.append(str(_root.get_path_to(p)))
		var label = str(node.get_path_to(p))
		_ap_player_opt.add_item(str(p.name) if label == "." else label)
	var at = _ap_players.find(prev_player)
	_ap_player_opt.select(at if at != -1 else 0)
	_fill_anim_options(prev_anim)


func _fill_anim_options(prefer: String) -> void:
	_ap_anim_opt.clear()
	_ap_info.text = ""
	var p = _chosen_anim_player()
	if p == null:
		return
	var names = []
	for nm in p.get_animation_list():
		names.append(str(nm))
	names.sort()
	for nm in names:
		_ap_anim_opt.add_item(nm)
	if names.empty():
		_ap_info.text = "This AnimationPlayer has no animations yet."
		return
	var at = names.find(prefer)
	_ap_anim_opt.select(at if at != -1 else 0)
	_on_ap_anim_selected()


func _on_ap_player_selected(_index = 0) -> void:
	_fill_anim_options("")


func _on_ap_anim_selected(_index = 0) -> void:
	_ap_info.text = ""
	var p = _chosen_anim_player()
	if p == null or _ap_anim_opt.selected < 0:
		return
	var a = p.get_animation(_ap_anim_opt.get_item_text(_ap_anim_opt.selected))
	if a != null:
		_ap_info.text = "Length %.2f s%s" % [a.length, ", loops" if a.loop else ""]


# Adds a key on an "Animation playback" track of the cutscene: when the cutscene reaches it, the
# AnimationPlayer starts the chosen animation.
func _on_key_play_animation() -> void:
	if not _ready_to_key():
		return
	var p = _chosen_anim_player()
	if p == null or _ap_anim_opt.selected < 0:
		_say("Select a node that has an AnimationPlayer, then pick an animation.")
		return
	var anim_name = _ap_anim_opt.get_item_text(_ap_anim_opt.selected)
	var idx = _get_track(_node_path_str(p), Animation.TYPE_ANIMATION)
	var k = _anim.track_find_key(idx, _time, true)
	if k != -1:
		_anim.track_remove_key(idx, k)
	_anim.track_insert_key(idx, _time, anim_name)
	var length = 0.0
	var a = p.get_animation(anim_name)
	if a != null and not a.loop:
		length = a.length                  # make room so the whole animation can play
	_extend(_time + length)
	_finish_edit("Keyed animation '%s' of %s at %s" % [anim_name, p.get_parent().name, _fmt_time(_time)], true)


func _on_key_stop_animation() -> void:
	if not _ready_to_key():
		return
	var p = _chosen_anim_player()
	if p == null:
		_say("Select a node that has an AnimationPlayer first.")
		return
	var idx = _get_track(_node_path_str(p), Animation.TYPE_ANIMATION)
	var k = _anim.track_find_key(idx, _time, true)
	if k != -1:
		_anim.track_remove_key(idx, k)
	_anim.track_insert_key(idx, _time, "[stop]")
	_extend(_time)
	_finish_edit("Keyed 'stop' of %s at %s" % [p.name, _fmt_time(_time)], true)


# While scrubbing the cutscene, the AnimationPlayers of animation keys are started by the cutscene and would
# then run on by themselves in the editor. This freezes each one on the frame that belongs to the playhead.
func _scrub_anim_players() -> void:
	if _anim == null or _root == null:
		return
	for i in range(_anim.get_track_count()):
		if _anim.track_get_type(i) != Animation.TYPE_ANIMATION or not _anim.track_is_enabled(i):
			continue
		var p = _root.get_node_or_null(str(_anim.track_get_path(i)).split(":")[0])
		if not (p is AnimationPlayer):
			continue
		p.stop(false)
		var k = _anim.track_find_key(i, _time)
		if k < 0:
			continue
		var nm = str(_anim.track_get_key_value(i, k))
		if nm == "[stop]" or not p.has_animation(nm):
			continue
		var a = p.get_animation(nm)
		var pos = _time - _anim.track_get_key_time(i, k)
		if a.length > 0.0:
			pos = fposmod(pos, a.length) if a.loop else min(pos, a.length)
		p.assigned_animation = nm
		p.seek(pos, true)


func _on_key_transform() -> void:
	if not _ready_to_key():
		return
	var count = 0
	for n in _selected_nodes():
		if n is Spatial and n != _director:
			_put_transform(n, _time)
			count += 1
	if count == 0:
		_say("Select a 3D node in the scene tree first.")
		return
	_finish_edit("Keyed transform of %d node(s) at %s, next: %s" % [count, _fmt_time(_time), _interp_opt.get_item_text(_interp_opt.selected)], false)


# "I": keys the transform of every selected 3D node (a camera included). With nothing selected it keys the
# camera chosen in the camera list instead.
func _on_key_selected() -> void:
	var fb = _face_node()
	if fb != null:
		_key_face_pose(fb)
		return
	for n in _selected_nodes():
		if n is Spatial and n != _director:
			_on_key_transform()
			return
	_on_key_camera_pose()


# ---------------------------------------------------------------------- FOV

func _on_key_fov_now() -> void:
	if not _ready_to_key():
		return
	var cam = _target_camera()
	if cam == null:
		_say("Select a Camera or pick one in the camera list.")
		return
	_put_value(_node_path_str(cam, "fov"), _time, cam.fov)
	_finish_edit("Keyed FOV %.1f of %s" % [cam.fov, cam.name], false)


func _on_fov_change() -> void:
	if not _ready_to_key():
		return
	var cam = _target_camera()
	if cam == null:
		_say("Select a Camera or pick one in the camera list.")
		return
	var path = _node_path_str(cam, "fov")
	var start = cam.fov
	var existing = _anim.find_track(NodePath(path))
	if existing != -1 and _anim.track_get_key_count(existing) > 0:
		# Start from the FOV the cutscene already has at the playhead.
		var k = _anim.track_find_key(existing, _time)
		if k != -1:
			start = _anim.track_get_key_value(existing, k)
	_put_value(path, _time, start)
	_put_value(path, _time + _fov_dur_spin.value, _fov_spin.value)
	_finish_edit("FOV %.1f to %.1f over %.2fs" % [start, _fov_spin.value, _fov_dur_spin.value], true)


# -------------------------------------------------------------------- shake

func _on_add_shake() -> void:
	if not _ready_to_key():
		return
	var path = _director_path("shake")
	var dur = _shake_dur.value
	var ramp = min(0.05, dur / 4.0)
	_put_value(path, _time, 0.0)
	_put_value(path, _time + ramp, _shake_amount.value)
	_put_value(path, _time + dur, 0.0)
	_finish_edit("Shake %.2f for %.2fs at %s" % [_shake_amount.value, dur, _fmt_time(_time)], true)


# ----------------------------------------------------------------- shakify

# Removes the keys of one track whose time lies in [from_t, to_t], so a new Shakify replaces what was there.
func _clear_range(path: String, from_t: float, to_t: float) -> void:
	var idx = _anim.find_track(NodePath(path))
	if idx == -1:
		return
	for k in range(_anim.track_get_key_count(idx) - 1, -1, -1):
		var kt = _anim.track_get_key_time(idx, k)
		if kt >= from_t - 0.0005 and kt <= to_t + 0.0005:
			_anim.track_remove_key(idx, k)


func _on_add_shakify(whole: bool) -> void:
	if not _ready_to_key():
		return
	var start = 0.0 if whole else _time
	var end = _anim.length if whole else _time + _sk_dur.value
	if end - start < 0.05:
		_say("Not enough time left after the playhead. Move it earlier or raise 'Time (s)'.")
		return
	var strength_path = _director_path("shakify")
	var setup_path = _director_path("shakify_setup")
	var span = end - start
	var fade_in = min(_sk_fade_in.value, span * 0.5)
	var fade_out = min(_sk_fade_out.value, span * 0.5)
	var amount = _sk_influence.value
	_clear_range(strength_path, start, end)
	_clear_range(setup_path, start, end)
	_put_value(setup_path, start, [_sk_preset.selected, _sk_scale.value, _sk_speed.value], true)
	_put_value(strength_path, start, 0.0 if fade_in > 0.0 else amount)
	if fade_in > 0.0:
		_put_value(strength_path, start + fade_in, amount)
	if fade_out > 0.0:
		_put_value(strength_path, end - fade_out, amount)
	else:
		_put_value(strength_path, end - CUT_GAP, amount)    # hold, then drop right at the end
	_put_value(strength_path, end, 0.0)
	_finish_edit("Shakify (%s) from %s to %s" % [_sk_preset.get_item_text(_sk_preset.selected), _fmt_time(start), _fmt_time(end)], true)


# ----------------------------------------------------------------- subtitles

func _on_add_subtitle() -> void:
	if not _ready_to_key():
		return
	if _put_subtitle(_text_dur.value):
		_finish_edit("Subtitle added at %s" % _fmt_time(_time), true)


# Writes the dialogue line at the playhead. dur_setting <= 0 picks a length from the text.
func _put_subtitle(dur_setting: float) -> bool:
	var text = _text_edit.text.strip_edges()
	if text == "":
		_say("Type what is said first.")
		return false
	var speaker = _speaker_edit.text.strip_edges()
	var full = text if speaker == "" else "%s: %s" % [speaker, text]
	var dur = dur_setting
	if dur <= 0.0:
		dur = clamp(1.0 + text.length() * 0.06, 2.0, 10.0)
	var path = _director_path("subtitle")
	var idx = _get_track(path, Animation.TYPE_VALUE, true)
	if _time > 0.0001 and _anim.track_find_key(idx, 0.0, true) == -1:
		_put_value(path, 0.0, "", true)
	_put_value(path, _time, full, true)
	# Clear the line after `dur`, unless another line starts before then (it replaces this one).
	var clear_at = _time + dur
	var next_start = -1.0
	for k in range(_anim.track_get_key_count(idx)):
		var kt = _anim.track_get_key_time(idx, k)
		if kt > _time + 0.0001 and (next_start < 0.0 or kt < next_start):
			next_start = kt
	if next_start < 0.0 or next_start > clear_at:
		_put_value(path, clear_at, "", true)
	_text_edit.text = ""
	return true


# ------------------------------------------------------------ subtitle look

func _pick_file(purpose: String, filters: Array) -> void:
	_file_purpose = purpose
	_file_dialog.clear_filters()
	for f in filters:
		_file_dialog.add_filter(f)
	_popup_centered(_file_dialog, editor.get_base_control().rect_size * 0.7)


func _on_file_selected(path: String) -> void:
	if _file_purpose == "font":
		_on_font_chosen(path)
	elif _file_purpose == "audio":
		_on_audio_chosen(path)


func _on_choose_font() -> void:
	if _director == null:
		return
	_pick_file("font", ["*.ttf, *.otf, *.ttc ; Font files", "*.tres, *.res, *.fnt ; Font resources"])


func _on_font_chosen(path: String) -> void:
	var res = load(path)
	var font = null
	if res is DynamicFontData:
		var df = DynamicFont.new()
		df.font_data = res
		df.size = int(_font_size_spin.value)
		font = df
	elif res is Font:
		font = res
	else:
		_say("%s is not a font." % path.get_file())
		return
	_director.subtitle_font = font
	_sync_look_ui()
	_look_changed("Subtitle font: %s" % path.get_file())


func _on_reset_font() -> void:
	if _director == null:
		return
	_director.subtitle_font = null
	_sync_look_ui()
	_look_changed("Subtitle font reset to the default.")


func _on_font_size_changed(value: float) -> void:
	if _syncing or _director == null:
		return
	var f = _director.subtitle_font
	if f is DynamicFont:
		f.size = int(value)
		_look_changed("Subtitle size %d" % int(value))


func _on_sub_color_changed(c: Color) -> void:
	if _syncing or _director == null:
		return
	_director.subtitle_color = c


func _on_sub_color_done() -> void:
	if _director != null:
		_look_changed("Subtitle color changed.")


func _look_changed(message: String) -> void:
	_sub_sig = ""
	_mark_changed(message)
	_say(message)


func _sync_look_ui() -> void:
	if _director == null:
		return
	_syncing = true
	var f = _director.subtitle_font
	_font_size_spin.editable = true
	if f == null:
		_font_path_edit.text = "Default font"
	elif f is DynamicFont:
		var nm = "dynamic font"
		if f.font_data != null and f.font_data.resource_path != "":
			nm = f.font_data.resource_path.get_file()
		_font_path_edit.text = nm
		_font_size_spin.value = f.size
	else:
		_font_path_edit.text = f.resource_path.get_file() if f.resource_path != "" else "custom font"
		_font_size_spin.editable = false         # bitmap / custom fonts have a fixed size
	_sub_color_btn.color = _director.subtitle_color
	_syncing = false
	_sub_sig = ""


# -------------------------------------------------------------------- audio

func _on_choose_audio() -> void:
	_pick_file("audio", ["*.ogg, *.wav, *.mp3 ; Audio files"])


func _on_audio_chosen(path: String) -> void:
	var res = load(path)
	if not (res is AudioStream):
		_say("%s is not an audio file Godot can play." % path.get_file())
		return
	_audio_stream = res
	_audio_path_edit.text = path.get_file()
	_say("Audio ready: %s. Move the playhead and press 'Add audio at playhead'." % path.get_file())


func _on_test_audio() -> void:
	if _audio_stream == null:
		_say("Choose an audio file first.")
		return
	if _test_player.playing:
		_test_player.stop()
	else:
		_test_player.stream = _audio_stream
		_test_player.play()


# The AudioStreamPlayer a voice line plays on: one you selected, else Cinematic/Voice (made if missing).
func _audio_target():
	for n in _selected_nodes():
		if n is AudioStreamPlayer or n is AudioStreamPlayer3D or n is AudioStreamPlayer2D:
			return n
	var voice = _director.get_node_or_null("Voice")
	if voice is AudioStreamPlayer:
		return voice
	voice = AudioStreamPlayer.new()
	voice.name = "Voice"
	_director.add_child(voice)
	voice.owner = _root
	return voice


func _on_add_audio() -> void:
	if not _ready_to_key():
		return
	if _audio_stream == null:
		_say("Choose an audio file first.")
		return
	var player = _audio_target()
	var length = 0.0
	if _audio_stream.has_method("get_length"):
		length = _audio_stream.get_length()
	var idx = _get_track(_node_path_str(player), Animation.TYPE_AUDIO)
	var k = _anim.track_find_key(idx, _time, true)
	if k != -1:
		_anim.track_remove_key(idx, k)
	_anim.audio_track_insert_key(idx, _time, _audio_stream, 0.0, 0.0)
	_aud_put(idx, _time, _audio_loop_check.pressed, 0.0)
	_extend(_time + length)
	var message = "Audio %s at %s on %s" % [_audio_path_edit.text, _fmt_time(_time), player.name]
	if _audio_sub_check.pressed and _text_edit.text.strip_edges() != "":
		if _put_subtitle(length):
			message += " (with subtitle)"
	_finish_edit(message, false)


# ---------------------------------------------------------------- key list

func _pretty_track(idx: int) -> String:
	var p = str(_anim.track_get_path(idx))
	var d = _director_path("")
	if p == d + ":active_camera":
		return "Camera cuts"
	if p == d + ":subtitle":
		return "Dialogue"
	if p == d + ":shake":
		return "Camera shake"
	if p == d + ":shakify":
		return "Shakify (strength)"
	if p == d + ":shakify_setup":
		return "Shakify (preset)"
	var type = _anim.track_get_type(idx)
	if type == Animation.TYPE_AUDIO:
		return "Audio: " + p.get_file()
	if type == Animation.TYPE_ANIMATION:
		return "Plays animation: " + p
	if type == Animation.TYPE_TRANSFORM:
		var names = ["constant", "linear", "cubic"]
		return "%s  [track: %s]" % [p, names[clamp(_anim.track_get_interpolation_type(idx), 0, 2)]]
	return p


func _pose_text(e: Dictionary) -> String:
	var names = ["linear", "cubic", "CONSTANT (cut to next key)"]
	return "pose  ->  %s" % names[clamp(e["m"], 0, 2)]


func _key_text(idx: int, k: int) -> String:
	var type = _anim.track_get_type(idx)
	if type == Animation.TYPE_AUDIO:
		var s = _anim.audio_track_get_key_stream(idx, k)
		return s.resource_path.get_file() if s != null else "(no audio)"
	var v = _anim.track_get_key_value(idx, k)
	if v is Array and v.size() >= 3:
		var presets = DirectorScript.SHAKIFY_PRESETS
		var pi = int(clamp(int(v[0]), 0, presets.size() - 1))
		return "%s  scale %.2f  speed %.2f" % [presets[pi]["name"], float(v[1]), float(v[2])]
	if v is NodePath:
		return "cut to " + str(v).get_file()
	if v is String:
		return v if v != "" else "(clear)"
	return str(v)


func _on_clear_all() -> void:
	if _anim == null:
		return
	while _anim.get_track_count() > 0:
		_anim.remove_track(0)
	if _anim.has_meta(SRC_META):
		_anim.remove_meta(SRC_META)
	if _anim.has_meta(AUD_META):
		_anim.remove_meta(AUD_META)
	_sel = []
	_sel_track = -1
	_finish_edit("All keys on this cutscene were removed.", false)


# ---------------------------------------------------------------- dope sheet
# One row per track (grouped under its node), keys as diamonds on a time grid, like Blender's Dope Sheet.

const LABEL_W = 200.0
const RULER_H = 24.0
const ROW_H = 22.0
const DIAMOND = 5.0
const SEL_COLOR = Color(1.0, 0.65, 0.1)
const EYE_W = 24.0                  # width of the eye button at the right end of a channel name


func _on_fit_view() -> void:
	_view_fit = true
	_scroll_y = 0.0
	_sheet.update()


# Eye of a timeline row: -1 = none, 0 = hidden, 1 = shown.
# Node row: the node's visibility in the scene.  Track row: the track is switched on / off.
func _row_eye(r: int) -> int:
	var row = _rows[r]
	if row["kind"] == "node":
		var n = _row_node(row["node"])
		if n == null or not ("visible" in n):
			return -1
		return 1 if n.visible else 0
	if row["kind"] == "track":
		return 0 if _track_hidden(row["track"]) else 1
	return -1


func _toggle_row_eye(r: int) -> void:
	var row = _rows[r]
	if row["kind"] == "node":
		_toggle_node_visible(_row_node(row["node"]))
	elif row["kind"] == "track" and _anim != null:
		var idx = row["track"]
		var turn_on = _track_hidden(idx)
		var cat = _track_cat(idx)
		_anim.track_set_enabled(idx, turn_on)
		_load_fx_state()
		if not turn_on and cat != "" and _fx_hidden.get(cat, false):
			_reset_fx_state(cat)
		_refresh_keys()
		_seek(_time)
		_mark_changed("%s %s" % ["Show" if turn_on else "Hide", row["label"]])
		_say("%s %s." % [row["label"], "shown" if turn_on else "hidden (switched off in the cutscene too)"])


func _row_label(idx: int) -> String:
	var p = str(_anim.track_get_path(idx))
	var d = _director_path("")
	var type = _anim.track_get_type(idx)
	if p == d + ":active_camera":
		return "Camera cuts"
	if p == d + ":subtitle":
		return "Dialogue"
	if p == d + ":shake":
		return "Shake"
	if p == d + ":shakify":
		return "Shakify strength"
	if p == d + ":shakify_setup":
		return "Shakify preset"
	if type == Animation.TYPE_AUDIO:
		return "Audio"
	if type == Animation.TYPE_ANIMATION:
		return "Plays animation"
	if type == Animation.TYPE_TRANSFORM:
		var names = ["constant", "linear", "cubic"]
		return "Pose  (%s)" % names[clamp(_anim.track_get_interpolation_type(idx), 0, 2)]
	var parts = p.split(":")
	return parts[parts.size() - 1] if parts.size() > 1 else p


func _refresh_keys() -> void:
	_rows = []
	_track_node = {}
	if _anim == null or _director == null:
		if _sheet != null:
			_sheet.update()
		return
	_rows.append({"kind": "summary", "label": "Summary", "track": -1, "node": ""})
	var nodes = []
	var groups = {}
	for idx in range(_anim.get_track_count()):
		var node = str(_anim.track_get_path(idx)).split(":")[0]
		_track_node[idx] = node
		if not groups.has(node):
			groups[node] = []
			nodes.append(node)
		groups[node].append(idx)
	for node in nodes:
		var nm = node.get_file() if node != "" else "(scene root)"
		_rows.append({"kind": "node", "label": nm, "track": -1, "node": node})
		for idx in groups[node]:
			_rows.append({"kind": "track", "label": _row_label(idx), "track": idx, "node": node})
	# forget selected keys that no longer exist
	var marks = _collect_marks()
	var keep = []
	for sk in _sel:
		for e in marks:
			if e["track"] == sk["track"] and abs(e["t"] - sk["t"]) < 0.0005:
				keep.append(sk)
				break
	_sel = keep
	if _sel_track >= _anim.get_track_count():
		_sel_track = -1
	_sheet.update()


# Every key of the cutscene: {t, c (color), track, key (key index or -1), src (pose index or -1), node, m}
func _collect_marks() -> Array:
	var out = []
	if _anim == null or _director == null:
		return out
	var d = _director_path("")
	for idx in range(_anim.get_track_count()):
		var type = _anim.track_get_type(idx)
		var p = str(_anim.track_get_path(idx))
		var node = _track_node.get(idx, "")
		if _track_hidden(idx):
			continue
		var col = Color(0.8, 0.8, 0.85)
		if p == d + ":active_camera":
			col = Color(1.0, 0.85, 0.2)
		elif p == d + ":subtitle":
			col = Color(0.5, 0.9, 0.5)
		elif p == d + ":shakify" or p == d + ":shakify_setup":
			col = Color(1.0, 0.7, 0.4)
		elif type == Animation.TYPE_AUDIO:
			col = Color(0.95, 0.5, 0.95)
		elif type == Animation.TYPE_ANIMATION:
			col = Color(0.4, 0.9, 0.9)
		if type == Animation.TYPE_TRANSFORM:
			var src = _get_src(idx)
			for i in range(src.size()):
				var c = Color(1.0, 0.35, 0.3) if src[i]["m"] == INTERP_CUT else Color(0.45, 0.8, 1.0)
				out.append({"t": src[i]["t"], "c": c, "track": idx, "key": -1, "src": i, "node": node, "m": src[i]["m"]})
		else:
			for k in range(_anim.track_get_key_count(idx)):
				out.append({"t": _anim.track_get_key_time(idx, k), "c": col, "track": idx, "key": k, "src": -1, "node": node, "m": -1})
	return out


func _is_sel(e: Dictionary) -> bool:
	for sk in _sel:
		if sk["track"] == e["track"] and abs(sk["t"] - e["t"]) < 0.0005:
			return true
	return false


func _has_time(times: Array, t: float) -> bool:
	for x in times:
		if abs(x - t) < 0.0005:
			return true
	return false


func _sort_dt(a, b) -> bool:
	return a["dt"] < b["dt"]


func _t2x(t: float) -> float:
	return LABEL_W + (t - _view_t0) * _view_pps


func _x2t(x: float) -> float:
	return _view_t0 + (x - LABEL_W) / _view_pps


func _apply_fit() -> void:
	if not _view_fit or _anim == null:
		return
	var w = max(_sheet.rect_size.x - LABEL_W - 24.0, 50.0)
	_view_pps = w / max(_anim.length, 0.1)
	_view_t0 = -12.0 / _view_pps


func _row_scope(row: Dictionary, marks: Array) -> Array:
	if row["kind"] == "summary":
		return marks
	var out = []
	for e in marks:
		if row["kind"] == "node" and e["node"] == row["node"]:
			out.append(e)
		elif row["kind"] == "track" and e["track"] == row["track"]:
			out.append(e)
	return out


func _draw_diamond(x: float, cy: float, fill: Color, edge: Color) -> void:
	if x < LABEL_W - DIAMOND or x > _sheet.rect_size.x + DIAMOND:
		return
	var pts = PoolVector2Array([Vector2(x, cy - DIAMOND), Vector2(x + DIAMOND, cy), Vector2(x, cy + DIAMOND), Vector2(x - DIAMOND, cy)])
	_sheet.draw_colored_polygon(pts, fill)
	pts.append(pts[0])
	_sheet.draw_polyline(pts, edge, 1.0)


func _sheet_draw() -> void:
	var s = _sheet
	var size = s.rect_size
	s.draw_rect(Rect2(Vector2(), size), Color(0.12, 0.12, 0.14))
	if _anim == null or _director == null:
		return
	_apply_fit()
	var font = s.get_font("font", "Label")
	var fcol = s.get_color("font_color", "Label")
	var text_dy = (font.get_ascent() - font.get_descent()) * 0.5

	var marks = _collect_marks()
	var shift = 0.0
	if _drag != null and _drag["mode"] == "move":
		shift = _drag["dt"]
	for e in marks:
		e["sel"] = _is_sel(e)
		e["dt"] = e["t"] + (shift if e["sel"] else 0.0)

	var max_scroll = max(0.0, _rows.size() * ROW_H - (size.y - RULER_H))
	_scroll_y = clamp(_scroll_y, 0.0, max_scroll)

	# row backgrounds
	var bgs = []
	for r in range(_rows.size()):
		var kind = _rows[r]["kind"]
		var bg = Color(0.19, 0.19, 0.21) if r % 2 == 0 else Color(0.165, 0.165, 0.185)
		if kind == "summary":
			bg = Color(0.40, 0.23, 0.10)
		elif kind == "node":
			bg = Color(0.21, 0.31, 0.41)
		bgs.append(bg)
		var y = RULER_H + r * ROW_H - _scroll_y
		if y + ROW_H < RULER_H or y > size.y:
			continue
		s.draw_rect(Rect2(0, y, size.x, ROW_H), bg)
		if kind == "track" and _row_eye(r) == 0:             # switched-off track: dimmed key area
			s.draw_rect(Rect2(LABEL_W, y, size.x - LABEL_W, ROW_H), Color(0, 0, 0, 0.3))

	# area outside the cutscene is darker
	var x0 = _t2x(0.0)
	var x1 = _t2x(_anim.length)
	if x0 > LABEL_W:
		s.draw_rect(Rect2(LABEL_W, RULER_H, x0 - LABEL_W, size.y), Color(0, 0, 0, 0.3))
	if x1 < size.x:
		s.draw_rect(Rect2(x1, RULER_H, size.x - x1, size.y), Color(0, 0, 0, 0.3))

	# grid lines
	var step = 600.0
	for c in [0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0]:
		step = c
		if c * _view_pps >= 60.0:
			break
	var ticks = []
	var tt = floor(_view_t0 / step) * step
	while _t2x(tt) < size.x:
		var gx = _t2x(tt)
		if gx >= LABEL_W:
			s.draw_line(Vector2(gx, RULER_H), Vector2(gx, size.y), Color(1, 1, 1, 0.07))
			ticks.append(tt)
		tt += step

	# keys
	for r in range(_rows.size()):
		var y = RULER_H + r * ROW_H - _scroll_y
		if y + ROW_H < RULER_H or y > size.y:
			continue
		var row = _rows[r]
		var cy = y + ROW_H * 0.5
		var scope = _row_scope(row, marks)
		if row["kind"] == "track":
			scope.sort_custom(self, "_sort_dt")
			for i in range(scope.size() - 1):
				if scope[i]["m"] == INTERP_CUT:       # a "constant" move: the pose is held, then cuts
					var bx0 = max(_t2x(scope[i]["dt"]), LABEL_W)
					var bx1 = _t2x(scope[i + 1]["dt"])
					if bx1 > bx0:
						s.draw_rect(Rect2(bx0, cy - 3.0, bx1 - bx0, 6.0), Color(0.85, 0.3, 0.25, 0.7))
			if row["track"] >= 0 and row["track"] < _anim.get_track_count() and _anim.track_get_type(row["track"]) == Animation.TYPE_AUDIO:
				for e in scope:                           # the length of every audio clip, with a handle to drag
					if e["key"] < 0:
						continue
					var info = _aud_info(row["track"], e["key"], e["t"])
					var eff = info["eff"]
					if _drag != null and _drag["mode"] == "adur" and _drag["track"] == row["track"] and abs(_drag["t"] - e["t"]) < 0.0005:
						eff = _drag["eff"]
					var ax0 = max(_t2x(e["dt"]), LABEL_W)
					var ax1 = _t2x(e["dt"] + eff)
					if ax1 > ax0:
						var bar = Rect2(ax0, cy - 5.0, ax1 - ax0, 10.0)
						s.draw_rect(bar, Color(0.95, 0.5, 0.95, 0.3 if info["loop"] else 0.45))
						s.draw_rect(bar, Color(0.95, 0.5, 0.95, 0.9), false)
						if info["loop"] and info["L"] > 0.05:
							var lt = e["dt"] + info["L"]
							var guard = 0
							while lt < e["dt"] + eff - 0.001 and guard < 300:
								var lx = _t2x(lt)
								if lx > LABEL_W:
									s.draw_line(Vector2(lx, cy - 5.0), Vector2(lx, cy + 5.0), Color(1, 1, 1, 0.55))
								lt += info["L"]
								guard += 1
						if info["loop"] and ax1 - ax0 > 40.0:
							s.draw_string(font, Vector2(ax0 + 10.0, cy + text_dy), "loop", Color(1, 1, 1, 0.85))
						if ax1 > LABEL_W + 1.0 and ax1 - _t2x(e["dt"]) > DIAMOND + 4.0:
							s.draw_rect(Rect2(ax1 - 3.0, cy - 8.0, 5.0, 16.0), Color(1, 1, 1, 0.85))
			var anim_row = row["track"] >= 0 and row["track"] < _anim.get_track_count() and _anim.track_get_type(row["track"]) == Animation.TYPE_ANIMATION
			for e in scope:
				var fill = SEL_COLOR if e["sel"] else e["c"]
				_draw_diamond(_t2x(e["dt"]), cy, fill, Color(1, 1, 1) if e["sel"] else Color(0, 0, 0, 0.7))
				if anim_row and e["key"] >= 0 and _t2x(e["dt"]) >= LABEL_W:
					s.draw_string(font, Vector2(_t2x(e["dt"]) + 9.0, cy + text_dy), str(_anim.track_get_key_value(row["track"], e["key"])), fcol * Color(1, 1, 1, 0.8))
		else:
			var agg = {}
			for e in scope:
				var key = int(round(e["dt"] * 2000.0))
				if not agg.has(key):
					agg[key] = {"x": _t2x(e["dt"]), "all": true}
				if not e["sel"]:
					agg[key]["all"] = false
			for key in agg:
				var a = agg[key]
				_draw_diamond(a["x"], cy, SEL_COLOR if a["all"] else Color(0.92, 0.92, 0.92), Color(0, 0, 0, 0.7))

	# channel names
	for r in range(_rows.size()):
		var y = RULER_H + r * ROW_H - _scroll_y
		if y + ROW_H < RULER_H or y > size.y:
			continue
		var row = _rows[r]
		var lc = bgs[r] * 0.82
		lc.a = 1.0
		if row["kind"] == "track" and row["track"] == _sel_track:
			lc = Color(0.30, 0.38, 0.52)
		s.draw_rect(Rect2(0, y, LABEL_W, ROW_H), lc)
		var indent = 22.0 if row["kind"] == "track" else 8.0
		var eye = _row_eye(r)
		var name_col = fcol if eye != 0 else fcol * Color(1, 1, 1, 0.4)
		s.draw_string(font, Vector2(indent, y + ROW_H * 0.5 + text_dy), row["label"], name_col, LABEL_W - indent - EYE_W - 4.0)
		if eye != -1:
			var tex = _eye_on if eye == 1 else _eye_off
			if tex != null:
				var ts = tex.get_size()
				s.draw_texture(tex, Vector2(LABEL_W - EYE_W + (EYE_W - ts.x) * 0.5 - 2.0, y + (ROW_H - ts.y) * 0.5), Color(1, 1, 1, 1.0 if eye == 1 else 0.6))
	s.draw_line(Vector2(LABEL_W, RULER_H), Vector2(LABEL_W, size.y), Color(0, 0, 0, 0.6))

	# ruler
	s.draw_rect(Rect2(0, 0, size.x, RULER_H), Color(0.2, 0.2, 0.23))
	s.draw_string(font, Vector2(8, RULER_H * 0.5 + text_dy), "Timeline", fcol * Color(1, 1, 1, 0.6), LABEL_W - 12.0)
	for t in ticks:
		var rx = _t2x(t)
		s.draw_line(Vector2(rx, RULER_H - 7.0), Vector2(rx, RULER_H), Color(1, 1, 1, 0.5))
		s.draw_string(font, Vector2(rx + 3.0, RULER_H * 0.5 + text_dy - 2.0), str(stepify(t, 0.01)) + "s", fcol * Color(1, 1, 1, 0.75))
	s.draw_line(Vector2(0, RULER_H), Vector2(size.x, RULER_H), Color(0, 0, 0, 0.7))

	# end-of-cutscene handle (drag it to change the length)
	if x1 >= LABEL_W - 1.0 and x1 <= size.x + 8.0:
		var orange = Color(1.0, 0.65, 0.1)
		s.draw_line(Vector2(x1, RULER_H), Vector2(x1, size.y), Color(1.0, 0.65, 0.1, 0.6), 1.5)
		s.draw_rect(Rect2(x1 - 4.0, 3.0, 8.0, RULER_H - 6.0), orange)
		s.draw_rect(Rect2(x1 - 4.0, 3.0, 8.0, RULER_H - 6.0), Color(0, 0, 0, 0.6), false)

	# playhead
	var px = _t2x(_time)
	if px >= LABEL_W - 1.0 and px <= size.x:
		var green = Color(0.3, 0.85, 0.4)
		s.draw_line(Vector2(px, RULER_H), Vector2(px, size.y), green, 1.5)
		s.draw_colored_polygon(PoolVector2Array([Vector2(px - 6, RULER_H - 11), Vector2(px + 6, RULER_H - 11), Vector2(px + 6, RULER_H - 4), Vector2(px, RULER_H + 1), Vector2(px - 6, RULER_H - 4)]), green)

	# selection box
	if _drag != null and _drag["mode"] == "box" and _drag["moved"]:
		var bx = Rect2(Vector2(min(_drag["x0"], _drag["x1"]), min(_drag["y0"], _drag["y1"])), Vector2(abs(_drag["x1"] - _drag["x0"]), abs(_drag["y1"] - _drag["y0"])))
		s.draw_rect(bx, Color(0.4, 0.7, 1.0, 0.18))
		s.draw_rect(bx, Color(0.5, 0.8, 1.0, 0.9), false)


func _row_at(y: float) -> int:
	var r = int(floor((y - RULER_H + _scroll_y) / ROW_H))
	return r if r >= 0 and r < _rows.size() else -1


# The key diamond(s) under a mouse position: {entries, t} or {}. In a node / Summary row, every key of
# that row at the same time counts, so one click selects them all.
func _hit_diamond(pos: Vector2) -> Dictionary:
	if pos.x < LABEL_W or pos.y < RULER_H:
		return {}
	var ri = _row_at(pos.y)
	if ri == -1:
		return {}
	var scope = _row_scope(_rows[ri], _collect_marks())
	var best = null
	var best_dx = DIAMOND + 3.0
	for e in scope:
		var dx = abs(_t2x(e["t"]) - pos.x)
		if dx < best_dx:
			best_dx = dx
			best = e
	if best == null:
		return {}
	var group = []
	for e in scope:
		if _rows[ri]["kind"] == "track":
			if e == best:
				group.append(e)
		elif abs(e["t"] - best["t"]) < 0.0005:
			group.append(e)
	return {"entries": group, "t": best["t"]}


func _scrub_to(x: float) -> void:
	_seek(clamp(stepify(_x2t(x), 0.01), 0.0, _anim.length))


func _zoom_at(x: float, factor: float) -> void:
	_view_fit = false
	var tm = _x2t(x)
	_view_pps = clamp(_view_pps * factor, 5.0, 4000.0)
	_view_t0 = tm - (x - LABEL_W) / _view_pps


func _sheet_input(ev: InputEvent) -> void:
	if _anim == null or _director == null:
		return
	if ev is InputEventMouseButton:
		var pos = ev.position
		if ev.pressed and (ev.button_index == BUTTON_WHEEL_UP or ev.button_index == BUTTON_WHEEL_DOWN):
			var up = ev.button_index == BUTTON_WHEEL_UP
			if ev.control:
				_zoom_at(pos.x, 1.2 if up else 1.0 / 1.2)
			elif ev.shift:
				_view_fit = false
				_view_t0 += (-60.0 if up else 60.0) / _view_pps
			else:
				_scroll_y += -ROW_H if up else ROW_H
			_sheet.update()
			accept_event()
		elif ev.button_index == BUTTON_LEFT:
			if ev.pressed:
				_sheet_press(ev)
			else:
				_sheet_release()
			accept_event()
		elif ev.button_index == BUTTON_RIGHT:
			if ev.pressed:
				_sheet_context(ev)
			accept_event()
		elif ev.button_index == BUTTON_MIDDLE:
			if ev.pressed:
				_drag = {"mode": "pan", "x0": pos.x, "y0": pos.y, "t0": _view_t0, "s0": _scroll_y}
			elif _drag != null and _drag["mode"] == "pan":
				_drag = null
			accept_event()
	elif ev is InputEventMouseMotion:
		var pos2 = ev.position
		if _drag == null:
			var over = not _hit_diamond(pos2).empty()
			var on_end = pos2.y < RULER_H and pos2.x >= LABEL_W and abs(pos2.x - _t2x(_anim.length)) <= 7.0
			if on_end:
				_sheet.mouse_default_cursor_shape = Control.CURSOR_HSIZE
			else:
				_sheet.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over else Control.CURSOR_ARROW
			return
		if _drag["mode"] == "scrub":
			_scrub_to(pos2.x)
		elif _drag["mode"] == "length":
			_set_length(stepify(_x2t(pos2.x), 0.1), false)
			_say("Length %.1fs  (release to set)" % _anim.length)
		elif _drag["mode"] == "pan":
			_view_fit = false
			_view_t0 = _drag["t0"] - (pos2.x - _drag["x0"]) / _view_pps
			_scroll_y = _drag["s0"] - (pos2.y - _drag["y0"])
		elif _drag["mode"] == "adur":
			var maxd = _drag["L"]
			if _drag["loop"] or maxd <= 0.0:
				maxd = max(_anim.length - _drag["t"], 0.05)
			_drag["eff"] = clamp(stepify(_x2t(pos2.x) - _drag["t"], 0.01), 0.05, maxd)
			_say("Audio length %.2fs  (release to set)" % _drag["eff"])
		elif _drag["mode"] == "box":
			_drag["x1"] = pos2.x
			_drag["y1"] = pos2.y
			if abs(pos2.x - _drag["x0"]) > 3.0 or abs(pos2.y - _drag["y0"]) > 3.0:
				_drag["moved"] = true
			if _drag["moved"]:
				_box_select()
		elif _drag["mode"] == "move":
			if abs(pos2.x - _drag["x0"]) > 3.0:
				_drag["moved"] = true
			if _drag["moved"]:
				var dt = stepify(_x2t(pos2.x) - _x2t(_drag["x0"]), 0.01)
				_drag["dt"] = clamp(dt, -_drag["tmin"], _anim.length - _drag["tmax"])
				_say("Moving %d key(s) by %+.2fs  (release to drop)" % [_sel.size(), _drag["dt"]])
		_sheet.update()
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		if ev.command and ev.scancode == KEY_C:
			_on_copy_keys()
			accept_event()
		elif ev.command and ev.scancode == KEY_X:
			_on_copy_keys(true)
			accept_event()
		elif ev.command and ev.scancode == KEY_V:
			_on_paste_keys()
			accept_event()
		elif ev.command and ev.scancode == KEY_A:
			_select_all_keys()
			accept_event()
		elif ev.scancode == KEY_L and not ev.command:
			_toggle_audio_loop()
			accept_event()
		elif ev.scancode == KEY_DELETE or ev.scancode == KEY_X:
			_on_delete_key()
			accept_event()
		elif ev.command and ev.scancode == KEY_Z:
			if ev.shift:
				_do_redo()
			else:
				_do_undo()
			accept_event()
		elif ev.command and ev.scancode == KEY_Y:
			_do_redo()
			accept_event()


func _sheet_press(ev: InputEventMouseButton) -> void:
	_sheet.grab_focus()
	var pos = ev.position
	if pos.y < RULER_H:
		if pos.x >= LABEL_W and abs(pos.x - _t2x(_anim.length)) <= 7.0:
			_view_fit = false
			_drag = {"mode": "length"}
			return
		if pos.x >= LABEL_W:
			_drag = {"mode": "scrub"}
			_scrub_to(pos.x)
		return
	if pos.x < LABEL_W and pos.x >= LABEL_W - EYE_W:     # the eye of a row: show / hide it
		var er = _row_at(pos.y)
		if er != -1 and _row_eye(er) != -1:
			_toggle_row_eye(er)
			return
	if pos.x < LABEL_W:                                  # a channel name: select the whole track
		_sel = []
		_sel_track = -1
		var ri = _row_at(pos.y)
		if ri != -1 and _rows[ri]["kind"] == "track":
			_sel_track = _rows[ri]["track"]
		_sheet.update()
		return
	_sel_track = -1
	var ah = _audio_handle_at(pos)
	if not ah.empty():                                   # the end handle of an audio bar: drag to set the length
		_sel = [{"track": ah["track"], "t": ah["t"]}]
		_drag = {"mode": "adur", "track": ah["track"], "t": ah["t"], "L": ah["info"]["L"], "loop": ah["info"]["loop"], "eff": ah["info"]["eff"]}
		_sheet.update()
		return
	var hit = _hit_diamond(pos)
	if hit.empty():
		# empty space: drag a selection box (Shift adds to the selection); a plain click just moves the playhead
		var base = []
		if ev.shift:
			base = _sel.duplicate(true)
		else:
			_sel = []
		_drag = {"mode": "box", "x0": pos.x, "y0": pos.y, "x1": pos.x, "y1": pos.y, "moved": false, "base": base}
		_sheet.update()
		return
	var group = hit["entries"]
	var already = true
	for e in group:
		if not _is_sel(e):
			already = false
	if ev.shift:
		if already:                                      # shift-click toggles
			var rest = []
			for sk in _sel:
				var in_group = false
				for e in group:
					if e["track"] == sk["track"] and abs(e["t"] - sk["t"]) < 0.0005:
						in_group = true
				if not in_group:
					rest.append(sk)
			_sel = rest
			_sheet.update()
			return
	elif not already:
		_sel = []
	if not already:
		for e in group:
			_sel.append({"track": e["track"], "t": e["t"]})
	var tmin = 1e9
	var tmax = -1e9
	for sk in _sel:
		tmin = min(tmin, sk["t"])
		tmax = max(tmax, sk["t"])
	_drag = {"mode": "move", "x0": pos.x, "dt": 0.0, "moved": false, "tmin": tmin, "tmax": tmax}
	if not ev.shift:
		_drag["click_t"] = hit["t"]
	_sheet.update()


func _sheet_release() -> void:
	if _drag == null:
		return
	var d = _drag
	_drag = null
	if d["mode"] == "length":
		_mark_changed("Cutscene length")
	if d["mode"] == "adur":
		_apply_audio_length(d["track"], d["t"], d["eff"], d["loop"], d["L"])
	if d["mode"] == "box":
		if d["moved"]:
			_say("%d key(s) selected.  Drag one of them to move them all, Ctrl+C / Ctrl+V to copy." % _sel.size())
		else:
			_scrub_to(d["x1"])
	if d["mode"] == "move":
		if d["moved"] and abs(d["dt"]) >= 0.0005:
			_move_selection(d["dt"])
		elif not d["moved"] and d.has("click_t"):
			_seek(d["click_t"])                          # a plain click on a key jumps the playhead there
	_sheet.update()


# The end handle of an audio clip under the mouse: {track, t, info} or {}.
func _audio_handle_at(pos: Vector2) -> Dictionary:
	if pos.x < LABEL_W or pos.y < RULER_H:
		return {}
	var ri = _row_at(pos.y)
	if ri == -1 or _rows[ri]["kind"] != "track":
		return {}
	var idx = _rows[ri]["track"]
	if idx < 0 or idx >= _anim.get_track_count() or _anim.track_get_type(idx) != Animation.TYPE_AUDIO:
		return {}
	for k in range(_anim.track_get_key_count(idx)):
		var t = _anim.track_get_key_time(idx, k)
		var info = _aud_info(idx, k, t)
		var ex = _t2x(t + info["eff"])
		if abs(pos.x - ex) <= 5.0 and ex - _t2x(t) > DIAMOND + 4.0:
			return {"track": idx, "t": t, "info": info}
	return {}


# Dropped the handle: not looping = trim with Godot's own end offset; looping = remember the length.
func _apply_audio_length(idx: int, t: float, eff: float, loop: bool, length: float) -> void:
	var k = _anim.track_find_key(idx, t, true)
	if k == -1:
		return
	if loop:
		_aud_put(idx, t, true, eff)
		_anim.audio_track_set_key_end_offset(idx, k, 0.0)
	else:
		var so = _anim.audio_track_get_key_start_offset(idx, k)
		var trim = max(length - so - eff, 0.0)
		if trim < 0.01:
			trim = 0.0
		_anim.audio_track_set_key_end_offset(idx, k, trim)
	_finish_edit("Audio length %.2fs." % eff, false)


func _selected_audio_keys() -> Array:
	var out = []
	for sk in _sel:
		var idx = sk["track"]
		if idx < 0 or idx >= _anim.get_track_count() or _anim.track_get_type(idx) != Animation.TYPE_AUDIO:
			continue
		var k = _anim.track_find_key(idx, sk["t"], true)
		if k != -1:
			out.append({"track": idx, "k": k, "t": sk["t"]})
	return out


func _toggle_audio_loop() -> void:
	if _anim == null:
		return
	var keys = _selected_audio_keys()
	if keys.empty():
		_say("Select an audio key in the timeline first.")
		return
	var want = not _aud_get(keys[0]["track"], keys[0]["t"])["loop"]
	for a in keys:
		_aud_put(a["track"], a["t"], want, 0.0)
		_anim.audio_track_set_key_end_offset(a["track"], a["k"], 0.0)
	_finish_edit("Audio loop %s for %d key(s)." % ["ON (until the cutscene ends - drag the handle to shorten)" if want else "off", keys.size()], false)


func _on_key_menu(id: int) -> void:
	if id == 0:
		_toggle_audio_loop()
	elif id == 1:
		var keys = _selected_audio_keys()
		for a in keys:
			var ex = _aud_get(a["track"], a["t"])
			_aud_put(a["track"], a["t"], ex["loop"], 0.0)
			_anim.audio_track_set_key_end_offset(a["track"], a["k"], 0.0)
		if not keys.empty():
			_finish_edit("Audio length reset.", false)


func _sheet_context(ev: InputEventMouseButton) -> void:
	_sheet.grab_focus()
	var hit = _hit_diamond(ev.position)
	if hit.empty():
		return
	var group = hit["entries"]
	var has_audio = false
	var already = true
	for e in group:
		if _anim.track_get_type(e["track"]) == Animation.TYPE_AUDIO:
			has_audio = true
		if not _is_sel(e):
			already = false
	if not has_audio:
		return
	if not already:
		_sel = []
		for e in group:
			_sel.append({"track": e["track"], "t": e["t"]})
	var keys = _selected_audio_keys()
	if keys.empty():
		return
	_key_menu.set_item_checked(0, _aud_get(keys[0]["track"], keys[0]["t"])["loop"])
	_key_menu.popup(Rect2(get_global_mouse_position(), Vector2(0, 0)))
	_sheet.update()


# Selects every key whose diamond lies inside the box being dragged (added to the keys selected before it, if Shift was held).
func _box_select() -> void:
	var xa = min(_drag["x0"], _drag["x1"])
	var xb = max(_drag["x0"], _drag["x1"])
	var ya = min(_drag["y0"], _drag["y1"])
	var yb = max(_drag["y0"], _drag["y1"])
	var marks = _collect_marks()
	var sel = _drag["base"].duplicate(true)
	for r in range(_rows.size()):
		var top = RULER_H + r * ROW_H - _scroll_y
		if top + ROW_H < ya or top > yb or top + ROW_H < RULER_H:
			continue
		for e in _row_scope(_rows[r], marks):
			var x = _t2x(e["t"])
			if x < LABEL_W or x + DIAMOND < xa or x - DIAMOND > xb:
				continue
			var have = false
			for sk in sel:
				if sk["track"] == e["track"] and abs(sk["t"] - e["t"]) < 0.0005:
					have = true
					break
			if not have:
				sel.append({"track": e["track"], "t": e["t"]})
	_sel = sel
	_say("%d key(s) selected" % _sel.size())


func _select_all_keys() -> void:
	_sel = []
	for e in _collect_marks():
		_sel.append({"track": e["track"], "t": e["t"]})
	_sel_track = -1
	_say("%d key(s) selected" % _sel.size())
	_sheet.update()


# Ctrl+C / Ctrl+X: remember the selected keys (what they are, which track path, and their time relative to the first one).
func _on_copy_keys(cut: bool = false) -> void:
	if _anim == null:
		return
	if _sel.empty():
		_say("Select keys first (click, Shift+click or drag a box in the timeline).")
		return
	var items = []
	var tmin = 1e9
	for sk in _sel:
		var idx = sk["track"]
		if idx < 0 or idx >= _anim.get_track_count():
			continue
		var type = _anim.track_get_type(idx)
		var it = {"path": str(_anim.track_get_path(idx)), "type": type, "t": sk["t"]}
		if type == Animation.TYPE_TRANSFORM:
			var found = false
			for e in _get_src(idx):
				if abs(e["t"] - sk["t"]) < 0.0005:
					it["o"] = e["o"]
					it["q"] = e["q"]
					it["s"] = e["s"]
					it["m"] = e["m"]
					found = true
					break
			if not found:
				continue
		else:
			var k = _anim.track_find_key(idx, sk["t"], true)
			if k == -1:
				continue
			if type == Animation.TYPE_AUDIO:
				it["stream"] = _anim.audio_track_get_key_stream(idx, k)
				it["so"] = _anim.audio_track_get_key_start_offset(idx, k)
				it["eo"] = _anim.audio_track_get_key_end_offset(idx, k)
				var ax = _aud_get(idx, sk["t"])
				it["loop"] = ax["loop"]
				it["dur"] = ax["dur"]
			elif type == Animation.TYPE_VALUE or type == Animation.TYPE_ANIMATION:
				it["v"] = _anim.track_get_key_value(idx, k)
				it["tr"] = _anim.track_get_key_transition(idx, k)
				if type == Animation.TYPE_VALUE:
					it["discrete"] = _anim.value_track_get_update_mode(idx) == Animation.UPDATE_DISCRETE
			else:
				continue
		items.append(it)
		tmin = min(tmin, sk["t"])
	if items.empty():
		_say("These keys cannot be copied.")
		return
	for it in items:
		it["dt"] = it["t"] - tmin
	_clip = items
	if cut:
		_on_delete_key()
		_say("Cut %d key(s). Move the playhead and press Ctrl+V to paste." % items.size())
	else:
		_say("Copied %d key(s). Move the playhead and press Ctrl+V to paste." % items.size())


# Ctrl+V: paste the copied keys so the first one lands on the playhead. Tracks are matched by their path, so
# keys can be pasted into another cutscene too; a key that lands on an existing key replaces it.
func _on_paste_keys() -> void:
	if _anim == null:
		return
	if _clip.empty():
		_say("Nothing copied yet. Select keys and press Ctrl+C.")
		return
	var base = _time
	var newsel = []
	var poses = {}
	for it in _clip:
		if it["type"] == Animation.TYPE_TRANSFORM:
			if not poses.has(it["path"]):
				poses[it["path"]] = []
			poses[it["path"]].append(it)
	for path in poses:
		var idx = _get_track(path, Animation.TYPE_TRANSFORM)
		var src = _get_src(idx)
		for it in poses[path]:
			var t = base + it["dt"]
			for i in range(src.size() - 1, -1, -1):
				if abs(src[i]["t"] - t) < 0.0005:
					src.remove(i)
			src.append({"t": t, "o": it["o"], "q": it["q"], "s": it["s"], "m": it["m"]})
			newsel.append({"track": idx, "t": t})
			_extend(t)
		src.sort_custom(self, "_sort_src")
		_rebake(idx, src)
	for it in _clip:
		var type = it["type"]
		if type == Animation.TYPE_TRANSFORM:
			continue
		var idx2 = _get_track(it["path"], type, it.get("discrete", false))
		var t2 = base + it["dt"]
		var ex = _anim.track_find_key(idx2, t2, true)
		if ex != -1:
			_anim.track_remove_key(idx2, ex)
		if type == Animation.TYPE_AUDIO:
			_anim.audio_track_insert_key(idx2, t2, it["stream"], it["so"], it["eo"])
			_aud_put(idx2, t2, it.get("loop", false), it.get("dur", 0.0))
		else:
			_anim.track_insert_key(idx2, t2, it["v"], it["tr"])
		newsel.append({"track": idx2, "t": t2})
		_extend(t2)
	_sel = newsel
	_sel_track = -1
	_finish_edit("Pasted %d key(s) at %s." % [newsel.size(), _fmt_time(base)], true)


# {track: [times]} of the selected keys, optionally only pose (transform) keys
func _selected_times(poses_only: bool = false) -> Dictionary:
	var by_track = {}
	for sk in _sel:
		if sk["track"] >= _anim.get_track_count():
			continue
		if poses_only and _anim.track_get_type(sk["track"]) != Animation.TYPE_TRANSFORM:
			continue
		if not by_track.has(sk["track"]):
			by_track[sk["track"]] = []
		by_track[sk["track"]].append(sk["t"])
	return by_track


func _move_selection(dt: float) -> void:
	var by_track = _selected_times()
	var count = _sel.size()
	for idx in by_track:
		var times = by_track[idx]
		if _anim.track_get_type(idx) == Animation.TYPE_TRANSFORM:
			var src = _get_src(idx)
			var moved = []
			var stay = []
			for e in src:
				if _has_time(times, e["t"]):
					e["t"] = clamp(e["t"] + dt, 0.0, _anim.length)
					moved.append(e)
				else:
					stay.append(e)
			for j in range(stay.size() - 1, -1, -1):          # a moved key replaces one it lands on
				for m in moved:
					if abs(stay[j]["t"] - m["t"]) < 0.0005:
						stay.remove(j)
						break
			var all = stay + moved
			all.sort_custom(self, "_sort_src")
			_rebake(idx, all)
		else:
			_move_plain_keys(idx, times, dt)
	for sk in _sel:
		sk["t"] = clamp(sk["t"] + dt, 0.0, _anim.length)
	_finish_edit("Moved %d key(s) by %+.2fs" % [count, dt], true)


func _move_plain_keys(idx: int, times: Array, dt: float) -> void:
	var type = _anim.track_get_type(idx)
	var items = []
	for k in range(_anim.track_get_key_count(idx) - 1, -1, -1):
		var kt = _anim.track_get_key_time(idx, k)
		if not _has_time(times, kt):
			continue
		var nt = clamp(kt + dt, 0.0, _anim.length)
		if type == Animation.TYPE_AUDIO:
			items.append({"t": nt, "ot": kt, "ax": _aud_get(idx, kt), "stream": _anim.audio_track_get_key_stream(idx, k),
					"so": _anim.audio_track_get_key_start_offset(idx, k), "eo": _anim.audio_track_get_key_end_offset(idx, k)})
		elif type == Animation.TYPE_VALUE or type == Animation.TYPE_ANIMATION:
			items.append({"t": nt, "v": _anim.track_get_key_value(idx, k), "tr": _anim.track_get_key_transition(idx, k)})
		else:
			continue
		_anim.track_remove_key(idx, k)
	if type == Animation.TYPE_AUDIO:
		for it in items:
			_aud_drop(idx, it["ot"])
	for it in items:
		var ex = _anim.track_find_key(idx, it["t"], true)
		if ex != -1:
			_anim.track_remove_key(idx, ex)
		if type == Animation.TYPE_AUDIO:
			_anim.audio_track_insert_key(idx, it["t"], it["stream"], it["so"], it["eo"])
			_aud_put(idx, it["t"], it["ax"]["loop"], it["ax"]["dur"])
		else:
			_anim.track_insert_key(idx, it["t"], it["v"], it["tr"])


func _on_delete_key() -> void:
	if _anim == null:
		return
	if not _sel.empty():
		var by_track = _selected_times()
		var count = _sel.size()
		var tracks = by_track.keys()
		tracks.sort()
		tracks.invert()                                      # highest track first so lower indexes stay valid
		for idx in tracks:
			var times = by_track[idx]
			if _anim.track_get_type(idx) == Animation.TYPE_TRANSFORM:
				var keep = []
				for e in _get_src(idx):
					if not _has_time(times, e["t"]):
						keep.append(e)
				if keep.empty():
					_drop_src(idx)
					_anim.remove_track(idx)
				else:
					_rebake(idx, keep)
			else:
				for k in range(_anim.track_get_key_count(idx) - 1, -1, -1):
					if _has_time(times, _anim.track_get_key_time(idx, k)):
						if _anim.track_get_type(idx) == Animation.TYPE_AUDIO:
							_aud_drop(idx, _anim.track_get_key_time(idx, k))
						_anim.track_remove_key(idx, k)
				if _anim.track_get_key_count(idx) == 0:
					_anim.remove_track(idx)
		_sel = []
		_sel_track = -1
		_finish_edit("Deleted %d key(s)." % count, true)
		return
	if _sel_track >= 0 and _sel_track < _anim.get_track_count():
		if _anim.track_get_type(_sel_track) == Animation.TYPE_TRANSFORM:
			_drop_src(_sel_track)
		_anim.remove_track(_sel_track)
		_sel_track = -1
		_finish_edit("Track deleted.", true)
		return
	_say("Click a key (or a channel name) in the timeline first.")
