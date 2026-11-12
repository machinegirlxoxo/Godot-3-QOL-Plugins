tool
extends Spatial
# MetaHumanBodyRig: the body control rig of the Character DNA Blender add-on, rebuilt for Godot 3.
#
#  * FK controls   one Vector3 property per body joint:  fk/<joint>  (euler degrees, XYZ, relative to the rest pose,
#                  same convention as the dock's Bones tab).  Root, pelvis and the pectorals also have  fkpos/<joint>
#                  (skeleton axes).  Every joint has  fkscale/<joint>  (local scale, 1 = rest).
#  * IK limbs      both arms and both legs:  a Position3D handle for the hand / foot  (CTRL_ik_<end>)  and one for the
#                  pole  (CTRL_pole_<arm|leg>_<side>) are children of this node.  Move / rotate them with the normal gizmo,
#                  key them in an AnimationPlayer or in the Cinematic tab.
#  * FK <-> IK     ik/<arm_l|arm_r|leg_l|leg_r>  = 0 (FK) .. 1 (IK).  Same defaults as in Blender: legs IK, arms FK.
#
# Everything is plain bone poses (Skeleton.set_bone_pose), so it works in the editor, in cutscenes and in the running game.
# The node only re-solves when one of its inputs changed, so it never fights with manual posing of other bones.

signal pose_changed

const BodyIK = preload("body_ik.gd")
const Shapes = preload("control_shapes.gd")
const Registry = preload("body_registry.gd")
const BodyLogic = preload("body_logic.gd")
const FK_PREFIX = "fk/"
const FKPOS_PREFIX = "fkpos/"
const FKSCALE_PREFIX = "fkscale/"
const IK_PREFIX = "ik/"
const LAYER_PREFIX = "layers/"
const PROTECT_KEY = "mh_body_joints_"   # Registry entry per skeleton id: [version, {joint name: true}] (joints the face rig must not touch)
const FK_CONTAINER = "FK"          # child Spatial that holds one rotatable handle per FK joint
const FK_NODE_PREFIX = "FK_"
const TORSO_PELVIS = "CTRL_pelvis"     # torso controls: plain Spatial handles, move / rotate gizmo, saved + keyable
const TORSO_SPINE = "CTRL_spine"
const TORSO_CHEST = "CTRL_chest"
# Standard MetaHuman body joints. Any of these that exist in the skeleton become FK controls even if body.json lacks them.
const BODY_JOINT_PATTERN = "^(root|pelvis|spine_\\d+|neck_\\d+|head|clavicle_[lr]|upperarm_[lr]|lowerarm_[lr]|hand_[lr]|(thumb|index|middle|ring|pinky)_\\d+_[lr]|thigh_[lr]|calf_[lr]|foot_[lr]|ball_[lr])$"

export(String, FILE, "*.json") var body_path = "" setget _set_body_path
export(String, FILE, "*.json") var body_logic_path = "" setget _set_logic_path   # body RigLogic (<n>.rig.json of the body DNA): drives corrective + twist joints
export(NodePath) var skeleton_path = NodePath("")
export var enabled := true
export var drive_in_game := true
export var show_shapes := true setget _set_show_shapes   # wire control shapes (hand / foot cubes, pole diamonds, FK rings)
export var show_fk_rings := true            # one ring per FK joint, click it in the viewport to get its rotate handle
export var show_torso_fk_rings := false     # also draw the big per-bone spine circles / pelvis box (the CTRL_pelvis / spine / chest handles replace them)
export var shape_scale := 1.0
export var show_names := false              # write the name of every visible control next to it in the 3D editor viewport
export var link_head_skeleton := true setget _set_link_head   # a second skeleton (separate head / face armature) follows this body skeleton
export var line_width := 0.008 setget _set_line_width     # thickness of the control lines, metres
var hidden_layers = PoolStringArray() setget _set_hidden_layers   # saved with the scene; edited through the layers/<name> tick boxes in the Inspector
export var show_shapes_in_game := false
export var ik_by_default := true          # all four limbs start in IK mode (Blender's arms default to FK)
export var create_fk_handles := false setget _set_create_fk_handles   # the 84 loose FK_<joint> nodes; off = IK handles only

var spec := {}
var logic = null          # BodyLogic, null when no body rig logic file is set
var skeleton: Skeleton = null
var limbs := []          # [{key, kind, side, names, bones, parent, rest, rest_parent_basis, bend_rest, target, pole, default_ik}]
var fk_list := []        # [{joint, bone, translate}]
var error := ""
var _lines: MeshInstance = null          # FK rings, limb sticks, pole lines (one mesh, rebuilt when the pose changes)
var _buf = null                         # LineBuf collecting the triangles
var _warned := {}
var _mat: SpatialMaterial = null
var _ring_info := []     # [{joint, center (skeleton space), radius}] from the last draw

var _fk_rot := {}        # joint -> Vector3 (degrees)
var _fk_pos := {}        # joint -> Vector3 (metres)
var _ik := {}            # limb key -> float
var _dirty := true
var _last_sig := []
var _loaded_spec_path := ""
var _h_rot := {}         # joint -> Vector3 degrees the FK handle was last synchronised to
var _h_pos := {}         # joint -> Vector3 metres the translate handle was last synchronised to
var _fk_scl := {}        # joint -> Vector3 local scale (missing = 1,1,1)
var _h_scl := {}         # joint -> Vector3 scale the FK handle was last synchronised to
var _h_wo := {}          # joint -> Vector3 skeleton space origin a "follow" translate handle (pectorals) was last written at

# Torso controls (pelvis / spine / chest). The handle node IS the state: its rotation is a world-axes rotation delta
# applied on top of the FK pose, the pelvis handle's position is a translation delta.
var torso := []          # [{name, kind, bones (root -> tip), tip, translate}]
var _tc_rot := {}        # handle name -> Basis (rotation delta, skeleton space)
var _tc_d := {}          # handle name -> Vector3 (pelvis translation delta, skeleton space)
var _tc_scl := {}        # handle name -> Vector3 scale of the handle (spread over the bones of the control)
var _tc_wo := {}         # handle name -> Vector3 skeleton space origin the handle was last written at
var _tc_pts := {}        # handle name -> PoolVector3Array shape lines in handle space (for picking)
var _char_b := Basis()   # handle rest orientation in skeleton space: x = character right, y = up, z = forward


func _ready() -> void:
	set_process(true)
	if not Engine.editor_hint and not drive_in_game:
		set_process(false)
		return
	if body_path != "":
		setup()


func _set_logic_path(p: String) -> void:
	body_logic_path = p
	if is_inside_tree() and skeleton != null:
		_setup_logic()
		_dirty = true


func _logic_file() -> String:
	if body_logic_path != "":
		return body_logic_path
	if body_path.ends_with(".body.json"):      # guess: <name>.body_dna.rig.json next to <name>.body.json
		var g: String = body_path.substr(0, body_path.length() - 10) + ".body_dna.rig.json"
		if File.new().file_exists(g):
			return g
	return ""


func _setup_logic() -> void:
	logic = null
	var path := _logic_file()
	if path == "" or skeleton == null:
		return
	var l = BodyLogic.new()
	var root: Node = get_owner() if get_owner() != null else self
	if l.setup(path, skeleton, root):
		logic = l
	else:
		push_warning("MetaHumanBodyRig: body logic not loaded: " + l.error)
		logic = l     # kept only for status_text(); evaluate() does nothing while it is not loaded


func _set_body_path(p: String) -> void:
	body_path = p


func _set_create_fk_handles(v: bool) -> void:
	create_fk_handles = v
	if not is_inside_tree() or skeleton == null:
		return
	if v:
		ensure_fk_handles(owner)
	else:
		remove_fk_handles()


func _set_line_width(v: float) -> void:
	line_width = clamp(v, 0.001, 0.05)
	_rebuild_shapes()


func _set_hidden_layers(v: PoolStringArray) -> void:
	hidden_layers = v
	_rebuild_shapes()


func _rebuild_shapes() -> void:
	if is_inside_tree() and skeleton != null:
		_ensure_shapes()
		_update_shapes()


func layer_names() -> Array:
	var out := []
	for l in Shapes.LAYERS:
		if l == "Pelvis" or l == "Spine" or l == "Chest":
			if layer_count(l) > 0:
				out.append(l)
		elif l == "IK Arms" or l == "IK Legs":
			var kind := "arm" if l == "IK Arms" else "leg"
			var found := false
			for lm in limbs:
				if lm["kind"] == kind:
					found = true
			if found:
				out.append(l)
		elif layer_count(l) > 0:
			out.append(l)
	return out


# How many controls a layer has (shown in the Body tab; Torso 0 means no spine bone was found in the skeleton).
func layer_count(layer: String) -> int:
	var c := 0
	if layer == "IK Arms" or layer == "IK Legs":
		for lm in limbs:
			if _limb_layer(lm) == layer:
				c += 2
		return c
	for e in fk_list:
		if Shapes.joint_layer(e["joint"]) == layer:
			c += 1
	for tc in torso:
		if _torso_layer(tc) == layer:
			c += 1
	return c


func is_layer_visible(layer: String) -> bool:
	if hidden_layers.has("Torso") and Shapes.TORSO_LAYERS.has(layer):      # scenes saved before the layer was split
		return false
	return not hidden_layers.has(layer)


