tool
extends Spatial
# Physicator for Godot 3.x (formerly SimpliCage)
#
# Pipeline (mirrors the Blender add-on):
#   1. Mask    - pick the region of the mesh that should jiggle
#   2. Cage    - cluster the masked vertices into a low-poly point cage (voxel grid)
#   3. Smooth  - optional Laplacian smoothing of the cage
#   4. Bind    - every mesh vertex follows its nearest cage points (inverse-distance weights)
#   5. Physics - mass/spring simulation of the cage (pinned at the region border)
#   6. Deform  - cage motion is transferred back to the mesh each physics frame
#
# Put this node anywhere in the scene, point `mesh_path` at a MeshInstance.
# Deformation runs in game, and in the editor too (simulate_in_editor), so the cage follows and jiggles while you pose
# the body with the control rig. The editor's temporary deformed mesh is swapped out before every scene save.

enum MaskMode { WHOLE_MESH, SPHERE, VERTEX_COLOR_RED, BONE_WEIGHT }
enum Preset { CUSTOM, BELLY, BREAST, VOLUME_1, VOLUME_2, PECTORALS, BUTT, THIGHS }   # presets only set physics values, never the region

export(NodePath) var mesh_path = NodePath("..") setget set_mesh_path

export(MaskMode) var mask_mode = MaskMode.SPHERE
export(Vector3) var region_center = Vector3.ZERO   # in the mesh's local space
export(float) var region_radius = 0.25

# Bone-weight mask (works on skinned meshes such as MetaHuman bodies)
# `target_bone` (dropdown of the skeleton's bones) is added in _get_property_list()
export(bool) var include_children = true            # also use the bones below the selected one
export(Vector3) var bone_offset = Vector3.ZERO      # shift the bone's centre (mesh space), e.g. forward to the chest surface
export(float) var bone_radius = 0.0                 # >0: only vertices within this distance of the bone centre (soft edge)
export(bool) var ignore_weights = false             # use only the sphere around the bone, not its skin weights
export(PoolStringArray) var bone_filters = PoolStringArray()   # a bone counts if its name contains one of these
export(Vector3) var facing_dir = Vector3.ZERO                  # only vertices whose normal faces this way (ZERO = off)
export(float, -1.0, 1.0) var facing_min = 0.15
export(bool) var use_height_range = false                      # restrict to a band of the mesh height (0 = feet, 1 = top)
export(float, 0.0, 1.0) var height_min = 0.0
export(float, 0.0, 1.0) var height_max = 1.0
export(bool) var relative_units = false    # cell_size and max_offset become fractions of the mesh height

export(float, 0.005, 1.0) var cell_size = 0.05      # cage resolution (smaller = denser cage)
export(int, 0, 10) var smooth_iterations = 1
export(float, 0.0, 1.0) var smooth_factor = 0.5

export(Preset) var preset = Preset.CUSTOM setget set_preset
export(float) var mass = 3.0
export(float) var edge_stiffness = 250.0
export(float) var internal_stiffness = 20.0    # volume/shape preservation
export(float) var pin_stiffness = 80.0
export(float) var damping = 3.0
export(Vector3) var gravity = Vector3.ZERO
export(float) var max_offset = 0.1             # max distance a cage point may stray (mesh units)
export(int, 1, 8) var substeps = 3

export(int, 1, 12) var influence_neighbors = 4  # cage points each vertex follows
export(float, 1.0, 10.0) var influence_gain = 3.0   # >1 makes the region's core follow the cage fully

export(Array, NodePath) var collider_paths = []   # CollisionShape nodes, bodies containing them, or plain MeshInstances
export(float) var collision_margin = 0.02          # extra thickness around colliders (try ~cell_size * 0.5)
export(float, 0.0, 1.0) var collision_friction = 0.2

# Other meshes (e.g. a separate head) whose vertices next to the cage follow it, so seams stay closed.
export(Array, NodePath) var follow_mesh_paths = []
export(float, 0.001, 1.0) var follow_distance = 0.03   # how far from the cage a follower vertex still moves (same units as cell_size)

export(bool) var simulate_in_game = true
export(bool) var simulate_in_editor = true setget set_simulate_in_editor   # cage follows + jiggles while you pose / animate in the editor
export(bool) var show_cage = false setget set_show_cage
export(bool) var reset = false setget set_reset         # tick to snap the cage back to rest (clears dents / jiggle)
export(bool) var rebuild = false setget set_rebuild   # tick to (re)generate the cage

var _mi: MeshInstance
var _orig_mesh: Mesh
var _new_mesh: ArrayMesh
var _built = false

var _rest = PoolVector3Array()      # cage rest positions (mesh local)
var _pos = PoolVector3Array()       # cage positions (world)
var _vel = PoolVector3Array()
var _kpin = PoolRealArray()
var _edges = []                     # [a, b, rest_length]
var _nbrs = []                      # PoolIntArray per point
var _cells = {}                     # Vector3 cell -> point index
var _surf = []                      # per-surface dictionaries
var _dbg: ImmediateGeometry
var target_bone = "(none)"
var _bone_center = Vector3.ZERO
var _has_center = false
var _skel: Skeleton
var _skin: Skin
var _slot_cache = {}                 # mesh bone slot -> [skeleton bone id, bind pose]
var _pslots = []                     # per cage point: PoolIntArray of bone slots
var _pw = []                         # per cage point: PoolRealArray of weights
var _tgt = PoolVector3Array()        # skinned rest position of each cage point (world)
var _mbasis = []                     # per cage point skinning basis
var _minv = []                       # and its inverse
var _scale = 1.0
var _aabb = AABB()
var _cols = []                      # collider descriptions
var _was_ready = false
var _saving = false
var _prev_tgt = PoolVector3Array()
var _fol = []                         # follower meshes (see follow_mesh_paths)
var _cweight = PoolRealArray()       # mask weight of every cage point
var _idle = 0                        # consecutive frames with nothing moving (simulation sleeps)


