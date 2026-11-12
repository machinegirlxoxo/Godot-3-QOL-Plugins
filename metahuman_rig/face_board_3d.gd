tool
extends Spatial
# The face board as a real object in the 3D editor viewport.
# The 2D face board is rendered into a Viewport, the Viewport is shown on a quad, and mouse input
# coming from the editor's 3D viewport is ray-cast onto the quad and forwarded into that Viewport.

signal gui_value_changed(index, value)
signal pose_changed     # the face pose was changed from outside the board (Cinematic keys, Inspector); sent once per frame
signal edit_finished    # the mouse was released after dragging a handle

const FaceBoard = preload("face_board.gd")
const RigLogic = preload("rig_logic.gd")
const Binder = preload("rig_binder.gd")

# The board quad lives on visual layer 20. The Cinematic tab's Result view never draws that layer (it is the same
# layer its own gizmos use), the Editor views and the 3D editor do, and in the running game the quad is switched off.
const BOARD_LAYER = 1 << 19

# Every face control is a property of this node called  face/<control name>  (float, usually 0..1 or -1..1), so
# the Cinematic tab (or any AnimationPlayer) can key it:  MetaHumanFaceBoard3D:face/CTRL_expressions_browDownL
const PROP_PREFIX = "face/"

var board = FaceBoard.new()
var pixel_size := Vector2(640, 400)
export var width_world := 0.5 setget _set_width   # quad width in world units

# Used by the running game (and by the editor when the MetaHuman Rig dock has not loaded a rig): the board loads
# the rig itself and drives the skeleton, so cutscene face animation also plays outside the editor.
export(String, FILE, "*.json") var rig_path = ""
export(NodePath) var skeleton_path = NodePath("")
export var drive_in_game := true

# The face pose the dock last wrote for this scene ({"gui": {control: value}, "raw": {control: value}}, only non-zero
# values). It is saved with the scene so that closing / reopening / switching scenes brings the expression back: the
# RigLogic state itself lives in the dock and is lost when the scene is left. Animations still override it (face/<control>).
var face_state := {}

var rig = null                 # RigLogic (the dock's one in the editor, our own in the game)
var _binder = null
var _own_rig := false
var _built := false
var _dirty := false
var _prop_to_index := {}
var _bind_error := ""
var last_joints := 0           # how many joints the last pose change moved
var _pending := {}             # values that arrived (game only) before the rig was loaded

var _vp := Viewport.new()
var _mesh := QuadMesh.new()
var _quad := MeshInstance.new()
var _mat := SpatialMaterial.new()
var _capturing := false
var _last := Vector2.ZERO


func _init() -> void:
	name = "MetaHumanFaceBoard3D"
	_vp.name = "BoardViewport"
	_vp.size = pixel_size
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.usage = Viewport.USAGE_2D
	_vp.render_target_v_flip = true
	_vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
	add_child(_vp)

	board.light_theme = true      # dark outlines, transparent background (no panel behind the board)
	board.board_pixels = 2400.0   # drawn large so lines and text stay sharp when the quad is zoomed
	board.scroll_horizontal_enabled = false
	board.scroll_vertical_enabled = false
	board.connect("gui_value_changed", self, "_relay")
	_vp.add_child(board)

	_mat.flags_unshaded = true
	_mat.flags_transparent = true
	_mat.params_cull_mode = SpatialMaterial.CULL_DISABLED
	_mat.albedo_texture = _vp.get_texture()
	_quad.mesh = _mesh
	_quad.material_override = _mat
	_quad.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
	_quad.layers = BOARD_LAYER     # not drawn by the Cinematic Result view
	add_child(_quad)
	_update_quad()


func _ready() -> void:
	if Engine.editor_hint:
		set_process(true)
		return
	# in the running game the board is never drawn, never updated
	_quad.visible = false
	_vp.render_target_update_mode = Viewport.UPDATE_DISABLED
	set_process(false)
	if drive_in_game:
		_runtime_setup()


func _relay(index: int, value: float) -> void:
	emit_signal("gui_value_changed", index, value)


