tool
extends Reference
# Analytic two-bone IK with a pole target, written for the MetaHuman body skeleton.
#
# Why not SkeletonIK?  The DNA body bones are "stubs" in DNA orientation (they do not point at their child), and
# SkeletonIK (FABRIK) has no pole-roll control and fights with set_bone_pose().  This solver works purely with joint
# positions and rigid rotation deltas, so it does not care how the bones are oriented, it has a real pole target and
# it writes ordinary bone poses (relative to the rest pose), exactly like the rest of the plugin.
#
# All transforms are in SKELETON space.  "rest" are Skeleton.get_bone_rest() transforms (local, parent relative).


# Shortest rotation that turns direction `from` into direction `to`.
static func arc(from: Vector3, to: Vector3) -> Basis:
	if from.length() < 1e-9 or to.length() < 1e-9:
		return Basis()
	var a := from.normalized()
	var b := to.normalized()
	var d := a.dot(b)
	if d > 0.999999:
		return Basis()
	if d < -0.999999:
		var axis := a.cross(Vector3(0, 1, 0))
		if axis.length() < 0.001:
			axis = a.cross(Vector3(1, 0, 0))
		return Basis(axis.normalized(), PI)
	return Basis(a.cross(b).normalized(), acos(clamp(d, -1.0, 1.0)))


# Right handed orthonormal frame with x = u, y = n (n must be perpendicular to u).
static func frame(u: Vector3, n: Vector3) -> Basis:
	return Basis(u, n, u.cross(n))


# Remove the part of v that is parallel to the unit vector u.
static func perp(v: Vector3, u: Vector3) -> Vector3:
	return v - u * v.dot(u)


# "XYZ" euler (R = Rz * Ry * Rx, same convention as RigLogic / the Bones tab) <-> basis.
static func euler_xyz(r: Vector3) -> Basis:
	return Basis(Vector3(0, 0, 1), r.z) * Basis(Vector3(0, 1, 0), r.y) * Basis(Vector3(1, 0, 0), r.x)


static func basis_to_euler_xyz(b: Basis) -> Vector3:
	# NOTE: in GDScript b.x / b.y / b.z are the basis AXES (columns), so element R[row][col] is b.<col>.<row>
	b = b.orthonormalized()
	var sy: float = clamp(-b.x.z, -1.0, 1.0)
	var ry := asin(sy)
	var rx := 0.0
	var rz := 0.0
	if abs(sy) < 0.999999:
		rx = atan2(b.y.z, b.z.z)
		rz = atan2(b.x.y, b.x.x)
	else:   # gimbal lock
		rz = atan2(-b.y.x, b.y.y)
	return Vector3(rx, ry, rz)


# Local scale as a matrix. Written out as a diagonal matrix on purpose: Basis.scaled() multiplies from the OUTSIDE
# (diag * basis) in Godot 3, a bone pose needs the scale INSIDE (rotation * diag).
static func scale_basis(s: Vector3) -> Basis:
	return Basis(Vector3(s.x, 0, 0), Vector3(0, s.y, 0), Vector3(0, 0, s.z))


# Scale of a basis that is rotation * diag(scale): the length of its three axes.
static func basis_scale(b: Basis) -> Vector3:
	return Vector3(b.x.length(), b.y.length(), b.z.length())


# True when a basis can be split into rotation and scale (not flat, not mirrored).
static func basis_usable(b: Basis) -> bool:
	return b.determinant() > 1e-12


# Keeps a scale away from 0 (a flat bone would make the whole skeleton below it collapse).
static func clamp_scale(s: Vector3) -> Vector3:
	return Vector3(clamp(s.x, 0.001, 1000.0), clamp(s.y, 0.001, 1000.0), clamp(s.z, 0.001, 1000.0))


static func is_unit_scale(s: Vector3) -> bool:
	return abs(s.x - 1.0) < 1e-4 and abs(s.y - 1.0) < 1e-4 and abs(s.z - 1.0) < 1e-4


# Where a pole target should sit for a limb in a given pose: mid joint pushed away from the start-end line.
static func pole_position(start: Vector3, mid: Vector3, end: Vector3, fallback_dir: Vector3) -> Vector3:
	var limb := end - start
	var length: float = max(limb.length(), 1e-6)
	var dir := limb / length
	var off := perp(mid - start, dir)
	if off.length() < length * 0.01:
		off = perp(fallback_dir, dir)
	if off.length() < 1e-6:
		off = Vector3(0, 0, 1)
	return mid + off.normalized() * length * 0.6