# ---------------------------------------------------------------- lifecycle

func _ready():
	_was_ready = true
	set_physics_process(false)
	set_process(false)
	if Engine.editor_hint:
		property_list_changed_notify()
		if simulate_in_editor and build_cage():
			_activate()
		return
	if not simulate_in_game:
		return
	if build_cage():
		_activate()


# Scene tabs in the editor remove/re-add the node without calling _ready again.
func _enter_tree():
	if _was_ready and Engine.editor_hint and simulate_in_editor and not _built:
		call_deferred("_editor_restart")


func _editor_restart():
	if is_inside_tree() and not _built and build_cage():
		_activate()


func _exit_tree():
	_restore_mesh()
	_built = false


# The temporary deformed mesh must never be written into the .tscn.
func _notification(what):
	if not Engine.editor_hint:
		return
	if what == 9001:   # NOTIFICATION_EDITOR_PRE_SAVE
		if _built and _mi and is_instance_valid(_mi) and _new_mesh and _mi.mesh == _new_mesh:
			_mi.mesh = _orig_mesh
			_swap_followers(false)
			_saving = true
	elif what == 9002:   # NOTIFICATION_EDITOR_POST_SAVE
		if _saving and _built and _mi and is_instance_valid(_mi) and _new_mesh:
			_mi.mesh = _new_mesh
			_swap_followers(true)
		_saving = false


func _physics_process(delta):
	if Engine.editor_hint:
		return
	_tick(delta)


# Editor: run after every other node's _process (the body rig poses the skeleton in its own _process).
func _process(delta):
	if Engine.editor_hint:
		call_deferred("_tick", min(delta, 1.0 / 30.0))


func _tick(delta: float) -> void:
	if not _built or _mi == null or not is_instance_valid(_mi) or _new_mesh == null:
		return
	if _mi.mesh != _new_mesh:
		return   # mesh swapped out (saving) - wait
	var gt: Transform = _mi.global_transform
	_update_targets(gt)
	# sleep when nothing moves (keeps the editor from redrawing forever)
	var moved = _prev_tgt.size() != _tgt.size() or not _cols.empty()
	if not moved:
		for i in range(_tgt.size()):
			if _tgt[i].distance_squared_to(_prev_tgt[i]) > 0.0000000001:
				moved = true
				break
	if moved:
		_prev_tgt = PoolVector3Array(_tgt)
		_idle = 0
	elif _idle > 8:
		return
	var h = delta / float(max(substeps, 1))
	for s in range(max(substeps, 1)):
		_step(h, gt)
	var vmax = 0.0
	for v in _vel:
		vmax = max(vmax, v.length_squared())
	if not moved and vmax < 0.000001:
		_idle += 1
	elif vmax >= 0.000001:
		_idle = 0
	_apply_deform(gt)
	if show_cage:
		_draw_cage(_pos)


# ---------------------------------------------------------------- setters

func set_preset(v):
	preset = v
	match v:
		Preset.BELLY:
			mass = 6.0; edge_stiffness = 300.0; internal_stiffness = 60.0
			pin_stiffness = 40.0; damping = 12.0
		Preset.BREAST:
			mass = 3.0; edge_stiffness = 250.0; internal_stiffness = 20.0
			pin_stiffness = 80.0; damping = 3.0
		Preset.VOLUME_1:
			mass = 6.0; edge_stiffness = 200.0; internal_stiffness = 40.0
			pin_stiffness = 40.0; damping = 2.0
		Preset.VOLUME_2:
			mass = 6.0; edge_stiffness = 200.0; internal_stiffness = 5.0
			pin_stiffness = 40.0; damping = 2.0
		Preset.PECTORALS:
			mass = 3.0; edge_stiffness = 1600.0; internal_stiffness = 20.0
			pin_stiffness = 700.0; damping = 4.0; max_offset = 0.015
		Preset.BUTT:
			mass = 5.0; edge_stiffness = 1600.0; internal_stiffness = 40.0
			pin_stiffness = 700.0; damping = 5.0; max_offset = 0.02
		Preset.THIGHS:
			mass = 6.0; edge_stiffness = 1600.0; internal_stiffness = 40.0
			pin_stiffness = 700.0; damping = 6.0; max_offset = 0.015


func set_simulate_in_editor(v):
	simulate_in_editor = v
	if not Engine.editor_hint or not is_inside_tree() or not _was_ready:
		return
	if v:
		if build_cage():
			_activate()
	else:
		_restore_mesh()
		_built = false


func set_mesh_path(v):
	mesh_path = v
	if Engine.editor_hint and is_inside_tree():
		property_list_changed_notify()