func _torso_layer(c: Dictionary) -> String:
	return "Pelvis" if c["kind"] == "pelvis" else ("Spine" if c["kind"] == "spine" else "Chest")


func set_all_layers_visible(v: bool) -> void:
	var cur := []
	if not v:
		cur = layer_names()
	self.hidden_layers = PoolStringArray(cur)


func set_layer_visible(layer: String, v: bool) -> void:
	var cur := Array(hidden_layers)
	if cur.has("Torso"):          # expand the old combined layer
		cur.erase("Torso")
		for tl in Shapes.TORSO_LAYERS:
			if not cur.has(tl):
				cur.append(tl)
	if v:
		cur.erase(layer)
	elif not cur.has(layer):
		cur.append(layer)
	self.hidden_layers = PoolStringArray(cur)


func _limb_layer(l: Dictionary) -> String:
	return "IK Arms" if l["kind"] == "arm" else "IK Legs"


func _set_show_shapes(v: bool) -> void:
	show_shapes = v
	if is_inside_tree() and skeleton != null:
		_ensure_shapes()
		_update_shapes()


# Deletes the FK/ container with all FK_<joint> nodes. The fk/<joint> properties stay (inspector, keys, Bones tab).
func remove_fk_handles() -> void:
	var cont := get_node_or_null(FK_CONTAINER)
	if cont != null:
		remove_child(cont)
		cont.queue_free()
	_h_rot.clear()
	_h_pos.clear()


# ---------------------------------------------------------------- loading / binding

func setup() -> bool:
	error = ""
	if not _load_spec():
		return false
	skeleton = _find_skeleton()
	if skeleton == null:
		error = "no Skeleton in the scene matches the body rig (set Skeleton Path)"
		return false
	_bind()
	_build_links()
	_register_protect()
	_setup_logic()
	_ensure_shapes()
	property_list_changed_notify()
	_dirty = true
	_last_sig = []
	return true


func _load_spec() -> bool:
	if body_path == "":
		error = "Body Path is empty"
		return false
	if spec.size() > 0 and _loaded_spec_path == body_path:
		return true
	var f := File.new()
	if f.open(body_path, File.READ) != OK:
		error = "cannot open " + body_path
		return false
	var parsed = JSON.parse(f.get_as_text())
	f.close()
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY or not parsed.result.has("limbs"):
		error = body_path + " is not a MetaHuman body rig file"
		return false
	spec = parsed.result
	_loaded_spec_path = body_path
	for l in spec["limbs"]:
		if ik_by_default:
			l["default_ik"] = 1.0
		if not _ik.has(l["key"]):
			_ik[l["key"]] = float(l.get("default_ik", 0.0))
	return true


func _spec_joint_names() -> Array:
	var out := []
	for e in spec.get("fk", []):
		out.append(e["joint"])
	for l in spec.get("limbs", []):
		for j in l["joints"]:
			out.append(j)
	return out


func _collect_skeletons(n: Node, out: Array) -> void:
	if n is Skeleton:
		out.append(n)
	for c in n.get_children():
		_collect_skeletons(c, out)


func _find_skeleton() -> Skeleton:
	if skeleton_path != NodePath("") and has_node(skeleton_path):
		var n: Node = get_node(skeleton_path)
		if n is Skeleton:
			return n as Skeleton
	return find_skeleton_in(owner if owner != null else get_parent())


# The Skeleton under `root` that has the most body joints of this rig (needs at least 10).
func find_skeleton_in(root: Node) -> Skeleton:
	if root == null or not _load_spec():
		return null
	var cands := []
	_collect_skeletons(root, cands)
	var names := _spec_joint_names()
	var best: Skeleton = null
	var best_count := 0
	for s in cands:
		var c := 0
		for j in names:
			if s.find_bone(j) >= 0:
				c += 1
		if c > best_count:
			best_count = c
			best = s
	return best if best_count >= 10 else null


func _rest_global(bone: int) -> Transform:
	var t := Transform()
	var cur := bone
	var guard := 0
	while cur >= 0 and guard < 512:
		t = skeleton.get_bone_rest(cur) * t
		cur = skeleton.get_bone_parent(cur)
		guard += 1
	return t


# Up axis and the direction the character faces, both in skeleton space.
func _up_forward() -> Array:
	var up := skeleton.global_transform.basis.xform_inv(Vector3(0, 1, 0)).normalized()
	var fwd := Vector3.ZERO
	for side in ["l", "r"]:
		var foot := skeleton.find_bone("foot_" + side)
		var ball := skeleton.find_bone("ball_" + side)
		if foot >= 0 and ball >= 0:
			fwd = BodyIK.perp(_rest_global(ball).origin - _rest_global(foot).origin, up)
			if fwd.length() > 1e-5:
				break
	if fwd.length() < 1e-5:
		fwd = BodyIK.perp(skeleton.global_transform.basis.xform_inv(Vector3(0, 0, 1)), up)
	return [up, fwd.normalized()]


func _bind() -> void:
	fk_list.clear()
	limbs.clear()
	for e in spec.get("fk", []):
		var b := skeleton.find_bone(e["joint"])
		if b >= 0:
			fk_list.append({"joint": e["joint"], "bone": b, "translate": bool(e.get("translate", false))})
	_add_missing_body_joints()
	var uf := _up_forward()
	var forward: Vector3 = uf[1]
	_bind_torso(uf)
	for l in spec["limbs"]:
		var bones := []
		var ok := true
		for j in l["joints"]:
			var b := skeleton.find_bone(j)
			if b < 0:
				ok = false
			bones.append(b)
		if not ok:
			continue
		var rest := []
		for b in bones:
			rest.append(skeleton.get_bone_rest(b))
		var parent := skeleton.get_bone_parent(bones[0])
		var rpb := Basis()
		if parent >= 0:
			rpb = _rest_global(parent).basis.orthonormalized()
		var g0 := _rest_global(bones[0]).origin
		var g1 := _rest_global(bones[1]).origin
		var g2 := _rest_global(bones[2]).origin
		var u := (g2 - g0).normalized()
		var off := BodyIK.perp(g1 - g0, u)
		if off.length() < (g2 - g0).length() * 0.01:      # (nearly) straight limb: knees bend forward, elbows backwards
			off = BodyIK.perp(forward if l["kind"] == "leg" else -forward, u)
		limbs.append({
			"key": l["key"], "kind": l["kind"], "side": l["side"], "names": l["joints"], "bones": bones,
			"parent": parent, "rest": rest, "rest_parent_basis": rpb, "bend_rest": off.normalized(),
			"target": l["target"], "pole": l["pole"], "default_ik": float(l.get("default_ik", 0.0)),
		})


func _bone_depth(b: int) -> int:
	var d := 0
	var cur := skeleton.get_bone_parent(b)
	while cur >= 0 and d < 512:
		d += 1
		cur = skeleton.get_bone_parent(cur)
	return d


# Central spine bones, root -> tip. Prefers the standard spine_01..N names, falls back to anything spine / chest like.
func _spine_chain() -> Array:
	var rx: RegEx = RegEx.new()
	rx.compile("^spine_\\d+$")
	var found := []
	for pass_ in range(2):
		for b in range(skeleton.get_bone_count()):
			var n := skeleton.get_bone_name(b)
			var ok: bool = rx.search(n) != null if pass_ == 0 else Shapes.is_spine(n)
			if ok:
				found.append([_bone_depth(b), b])
		if found.size() > 0:
			break
	var out := []      # insertion sort by depth (Array.sort() does not order nested arrays in Godot 3)
	for f in found:
		var at := out.size()
		while at > 0 and found_depth(out[at - 1]) > f[0]:
			at -= 1
		out.insert(at, f[1])
	return out


func found_depth(b: int) -> int:
	return _bone_depth(b)


# Pelvis (position + rotation), spine (lower half of the spine chain) and chest (upper half).
# A control's rotation is spread evenly over its bones, so the spine bends smoothly instead of kinking at one bone.
func _bind_torso(uf: Array) -> void:
	torso.clear()
	var up: Vector3 = uf[0]
	var fwd: Vector3 = uf[1]
	_char_b = Basis(up.cross(fwd).normalized(), up.normalized(), fwd.normalized()).orthonormalized()
	var pel := skeleton.find_bone("pelvis")
	if pel >= 0:
		torso.append({"name": TORSO_PELVIS, "kind": "pelvis", "bones": [pel], "tip": pel, "translate": true})
	var sp := _spine_chain()
	var n := sp.size()
	if n == 1:
		torso.append({"name": TORSO_CHEST, "kind": "chest", "bones": [sp[0]], "tip": sp[0], "translate": false})
	elif n >= 2:
		var idx: int = (n - 1) >> 1
		var low := sp.slice(0, idx)
		var high := sp.slice(idx + 1, n - 1)
		torso.append({"name": TORSO_SPINE, "kind": "spine", "bones": low, "tip": low[low.size() - 1], "translate": false})
		var chest_bones := [low[low.size() - 1]]      # one bone of the lower spine bends with the chest, so the bend is spread over more bones
		chest_bones.append_array(high)
		torso.append({"name": TORSO_CHEST, "kind": "chest", "bones": chest_bones, "tip": high[high.size() - 1], "translate": false})


