tool
extends Reference
# Shared helpers for the RTGI editor integration (static only).

const GDNS_PATH = "res://addons/rtgi/bin/rtgi.gdns"
const NODE_NAME = "RTGI"
const SSAO_SCRIPT_PATH = "res://addons/rtgi/rtgi_ssao.gd"
const SSAO_NODE_NAME = "RTGI_SSAO"
const MOTION_BLUR_SCRIPT_PATH = "res://addons/rtgi/rtgi_motion_blur.gd"
const MOTION_BLUR_NODE_NAME = "RTGI_MotionBlur"
const MAX_PROBES = 4096
const PROBE_SPACING = 1.0
const PADDING = 1.0

# The WorldEnvironment node (in the edited scene) that uses `env`, or null.
static func find_world_env(n, env):
	if n is WorldEnvironment and n.environment == env:
		return n
	for c in n.get_children():
		var r = find_world_env(c, env)
		if r:
			return r
	return null

# The RTGI node (any node whose script is rtgi.gdns) among the children of `parent`, or null.
static func find_rtgi(parent):
	if parent == null:
		return null
	for c in parent.get_children():
		var s = c.get_script()
		if s and s.resource_path == GDNS_PATH:
			return c
	return null

# The Godot 4 style SSAO node (script rtgi_ssao.gd) among the children of `parent`, or null.
static func find_ssao(parent):
	if parent == null:
		return null
	for c in parent.get_children():
		var s = c.get_script()
		if s and s.resource_path == SSAO_SCRIPT_PATH:
			return c
	return null

# The per-pixel motion blur node (script rtgi_motion_blur.gd) among the children of `parent`, or null.
static func find_motion_blur(parent):
	if parent == null:
		return null
	for c in parent.get_children():
		var s = c.get_script()
		if s and s.resource_path == MOTION_BLUR_SCRIPT_PATH:
			return c
	return null

static func _collect_aabb(n, skip, box):
	if n == skip or n.is_in_group("rtgi_ignore"):
		return
	var is_geo = (n is MeshInstance and n.mesh) or (n is CSGShape and n.is_root_shape())
	if is_geo and n.is_visible_in_tree():
		var a = n.get_transformed_aabb()
		if box[1]:
			box[0] = box[0].merge(a)
		else:
			box[0] = a
			box[1] = true
	for c in n.get_children():
		_collect_aabb(c, skip, box)

# Probe grid that covers every mesh under `parent` (excluding `skip`).
# Returns {} when there is no geometry, else {center, bounds_size, probes_x/y/z}.
static func compute_fit(parent, skip):
	var box = [AABB(), false]
	_collect_aabb(parent, skip, box)
	if not box[1]:
		return {}
	var a = box[0].grow(PADDING)
	var size = a.size
	var spacing = PROBE_SPACING
	var cnt = Vector3(2, 2, 2)
	for i in range(64):
		cnt = Vector3(
				clamp(ceil(size.x / spacing), 2, 64),
				clamp(ceil(size.y / spacing), 2, 64),
				clamp(ceil(size.z / spacing), 2, 64))
		if cnt.x * cnt.y * cnt.z <= MAX_PROBES:
			break
		spacing *= 1.12
	return {
		"center": a.position + a.size * 0.5,
		"bounds_size": size,
		"probes_x": int(cnt.x),
		"probes_y": int(cnt.y),
		"probes_z": int(cnt.z),
	}

# Position/size the RTGI node. `parent` is passed explicitly so this also works before the node is in the tree.
static func apply_fit(node, fit, parent):
	var c = fit["center"]
	if parent is Spatial:
		c = parent.global_transform.xform_inv(c)
	node.translation = c
	node.bounds_size = fit["bounds_size"]
	node.probes_x = fit["probes_x"]
	node.probes_y = fit["probes_y"]
	node.probes_z = fit["probes_z"]

static func current_fit(node, parent):
	var c = node.translation
	if parent is Spatial:
		c = parent.global_transform.xform(c)
	return {
		"center": c,
		"bounds_size": node.bounds_size,
		"probes_x": node.probes_x,
		"probes_y": node.probes_y,
		"probes_z": node.probes_z,
	}


# The tuned default look (bounce light, no leaking onto window frames). Sky light always comes from the Environment.
# Applied to every node the plugin creates, so it works with the shipped binaries (no rebuild needed).
static func apply_look(node):
	node.sky_energy = 1.1
	node.intensity = 5.0
	node.radiance_clamp = 6.0
	node.bounce_strength = 0.97
	node.normal_bias = 1.8
	node.rays_per_probe = 96
	node.env_ambient_strength = 0.0
	# GI quality preset: 0 = Low Quality, 1 = High Quality, 2 = Custom (individual properties). Needs the rebuilt library.
	if "quality_preset" in node:
		node.quality_preset = 1