func _get_property_list():
	var names = "(none)"
	if is_inside_tree() and has_node(mesh_path):
		var m = get_node(mesh_path) as MeshInstance
		if m and m.skeleton != NodePath("") and m.has_node(m.skeleton):
			var sk = m.get_node(m.skeleton) as Skeleton
			if sk:
				for i in range(sk.get_bone_count()):
					names += "," + sk.get_bone_name(i)
	return [{"name": "target_bone", "type": TYPE_STRING, "hint": PROPERTY_HINT_ENUM, "hint_string": names, "usage": PROPERTY_USAGE_DEFAULT}]


func set_show_cage(v):
	show_cage = v
	if not is_inside_tree():
		return
	if v:
		if Engine.editor_hint and not _built:
			build_cage()
		if _built:
			_draw_cage(_pos if _new_mesh != null else _world_rest())
	elif _dbg:
		_dbg.clear()


func set_reset(v):
	reset = false   # behaves like a button
	if v and is_inside_tree():
		reset_simulation()


# Snaps the cage back to its rest pose (no dents, no motion). Also callable from your own scripts.
# If the mesh is stuck on a temporary deformed copy (script reloaded), it puts the original back when it can.
func reset_simulation() -> void:
	if _built and _new_mesh != null and _mi != null and is_instance_valid(_mi) and _mi.mesh == _new_mesh:
		_update_targets(_mi.global_transform)
		_pos = PoolVector3Array(_tgt)
		_prev_tgt = PoolVector3Array(_tgt)
		_vel = PoolVector3Array()
		_vel.resize(_rest.size())
		_idle = 0
		_apply_deform(_mi.global_transform)
		if show_cage:
			_draw_cage(_pos)
		return
	var mi = get_node(mesh_path) as MeshInstance if has_node(mesh_path) else null
	if mi != null and mi.mesh != null and mi.mesh.resource_name == "__simplicage_tmp":
		if _orig_mesh != null and _orig_mesh.resource_name != "__simplicage_tmp":
			mi.mesh = _orig_mesh
			_swap_followers(false)
			_built = false
			push_warning("Physicator: original mesh restored. Tick rebuild to start the simulation again.")
		else:
			push_warning("Physicator: the mesh is stuck on a temporary deformed copy. Reload the scene (Scene > Reload Saved Scene), then rebuild.")


func set_rebuild(v):
	rebuild = false   # behaves like a button
	if not v or not is_inside_tree():
		return
	if build_cage():
		if Engine.editor_hint:
			print("Physicator: cage built with %d points, %d springs" % [_rest.size(), _edges.size()])
			if simulate_in_editor:
				_activate()
			elif show_cage:
				_draw_cage(_world_rest())
		else:
			_activate()


# ---------------------------------------------------------------- cage building

func _unit() -> float:
	return max(_aabb.size.y, 0.0001) if relative_units else 1.0


func _mask_weight(p: Vector3, cols, i: int, ctx: Dictionary) -> float:
	var w = 0.0
	match mask_mode:
		MaskMode.WHOLE_MESH:
			w = 1.0
		MaskMode.SPHERE:
			var t: float = clamp(1.0 - p.distance_to(region_center) / max(region_radius, 0.0001), 0.0, 1.0)
			w = t * t * (3.0 - 2.0 * t)
		MaskMode.VERTEX_COLOR_RED:
			if cols != null:
				w = cols[i].r
		MaskMode.BONE_WEIGHT:
			if ignore_weights:
				w = 1.0
			else:
				w = ctx.bone[i] if ctx.has("bone") else 0.0
	if w <= 0.0:
		return 0.0
	if mask_mode == MaskMode.BONE_WEIGHT and bone_radius > 0.0 and _has_center:
		var dd: float = p.distance_to(_bone_center) / (bone_radius * _unit())
		w *= 1.0 - smoothstep(0.6, 1.0, dd)
		if w <= 0.0:
			return 0.0
	if facing_dir != Vector3.ZERO and ctx.has("normals"):
		var dp: float = ctx.normals[i].dot(facing_dir.normalized())
		w *= smoothstep(facing_min - 0.15, facing_min + 0.15, dp)
	if use_height_range and _aabb.size.y > 0.0:
		var ty: float = (p.y - _aabb.position.y) / _aabb.size.y
		w *= smoothstep(height_min - 0.02, height_min + 0.02, ty) * (1.0 - smoothstep(height_max - 0.02, height_max + 0.02, ty))
	return w


