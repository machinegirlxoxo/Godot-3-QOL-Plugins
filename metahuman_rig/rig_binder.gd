tool
extends Reference
# Applies RigLogic outputs to a Skeleton (joint deltas) and MeshInstances (blend shapes).
#
# DNA joint local transform (Maya convention) is   T(t + dt) * JO * R(dr) * S
# The skeleton rest pose is                         T(t)      * JO
# so the Godot bone pose (applied after rest) is    T(JO^-1 * dt) * R(dr) * S
# A constant axis change G between DNA space and the GLB's bone space is detected
# automatically and applied as a similarity transform.

const Registry = preload("body_registry.gd")

var rig
var skeleton: Skeleton
var bone_for_joint := PoolIntArray()
var _qinv := []
var _g := Basis()
var _gt := Basis()
var _g_identity := true
var translation_scale := 0.01
var calibration_error_deg := 0.0
var matched_joints := 0
var matched_channels := 0
var _prot_version := -1                    # joints owned by the body rig (MetaHumanBodyRig registers them in Engine meta)
var _prot := PoolByteArray()
var _channel_targets := {}  # channel index -> Array of [MeshInstance, property path]


func bind(p_rig, p_skeleton: Skeleton, scene_root: Node) -> void:
	rig = p_rig
	skeleton = p_skeleton
	bone_for_joint = PoolIntArray()
	bone_for_joint.resize(rig.joint_names.size())
	matched_joints = 0
	for j in range(rig.joint_names.size()):
		var b := skeleton.find_bone(rig.joint_names[j])
		bone_for_joint[j] = b
		if b >= 0:
			matched_joints += 1
	_calibrate()
	_qinv.clear()
	for j in range(rig.joint_names.size()):
		var b: int = bone_for_joint[j]
		if b >= 0:
			_qinv.append(skeleton.get_bone_rest(b).basis.orthonormalized().inverse())
		else:
			_qinv.append(Basis())
	_bind_meshes(scene_root)


func _to_rad(v: float) -> float:
	return v if rig.rotation_radians else deg2rad(v)


static func euler_xyz(r: Vector3) -> Basis:
	# Blender / Maya "XYZ": R = Rz * Ry * Rx
	return Basis(Vector3(0, 0, 1), r.z) * Basis(Vector3(0, 1, 0), r.y) * Basis(Vector3(1, 0, 0), r.x)


func _dna_local_basis(j: int) -> Basis:
	var r := Vector3(rig.neutral_r[j * 3], rig.neutral_r[j * 3 + 1], rig.neutral_r[j * 3 + 2])
	return euler_xyz(Vector3(_to_rad(r.x), _to_rad(r.y), _to_rad(r.z)))


func _dna_global_basis(j: int) -> Basis:
	var chain := []
	var cur := j
	var guard := 0
	while guard < 512:
		chain.push_front(cur)
		var p: int = rig.joint_parents[cur]
		if p == cur or p < 0:
			break
		cur = p
		guard += 1
	var b := Basis()
	for k in chain:
		b = b * _dna_local_basis(k)
	return b


func _godot_global_rest_basis(bone: int) -> Basis:
	var b := Basis()
	var cur := bone
	while cur >= 0:
		b = skeleton.get_bone_rest(cur).basis.orthonormalized() * b
		cur = skeleton.get_bone_parent(cur)
	return b


func _snap(b: Basis) -> Basis:
	var r := Basis()
	for i in range(3):
		var row := b[i]
		r[i] = Vector3(round(row.x), round(row.y), round(row.z))
	return r


func _calibrate() -> void:
	_g = Basis()
	_g_identity = true
	translation_scale = 0.01
	calibration_error_deg = 0.0
	var present := []
	for j in range(bone_for_joint.size()):
		if bone_for_joint[j] >= 0 and rig.joint_parents[j] != j:
			present.append(j)
	if present.empty():
		return
	# axis change G from one joint in the middle of the hierarchy
	var probe: int = present[present.size() / 2]
	# GLB bone axes = DNA axes * K (constant), so G = K^-1 = O_godot^-1 * O_dna
	var guess := _snap(_godot_global_rest_basis(bone_for_joint[probe]).inverse() * _dna_global_basis(probe))
	if abs(guess.determinant() - 1.0) < 0.01:
		_g = guess
	_gt = _g.transposed()
	_g_identity = _g.is_equal_approx(Basis())
	# unit scale from the joint with the largest neutral translation
	var best := 0.0
	for j in present:
		var t := Vector3(rig.neutral_t[j * 3], rig.neutral_t[j * 3 + 1], rig.neutral_t[j * 3 + 2])
		if t.length() > best:
			best = t.length()
			var o := skeleton.get_bone_rest(bone_for_joint[j]).origin
			if o.length() > 1e-9:
				translation_scale = o.length() / t.length()
	# validate rest rotations on a sample of joints
	var worst := 0.0
	var step: int = max(1, present.size() / 40)
	for k in range(0, present.size(), step):
		var j: int = present[k]
		var expected := _conj(_dna_local_basis(j))
		var actual := skeleton.get_bone_rest(bone_for_joint[j]).basis.orthonormalized()
		var diff := expected.inverse() * actual
		var ang := acos(clamp((diff.x.x + diff.y.y + diff.z.z - 1.0) * 0.5, -1.0, 1.0))
		worst = max(worst, rad2deg(ang))
	calibration_error_deg = worst