# Adds every standard body joint of the skeleton (spine, neck, head, clavicles, arms, fingers, legs, toes) that body.json
# did not list, so all of them get FK controls.
func _add_missing_body_joints() -> void:
	var rx: RegEx = RegEx.new()
	rx.compile(BODY_JOINT_PATTERN)
	var have := {}
	for e in fk_list:
		have[e["joint"]] = true
	for b in range(skeleton.get_bone_count()):
		var n := skeleton.get_bone_name(b)
		if have.has(n) or (rx.search(n) == null and not Shapes.is_spine(n) and not Shapes.is_pec(n) and Shapes.twist_kind(n) == ""):
			continue
		fk_list.append({"joint": n, "bone": b, "translate": n == "root" or n == "pelvis" or Shapes.is_pec(n)})
	for e in fk_list:      # a pectoral listed by body.json can move too
		if Shapes.is_pec(e["joint"]):
			e["translate"] = true


func limb_keys() -> Array:
	var out := []
	for l in limbs:
		out.append(l["key"])
	return out


func _limb(key: String):
	for l in limbs:
		if l["key"] == key:
			return l
	return null


# ---------------------------------------------------------------- handles (children of this node)

func _handle(node_name: String) -> Spatial:
	var n: Node = get_node_or_null(node_name)
	return n as Spatial


func handles_missing() -> bool:
	for l in limbs:
		if _handle(l["target"]) == null or _handle(l["pole"]) == null:
			return true
	for c in torso:
		if _handle(c["name"]) == null:
			return true
	if not create_fk_handles:
		return false
	var cont := get_node_or_null(FK_CONTAINER)
	for e in fk_list:
		if cont == null or cont.get_node_or_null(FK_NODE_PREFIX + e["joint"]) == null:
			return true
	return false


func _rest_target_transform(l: Dictionary) -> Transform:
	var g := _rest_global(l["bones"][2])
	return Transform(g.basis.orthonormalized(), g.origin)


func _rest_pole_position(l: Dictionary) -> Vector3:
	var a := _rest_global(l["bones"][0]).origin
	var b := _rest_global(l["bones"][1]).origin
	var c := _rest_global(l["bones"][2]).origin
	return BodyIK.pole_position(a, b, c, l["bend_rest"])


func _set_handle_skel(h: Spatial, t: Transform) -> void:
	if h.is_inside_tree() and skeleton.is_inside_tree():
		h.global_transform = skeleton.global_transform * t
	else:
		h.transform = t


# Position3D draws a big axis cross in the editor ("markers"). Plain Spatial draws nothing, the shapes are the only visuals.
# Old scenes have Position3D handles: swap them in place, keeping name, transform, children and owner.
func _swap_marker(h: Node) -> Node:
	if not (h is Position3D):
		return h
	var par := h.get_parent()
	var idx := h.get_index()
	var own := h.owner
	var t: Transform = h.transform
	var nm := h.name
	var kids := h.get_children()
	par.remove_child(h)
	for k in kids:
		h.remove_child(k)
	h.free()
	var n := Spatial.new()
	n.name = nm
	par.add_child(n)
	par.move_child(n, idx)
	n.owner = own
	n.transform = t
	for k in kids:
		n.add_child(k)
	return n


func _strip_markers() -> void:
	for l in limbs:
		for nm in [l["target"], l["pole"]]:
			var h := _handle(nm)
			if h != null and h is Position3D:
				_swap_marker(h)
	var cont := get_node_or_null(FK_CONTAINER)
	if cont != null:
		for c in cont.get_children():
			if c is Position3D:
				_swap_marker(c)


# Creates the missing IK / pole handles at their rest positions. `root` becomes their owner (so they are saved).
func ensure_handles(root: Node) -> int:
	if skeleton == null:
		return 0
	var created := 0
	for l in limbs:
		for pair in [[l["target"], true], [l["pole"], false]]:
			if _handle(pair[0]) != null:
				continue
			var h := Spatial.new()
			h.name = pair[0]
			add_child(h)
			if root != null:
				h.owner = root
			if pair[1]:
				_set_handle_skel(h, _rest_target_transform(l))
			else:
				_set_handle_skel(h, Transform(Basis(), _rest_pole_position(l)))
			created += 1
	for c in torso:
		if _handle(c["name"]) != null:
			continue
		var th := Spatial.new()
		th.name = c["name"]
		add_child(th)
		if root != null:
			th.owner = root
		_tc_place(c)
		created += 1
	if create_fk_handles:
		ensure_fk_handles(root)
	else:
		remove_fk_handles()
	_ensure_shapes()
	_dirty = true
	return created


# One Position3D per FK joint under FK/. Rotate it with the normal gizmo (it is the fk/<joint> value); for root / pelvis
# the position is the translation too. Created at the joint, so the gizmo sits on the bone.
func ensure_fk_handles(root: Node) -> int:
	if skeleton == null:
		return 0
	var cont: Spatial = get_node_or_null(FK_CONTAINER) as Spatial
	if cont == null:
		cont = Spatial.new()
		cont.name = FK_CONTAINER
		cont.set_meta("fk_frame", 2)
		add_child(cont)
		if root != null:
			cont.owner = root
	var created := 0
	for e in fk_list:
		var nm: String = FK_NODE_PREFIX + e["joint"]
		if cont.get_node_or_null(nm) != null:
			continue
		var h := Spatial.new()
		h.name = nm
		cont.add_child(h)
		if root != null:
			h.owner = root
		h.transform = Transform(_fk_to_local(h, e["bone"], _fk_rot.get(e["joint"], Vector3.ZERO)) * BodyIK.scale_basis(_fk_scl.get(e["joint"], Vector3.ONE)), _skel_to_local(h, _rest_global(e["bone"]).origin))
		_note_handle_origin(e["joint"], h)
		created += 1
	_dirty = true
	return created


func _skel_to_local(h: Spatial, p: Vector3) -> Vector3:
	var w: Vector3 = p
	if skeleton.is_inside_tree():
		w = skeleton.global_transform.xform(p)
	var par: Spatial = h.get_parent() as Spatial
	if par != null and par.is_inside_tree():
		return par.global_transform.affine_inverse().xform(w)
	return w


func _local_to_skel(h: Spatial, o: Vector3) -> Vector3:
	var par: Spatial = h.get_parent() as Spatial
	var w: Vector3 = o
	if par != null and par.is_inside_tree():
		w = par.global_transform.xform(o)
	if skeleton.is_inside_tree():
		w = skeleton.global_transform.affine_inverse().xform(w)
	return w


func _fk_handle(joint: String) -> Spatial:
	var cont := get_node_or_null(FK_CONTAINER)
	if cont == null:
		return null
	return cont.get_node_or_null(FK_NODE_PREFIX + joint) as Spatial


func _basis_close(a: Basis, b: Basis) -> bool:
	return (a.x - b.x).length() + (a.y - b.y).length() + (a.z - b.z).length() < 1e-4


func _deg(r: Vector3) -> Vector3:
	return Vector3(rad2deg(r.x), rad2deg(r.y), rad2deg(r.z))


func _rad(d: Vector3) -> Vector3:
	return Vector3(deg2rad(d.x), deg2rad(d.y), deg2rad(d.z))


# FK handles: the handle's WORLD orientation is the bone's orientation (parent * rest * FK rotation), so the gizmo axes
# are the real axes the bone turns around. (Before, the handle held the raw bone-local Euler angles, whose axes are
# arbitrary bone axes: dragging the red ring turned the bone around some other axis, i.e. "the wrong way".)
func _fk_frame(bone: int) -> Basis:
	var parent := skeleton.get_bone_parent(bone)
	var pb := skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis()
	return (pb * skeleton.get_bone_rest(bone).basis).orthonormalized()


func _parent_basis_o(h: Spatial) -> Basis:
	var par: Spatial = h.get_parent() as Spatial
	if par != null and par.is_inside_tree():
		return par.global_transform.basis.orthonormalized()
	return Basis()


func _fk_to_local(h: Spatial, bone: int, euler_deg: Vector3) -> Basis:
	return _parent_basis_o(h).inverse() * _skel_basis_o() * _fk_frame(bone) * BodyIK.euler_xyz(_rad(euler_deg))


func _fk_from_local(h: Spatial, bone: int, b: Basis) -> Vector3:
	var e := (_fk_frame(bone).inverse() * _skel_basis_o().inverse() * _parent_basis_o(h) * b.orthonormalized()).orthonormalized()
	return _deg(BodyIK.basis_to_euler_xyz(e))


# Scenes saved with the old handle convention (handle basis = Euler angles): read the angles once, rewrite the handles.
func _migrate_fk_handles(cont: Node) -> void:
	for e in fk_list:
		var h: Spatial = _fk_handle(e["joint"])
		if h != null:
			var v := _deg(BodyIK.basis_to_euler_xyz(h.transform.basis.orthonormalized()))
			_fk_rot[e["joint"]] = v
			_h_rot[e["joint"]] = v
	cont.set_meta("fk_frame", 2)
	solve()
	sync_fk_handles_out()


