tool
extends Reference
# Body RigLogic: the Godot counterpart of the "Body" checkbox under Rig Logic Linked Data in the Blender add-on.
#
#   body joint poses (FK / IK / torso, already solved by MetaHumanBodyRig)
#     -> DNA driver inputs (joint rotation in DNA axes, degrees)
#     -> RigLogic (rig_logic.gd, the same evaluator the face board uses)
#     -> corrective / twist joint deltas -> Skeleton.set_bone_pose()
#
# Needs a body rig file exported like the head one:  <name>.rig.json + <name>.rig.bin  (see body_rig.gd: Body Logic Path).
# Main body joints (spine, thigh, calf, upperarm ...) stay owned by the body rig; only the extra joints are driven here:
#   * corrective joints (names with "cor")  -> pose = RigLogic output
#   * twist joints (upperarm_twist_01_l ...) -> pose = their FK pose * RigLogic output, so the FK twist controls still work

const RigLogic = preload("rig_logic.gd")
const Binder = preload("rig_binder.gd")
const BodyIK = preload("body_ik.gd")
const Shapes = preload("control_shapes.gd")

const MAIN_JOINTS = "^(root|pelvis|spine_\\d+|neck_\\d+|head|clavicle_[lr]|upperarm_[lr]|lowerarm_[lr]|hand_[lr]|(thumb|index|middle|ring|pinky)_\\d+_[lr]|thigh_[lr]|calf_[lr]|foot_[lr]|ball_[lr])$"

var rig = RigLogic.new()
var binder = Binder.new()
var skeleton: Skeleton = null
var loaded := false
var error := ""

var _in_gui := PoolIntArray()      # RigLogic gui index of each mapped input
var _in_bone := PoolIntArray()     # skeleton bone the input reads
var _in_attr := PoolIntArray()     # 0..2 rotate xyz, 3..5 translate xyz
var _out_joints := []              # RigLogic joint indices that are driven here
var _out_compose := PoolByteArray()  # 1 = twist joint (compose with its FK pose)
var unmapped := []                 # gui names that could not be mapped to a bone / attribute
var mapped_inputs := 0
var driven_joints := 0

const ATTRS = {
	"rx": 0, "ry": 1, "rz": 2, "tx": 3, "ty": 4, "tz": 5,
	"rotatex": 0, "rotatey": 1, "rotatez": 2, "translatex": 3, "translatey": 4, "translatez": 5,
}


func setup(json_path: String, p_skeleton: Skeleton, scene_root: Node) -> bool:
	loaded = false
	error = ""
	skeleton = p_skeleton
	if skeleton == null:
		error = "no skeleton"
		return false
	if not rig.load_files(json_path):
		error = rig.error
		return false
	binder.bind(rig, skeleton, scene_root)
	_map_inputs()
	_map_outputs()
	if mapped_inputs == 0:
		error = "none of the %d body rig inputs could be mapped to a bone (first: %s)" % [rig.gui_names.size(), str(unmapped.slice(0, 4))]
		return false
	loaded = true
	return true


# Input names look like "<joint>.<attr>" (or <joint>_<attr>), e.g. calf_l.rx.
func _map_inputs() -> void:
	_in_gui = PoolIntArray()
	_in_bone = PoolIntArray()
	_in_attr = PoolIntArray()
	unmapped = []
	var rx := RegEx.new()
	rx.compile("^(.+?)[._]([A-Za-z]+)$")
	for gi in range(rig.gui_names.size()):
		var n: String = rig.gui_names[gi]
		var ok := false
		var m := rx.search(n)
		if m != null:
			var attr: String = m.get_string(2).to_lower()
			var bone := skeleton.find_bone(m.get_string(1))
			if bone < 0 and "." in m.get_string(1):
				bone = skeleton.find_bone(m.get_string(1).get_slice(".", 1))
			if bone >= 0 and ATTRS.has(attr):
				_in_gui.append(gi)
				_in_bone.append(bone)
				_in_attr.append(ATTRS[attr])
				ok = true
		if not ok:
			unmapped.append(n)
	mapped_inputs = _in_gui.size()