func build_cage() -> bool:
	_restore_mesh()
	_built = false
	_mi = null
	if has_node(mesh_path):
		_mi = get_node(mesh_path) as MeshInstance
	if _mi == null or _mi.mesh == null:
		push_warning("Physicator: mesh_path must point to a MeshInstance that has a mesh.")
		return false
	if _mi.mesh.resource_name == "__simplicage_tmp":
		push_warning("Physicator: the MeshInstance still holds a temporary deformed mesh (script was reloaded). Reload the scene (Scene > Reload Saved Scene) and rebuild.")
		return false
	_orig_mesh = _mi.mesh
	_aabb = _orig_mesh.get_aabb()
	_prepare_skeleton()
	if mask_mode == MaskMode.BONE_WEIGHT and _skel == null:
		push_warning("Physicator: BONE_WEIGHT mask needs the MeshInstance to have a Skeleton (check its 'skeleton' property).")
		return false

	_has_center = false
	if _skel != null and target_bone != "" and target_bone != "(none)":
		var tid = _skel.find_bone(target_bone)
		if tid >= 0:
			_bone_center = _global_rest(tid).origin + bone_offset
			_has_center = true
	if mask_mode == MaskMode.BONE_WEIGHT and not _has_center and bone_filters.size() == 0:
		push_warning("Physicator: pick a target_bone (or set bone_filters) for the bone mask.")
		return false

	_cells.clear()
	_surf.clear()
	var sums = []
	var counts = []
	var wsums = []
	var cs: float = max(cell_size * _unit(), 0.0001)
	var cbones = []

	# 1+2: mask and cluster
	for s in range(_orig_mesh.get_surface_count()):
		var arrays: Array = _orig_mesh.surface_get_arrays(s)
		var verts: PoolVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var cols = arrays[Mesh.ARRAY_COLOR]
		if typeof(cols) != TYPE_COLOR_ARRAY or cols.size() != verts.size():
			cols = null
		var ctx = {}
		var nrm = arrays[Mesh.ARRAY_NORMAL]
		if typeof(nrm) == TYPE_VECTOR3_ARRAY and nrm.size() == verts.size():
			ctx["normals"] = nrm
		var bones = arrays[Mesh.ARRAY_BONES]
		var bweights = arrays[Mesh.ARRAY_WEIGHTS]
		var stride = 0
		if _skel != null and bones != null and bweights != null and verts.size() > 0:
			stride = int(bones.size() / verts.size())
			if bweights.size() != bones.size():
				stride = 0
		if stride > 0 and mask_mode == MaskMode.BONE_WEIGHT and not ignore_weights:
			ctx["bone"] = _bone_mask(bones, bweights, verts.size(), stride)
		var mask = PoolRealArray()
		mask.resize(verts.size())
		for i in range(verts.size()):
			var w = _mask_weight(verts[i], cols, i, ctx)
			mask[i] = w
			if w > 0.01:
				var key: Vector3 = (verts[i] / cs).floor()
				var ci: int
				if _cells.has(key):
					ci = _cells[key]
				else:
					ci = sums.size()
					_cells[key] = ci
					sums.append(Vector3.ZERO)
					counts.append(0)
					wsums.append(0.0)
					cbones.append({})
				if stride > 0:
					for j in range(stride):
						var bw = bweights[i * stride + j]
						if bw > 0.0:
							var slot = int(bones[i * stride + j])
							cbones[ci][slot] = cbones[ci].get(slot, 0.0) + bw * w
				sums[ci] += verts[i]
				counts[ci] += 1
				wsums[ci] += w
		_surf.append({
			"arrays": arrays,
			"base": verts,
			"mask": mask,
			"prim": _orig_mesh.surface_get_primitive_type(s) if _orig_mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES,
			"mat": _orig_mesh.surface_get_material(s),
		})

	var n = sums.size()
	if n == 0:
		push_warning("Physicator: no vertices inside the mask - adjust region_center / region_radius.")
		return false

	_rest = PoolVector3Array()
	_rest.resize(n)
	var weight = PoolRealArray()
	weight.resize(n)
	var keys = []
	keys.resize(n)
	for key in _cells.keys():
		var i: int = _cells[key]
		_rest[i] = sums[i] / float(counts[i])
		weight[i] = wsums[i] / float(counts[i])
		keys[i] = key

	_cweight = weight
	_pslots = []
	_pw = []
	for i in range(n):
		var slots = PoolIntArray()
		var wts = PoolRealArray()
		if _skel != null and i < cbones.size():
			var d: Dictionary = cbones[i]
			var picked = 0
			var tot = 0.0
			while picked < 4 and not d.empty():
				var best = -1
				var bwv = -1.0
				for k2 in d.keys():
					if d[k2] > bwv:
						bwv = d[k2]; best = k2
				slots.append(best); wts.append(bwv); tot += bwv
				d.erase(best)
				picked += 1
			if tot > 0.0:
				for q in range(wts.size()):
					wts[q] = wts[q] / tot
		_pslots.append(slots)
		_pw.append(wts)

	# connectivity (26-neighbourhood on the voxel grid)
	var nb_lists = []
	for i in range(n):
		nb_lists.append(PoolIntArray())
	var pairs = []
	for i in range(n):
		var k: Vector3 = keys[i]
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					if x == 0 and y == 0 and z == 0:
						continue
					var nk = k + Vector3(x, y, z)
					if _cells.has(nk):
						var j: int = _cells[nk]
						nb_lists[i].append(j)
						if j > i:
							pairs.append([i, j])
	_nbrs = nb_lists

	# 3: smoothing
	for it in range(smooth_iterations):
		var smoothed = PoolVector3Array(_rest)
		for i in range(n):
			var nb: PoolIntArray = _nbrs[i]
			if nb.size() == 0:
				continue
			var avg = Vector3.ZERO
			for j in nb:
				avg += _rest[j]
			avg /= float(nb.size())
			smoothed[i] = _rest[i].linear_interpolate(avg, smooth_factor)
		_rest = smoothed

	_edges.clear()
	for p in pairs:
		_edges.append([p[0], p[1], _rest[p[0]].distance_to(_rest[p[1]])])

	# pin weights: points at the region border are held, the core is free
	_kpin = PoolRealArray()
	_kpin.resize(n)
	for i in range(n):
		var f: float = 1.0 - clamp(weight[i], 0.0, 1.0)
		_kpin[i] = 0.05 + 0.95 * f * f

	# 4: bind mesh vertices to cage points
	var k_count: int = max(influence_neighbors, 1)
	for sd in _surf:
		var verts: PoolVector3Array = sd.base
		var mask: PoolRealArray = sd.mask
		var affected = PoolIntArray()
		var bind_idx = PoolIntArray()
		var bind_w = PoolRealArray()
		var infl = PoolRealArray()
		for vi in range(verts.size()):
			if mask[vi] <= 0.01:
				continue
			var base: Vector3 = (verts[vi] / cs).floor()
			var cand = []
			var r = 1
			while r <= 4:
				cand = _gather(base, r)
				if cand.size() >= k_count:
					break
				r += 1
			if cand.empty():
				continue
			# pick k nearest
			var scored = []
			for ci in cand:
				scored.append([verts[vi].distance_squared_to(_rest[ci]), ci])
			scored.sort_custom(self, "_cmp_first")
			var total = 0.0
			var ws = []
			var cnt: int = min(k_count, scored.size())
			for m in range(cnt):
				var wgt: float = 1.0 / (scored[m][0] + 0.000001)
				ws.append(wgt)
				total += wgt
			affected.append(vi)
			for m in range(k_count):
				if m < cnt:
					bind_idx.append(scored[m][1])
					bind_w.append(ws[m] / total)
				else:
					bind_idx.append(-1)
					bind_w.append(0.0)
			infl.append(clamp(mask[vi] * influence_gain, 0.0, 1.0))
		sd["affected"] = affected
		sd["bind_idx"] = bind_idx
		sd["bind_w"] = bind_w
		sd["infl"] = infl
		sd["k"] = k_count

	_build_followers(cs)
	_collect_colliders()
	_update_targets(_mi.global_transform)
	_pos = PoolVector3Array(_tgt)
	_vel = PoolVector3Array()
	_vel.resize(n)
	_built = true
	return true