func _conj(m: Basis) -> Basis:
	return m if _g_identity else _g * m * _gt


func _bind_meshes(root: Node) -> void:
	_channel_targets.clear()
	matched_channels = 0
	var lookup := {}
	for c in range(rig.bs_names.size()):
		lookup[rig.bs_names[c]] = c
	_scan_meshes(root, lookup)


func _scan_meshes(node: Node, lookup: Dictionary) -> void:
	if node is MeshInstance and node.mesh is ArrayMesh:   # QuadMesh etc. (the face board) have no blend shapes
		var mesh: Mesh = node.mesh
		for k in range(mesh.get_blend_shape_count()):
			var bname: String = mesh.get_blend_shape_name(k)
			var ch := -1
			if lookup.has(bname):
				ch = lookup[bname]
			else:
				for key in lookup:
					if key.ends_with("__" + bname) or bname.ends_with("__" + key):
						ch = lookup[key]
						break
			if ch >= 0:
				if not _channel_targets.has(ch):
					_channel_targets[ch] = []
				_channel_targets[ch].append([node, "blend_shapes/" + bname])
				matched_channels += 1
	for child in node.get_children():
		_scan_meshes(child, lookup)


func _refresh_protect() -> void:
	if rig == null or skeleton == null:
		return
	var key := "mh_body_joints_" + str(skeleton.get_instance_id())
	var m = Registry.DATA[key] if Registry.DATA.has(key) else null
	var ver := -1 if m == null else int(m[0])
	if ver == _prot_version:
		return
	_prot_version = ver
	_prot = PoolByteArray()
	_prot.resize(rig.joint_names.size())
	for j in range(_prot.size()):
		_prot[j] = 0
	if m != null:
		for j in range(_prot.size()):
			if m[1].has(rig.joint_names[j]):
				_prot[j] = 1


func apply(joints: Array, channels: Array) -> void:
	_refresh_protect()
	for j in joints:
		_apply_joint(j)
	for c in channels:
		if _channel_targets.has(c):
			for t in _channel_targets[c]:
				if is_instance_valid(t[0]):
					t[0].set(t[1], rig.bs_values[c])


func apply_all() -> void:
	var js := []
	for j in range(rig.joint_names.size()):
		js.append(j)
	apply(js, range(rig.bs_names.size()))


func _apply_joint(j: int) -> void:
	var b: int = bone_for_joint[j]
	if b < 0:
		return
	if j < _prot.size() and _prot[j] == 1:      # a body control (FK / IK / head link) owns this joint
		return
	var o: PoolRealArray = rig.out_attr
	var base := j * 9
	var dt := Vector3(o[base], o[base + 1], o[base + 2])
	var dr := Vector3(_to_rad(o[base + 3]), _to_rad(o[base + 4]), _to_rad(o[base + 5]))
	var ds := Vector3(o[base + 6], o[base + 7], o[base + 8])
	var rot := euler_xyz(dr)
	var s := Basis(Vector3(1.0 + ds.x, 0, 0), Vector3(0, 1.0 + ds.y, 0), Vector3(0, 0, 1.0 + ds.z))
	var basis := _conj(rot * s)
	var origin: Vector3 = _qinv[j].xform((dt if _g_identity else _g.xform(dt)) * translation_scale)
	skeleton.set_bone_pose(b, Transform(basis, origin))


func status_text() -> String:
	var s := "%d/%d joints, %d blend shapes matched" % [matched_joints, rig.joint_names.size(), matched_channels]
	s += " | axis %s | rest-frame error %.2f°" % ["identity" if _g_identity else "remapped", calibration_error_deg]
	return s
