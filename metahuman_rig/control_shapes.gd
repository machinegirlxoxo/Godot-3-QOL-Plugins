tool
extends Reference
# Wire shapes for the body control rig (the Godot counterpart of Blender's WGT_* custom shapes).
# Everything is a line mesh, unshaded, drawn on top of the character, on visual layer 20 (like the 3D face board):
# visible in the editor and the Cinematic editor view, not in the Cinematic result / the running game.

const SHAPE_LAYER = 1 << 19
const COL_L = Color(0.25, 0.55, 1.0)
const COL_R = Color(1.0, 0.3, 0.3)
const COL_C = Color(1.0, 0.85, 0.2)
const COL_POLE_LINE = Color(0.7, 0.7, 0.7)
const COL_PELVIS = Color(1.0, 0.5, 0.1)
const LINE_WIDTH = 0.008          # thickness of every control line in metres (the GPU's own lines are always 1 px)

# Layers of the body controls (each can be switched off in the Inspector / Body tab).
const LAYERS = ["Pelvis", "Spine", "Chest", "Pectorals", "Neck/Head", "Arms", "Arm Twists", "Legs", "Leg Twists", "Fingers", "Toes", "IK Arms", "IK Legs"]
const TORSO_LAYERS = ["Pelvis", "Spine", "Chest", "Neck/Head"]      # old scenes stored one "Torso" layer for these
# One colour per body region (both sides the same): head, torso, arms (+ fingers + IK arms), legs (+ toes + IK legs).
const COL_HEAD = Color(0.85, 0.65, 1.0)
const COL_TORSO = Color(1.0, 0.72, 0.1)
const COL_ARMS = Color(0.25, 0.55, 1.0)
const COL_LEGS = Color(0.2, 0.85, 0.35)
const LAYER_REGION = {
	"Pelvis": "torso", "Spine": "torso", "Chest": "torso", "Pectorals": "torso", "Neck/Head": "head",
	"Arms": "arms", "Arm Twists": "arms", "Fingers": "arms", "IK Arms": "arms",
	"Legs": "legs", "Leg Twists": "legs", "Toes": "legs", "IK Legs": "legs",
}
const REGION_COLORS = {"head": COL_HEAD, "torso": COL_TORSO, "arms": COL_ARMS, "legs": COL_LEGS}


static func layer_color(layer: String, _side: String = "c") -> Color:
	return REGION_COLORS.get(LAYER_REGION.get(layer, ""), COL_TORSO)


# Spine / chest bones whatever the naming (spine_01, Spine1, chest, abdomen ...).
static func is_spine(n: String) -> bool:
	var l := n.to_lower()
	if l.ends_with("_l") or l.ends_with("_r"):      # spine_04_latissimus_l and friends are side bones, not the spine
		return false
	return "spine" in l or "chest" in l or "abdomen" in l or "torso" in l


# Pectoral joints (MetaHuman: clavicle_pec_l / _r).
static func is_pec(n: String) -> bool:
	return "pec" in n.to_lower()


# "arm" / "leg" for the twist joints of a limb (upperarm_twist_01_l, lowerarm_twist_02_r, thigh_twist_01_l, calf_twist_01_r ...),
# "" for everything else. The corrective twist joints (twistCor) are left to the face / corrective rig.
static func twist_kind(n: String) -> String:
	var l := n.to_lower()
	if not ("twist" in l) or "cor" in l:
		return ""
	if l.begins_with("upperarm") or l.begins_with("lowerarm"):
		return "arm"
	if l.begins_with("thigh") or l.begins_with("calf"):
		return "leg"
	return ""


# Which layer an FK joint belongs to.
static func joint_layer(j: String) -> String:
	if j == "root" or j == "pelvis":
		return "Pelvis"
	if is_spine(j):
		return "Spine"
	if j == "head" or j.begins_with("neck_"):
		return "Neck/Head"
	if is_pec(j):
		return "Pectorals"
	var tk := twist_kind(j)
	if tk == "arm":
		return "Arm Twists"
	if tk == "leg":
		return "Leg Twists"
	for p in ["clavicle", "upperarm", "lowerarm", "hand"]:
		if j.begins_with(p):
			return "Arms"
	for p in ["thigh", "calf", "foot"]:
		if j.begins_with(p):
			return "Legs"
	if j.begins_with("ball") or "toe" in j:
		return "Toes"
	return "Fingers"