func _cmp_first(a, b):
	return a[0] < b[0]


func _gather(base: Vector3, r: int) -> Array:
	var out = []
	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			for z in range(-r, r + 1):
				var key = base + Vector3(x, y, z)
				if _cells.has(key):
					out.append(_cells[key])
	return out


func _world_rest() -> PoolVector3Array:
	_update_targets(_mi.global_transform if _mi else global_transform)
	return _tgt


# ---------------------------------------------------------------- skeleton / skinning

func _prepare_skeleton() -> void:
	_skel = null
	_skin = null
	_slot_cache.clear()
	if _mi.skeleton != NodePath("") and _mi.has_node(_mi.skeleton):
		_skel = _mi.get_node(_mi.skeleton) as Skeleton
	_skin = _mi.skin


func _global_rest(id: int) -> Transform:
	var t = _skel.get_bone_rest(id)
	var p = _skel.get_bone_parent(id)
	while p >= 0:
		t = _skel.get_bone_rest(p) * t
		p = _skel.get_bone_parent(p)
	return t


# mesh bone slot -> [skeleton bone id, bind pose]
func _slot(b: int) -> Array:
	if _slot_cache.has(b):
		return _slot_cache[b]
	var id = b
	var bind = Transform.IDENTITY
	if _skin != null and b < _skin.get_bind_count():
		id = _skin.get_bind_bone(b)
		var nm = _skin.get_bind_name(b)
		if nm != "":
			id = _skel.find_bone(nm)
		bind = _skin.get_bind_pose(b)
	elif id >= 0 and id < _skel.get_bone_count():
		bind = _global_rest(id).affine_inverse()
	var out = [id, bind]
	_slot_cache[b] = out
	return out


func _bone_selected(id: int) -> bool:
	if id < 0 or id >= _skel.get_bone_count():
		return false
	if target_bone != "" and target_bone != "(none)":
		var tid = _skel.find_bone(target_bone)
		if tid >= 0:
			if id == tid:
				return true
			if include_children:
				var p = _skel.get_bone_parent(id)
				while p >= 0:
					if p == tid:
						return true
					p = _skel.get_bone_parent(p)
	var nm = _skel.get_bone_name(id).to_lower()
	for f in bone_filters:
		if nm.find(String(f).to_lower()) >= 0:
			return true
	return false


func _bone_mask(bones, bweights, vcount: int, stride: int) -> PoolRealArray:
	var match_slot = {}
	var out = PoolRealArray()
	out.resize(vcount)
	for i in range(vcount):
		var tot = 0.0
		for j in range(stride):
			var bw = bweights[i * stride + j]
			if bw <= 0.0:
				continue
			var slot = int(bones[i * stride + j])
			if not match_slot.has(slot):
				var id = _slot(slot)[0]
				match_slot[slot] = _bone_selected(id)
			if match_slot[slot]:
				tot += bw
		out[i] = clamp(tot, 0.0, 1.0)
	return out