func _map_outputs() -> void:
	_out_joints = []
	_out_compose = PoolByteArray()
	var rx := RegEx.new()
	rx.compile(MAIN_JOINTS)
	for j in range(rig.joint_names.size()):
		if rig.joint_driven[j] != 1 or binder.bone_for_joint[j] < 0:
			continue
		var n: String = rig.joint_names[j]
		var tw: bool = Shapes.twist_kind(n) != ""
		if not tw and (rx.search(n) != null or Shapes.is_spine(n) or Shapes.is_pec(n)):
			continue            # owned by the FK / IK body rig
		_out_joints.append(j)
		_out_compose.append(1 if tw else 0)
	driven_joints = _out_joints.size()


# Read the current bone poses and push them into RigLogic as inputs (DNA axes, degrees).
func _read_inputs() -> void:
	var g_t: Basis = binder._gt
	var g: Basis = binder._g
	var scale: float = max(binder.translation_scale, 1e-9)
	var cache := {}
	for k in range(_in_gui.size()):
		var bone: int = _in_bone[k]
		if not cache.has(bone):
			var pose: Transform = skeleton.get_bone_pose(bone)
			var r_dna := g_t * pose.basis.orthonormalized() * g if not binder._g_identity else pose.basis.orthonormalized()
			var e := BodyIK.basis_to_euler_xyz(r_dna)
			if not rig.rotation_radians:
				e = Vector3(rad2deg(e.x), rad2deg(e.y), rad2deg(e.z))
			var q: Basis = binder._qinv[_joint_of_bone(bone)]
			var t_loc: Vector3 = q.inverse().xform(pose.origin) / scale
			var t_dna := t_loc if binder._g_identity else g_t.xform(t_loc)
			cache[bone] = [e, t_dna]
		var c: Array = cache[bone]
		var a: int = _in_attr[k]
		var v: float = c[0][a] if a < 3 else c[1][a - 3]
		rig.set_gui_value(_in_gui[k], v)


var _joint_of := {}

func _joint_of_bone(bone: int) -> int:
	if _joint_of.empty():
		for j in range(binder.bone_for_joint.size()):
			if binder.bone_for_joint[j] >= 0:
				_joint_of[binder.bone_for_joint[j]] = j
	return _joint_of.get(bone, 0)


# Call after the body rig has solved FK / IK / torso for this frame.
func evaluate() -> void:
	if not loaded or skeleton == null:
		return
	_read_inputs()
	var o: PoolRealArray = rig.out_attr
	for k in range(_out_joints.size()):
		var j: int = _out_joints[k]
		var b: int = binder.bone_for_joint[j]
		var base := j * 9
		var dt := Vector3(o[base], o[base + 1], o[base + 2])
		var dr := Vector3(binder._to_rad(o[base + 3]), binder._to_rad(o[base + 4]), binder._to_rad(o[base + 5]))
		var ds := Vector3(o[base + 6], o[base + 7], o[base + 8])
		var s := BodyIK.scale_basis(Vector3(1.0 + ds.x, 1.0 + ds.y, 1.0 + ds.z))
		var basis: Basis = binder._conj(Binder.euler_xyz(dr) * s)
		var origin: Vector3 = binder._qinv[j].xform((dt if binder._g_identity else binder._g.xform(dt)) * binder.translation_scale)
		if _out_compose[k] == 1:
			var fk := skeleton.get_bone_pose(b)
			skeleton.set_bone_pose(b, Transform(fk.basis * basis, fk.origin + fk.basis.xform(origin)))
		else:
			skeleton.set_bone_pose(b, Transform(basis, origin))


func status_text() -> String:
	if not loaded:
		return "Body logic: off" + ((" (" + error + ")") if error != "" else "")
	var s := "Body logic: %d inputs -> %d corrective / twist joints" % [mapped_inputs, driven_joints]
	if not unmapped.empty():
		s += " | %d inputs unmapped (e.g. %s)" % [unmapped.size(), str(unmapped.slice(0, 2))]
	return s