func build(p_rig, font = null) -> void:
	# the MetaHuman Rig dock owns the rig; the board ALSO binds the skeleton itself (applying the same values twice
	# is harmless), so poses from the Cinematic tab / animations reach the model even if the dock's own binding is stale
	if rig != null and rig.is_connected("outputs_changed", self, "_on_own_outputs"):
		rig.disconnect("outputs_changed", self, "_on_own_outputs")
	_own_rig = false
	_binder = null
	_bind_error = ""
	rig = p_rig
	_index_controls()
	if is_inside_tree() and rig != null and rig.loaded:
		var root: Node = owner if owner != null else get_parent()
		var skel = _find_skeleton(rig, root)
		if skel == null:
			_bind_error = "no Skeleton in the scene matches the rig"
		else:
			_binder = Binder.new()
			_binder.bind(rig, skel, root)
			rig.connect("outputs_changed", self, "_on_own_outputs")
	board.base_font = font
	board.build(rig)
	_built = true
	property_list_changed_notify()
	var s: Vector2 = board.content_size()
	pixel_size = Vector2(max(s.x, 200.0), max(s.y, 120.0))
	_vp.size = pixel_size
	board.rect_position = Vector2.ZERO
	board.rect_size = pixel_size
	_update_quad()


func sync_from(p_rig) -> void:
	board.sync_from(p_rig)


func _set_width(w: float) -> void:
	width_world = max(w, 0.001)
	_update_quad()


func set_world_width(w: float) -> void:
	_set_width(w)


func world_height() -> float:
	return width_world * pixel_size.y / pixel_size.x


func _update_quad() -> void:
	_mesh.size = Vector2(width_world, world_height())


# Screen position (in the 3D viewport) -> pixel position on the board, or null if the ray misses the plane.
func pixel_from_screen(camera: Camera, screen_pos: Vector2):
	var from: Vector3 = camera.project_ray_origin(screen_pos)
	var dir: Vector3 = camera.project_ray_normal(screen_pos)
	var gt: Transform = global_transform
	var n: Vector3 = gt.basis.z.normalized()
	var plane := Plane(n, n.dot(gt.origin))
	var hit = plane.intersects_ray(from, dir)
	if hit == null:
		return null
	var l: Vector3 = gt.affine_inverse().xform(hit)
	var h := world_height()
	return Vector2((l.x / width_world + 0.5) * pixel_size.x, (0.5 - l.y / h) * pixel_size.y)


func screen_from_pixel(camera: Camera, px: Vector2) -> Vector2:
	var h := world_height()
	var l := Vector3((px.x / pixel_size.x - 0.5) * width_world, (0.5 - px.y / pixel_size.y) * h, 0.0)
	return camera.unproject_position(global_transform.xform(l))


func _inside(p: Vector2) -> bool:
	return p.x >= 0.0 and p.y >= 0.0 and p.x <= pixel_size.x and p.y <= pixel_size.y


# Called by the plugin for every 3D viewport mouse event. Returns true when the board consumed it.
func handle_input(camera: Camera, ev: InputEvent) -> bool:
	if not visible or not is_inside_tree():
		return false
	if ev is InputEventMouseButton:
		if ev.button_index != BUTTON_LEFT:
			return false
		var p = pixel_from_screen(camera, ev.position)
		if ev.pressed:
			# only grab the click when it is on a handle, so the editor gizmo / selection still work elsewhere
			if p == null or not _inside(p) or not board.has_control_at(p):
				return false
			_capturing = true
		elif not _capturing:
			return false
		var pos: Vector2 = p if p != null else _last
		_send_button(pos, ev.pressed, ev.doubleclick)
		if not ev.pressed:
			_capturing = false
			emit_signal("edit_finished")
		return true
	if ev is InputEventMouseMotion and _capturing:
		var q = pixel_from_screen(camera, ev.position)
		if q != null:
			_send_motion(q)
		return true
	return false