# Handle -> fk values. A handle that was rotated / moved (gizmo, AnimationPlayer, scene load) wins over the stored value.
# Returns true when anything changed.
func sync_fk_handles_in() -> bool:
	var changed := false
	var fcont := get_node_or_null(FK_CONTAINER)
	if fcont != null and fcont.get_child_count() > 0 and not fcont.has_meta("fk_frame"):
		_migrate_fk_handles(fcont)
		return true
	for e in fk_list:
		var j: String = e["joint"]
		var h: Spatial = _fk_handle(j)
		if h == null:
			continue
		var hbs: Basis = h.transform.basis
		if not BodyIK.basis_usable(hbs):
			continue          # scaled flat / mirrored with the scale gizmo: wait for a sensible value
		var last: Vector3 = _h_rot.get(j, Vector3.ZERO)
		var hb := hbs.orthonormalized()
		if not _basis_close(hb, _fk_to_local(h, e["bone"], last)):
			var v := _fk_from_local(h, e["bone"], hb)
			_fk_rot[j] = v
			_h_rot[j] = v
			changed = true
		var hs := BodyIK.clamp_scale(BodyIK.basis_scale(hbs))
		if (hs - _h_scl.get(j, Vector3.ONE)).length() > 1e-4:
			_fk_scl[j] = hs
			_h_scl[j] = hs
			changed = true
		if e["translate"]:
			if Shapes.is_pec(j):
				if _follow_in(e, h):
					changed = true
				continue
			var base := _rest_global(e["bone"]).origin
			var o := _local_to_skel(h, h.transform.origin)
			var lp: Vector3 = _h_pos.get(j, Vector3.ZERO)
			if (o - (base + lp)).length() > 1e-5:
				_fk_pos[j] = o - base
				_h_pos[j] = o - base
				changed = true
	return changed


# Remember where a "follow" handle (pectorals) sits, so the next sync only sees what the user did to it.
func _note_handle_origin(j: String, h: Spatial) -> void:
	if Shapes.is_pec(j):
		_h_wo[j] = _local_to_skel(h, h.transform.origin)


# Where the bone sits when it has no translation of its own, i.e. where its (posed) parent carries it.
func _follow_base(bone: int) -> Vector3:
	var rest := skeleton.get_bone_rest(bone)
	var par := skeleton.get_bone_parent(bone)
	if par < 0:
		return rest.origin
	return skeleton.get_bone_global_pose(par).xform(rest.origin)


# Pectoral handle -> fkpos. The handle follows the bone (it sits on it wherever the torso is), so the translation is
# whatever the user moved it by since it was last written; a handle that comes out of a saved scene is compared with
# where the parent carries the bone.
func _follow_in(e: Dictionary, h: Spatial) -> bool:
	var j: String = e["joint"]
	var o := _local_to_skel(h, h.transform.origin)
	if not _h_wo.has(j):
		_h_wo[j] = o
		var d0 := o - _follow_base(e["bone"])
		if d0.length() > 1e-5:
			_fk_pos[j] = d0
			return true
		return false
	var dd: Vector3 = o - _h_wo[j]
	if dd.length() > 1e-5:
		_fk_pos[j] = _fk_pos.get(j, Vector3.ZERO) + dd
		_h_wo[j] = o
		return true
	return false


# fk values / solved pose -> handles (so they follow the inspector properties, keyframes, IK and the pelvis).
func sync_fk_handles_out() -> void:
	for e in fk_list:
		var j: String = e["joint"]
		var h: Spatial = _fk_handle(j)
		if h == null:
			continue
		var cur: Vector3 = _fk_rot.get(j, Vector3.ZERO)
		var scl: Vector3 = _fk_scl.get(j, Vector3.ONE)
		var b := _fk_to_local(h, e["bone"], cur) * BodyIK.scale_basis(scl)
		var p: Vector3
		if e["translate"] and not Shapes.is_pec(j):
			var d: Vector3 = _fk_pos.get(j, Vector3.ZERO)
			p = _rest_global(e["bone"]).origin + d
			_h_pos[j] = d
		else:
			p = skeleton.get_bone_global_pose(e["bone"]).origin
		_h_rot[j] = cur
		_h_scl[j] = scl
		var lo := _skel_to_local(h, p)
		if not _basis_close(h.transform.basis, b) or (h.transform.origin - lo).length() > 1e-6:
			h.transform = Transform(b, lo)
		_note_handle_origin(j, h)


func reset_handles() -> void:
	for l in limbs:
		var t := _handle(l["target"])
		var p := _handle(l["pole"])
		if t != null:
			_set_handle_skel(t, _rest_target_transform(l))
		if p != null:
			_set_handle_skel(p, Transform(Basis(), _rest_pole_position(l)))
	for c in torso:
		_tc_rot[c["name"]] = Basis()
		_tc_scl[c["name"]] = Vector3.ONE
		_tc_d[c["name"]] = Vector3.ZERO
	if skeleton != null and skeleton.is_inside_tree() and is_inside_tree():
		solve()
		sync_torso_out()
	_dirty = true


# ---------------------------------------------------------------- torso controls (pelvis / spine / chest)

func _skel_basis_o() -> Basis:
	return skeleton.global_transform.basis.orthonormalized() if skeleton != null and skeleton.is_inside_tree() else Basis()


func _rig_basis_o() -> Basis:
	return global_transform.basis.orthonormalized() if is_inside_tree() else Basis()


# rotation delta (skeleton space) <-> local basis of the handle node
func _tc_to_local(delta: Basis) -> Basis:
	return _rig_basis_o().inverse() * _skel_basis_o() * delta * _char_b


func _tc_from_local(b: Basis) -> Basis:
	return ((_skel_basis_o().inverse() * _rig_basis_o() * b.orthonormalized()) * _char_b.inverse()).orthonormalized()


# Writes the handle of one torso control from the current state: rotation = delta, position = where the tip bone is now.
func _tc_place(c: Dictionary) -> void:
	var h := _handle(c["name"])
	if h == null or skeleton == null:
		return
	var rot: Basis = _tc_rot.get(c["name"], Basis())
	var p: Vector3 = skeleton.get_bone_global_pose(c["tip"]).origin
	var t := Transform(_tc_to_local(rot) * BodyIK.scale_basis(_tc_scl.get(c["name"], Vector3.ONE)), _skel_to_local(h, p))
	if not _basis_close(h.transform.basis, t.basis) or (h.transform.origin - t.origin).length() > 1e-6:
		h.transform = t
	_tc_wo[c["name"]] = _local_to_skel(h, h.transform.origin)


# Handle -> state. A handle that was rotated / moved (gizmo, AnimationPlayer, scene load) wins over the stored value.
func sync_torso_in() -> bool:
	var changed := false
	for c in torso:
		var nm: String = c["name"]
		var h := _handle(nm)
		if h == null:
			continue
		var hbs: Basis = h.transform.basis
		if not BodyIK.basis_usable(hbs):
			continue          # scaled flat / mirrored with the scale gizmo: wait for a sensible value
		var nb := _tc_from_local(hbs)
		if not _basis_close(nb, _tc_rot.get(nm, Basis())):
			_tc_rot[nm] = nb
			changed = true
		var ns := BodyIK.clamp_scale(BodyIK.basis_scale(hbs))
		if (ns - _tc_scl.get(nm, Vector3.ONE)).length() > 1e-4:
			_tc_scl[nm] = ns
			changed = true
		if c["translate"]:
			var o := _local_to_skel(h, h.transform.origin)
			if not _tc_wo.has(nm):
				# freshly loaded scene: the saved handle position is base + delta, so recover the delta
				apply_fk()
				var base := skeleton.get_bone_global_pose(c["tip"]).origin
				if (o - base).length() > 1e-5:
					_tc_d[nm] = o - base
					changed = true
			elif (o - _tc_wo[nm]).length() > 1e-5:
				_tc_d[nm] = _tc_d.get(nm, Vector3.ZERO) + (o - _tc_wo[nm])
				changed = true
			_tc_wo[nm] = o
	return changed


# State / solved pose -> handles (they follow the bones when something else moves them).
func sync_torso_out() -> void:
	for c in torso:
		_tc_place(c)


# Called after apply_fk(): adds the torso rotations / the pelvis translation on top of the FK pose.
func apply_torso() -> void:
	for c in torso:
		var nm: String = c["name"]
		var rot: Basis = _tc_rot.get(nm, Basis())
		var sc: Vector3 = _tc_scl.get(nm, Vector3.ONE)
		var d: Vector3 = _tc_d.get(nm, Vector3.ZERO)
		var has_rot := not _basis_close(rot, Basis())
		var has_scl := not BodyIK.is_unit_scale(sc)
		if not has_rot and not has_scl and d.length_squared() == 0.0:
			continue
		var chain: Array = c["bones"]
		var di := Basis()
		if has_rot:
			di = Basis(Quat(Basis()).slerp(Quat(rot.orthonormalized()), 1.0 / chain.size()))
		# scale along the handle's axes (x = character right, y = up, z = forward), spread like the rotation: every bone
		# of the control takes the n-th root, so the product over the chain is the handle's scale
		var si := Basis()
		if has_scl:
			var k := 1.0 / chain.size()
			si = _char_b * BodyIK.scale_basis(Vector3(pow(sc.x, k), pow(sc.y, k), pow(sc.z, k))) * _char_b.inverse()
		for b in chain:
			var parent := skeleton.get_bone_parent(b)
			var pb := skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis()
			var rb := skeleton.get_bone_rest(b).basis
			var cb := (pb * rb).orthonormalized()
			var pose := skeleton.get_bone_pose(b)
			var nbas := pose.basis
			if has_rot or has_scl:
				nbas = cb.inverse() * di * si * cb * pose.basis
			var origin := pose.origin
			if c["translate"] and d.length_squared() > 0.0:
				origin += (pb * rb).inverse().xform(d)
			skeleton.set_bone_pose(b, Transform(nbas, origin))