# Line segments (pairs of points) -> thin triangles: every segment becomes two crossed quads of the given width,
# so it looks equally thick from every side.
static func thick(verts: PoolVector3Array, width: float) -> PoolVector3Array:
	var out := PoolVector3Array()
	var i := 0
	while i + 1 < verts.size():
		if _sane(verts[i]) and _sane(verts[i + 1]) and verts[i].distance_to(verts[i + 1]) < MAX_SEGMENT:
			out.append_array(_seg_tris(verts[i], verts[i + 1], width * 0.5))
		i += 2
	return out


# A vertex that is NaN / infinite / absurdly far away becomes a long spike and huge flat shards in the viewport.
const MAX_SEGMENT = 5.0
static func _sane(v: Vector3) -> bool:
	return not (is_nan(v.x) or is_nan(v.y) or is_nan(v.z) or is_inf(v.x) or is_inf(v.y) or is_inf(v.z)) and v.length() < 1.0e5


static func _seg_tris(a: Vector3, b: Vector3, h: float) -> PoolVector3Array:
	var out := PoolVector3Array()      # (pool arrays are passed by value, so this returns its triangles)
	var d := b - a
	if d.length() < 1e-6:
		return out
	d = d.normalized()
	var up := Vector3(0, 1, 0) if abs(d.y) < 0.9 else Vector3(1, 0, 0)
	var n1 := d.cross(up).normalized() * h
	var n2 := d.cross(n1).normalized() * h
	for n in [n1, n2]:
		out.append_array(PoolVector3Array([a - n, a + n, b + n, a - n, b + n, b - n]))
	return out


# Adds one thick segment to an ImmediateGeometry that is between begin(PRIMITIVE_TRIANGLES) and end().
static func emit_thick(g, a: Vector3, b: Vector3, col: Color, width: float) -> void:
	g.set_color(col)
	for v in thick(PoolVector3Array([a, b]), width):
		g.add_vertex(v)


# Same for a list of segment pairs (ring_points).
static func emit_thick_list(g, pts: PoolVector3Array, col: Color, width: float) -> void:
	g.set_color(col)
	for v in thick(pts, width):
		g.add_vertex(v)


static func side_color(side: String) -> Color:
	if side == "l":
		return COL_L
	if side == "r":
		return COL_R
	return COL_C


static func material() -> SpatialMaterial:
	var m := SpatialMaterial.new()
	m.flags_unshaded = true
	m.flags_no_depth_test = true
	m.vertex_color_use_as_albedo = true
	m.flags_do_not_receive_shadows = true
	m.params_cull_mode = SpatialMaterial.CULL_DISABLED
	m.flags_disable_ambient_light = true
	m.render_priority = 100
	return m


static func _mesh(line_verts: PoolVector3Array, col: Color, width: float = LINE_WIDTH) -> ArrayMesh:
	var verts := thick(line_verts, width)
	var cols := PoolColorArray()
	for _i in range(verts.size()):
		cols.append(col)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


static func _box_lines(h: Vector3, out: PoolVector3Array) -> void:
	var c := []
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			for sz in [-1, 1]:
				c.append(Vector3(sx * h.x, sy * h.y, sz * h.z))
	# corner index = 4*x + 2*y + z, edges join corners that differ in one bit
	for i in range(8):
		for bit in [1, 2, 4]:
			var j: int = i | bit
			if j != i and (i & bit) == 0:
				out.append(c[i])
				out.append(c[j])