func _send_button(p: Vector2, pressed: bool, dbl: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = BUTTON_LEFT
	e.pressed = pressed
	e.doubleclick = dbl
	e.position = p
	e.global_position = p
	e.button_mask = BUTTON_MASK_LEFT if pressed else 0
	_last = p
	_vp.input(e)


func _send_motion(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	e.relative = p - _last
	e.button_mask = BUTTON_MASK_LEFT
	_last = p
	_vp.input(e)


# ---------------------------------------------------------------- animatable face controls

func _safe(n: String) -> String:
	return n.replace(":", "_").replace("/", "_").replace(",", "_")


func _index_controls() -> void:
	_prop_to_index.clear()
	if rig == null or not rig.loaded:
		return
	for i in range(rig.gui_names.size()):
		_prop_to_index[PROP_PREFIX + _safe(rig.gui_names[i])] = i


func _get_property_list() -> Array:
	var out := [{"name": "face_state", "type": TYPE_DICTIONARY, "usage": PROPERTY_USAGE_STORAGE}]
	if rig == null or not rig.loaded:
		return out
	out.append({"name": "Face controls", "type": TYPE_NIL, "hint_string": PROP_PREFIX, "usage": PROPERTY_USAGE_GROUP})
	for i in range(rig.gui_names.size()):
		var rng: Array = rig.gui_ranges[i]
		out.append({
			"name": PROP_PREFIX + _safe(rig.gui_names[i]),
			"type": TYPE_REAL,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "%s,%s,0.001" % [rng[0], rng[1]],
			"usage": PROPERTY_USAGE_EDITOR,     # not stored in the scene: the pose lives in animations
		})
	return out


func _get(property):
	if rig != null and _prop_to_index.has(property):
		return rig.gui_values[_prop_to_index[property]]
	return null


func _set(property, value) -> bool:
	if not (property is String) or not property.begins_with(PROP_PREFIX):
		return false
	if rig == null or not rig.loaded:
		if not Engine.editor_hint:
			_pending[property] = value     # applied as soon as the game has loaded the rig
		return true
	if not _prop_to_index.has(property):
		return false
	rig.set_gui_value(_prop_to_index[property], float(value))
	_dirty = true
	return true


func _process(_delta: float) -> void:
	if not _dirty:
		return
	_dirty = false
	if _built and rig != null and rig.loaded:
		board.sync_from(rig)
	emit_signal("pose_changed")


# {"face/<control>": value} for every control. The Cinematic tab keys this.
func get_face_pose() -> Dictionary:
	var d := {}
	if rig == null or not rig.loaded:
		return d
	for k in _prop_to_index:
		d[k] = rig.gui_values[_prop_to_index[k]]
	return d


# Sets one raw GUI control (index into rig.gui_names), e.g. from a 2D board embedded in the Cinematic tab.
func set_gui_value(index: int, value: float) -> void:
	if rig == null or not rig.loaded:
		return
	rig.set_gui_value(index, value)
	if _built:
		board.sync_from(rig)
	emit_signal("gui_value_changed", index, value)    # the dock refreshes its 2D board from this


func get_face_control_count() -> int:
	return _prop_to_index.size()


func reset_face() -> void:
	if rig == null or not rig.loaded:
		return
	rig.reset_all()
	_dirty = true


# ---------------------------------------------------------------- running game: load the rig, bind the skeleton

func _runtime_setup() -> void:
	if rig != null or rig_path == "":
		return
	var r = RigLogic.new()
	if not r.load_files(rig_path):
		push_warning("MetaHumanFaceBoard3D: " + r.error)
		return
	var root: Node = owner if owner != null else get_parent()
	var skel = _find_skeleton(r, root)
	if skel == null:
		push_warning("MetaHumanFaceBoard3D: no Skeleton matching the rig was found (set Skeleton Path).")
		return
	_binder = Binder.new()
	_binder.bind(r, skel, root)
	rig = r
	_own_rig = true
	rig.connect("outputs_changed", self, "_on_own_outputs")
	_index_controls()
	var pend := _pending
	_pending = {}
	for k in pend:
		_set(k, pend[k])


func _on_own_outputs(joints: Array, channels: Array) -> void:
	last_joints = joints.size()
	if _binder != null:
		_binder.apply(joints, channels)


# One line for the Cinematic tab: what the board is bound to.
func get_apply_status() -> String:
	if _binder != null:
		return _binder.status_text()
	if _bind_error != "":
		return "Not applied to a model: " + _bind_error
	return "Waiting for the MetaHuman Rig dock to load the rig"


func _find_skeleton(r, root: Node):
	if skeleton_path != NodePath(""):
		var s = get_node_or_null(skeleton_path)
		if s is Skeleton:
			return s
	var list := []
	_collect_skeletons(root, list)
	var best = null
	var best_count := 0
	for s in list:
		var c := 0
		for j in r.joint_names:
			if s.find_bone(j) >= 0:
				c += 1
		if c > best_count:
			best_count = c
			best = s
	return best


func _collect_skeletons(n: Node, out: Array) -> void:
	if n is Skeleton:
		out.append(n)
	for c in n.get_children():
		_collect_skeletons(c, out)