# ---------------------------------------------------------------- control shapes + viewport picking

func _shapes_visible() -> bool:
	return show_shapes and (Engine.editor_hint or show_shapes_in_game)


# Shape meshes live under the IK handles (so they follow them); they are not owned by the scene, so they are never saved.
func _ensure_shapes() -> void:
	_strip_markers()
	if skeleton == null:
		return
	if _mat == null:
		_mat = Shapes.material()
	for l in limbs:
		var layer := _limb_layer(l)
		var col: Color = Shapes.layer_color(layer, l["side"])
		for pair in [[l["target"], true], [l["pole"], false]]:
			var h := _handle(pair[0])
			if h == null:
				continue
			var mi: MeshInstance = h.get_node_or_null("Shape") as MeshInstance
			if mi == null:
				mi = MeshInstance.new()
				mi.name = "Shape"
				h.add_child(mi)          # no owner on purpose
			var sz := 0.05 * shape_scale
			if pair[1]:
				mi.mesh = Shapes.hand(sz, col, line_width) if l["kind"] == "arm" else Shapes.foot(sz * 1.4, col, line_width)
			else:
				mi.mesh = Shapes.pole(sz * 0.7, col, line_width)
			mi.material_override = _mat
			mi.layers = Shapes.SHAPE_LAYER
			mi.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
			mi.visible = _shapes_visible() and is_layer_visible(layer)
	for c in torso:
		var th := _handle(c["name"])
		if th == null:
			continue
		var tmi: MeshInstance = th.get_node_or_null("Shape") as MeshInstance
		if tmi == null:
			tmi = MeshInstance.new()
			tmi.name = "Shape"
			th.add_child(tmi)
		var pts: PoolVector3Array
		var tcol: Color = Shapes.layer_color(_torso_layer(c), "c")
		if c["kind"] == "pelvis":
			pts = Shapes.pelvis_points(shape_scale)
		elif c["kind"] == "spine":
			pts = Shapes.torso_ring_points(0.15, shape_scale)
		else:
			pts = Shapes.torso_ring_points(0.18, shape_scale)
		_tc_pts[c["name"]] = pts
		tmi.mesh = Shapes.lines(pts, tcol, line_width * 1.3)
		tmi.material_override = _mat
		tmi.layers = Shapes.SHAPE_LAYER
		tmi.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
		tmi.visible = _shapes_visible() and is_layer_visible(_torso_layer(c))
	if _lines == null or not is_instance_valid(_lines):
		var old := get_node_or_null("_ControlLines")
		if old != null and not (old is MeshInstance):
			remove_child(old)            # leftover ImmediateGeometry of an older version
			old.queue_free()
			old = null
		_lines = old as MeshInstance
		if _lines == null:
			_lines = MeshInstance.new()
			_lines.name = "_ControlLines"
			add_child(_lines)            # no owner: rebuilt on load
	_lines.material_override = _mat
	_lines.layers = Shapes.SHAPE_LAYER
	_lines.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
	_lines.visible = _shapes_visible()
	_dirty = true


func _child_dir(bone: int) -> Vector3:
	# direction (skeleton space) from this bone to its first body child, or the bone's own up axis
	var g := skeleton.get_bone_global_pose(bone)
	for c in range(skeleton.get_bone_count()):
		if skeleton.get_bone_parent(c) == bone:
			var d := skeleton.get_bone_global_pose(c).origin - g.origin
			if d.length() > 1e-4:
				return d
	return g.basis.y


# Direction along the spine at this bone: towards the next spine / neck bone, else the bone's own axis.
func _spine_dir(bone: int) -> Vector3:
	var g := skeleton.get_bone_global_pose(bone)
	for c in range(skeleton.get_bone_count()):
		if skeleton.get_bone_parent(c) == bone:
			var n := skeleton.get_bone_name(c)
			if Shapes.is_spine(n) or n.begins_with("neck_"):
				var d := skeleton.get_bone_global_pose(c).origin - g.origin
				if d.length() > 1e-4:
					return d
	var up: Vector3 = _up_forward()[0]
	return up


# Redraws pole lines (pole -> elbow / knee, limb bones) and the FK rings. Vertices are in skeleton space.
# Lines are drawn as thin crossed quads (line_width metres), because plain GPU lines are always 1 px.
func _update_shapes() -> void:
	_ring_info.clear()
	if _lines == null or not is_instance_valid(_lines):
		return
	var vis := _shapes_visible()
	_lines.visible = vis
	for l in limbs:
		for n in [l["target"], l["pole"]]:
			var h := _handle(n)
			if h != null:
				var mi := h.get_node_or_null("Shape") as MeshInstance
				if mi != null:
					mi.visible = vis and is_layer_visible(_limb_layer(l))
	for c in torso:
		var th := _handle(c["name"])
		if th != null:
			var tmi := th.get_node_or_null("Shape") as MeshInstance
			if tmi != null:
				tmi.visible = vis and is_layer_visible(_torso_layer(c))
	if _lines.is_inside_tree() and skeleton.is_inside_tree():
		_lines.global_transform = skeleton.global_transform
	if _buf == null:
		_buf = LineBuf.new()
	_buf.clear()
	_lines.mesh = null
	if not vis:
		return
	var inv := skeleton.global_transform.affine_inverse() if skeleton.is_inside_tree() else Transform()
	var sc := skeleton.global_transform.basis.get_scale().x if skeleton.is_inside_tree() else 1.0
	var w := line_width / sc if sc > 1e-6 else line_width
	for l in limbs:
		var layer := _limb_layer(l)
		if not is_layer_visible(layer):
			continue
		var col: Color = Shapes.layer_color(layer, l["side"])
		var p0 := skeleton.get_bone_global_pose(l["bones"][0]).origin
		var p1 := skeleton.get_bone_global_pose(l["bones"][1]).origin
		var p2 := skeleton.get_bone_global_pose(l["bones"][2]).origin
		# limb sticks
		_emit(p0, p1, col, w, l["key"] + " upper")
		_emit(p1, p2, col, w, l["key"] + " lower")
		# pole line
		var ph := _handle(l["pole"])
		if ph != null and ph.is_inside_tree():
			_emit(p1, inv.xform(ph.global_transform.origin), Shapes.COL_POLE_LINE, w * 0.6, l["pole"] + " line")
		# line from the IK handle to the end joint (shows what the handle controls when the limb is blended / out of reach)
		var th := _handle(l["target"])
		if th != null and th.is_inside_tree():
			_emit(p2, inv.xform(th.global_transform.origin), Shapes.COL_POLE_LINE, w * 0.6, l["target"] + " line")
	if show_fk_rings:
		for e in fk_list:
			var jn: String = e["joint"]
			var layer := Shapes.joint_layer(jn)
			if not is_layer_visible(layer):
				continue
			if torso.size() > 0 and not show_torso_fk_rings and (jn == "pelvis" or Shapes.is_spine(jn)):
				continue          # the CTRL_pelvis / spine / chest handles replace these
			var b: int = e["bone"]
			var g := skeleton.get_bone_global_pose(b)
			var side := "c"
			if jn.ends_with("_l"):
				side = "l"
			elif jn.ends_with("_r"):
				side = "r"
			var col: Color = Shapes.layer_color(layer, side)
			if jn == "pelvis":
				# big box around the pelvis, axes follow the character (up / forward), not the bone
				var uf := _up_forward()
				var up: Vector3 = uf[0]
				var fwd: Vector3 = uf[1]
				var right := up.cross(fwd).normalized()
				var pts := Shapes.box_points(g.origin, right, up, fwd, 0.19 * shape_scale, 0.1 * shape_scale, 0.13 * shape_scale)
				Shapes.emit_thick_list(_buf, pts, col, w * 1.3)
				_ring_info.append({"joint": jn, "center": g.origin, "radius": 0.2 * shape_scale, "pts": pts})
				continue
			if Shapes.is_spine(jn):
				# big circle around the torso at this spine bone, normal along the spine
				var r2 := 0.16 * shape_scale
				var pts2 := Shapes.ring_points(g.origin, _spine_dir(b), r2, 32)
				Shapes.emit_thick_list(_buf, pts2, col, w * 1.3)
				_ring_info.append({"joint": jn, "center": g.origin, "radius": r2, "pts": pts2})
				continue
			var d := _child_dir(b)
			var r: float = clamp(d.length() * 0.3, 0.012, 0.07) * shape_scale
			Shapes.emit_thick_list(_buf, Shapes.ring_points(g.origin, d, r), col, w)
			_ring_info.append({"joint": jn, "center": g.origin, "radius": r})
	_finish_lines()