# Solve one two-bone chain.
#   pg          global transform of the chain's parent bone in the CURRENT pose (identity when the chain has no parent)
#   rest        [upper, lower, end] local rest transforms
#   target      wanted global transform of the end bone (origin = where the end joint goes, basis = its orientation)
#   pole        wanted global position of the pole (the knee / elbow is pushed towards it)
#   bend_rest   unit vector (rest skeleton space, perpendicular to the limb) the joint bends towards in the rest pose
#   rest_parent_basis  global REST basis of the chain's parent bone
#   stretch     0 = never stretch (target is clamped to the reach), 1 = chain scales... (not used, reserved)
# Returns [pose_upper, pose_lower, pose_end] (bone poses, i.e. relative to rest, as for Skeleton.set_bone_pose)
# and nothing else changes.  Also returns the solved global positions in `out_info` (mid, end, reached).
static func solve(pg: Transform, rest: Array, target: Transform, pole: Vector3, bend_rest: Vector3, rest_parent_basis: Basis, out_info: Dictionary = {}) -> Array:
	var gu: Transform = pg * rest[0]
	var gl: Transform = gu * rest[1]
	var ge: Transform = gl * rest[2]
	var a: Vector3 = gu.origin
	var b0: Vector3 = gl.origin
	var c0: Vector3 = ge.origin
	var l1 := (b0 - a).length()
	var l2 := (c0 - b0).length()
	if l1 < 1e-7 or l2 < 1e-7 or (c0 - a).length() < 1e-7:
		return [Transform(), Transform(), Transform()]

	var to_t: Vector3 = target.origin - a
	var dist := to_t.length()
	var u0 := (c0 - a).normalized()
	var u: Vector3 = u0 if dist < 1e-7 else to_t / dist
	var reach := l1 + l2
	var lo: float = max(abs(l1 - l2), reach * 0.0001)
	var hi: float = reach
	var d: float = clamp(dist, lo, hi)

	# bend direction of the reference chain (follows the posed parent), and of the wanted solution (from the pole)
	var rot_par: Basis = pg.basis.orthonormalized() * rest_parent_basis.orthonormalized().inverse()
	var n0 := perp(rot_par.xform(bend_rest), u0)
	if n0.length() < 1e-6:
		n0 = perp(Vector3(0, 0, 1), u0)
		if n0.length() < 1e-6:
			n0 = perp(Vector3(1, 0, 0), u0)
	n0 = n0.normalized()
	var n := perp(pole - a, u)
	if n.length() < 1e-5:
		n = arc(u0, u).xform(n0)
		n = perp(n, u)
	n = n.normalized()

	# law of cosines: where does the middle joint go?
	var cos_a: float = clamp((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var sin_a := sqrt(max(0.0, 1.0 - cos_a * cos_a))
	var mid: Vector3 = a + u * (l1 * cos_a) + n * (l1 * sin_a)
	var tip: Vector3 = a + u * d

	# rotate the whole reference chain into the new bend plane, then bend it
	var r_plane: Basis = frame(u, n) * frame(u0, n0).inverse()
	var s_up: Basis = arc(r_plane.xform(b0 - a), mid - a)
	var q_up: Basis = s_up * r_plane
	var s_lo: Basis = arc(q_up.xform(c0 - b0), tip - mid)
	var q_lo: Basis = s_lo * q_up

	var bu: Basis = q_up * gu.basis
	var bl: Basis = q_lo * gl.basis
	var be: Basis = target.basis.orthonormalized()

	var g_up := Transform(bu, a)
	var g_lo := Transform(bl, mid)
	var g_en := Transform(be, tip)
	var pose_u: Transform = gu.affine_inverse() * g_up
	var pose_l: Transform = (g_up * rest[1]).affine_inverse() * g_lo
	var pose_e: Transform = (g_lo * rest[2]).affine_inverse() * g_en
	out_info["mid"] = mid
	out_info["end"] = tip
	out_info["reached"] = dist <= hi
	return [pose_u, pose_l, pose_e]


# Blend two bone poses: rotation by slerp, translation by lerp.
static func blend_pose(fk: Transform, ik: Transform, w: float) -> Transform:
	if w <= 0.0:
		return fk
	if w >= 1.0:
		return ik
	var q: Quat = Quat(fk.basis.orthonormalized()).slerp(Quat(ik.basis.orthonormalized()), w)
	var sc: Vector3 = basis_scale(fk.basis).linear_interpolate(basis_scale(ik.basis), w)
	return Transform(Basis(q) * scale_basis(sc), fk.origin.linear_interpolate(ik.origin, w))