# Hand IK control: cube with a small axis cross inside (shows the orientation).
static func hand(size: float, col: Color, width: float = LINE_WIDTH) -> ArrayMesh:
	var v := PoolVector3Array()
	_box_lines(Vector3(size, size, size) * 0.5, v)
	var a := size * 0.9
	v.append_array(PoolVector3Array([Vector3(-a, 0, 0), Vector3(a, 0, 0), Vector3(0, -a, 0), Vector3(0, a, 0), Vector3(0, 0, -a), Vector3(0, 0, a)]))
	return _mesh(v, col, width)


# Foot IK control: flatter, longer box (long axis = local Z) with an axis cross.
static func foot(size: float, col: Color, width: float = LINE_WIDTH) -> ArrayMesh:
	var v := PoolVector3Array()
	_box_lines(Vector3(size * 0.5, size * 0.3, size * 1.1), v)
	var a := size * 0.9
	v.append_array(PoolVector3Array([Vector3(-a, 0, 0), Vector3(a, 0, 0), Vector3(0, -a, 0), Vector3(0, a, 0), Vector3(0, 0, -a), Vector3(0, 0, a)]))
	return _mesh(v, col, width)


# Plain line list (segment pairs) -> thick mesh.
static func lines(pts: PoolVector3Array, col: Color, width: float = LINE_WIDTH) -> ArrayMesh:
	return _mesh(pts, col, width)


# Torso controls. Local frame of the handle: x = character right, y = up, z = forward.
# Pelvis: big box with a nose pointing forward.
static func pelvis_points(scale: float) -> PoolVector3Array:
	var h := Vector3(0.19, 0.1, 0.13) * scale
	var v := box_points(Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1), h.x, h.y, h.z)
	v.append(Vector3(0, 0, h.z))
	v.append(Vector3(0, 0, h.z + 0.06 * scale))
	return v


# Spine / chest: horizontal circle around the torso with a nose pointing forward.
static func torso_ring_points(radius: float, scale: float) -> PoolVector3Array:
	var r := radius * scale
	var v := ring_points(Vector3.ZERO, Vector3(0, 1, 0), r, 32)
	v.append(Vector3(0, 0, r))
	v.append(Vector3(0, 0, r + 0.05 * scale))
	return v


# Pole target (elbow / knee direction): octahedron.
static func pole(size: float, col: Color, width: float = LINE_WIDTH) -> ArrayMesh:
	var v := PoolVector3Array()
	var p := [Vector3(size, 0, 0), Vector3(-size, 0, 0), Vector3(0, size, 0), Vector3(0, -size, 0), Vector3(0, 0, size), Vector3(0, 0, -size)]
	for i in range(6):
		for j in range(i + 1, 6):
			if (p[i] + p[j]).length() > 1e-6:     # skip opposite tips
				v.append(p[i])
				v.append(p[j])
	return _mesh(v, col, width)


# Appends a circle of `segments` lines to the immediate geometry, centre c, in the plane perpendicular to `normal`.
static func ring_points(c: Vector3, normal: Vector3, radius: float, segments: int = 20) -> PoolVector3Array:
	var n := normal.normalized()
	if not _sane(n) or n.length() < 0.5:
		n = Vector3(0, 1, 0)
	var t := n.cross(Vector3(0, 1, 0))
	if t.length() < 0.01:
		t = n.cross(Vector3(1, 0, 0))
	t = t.normalized()
	var b := n.cross(t)
	var pts := PoolVector3Array()
	for i in range(segments):
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		pts.append(c + (t * cos(a0) + b * sin(a0)) * radius)
		pts.append(c + (t * cos(a1) + b * sin(a1)) * radius)
	return pts


# Edges (pairs of points) of a box centred on c with half sizes hx, hy, hz along the unit axes ax, ay, az.
static func box_points(c: Vector3, ax: Vector3, ay: Vector3, az: Vector3, hx: float, hy: float, hz: float) -> PoolVector3Array:
	var corners := []
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			for sz in [-1, 1]:
				corners.append(c + ax * (sx * hx) + ay * (sy * hy) + az * (sz * hz))
	var out := PoolVector3Array()
	for i in range(8):
		for bit in [1, 2, 4]:
			if (i & bit) == 0:
				out.append(corners[i])
				out.append(corners[i | bit])
	return out