class LineBuf:
	extends Reference
	var verts := PoolVector3Array()
	var cols := PoolColorArray()
	var cur := Color(1, 1, 1)

	func clear() -> void:
		verts = PoolVector3Array()
		cols = PoolColorArray()

	func set_color(c: Color) -> void:
		cur = c

	func add_vertex(v: Vector3) -> void:
		verts.append(v)
		cols.append(cur)


# One thick line. A segment that is longer than 2 m (a handle that sits somewhere absurd, a broken bone pose) is not
# drawn: it would show up as a huge spike / flat shards in the viewport. It is reported once in the Output panel.
func _emit(a: Vector3, b: Vector3, col: Color, width: float, source: String) -> void:
	var sc := skeleton.global_transform.basis.get_scale().x if skeleton.is_inside_tree() else 1.0
	if a.distance_to(b) * sc > 2.0:
		if not _warned.has(source):
			_warned[source] = true
			print("MetaHumanBodyRig: skipped a %.1f m long line (%s): from skeleton-space %s to %s" % [a.distance_to(b) * sc, source, a, b])
		return
	Shapes.emit_thick(_buf, a, b, col, width)


func _finish_lines() -> void:
	if _buf.verts.size() == 0:
		_lines.mesh = null
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = _buf.verts
	arr[Mesh.ARRAY_COLOR] = _buf.cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_lines.mesh = m


# Closest control under a world space ray. Returns {} or {"node": Spatial} for an IK / pole handle,
# or {"joint": String} for an FK ring.
func pick(ray_from: Vector3, ray_dir: Vector3) -> Dictionary:
	if skeleton == null or not _shapes_visible():
		return {}
	var d := ray_dir.normalized()
	var best := {}
	var best_t := 1e20
	for l in limbs:
		if not is_layer_visible(_limb_layer(l)):
			continue
		for pair in [[l["target"], 0.06], [l["pole"], 0.045]]:
			var h := _handle(pair[0])
			if h == null or not h.is_inside_tree():
				continue
			var t := _ray_sphere(ray_from, d, h.global_transform.origin, pair[1] * shape_scale)
			if t >= 0.0 and t < best_t - 0.02:        # IK handles win ties against rings behind them
				best_t = t
				best = {"node": h}
	for tc in torso:
		if not is_layer_visible(_torso_layer(tc)):
			continue
		var th := _handle(tc["name"])
		if th == null or not th.is_inside_tree() or not _tc_pts.has(tc["name"]):
			continue
		var tt := _ray_shape(ray_from, d, _tc_pts[tc["name"]], 0.035 * shape_scale, th.global_transform)
		var tmargin := 0.12 if best.has("node") and not _is_torso_node(best["node"]) else 0.0
		if tt >= 0.0 and tt < best_t - tmargin:
			best_t = tt
			best = {"node": th}
	for ri in _ring_info:
		var c: Vector3 = skeleton.global_transform.xform(ri["center"])
		var t := -1.0
		if ri.has("pts"):
			t = _ray_shape(ray_from, d, ri["pts"], 0.035 * shape_scale)
		else:
			t = _ray_sphere(ray_from, d, c, ri["radius"] * 1.3)
		# an IK / pole handle wins against a ring that sits on it (the hand ring is inside the hand cube)
		var margin := 0.12 if best.has("node") else 0.0
		if t >= 0.0 and t < best_t - margin:
			best_t = t
			best = {"joint": ri["joint"]}
	return best


# Distance along the ray to a line shape (segment pairs in skeleton space), or -1 when the ray misses it by more than `tol`.
func _ray_shape(o: Vector3, d: Vector3, pts: PoolVector3Array, tol: float, xf = null) -> float:
	var best := -1.0
	var best_dist := tol
	var far := o + d * 100.0
	var i := 0
	var m: Transform = xf if xf != null else skeleton.global_transform
	while i + 1 < pts.size():
		var a: Vector3 = m.xform(pts[i])
		var b: Vector3 = m.xform(pts[i + 1])
		var cp := Geometry.get_closest_points_between_segments(o, far, a, b)
		var dist: float = cp[0].distance_to(cp[1])
		if dist < best_dist:
			best_dist = dist
			best = o.distance_to(cp[0])
		i += 2
	return best


func _is_torso_node(n) -> bool:
	for c in torso:
		if n != null and n.name == c["name"]:
			return true
	return false