# Skinned rest position of every cage point (world) plus its skinning basis.
func _update_targets(gt: Transform) -> void:
	var n = _rest.size()
	if _tgt.size() != n:
		_tgt.resize(n)
	if _mbasis.size() != n:
		_mbasis.resize(n)
		_minv.resize(n)
	if _skel == null:
		var bs: Basis = gt.basis
		var bi: Basis = bs.inverse()
		_scale = bs.get_scale().x
		for i in range(n):
			_tgt[i] = gt.xform(_rest[i])
			_mbasis[i] = bs
			_minv[i] = bi
		return
	var skel_gt: Transform = _skel.global_transform
	_scale = skel_gt.basis.get_scale().x
	var slot_xf = {}
	for i in range(n):
		var slots: PoolIntArray = _pslots[i]
		var wts: PoolRealArray = _pw[i]
		var m: Transform
		if slots.size() == 0:
			m = gt
		else:
			var basis_sum = Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			var origin_sum = Vector3.ZERO
			for q in range(slots.size()):
				var sl = slots[q]
				if not slot_xf.has(sl):
					var info = _slot(sl)
					var id: int = info[0]
					if id >= 0 and id < _skel.get_bone_count():
						slot_xf[sl] = skel_gt * _skel.get_bone_global_pose(id) * info[1]
					else:
						slot_xf[sl] = gt
				var x: Transform = slot_xf[sl]
				basis_sum = Basis(basis_sum.x + x.basis.x * wts[q], basis_sum.y + x.basis.y * wts[q], basis_sum.z + x.basis.z * wts[q])
				origin_sum += x.origin * wts[q]
			m = Transform(basis_sum, origin_sum)
		_tgt[i] = m.xform(_rest[i])
		_mbasis[i] = m.basis
		_minv[i] = m.basis.inverse()


# ---------------------------------------------------------------- colliders

func _collect_colliders() -> void:
	_cols.clear()
	for p in collider_paths:
		if has_node(p):
			var n = get_node(p)
			var before = _cols.size()
			_scan_shapes(n)
			if _cols.size() == before and n is MeshInstance and n.mesh:
				var bb: AABB = n.mesh.get_aabb()   # no collision shape: use the mesh bounds as a box
				_cols.append({"node": n, "kind": 2, "r": 0.0, "h": 0.0, "ext": bb.size * 0.5, "off": bb.position + bb.size * 0.5})


func _scan_shapes(n: Node) -> void:
	if n == self or n == _mi:
		return
	if n is CollisionShape and n.shape != null and not n.disabled:
		var sh = n.shape
		if sh is SphereShape:
			_cols.append({"node": n, "kind": 0, "r": sh.radius, "h": 0.0, "ext": Vector3.ZERO, "off": Vector3.ZERO})
		elif sh is CapsuleShape:
			_cols.append({"node": n, "kind": 1, "r": sh.radius, "h": sh.height, "ext": Vector3.ZERO, "off": Vector3.ZERO})
		elif sh is BoxShape:
			_cols.append({"node": n, "kind": 2, "r": 0.0, "h": 0.0, "ext": sh.extents, "off": Vector3.ZERO})
		else:
			var bb: AABB = sh.get_debug_mesh().get_aabb()   # other shapes: bounding box approximation
			_cols.append({"node": n, "kind": 2, "r": 0.0, "h": 0.0, "ext": bb.size * 0.5, "off": bb.position + bb.size * 0.5})
	for c in n.get_children():
		_scan_shapes(c)


# lc = [basis (no scale), origin, scale, collider]; returns a world-space correction or ZERO
func _push_out(p: Vector3, lc: Array) -> Vector3:
	var bs: Basis = lc[0]
	var s: float = lc[2]
	var c: Dictionary = lc[3]
	var local: Vector3 = bs.xform_inv(p - lc[1]) - c.off * s
	var corr = Vector3.ZERO
	match c.kind:
		0, 1:
			var closest = Vector3.ZERO
			if c.kind == 1:
				var half: float = c.h * 0.5 * s
				closest = Vector3(0.0, 0.0, clamp(local.z, -half, half))   # Godot 3 capsules lie along local Z
			var v = local - closest
			var d = v.length()
			var r: float = c.r * s + collision_margin
			if d < r:
				var dir = v / d if d > 0.000001 else Vector3.UP
				corr = dir * (r - d)
		2:
			var ext: Vector3 = c.ext * s + Vector3.ONE * collision_margin
			var q = Vector3(abs(local.x) - ext.x, abs(local.y) - ext.y, abs(local.z) - ext.z)
			if q.x < 0.0 and q.y < 0.0 and q.z < 0.0:
				if q.x >= q.y and q.x >= q.z:
					corr = Vector3((1.0 if local.x >= 0.0 else -1.0) * -q.x, 0.0, 0.0)
				elif q.y >= q.z:
					corr = Vector3(0.0, (1.0 if local.y >= 0.0 else -1.0) * -q.y, 0.0)
				else:
					corr = Vector3(0.0, 0.0, (1.0 if local.z >= 0.0 else -1.0) * -q.z)
	return bs.xform(corr)


# ---------------------------------------------------------------- runtime

func _activate():
	_new_mesh = ArrayMesh.new()
	_new_mesh.resource_name = "__simplicage_tmp"
	_idle = 0
	_prev_tgt = PoolVector3Array()
	_new_mesh.custom_aabb = _orig_mesh.get_aabb().grow(max_offset * _unit() * 2.0)
	_mi.mesh = _new_mesh
	for fl in _fol:
		fl.new.custom_aabb = fl.orig.get_aabb().grow(max_offset * _unit() * 2.0)
		fl.mi.mesh = fl.new
	_apply_deform(_mi.global_transform)
	if Engine.editor_hint:
		set_process(true)
		set_physics_process(false)
	else:
		set_process(false)
		set_physics_process(true)