static func _ray_sphere(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := o - c
	var b := oc.dot(d)
	var cc := oc.dot(oc) - r * r
	var disc := b * b - cc
	if disc < 0.0:
		return -1.0
	var t := -b - sqrt(disc)
	return t if t >= 0.0 else -1.0


# The rotate handle of one FK joint (created on demand, so no field of loose nodes is needed).
func fk_handle_for(joint: String, root: Node) -> Spatial:
	var h := _fk_handle(joint)
	if h != null:
		return h
	for e in fk_list:
		if e["joint"] == joint:
			var cont: Spatial = get_node_or_null(FK_CONTAINER) as Spatial
			if cont == null:
				cont = Spatial.new()
				cont.name = FK_CONTAINER
				cont.set_meta("fk_frame", 2)
				add_child(cont)
				if root != null:
					cont.owner = root
			var n := Spatial.new()
			n.name = FK_NODE_PREFIX + joint
			cont.add_child(n)
			if root != null:
				n.owner = root
			n.transform = Transform(_fk_to_local(n, e["bone"], _fk_rot.get(joint, Vector3.ZERO)) * BodyIK.scale_basis(_fk_scl.get(joint, Vector3.ONE)), _skel_to_local(n, skeleton.get_bone_global_pose(e["bone"]).origin))
			_h_rot[joint] = _fk_rot.get(joint, Vector3.ZERO)
			_h_scl[joint] = _fk_scl.get(joint, Vector3.ONE)
			_note_handle_origin(joint, n)
			_dirty = true
			return n
	return null


# ---------------------------------------------------------------- solving

func _process(_delta: float) -> void:
	if not enabled or skeleton == null or not is_instance_valid(skeleton) or not skeleton.is_inside_tree():
		return
	if sync_fk_handles_in():
		_dirty = true
	if sync_torso_in():
		_dirty = true
	var sig := _signature()
	if not _dirty and sig == _last_sig:
		if _links_changed():
			_sync_links()
		return
	_dirty = false
	_last_sig = sig
	solve()
	_sync_links()
	sync_fk_handles_out()
	sync_torso_out()
	_update_shapes()
	emit_signal("pose_changed")


func _signature() -> Array:
	var inv := skeleton.global_transform.affine_inverse()
	var s := []
	for l in limbs:
		s.append(_ik.get(l["key"], 0.0))
		var t := _handle(l["target"])
		var p := _handle(l["pole"])
		s.append(inv * t.global_transform if t != null and t.is_inside_tree() else Transform())
		s.append(inv.xform(p.global_transform.origin) if p != null and p.is_inside_tree() else Vector3.ZERO)
	return s


func apply_fk() -> void:
	for e in fk_list:
		var j: String = e["joint"]
		var rot: Vector3 = _fk_rot.get(j, Vector3.ZERO)
		var basis := BodyIK.euler_xyz(Vector3(deg2rad(rot.x), deg2rad(rot.y), deg2rad(rot.z)))
		var scl: Vector3 = _fk_scl.get(j, Vector3.ONE)
		if not BodyIK.is_unit_scale(scl):
			basis = basis * BodyIK.scale_basis(scl)
		var origin := Vector3.ZERO
		if e["translate"] and not Shapes.is_pec(j):      # the pectorals move after the torso and the IK (apply_follow_translation)
			var d: Vector3 = _fk_pos.get(j, Vector3.ZERO)
			if d.length_squared() > 0.0:
				var b: int = e["bone"]
				var parent := skeleton.get_bone_parent(b)
				var pb := Basis()
				if parent >= 0:
					pb = skeleton.get_bone_global_pose(parent).basis
				origin = (pb * skeleton.get_bone_rest(b).basis).inverse().xform(d)
		skeleton.set_bone_pose(e["bone"], Transform(basis, origin))


func solve() -> void:
	if skeleton == null:
		return
	apply_fk()
	apply_torso()
	var inv := skeleton.global_transform.affine_inverse()
	for l in limbs:
		var w := float(_ik.get(l["key"], l["default_ik"]))
		if w <= 0.0005:
			continue
		var th := _handle(l["target"])
		var ph := _handle(l["pole"])
		if th == null or ph == null or not th.is_inside_tree() or not ph.is_inside_tree():
			continue
		var res := _solve_limb(l, inv * th.global_transform, inv.xform(ph.global_transform.origin))
		var es := _end_scale(inv * th.global_transform)
		if not BodyIK.is_unit_scale(es):         # the scale of the hand / foot handle scales the end bone
			res[2] = Transform(res[2].basis * BodyIK.scale_basis(es), res[2].origin)
		for k in range(3):
			var bone: int = l["bones"][k]
			skeleton.set_bone_pose(bone, BodyIK.blend_pose(skeleton.get_bone_pose(bone), res[k], w))
	apply_follow_translation()
	if logic != null:
		logic.evaluate()      # corrective + twist joints follow the bones that were just posed


# Scale of an IK handle relative to the skeleton (the handles are created with the skeleton's own scale, so only the
# ratio counts). `t` is the handle's transform in skeleton space.
func _end_scale(t: Transform) -> Vector3:
	if not BodyIK.basis_usable(t.basis):
		return Vector3.ONE
	return BodyIK.clamp_scale(BodyIK.basis_scale(t.basis))


# The pectorals are moved after the torso and the IK have posed everything above them, so a move of their handle is
# exactly that move in skeleton space, wherever the torso is turned to.
func apply_follow_translation() -> void:
	for e in fk_list:
		if not e["translate"] or not Shapes.is_pec(e["joint"]):
			continue
		var d: Vector3 = _fk_pos.get(e["joint"], Vector3.ZERO)
		if d.length_squared() == 0.0:
			continue
		var b: int = e["bone"]
		var par := skeleton.get_bone_parent(b)
		var pb := skeleton.get_bone_global_pose(par).basis if par >= 0 else Basis()
		var pose := skeleton.get_bone_pose(b)
		skeleton.set_bone_pose(b, Transform(pose.basis, (pb * skeleton.get_bone_rest(b).basis).inverse().xform(d)))


func _solve_limb(l: Dictionary, target: Transform, pole: Vector3) -> Array:
	var parent: int = l["parent"]
	var pg := skeleton.get_bone_global_pose(parent) if parent >= 0 else Transform()
	return BodyIK.solve(pg, l["rest"], target, pole, l["bend_rest"], l["rest_parent_basis"])


# ---------------------------------------------------------------- FK <-> IK matching

# Puts the IK handle and the pole where the FK pose currently has the hand / foot and the elbow / knee.
func snap_ik_to_fk(key: String) -> bool:
	var l = _limb(key)
	if l == null or skeleton == null:
		return false
	var th := _handle(l["target"])
	var ph := _handle(l["pole"])
	if th == null or ph == null:
		return false
	apply_fk()
	var g0 := skeleton.get_bone_global_pose(l["bones"][0])
	var g1 := skeleton.get_bone_global_pose(l["bones"][1])
	var g2 := skeleton.get_bone_global_pose(l["bones"][2])
	var parent: int = l["parent"]
	var pg := skeleton.get_bone_global_pose(parent) if parent >= 0 else Transform()
	var rot_par: Basis = pg.basis.orthonormalized() * l["rest_parent_basis"].inverse()
	_set_handle_skel(th, Transform(g2.basis.orthonormalized() * BodyIK.scale_basis(_fk_scl.get(l["names"][2], Vector3.ONE)), g2.origin))
	_set_handle_skel(ph, Transform(Basis(), BodyIK.pole_position(g0.origin, g1.origin, g2.origin, rot_par.xform(l["bend_rest"]))))
	_dirty = true
	return true


# Copies the pose the IK handles currently produce into the FK properties of that limb, so switching to FK does not pop.
func snap_fk_to_ik(key: String) -> bool:
	var l = _limb(key)
	if l == null or skeleton == null:
		return false
	var th := _handle(l["target"])
	var ph := _handle(l["pole"])
	if th == null or ph == null:
		return false
	apply_fk()
	var inv := skeleton.global_transform.affine_inverse()
	var res := _solve_limb(l, inv * th.global_transform, inv.xform(ph.global_transform.origin))
	for k in range(3):
		var r := BodyIK.basis_to_euler_xyz(res[k].basis)
		_fk_rot[l["names"][k]] = Vector3(rad2deg(r.x), rad2deg(r.y), rad2deg(r.z))
	_fk_scl[l["names"][2]] = _end_scale(inv * th.global_transform)
	_dirty = true
	property_list_changed_notify()
	return true


func set_ik_weight(key: String, w: float) -> void:
	_ik[key] = clamp(w, 0.0, 1.0)
	_dirty = true


func get_ik_weight(key: String) -> float:
	return float(_ik.get(key, 0.0))


func reset_pose() -> void:
	_fk_rot.clear()
	_fk_pos.clear()
	_fk_scl.clear()
	for l in limbs:
		_ik[l["key"]] = l["default_ik"]
	reset_handles()
	if skeleton != null:
		for e in fk_list:
			skeleton.set_bone_pose(e["bone"], Transform())
	_dirty = true
	property_list_changed_notify()


func status_text() -> String:
	if error != "":
		return "Body rig: " + error
	if skeleton == null:
		return "Body rig: not bound"
	var s := "Body rig: %d FK joints, %d IK limbs, %d torso controls on %s" % [fk_list.size(), limbs.size(), torso.size(), skeleton.name]
	if handles_missing():
		s += " (IK handles missing: use 'Add / rebuild IK handles')"
	s += "\n" + (logic.status_text() if logic != null else "Body logic: off (set Body Logic Path to the body DNA's .rig.json to drive the corrective joints)")
	if link_head_skeleton:
		s += "\nHead link: " + (PoolStringArray(_link_names()).join(", ") if _links.size() > 0 else "no second skeleton found (head and body share one skeleton, or the head armature is missing)")
	return s


# ---------------------------------------------------------------- head <-> body link
# A GLB can hold the head (face armature) and the body as two Skeletons. Only the body skeleton is posed by this rig, so
# the head stayed behind when the body moved. Every other Skeleton that has a "head" bone and at least three body joints
# of this skeleton (root, pelvis, spine_xx, neck_xx, head, clavicles ...) is linked: after each solve its body joints are
# set so that they sit exactly where the same joints of the body skeleton are (world space). The face rig keeps driving
# the facial joints below the head; it never writes the linked body joints (see PROTECT_KEY).

var _links := []         # [{skel, pairs: [[face bone, body bone, depth], ...]}] sorted parents first
var _link_sig := []


func _set_link_head(v: bool) -> void:
	link_head_skeleton = v
	if is_inside_tree() and skeleton != null:
		_build_links()
		_register_protect()
		_dirty = true


func _is_linkable(n: String, rx: RegEx) -> bool:
	return rx.search(n) != null or Shapes.is_spine(n) or Shapes.is_pec(n) or Shapes.twist_kind(n) != ""


func _skel_bone_depth(s: Skeleton, b: int) -> int:
	var d := 0
	var cur := s.get_bone_parent(b)
	while cur >= 0 and d < 512:
		d += 1
		cur = s.get_bone_parent(cur)
	return d


func _rest_global_in(sk: Skeleton, bone: int) -> Transform:
	var t := Transform()
	var cur := bone
	var guard := 0
	while cur >= 0 and guard < 512:
		t = sk.get_bone_rest(cur) * t
		cur = sk.get_bone_parent(cur)
		guard += 1
	return t


func _cmp_depth(a, b) -> bool:
	return a[2] < b[2]


func _build_links() -> void:
	_unregister_links()
	_links.clear()
	_link_sig = []
	if skeleton == null or not link_head_skeleton:
		return
	var root: Node = owner if owner != null else get_parent()
	if root == null:
		return
	var cands := []
	_collect_skeletons(root, cands)
	var rx: RegEx = RegEx.new()
	rx.compile(BODY_JOINT_PATTERN)
	for s in cands:
		if s == skeleton or s.find_bone("head") < 0:
			continue
		var pairs := []
		for fb in range(s.get_bone_count()):
			var n: String = s.get_bone_name(fb)
			if not _is_linkable(n, rx):
				continue
			var bb := skeleton.find_bone(n)
			if bb >= 0:
				pairs.append([fb, bb, _skel_bone_depth(s, fb), _rest_global_in(skeleton, bb), _rest_global_in(s, fb)])
		if pairs.size() < 3:
			continue
		pairs.sort_custom(self, "_cmp_depth")
		_links.append({"skel": s, "pairs": pairs})


func _link_names() -> Array:
	var out := []
	for lk in _links:
		if is_instance_valid(lk["skel"]):
			out.append("%s (%d joints)" % [lk["skel"].name, lk["pairs"].size()])
	return out


# Tells the RigLogic binders which joints of a skeleton belong to the body rig (they would otherwise be reset to the
# neutral pose every time the face rig is applied).
func _register_protect() -> void:
	if skeleton == null:
		return
	var names := {}
	for e in fk_list:
		names[e["joint"]] = true
	Registry.DATA[PROTECT_KEY + str(skeleton.get_instance_id())] = [OS.get_ticks_usec(), names]
	for lk in _links:
		var d := {}
		for p in lk["pairs"]:
			d[lk["skel"].get_bone_name(p[0])] = true
		Registry.DATA[PROTECT_KEY + str(lk["skel"].get_instance_id())] = [OS.get_ticks_usec(), d]


func _unregister_links() -> void:
	for lk in _links:
		if is_instance_valid(lk["skel"]):
			var k: String = PROTECT_KEY + str(lk["skel"].get_instance_id())
			if Registry.DATA.has(k):
				Registry.DATA.erase(k)


func _exit_tree() -> void:
	_unregister_links()
	if skeleton != null and is_instance_valid(skeleton):
		var k: String = PROTECT_KEY + str(skeleton.get_instance_id())
		if Registry.DATA.has(k):
			Registry.DATA.erase(k)


# The editor keeps a scene alive when you switch to another scene tab: the nodes leave the tree (_exit_tree above) and
# come back later, but _ready only runs once. Without this the face rig no longer knew which joints the body rig owns
# and wrote the neutral pose over the neck / head / spine as soon as it touched them.
func _enter_tree() -> void:
	if skeleton != null and is_instance_valid(skeleton) and not spec.empty():
		_register_protect()
		_dirty = true
		_last_sig = []


# True when the body or a linked skeleton node was moved / scaled since the last sync.
func _links_changed() -> bool:
	if _links.empty():
		return false
	var sig := [skeleton.global_transform]
	for lk in _links:
		sig.append(lk["skel"].global_transform if is_instance_valid(lk["skel"]) and lk["skel"].is_inside_tree() else Transform())
	if sig == _link_sig:
		return false
	_link_sig = sig
	return true


func _sync_links() -> void:
	if _links.empty() or skeleton == null or not skeleton.is_inside_tree():
		return
	_link_sig = [skeleton.global_transform]
	for lk in _links:
		var s: Skeleton = lk["skel"]
		if not is_instance_valid(s) or not s.is_inside_tree():
			_link_sig.append(Transform())
			continue
		_link_sig.append(s.global_transform)
		# Every shared joint gets the same world-space movement away from its rest pose as the body joint (a rest offset
		# between the two armatures is kept, so nothing jumps when the link switches on).
		var bsx: Transform = skeleton.global_transform
		var fsx: Transform = s.global_transform
		var f_inv: Transform = fsx.affine_inverse()
		for p in lk["pairs"]:
			var fb: int = p[0]
			var body_cur: Transform = bsx * skeleton.get_bone_global_pose(p[1])
			var body_rest: Transform = bsx * p[3]
			var want: Transform = f_inv * (body_cur * body_rest.affine_inverse()) * (fsx * p[4])      # in the linked skeleton's space
			var par := s.get_bone_parent(fb)
			var pg := Transform()
			if par >= 0:
				pg = s.get_bone_global_pose(par)
			var pose: Transform = s.get_bone_rest(fb).affine_inverse() * pg.affine_inverse() * want
			var cur := s.get_bone_pose(fb)
			if not (cur.origin.is_equal_approx(pose.origin) and cur.basis.is_equal_approx(pose.basis)):
				s.set_bone_pose(fb, pose)


# ---------------------------------------------------------------- names in the 3D viewport

# [{text, pos (world space), col}] for every control that is drawn right now. The editor plugin writes them over the viewport.
func name_labels() -> Array:
	var out := []
	if skeleton == null or not is_instance_valid(skeleton) or not skeleton.is_inside_tree() or not show_names or not _shapes_visible():
		return out
	var sx := skeleton.global_transform
	for ri in _ring_info:
		var jn: String = ri["joint"]
		out.append({"text": jn, "pos": sx.xform(ri["center"]), "col": Shapes.layer_color(Shapes.joint_layer(jn), "c")})
	for l in limbs:
		var layer := _limb_layer(l)
		if not is_layer_visible(layer):
			continue
		for n in [l["target"], l["pole"]]:
			var h := _handle(n)
			if h != null and h.is_inside_tree():
				out.append({"text": n, "pos": h.global_transform.origin, "col": Shapes.layer_color(layer, "c")})
	for c in torso:
		if not is_layer_visible(_torso_layer(c)):
			continue
		var th := _handle(c["name"])
		if th != null and th.is_inside_tree():
			out.append({"text": c["name"], "pos": th.global_transform.origin, "col": Shapes.layer_color(_torso_layer(c), "c")})
	return out


# ---------------------------------------------------------------- animatable properties

# Joint names for the fk/, fkscale/ and fkpos/ properties: the FK list, plus any joint that has a stored value (so a value
# is never dropped from the scene file just because the spec was not loaded when the scene was saved).
func _prop_joints(store: Dictionary, translate_only: bool) -> Array:
	var names := []
	var seen := {}
	for e in (fk_list if fk_list.size() > 0 else spec.get("fk", [])):
		if translate_only and not e.get("translate", false):
			continue
		names.append(e["joint"])
		seen[e["joint"]] = true
	for j in store:
		if not seen.has(j):
			names.append(j)
	return names


# A value that differs from rest is STORED with the scene (and shown in the Inspector); a value at rest is editor-only.
func _usage_for(non_default: bool) -> int:
	return PROPERTY_USAGE_DEFAULT if non_default else PROPERTY_USAGE_EDITOR


func _get_property_list() -> Array:
	var out := [{"name": "hidden_layers", "type": TYPE_STRING_ARRAY, "usage": PROPERTY_USAGE_STORAGE}]
	if spec.empty():
		# spec not loaded (yet): keep whatever was loaded from the scene so a re-save does not lose it
		for j in _fk_rot:
			if _fk_rot[j] != Vector3.ZERO:
				out.append({"name": FK_PREFIX + j, "type": TYPE_VECTOR3, "usage": PROPERTY_USAGE_STORAGE})
		for j in _fk_scl:
			if not BodyIK.is_unit_scale(_fk_scl[j]):
				out.append({"name": FKSCALE_PREFIX + j, "type": TYPE_VECTOR3, "usage": PROPERTY_USAGE_STORAGE})
		for j in _fk_pos:
			if _fk_pos[j] != Vector3.ZERO:
				out.append({"name": FKPOS_PREFIX + j, "type": TYPE_VECTOR3, "usage": PROPERTY_USAGE_STORAGE})
		return out
	out.append({"name": "Layers (tick = visible)", "type": TYPE_NIL, "hint_string": LAYER_PREFIX, "usage": PROPERTY_USAGE_GROUP})
	for ln in layer_names():
		out.append({"name": LAYER_PREFIX + ln, "type": TYPE_BOOL, "usage": PROPERTY_USAGE_EDITOR})
	out.append({"name": "IK / FK blend (0 = FK, 1 = IK)", "type": TYPE_NIL, "hint_string": IK_PREFIX, "usage": PROPERTY_USAGE_GROUP})
	for l in spec.get("limbs", []):
		out.append({
			"name": IK_PREFIX + l["key"], "type": TYPE_REAL,
			"hint": PROPERTY_HINT_RANGE, "hint_string": "0,1,0.01",
			"usage": PROPERTY_USAGE_DEFAULT,
		})
	out.append({"name": "FK controls (degrees)", "type": TYPE_NIL, "hint_string": FK_PREFIX, "usage": PROPERTY_USAGE_GROUP})
	for j in _prop_joints(_fk_rot, false):
		out.append({"name": FK_PREFIX + j, "type": TYPE_VECTOR3, "usage": _usage_for(_fk_rot.get(j, Vector3.ZERO) != Vector3.ZERO)})
	out.append({"name": "FK scale (1 = rest)", "type": TYPE_NIL, "hint_string": FKSCALE_PREFIX, "usage": PROPERTY_USAGE_GROUP})
	for j in _prop_joints(_fk_scl, false):
		out.append({"name": FKSCALE_PREFIX + j, "type": TYPE_VECTOR3, "usage": _usage_for(not BodyIK.is_unit_scale(_fk_scl.get(j, Vector3.ONE)))})
	out.append({"name": "Translation: root, pelvis, pectorals (skeleton axes)", "type": TYPE_NIL, "hint_string": FKPOS_PREFIX, "usage": PROPERTY_USAGE_GROUP})
	for j in _prop_joints(_fk_pos, true):
		out.append({"name": FKPOS_PREFIX + j, "type": TYPE_VECTOR3, "usage": _usage_for(_fk_pos.get(j, Vector3.ZERO) != Vector3.ZERO)})
	return out


func _get(property):
	if not (property is String):
		return null
	if property.begins_with(LAYER_PREFIX):
		return is_layer_visible(property.substr(LAYER_PREFIX.length()))
	if property.begins_with(IK_PREFIX):
		var k: String = property.substr(IK_PREFIX.length())
		return _ik.get(k, 0.0) if _ik.has(k) else null
	if property.begins_with(FKSCALE_PREFIX):
		return _fk_scl.get(property.substr(FKSCALE_PREFIX.length()), Vector3.ONE)
	if property.begins_with(FKPOS_PREFIX):
		return _fk_pos.get(property.substr(FKPOS_PREFIX.length()), Vector3.ZERO)
	if property.begins_with(FK_PREFIX):
		return _fk_rot.get(property.substr(FK_PREFIX.length()), Vector3.ZERO)
	return null


func _set(property, value) -> bool:
	if not (property is String):
		return false
	if property.begins_with(LAYER_PREFIX):
		set_layer_visible(property.substr(LAYER_PREFIX.length()), bool(value))
		return true
	if property.begins_with(IK_PREFIX):
		_ik[property.substr(IK_PREFIX.length())] = clamp(float(value), 0.0, 1.0)
	elif property.begins_with(FKSCALE_PREFIX):
		_fk_scl[property.substr(FKSCALE_PREFIX.length())] = BodyIK.clamp_scale(value)
	elif property.begins_with(FKPOS_PREFIX):
		_fk_pos[property.substr(FKPOS_PREFIX.length())] = value
	elif property.begins_with(FK_PREFIX):
		_fk_rot[property.substr(FK_PREFIX.length())] = value
	else:
		return false
	_dirty = true
	return true