func _restore_mesh():
	_swap_followers(false)
	_fol.clear()
	if _mi and is_instance_valid(_mi) and _orig_mesh and _new_mesh and _mi.mesh == _new_mesh:
		_mi.mesh = _orig_mesh
	_new_mesh = null
	set_physics_process(false)
	set_process(false)


func _step(h: float, gt: Transform) -> void:
	var n = _rest.size()
	var sc: float = _scale
	var inv_m: float = 1.0 / max(mass, 0.0001)
	var acc = PoolVector3Array()
	acc.resize(n)

	for i in range(n):
		var target = _tgt[i]
		acc[i] = (target - _pos[i]) * (pin_stiffness * _kpin[i] * inv_m) + gravity

	var ke = edge_stiffness * inv_m
	for e in _edges:
		var a: int = e[0]
		var b: int = e[1]
		var d = _pos[b] - _pos[a]
		var l = d.length()
		if l < 0.00001:
			continue
		var f = d / l * ((l - e[2] * sc) * ke)
		acc[a] += f
		acc[b] -= f

	if internal_stiffness > 0.0:
		var ki = internal_stiffness * inv_m
		for i in range(n):
			var nb: PoolIntArray = _nbrs[i]
			if nb.size() == 0:
				continue
			var avg = Vector3.ZERO
			var avg_rest = Vector3.ZERO
			for j in nb:
				avg += _pos[j]
				avg_rest += _rest[j]
			avg /= float(nb.size())
			avg_rest /= float(nb.size())
			var desired = avg + _mbasis[i].xform(_rest[i] - avg_rest)
			acc[i] += (desired - _pos[i]) * ki

	var damp: float = max(0.0, 1.0 - damping * h)
	var lim: float = max_offset * _unit() * sc
	var live = []
	for c in _cols:
		if is_instance_valid(c.node):
			var ct: Transform = c.node.global_transform
			live.append([ct.basis.orthonormalized(), ct.origin, ct.basis.get_scale().x, c])
	for i in range(n):
		_vel[i] = (_vel[i] + acc[i] * h) * damp
		_pos[i] += _vel[i] * h
		var t = _tgt[i]
		var off = _pos[i] - t
		if off.length() > lim:
			_pos[i] = t + off.normalized() * lim
		for lc in live:
			var corr: Vector3 = _push_out(_pos[i], lc)
			if corr != Vector3.ZERO:
				_pos[i] += corr
				var nrm = corr.normalized()
				var vn = _vel[i].dot(nrm)
				if vn < 0.0:
					_vel[i] -= nrm * vn
				var vt = _vel[i] - nrm * _vel[i].dot(nrm)
				_vel[i] -= vt * collision_friction


func _apply_deform(gt: Transform) -> void:
	var n = _rest.size()
	var disp = PoolVector3Array()
	disp.resize(n)
	for i in range(n):
		disp[i] = _minv[i].xform(_pos[i] - _tgt[i])

	_new_mesh.clear_surfaces()
	for s in range(_surf.size()):
		var sd = _surf[s]
		var base: PoolVector3Array = sd.base
		var out = PoolVector3Array(base)
		var affected: PoolIntArray = sd.affected
		var bi: PoolIntArray = sd.bind_idx
		var bw: PoolRealArray = sd.bind_w
		var infl: PoolRealArray = sd.infl
		var k: int = sd.k
		for a in range(affected.size()):
			var d = Vector3.ZERO
			for m in range(k):
				var ci = bi[a * k + m]
				if ci < 0:
					break
				d += disp[ci] * bw[a * k + m]
			var vi = affected[a]
			out[vi] = base[vi] + d * infl[a]
		var arrays: Array = sd.arrays
		arrays[Mesh.ARRAY_VERTEX] = out
		_new_mesh.add_surface_from_arrays(sd.prim, arrays, [], 0)
		if sd.mat:
			_new_mesh.surface_set_material(s, sd.mat)

	# follower meshes (e.g. the head): same cage displacement for their vertices next to the cage
	for fl in _fol:
		if not is_instance_valid(fl.mi):
			continue
		var nm: ArrayMesh = fl.new
		var fb: Basis = fl.basis
		nm.clear_surfaces()
		for s in range(fl.surf.size()):
			var fd = fl.surf[s]
			var fbase: PoolVector3Array = fd.base
			var fout = PoolVector3Array(fbase)
			var faff: PoolIntArray = fd.affected
			var fbi: PoolIntArray = fd.bind_idx
			var fbw: PoolRealArray = fd.bind_w
			var finfl: PoolRealArray = fd.infl
			var fk: int = fd.k
			for a in range(faff.size()):
				var d = Vector3.ZERO
				for m in range(fk):
					var ci = fbi[a * fk + m]
					if ci < 0:
						break
					d += disp[ci] * fbw[a * fk + m]
				var vi = faff[a]
				fout[vi] = fbase[vi] + fb.xform(d) * finfl[a]
			var farrays: Array = fd.arrays
			farrays[Mesh.ARRAY_VERTEX] = fout
			nm.add_surface_from_arrays(fd.prim, farrays, fd.bs, 0)
			if fd.mat:
				nm.surface_set_material(s, fd.mat)


# ---------------------------------------------------------------- follower meshes (head etc.)

func _swap_followers(to_new: bool) -> void:
	for fl in _fol:
		if is_instance_valid(fl.mi):
			if to_new:
				fl.mi.mesh = fl.new
			elif fl.mi.mesh == fl.new:
				fl.mi.mesh = fl.orig


# Binds the vertices of the follower meshes that lie within follow_distance of a cage point to the cage.
func _build_followers(cs: float) -> void:
	_fol.clear()
	if follow_mesh_paths.empty() or _rest.size() == 0:
		return
	var reach: float = max(follow_distance * _unit(), cs)
	var reach2: float = reach * reach
	var k_count: int = max(influence_neighbors, 1)
	var lo: Vector3 = _rest[0]
	var hi: Vector3 = _rest[0]
	for p in _rest:
		lo = Vector3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
		hi = Vector3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
	var box: AABB = AABB(lo, hi - lo).grow(reach)
	for np in follow_mesh_paths:
		if not has_node(np):
			continue
		var f = get_node(np) as MeshInstance
		if f == null or f == _mi or f.mesh == null:
			continue
		if f.mesh.resource_name == "__simplicage_tmp":
			push_warning("Physicator: follower '%s' still holds a temporary mesh. Reload the scene and rebuild." % f.name)
			continue
		var m = f.mesh
		var to_body: Transform = _mi.global_transform.affine_inverse() * f.global_transform   # follower mesh space -> body mesh space
		var surfs = []
		var found = 0
		for s in range(m.get_surface_count()):
			var arrays: Array = m.surface_get_arrays(s)
			var verts: PoolVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var affected = PoolIntArray()
			var bind_idx = PoolIntArray()
			var bind_w = PoolRealArray()
			var infl = PoolRealArray()
			for vi in range(verts.size()):
				var bp: Vector3 = to_body.xform(verts[vi])
				if not box.has_point(bp):
					continue
				var scored = []
				for ci in range(_rest.size()):
					var d2: float = bp.distance_squared_to(_rest[ci])
					if d2 <= reach2:
						scored.append([d2, ci])
				if scored.empty():
					continue
				scored.sort_custom(self, "_cmp_first")
				var cnt: int = min(k_count, scored.size())
				var total = 0.0
				var ws = []
				for q in range(cnt):
					var wgt: float = 1.0 / (scored[q][0] + 0.000001)
					ws.append(wgt)
					total += wgt
				var wavg = 0.0
				affected.append(vi)
				for q in range(k_count):
					if q < cnt:
						bind_idx.append(scored[q][1])
						bind_w.append(ws[q] / total)
						wavg += _cweight[scored[q][1]] * ws[q] / total
					else:
						bind_idx.append(-1)
						bind_w.append(0.0)
				var fall: float = 1.0 - smoothstep(reach * 0.5, reach, sqrt(scored[0][0]))
				infl.append(clamp(wavg * influence_gain, 0.0, 1.0) * fall)
			found += affected.size()
			var bs = []
			if m is ArrayMesh and m.get_blend_shape_count() > 0:
				bs = m.surface_get_blend_shape_arrays(s)
			surfs.append({
				"arrays": arrays,
				"base": verts,
				"prim": m.surface_get_primitive_type(s) if m is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES,
				"mat": m.surface_get_material(s),
				"bs": bs,
				"affected": affected,
				"bind_idx": bind_idx,
				"bind_w": bind_w,
				"infl": infl,
				"k": k_count,
			})
		if found == 0:
			continue   # nothing of this mesh is near the cage: leave it alone
		var nm = ArrayMesh.new()
		nm.resource_name = "__simplicage_tmp"
		if m is ArrayMesh:
			for b in range(m.get_blend_shape_count()):
				nm.add_blend_shape(m.get_blend_shape_name(b))
			nm.blend_shape_mode = m.blend_shape_mode
		_fol.append({"mi": f, "orig": m, "new": nm, "surf": surfs, "basis": to_body.basis.inverse()})
		print("Physicator: follower '%s' - %d vertices follow the cage" % [f.name, found])


# ---------------------------------------------------------------- debug drawing

func _draw_cage(world_points: PoolVector3Array) -> void:
	if _dbg == null or not is_instance_valid(_dbg):
		_dbg = ImmediateGeometry.new()
		var mat = SpatialMaterial.new()
		mat.flags_unshaded = true
		mat.vertex_color_use_as_albedo = true
		_dbg.material_override = mat
		_dbg.set_as_toplevel(true)
		add_child(_dbg)   # not owned -> never saved into the scene
	_dbg.global_transform = Transform.IDENTITY
	_dbg.clear()
	_dbg.begin(Mesh.PRIMITIVE_LINES)
	for e in _edges:
		var pin_a: float = _kpin[e[0]]
		_dbg.set_color(Color(0.3 + 0.7 * (1.0 - pin_a), 0.8 * pin_a + 0.2, 0.2))
		_dbg.add_vertex(world_points[e[0]])
		_dbg.add_vertex(world_points[e[1]])
	if _has_center and _mi:
		var c = _mi.global_transform.xform(_bone_center)
		var r = 0.03 * _scale
		_dbg.set_color(Color(0.2, 0.6, 1.0))
		_dbg.add_vertex(c - Vector3(r, 0, 0)); _dbg.add_vertex(c + Vector3(r, 0, 0))
		_dbg.add_vertex(c - Vector3(0, r, 0)); _dbg.add_vertex(c + Vector3(0, r, 0))
		_dbg.add_vertex(c - Vector3(0, 0, r)); _dbg.add_vertex(c + Vector3(0, 0, r))
	_dbg.end()
