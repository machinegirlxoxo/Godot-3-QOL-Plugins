tool
extends Spatial
# Per-pixel motion blur for Godot 3.5 (GLES3), ported from the Godot 4 "JFA driven motion blur" CompositorEffect addon
# (Sphynx Motion Blur Toolkit: PreBlurProcessor + SphynxSimpleJumpFloodMotionBlur).
# Draws one full-screen quad with shaders/rtgi_motion_blur.shader after the lit opaque frame (and after the Godot 4 SSAO quad).
# Created next to the WorldEnvironment by the plugin ("Per-pixel Motion Blur" -> Enabled), or add it by hand
# (Spatial + this script). Property names follow the Godot 4 addon.
# Camera motion only: Godot 3 has no velocity buffer, so moving objects are not blurred by their own motion.

const SHADER_PATH = "res://addons/rtgi/shaders/rtgi_motion_blur.shader"
const MAX_PASSES = 5
const PRESETS = [
	{"samples": 6, "jfa_pass_count": 2, "sample_step_multiplier": 24, "pixels_per_sample": 4.0, "fast_trail": true, "dilation_cross_only": true},
	{"samples": 10, "jfa_pass_count": 3, "sample_step_multiplier": 14, "pixels_per_sample": 3.0, "fast_trail": true, "dilation_cross_only": false},
	{"samples": 16, "jfa_pass_count": 3, "sample_step_multiplier": 16, "pixels_per_sample": 1.0, "fast_trail": false, "dilation_cross_only": false},
]
# meshes that did not move for IDLE_AFTER checks are only checked every IDLE_PERIOD frames (keeps the per-frame GDScript loop cheap in big scenes)
const IDLE_AFTER = 30
const IDLE_PERIOD = 8
const RESCAN_FRAMES = 900
const VEL_SHADER_PATH = "res://addons/rtgi/shaders/rtgi_velocity.shader"

export(bool) var enabled = true setget set_enabled
# Quality preset: Low / Medium / High fill samples, jfa_pass_count, sample_step_multiplier, pixels_per_sample and fast_trail.
# Changing any of those by hand switches this to Custom. High = the original look.
export(int, "Low", "Medium", "High", "Custom") var quality = 1 setget set_quality
# Blur length multiplier. With framerate_independent on, the effective value is scaled so the blur simulates a shutter of
# 1 / target_constant_framerate seconds (so 1.0 at 60 fps is half a frame of blur, like the Godot 4 addon).
export(float, 0.0, 4.0, 0.01) var intensity = 1.0 setget set_intensity
# Blur samples per pixel (diminishing returns over 16).
export(int, 4, 64) var samples = 16 setget set_samples
# One blur sample per this many px of blur length (the sample count adapts to the blur, `samples` is the maximum). Higher = faster.
export(float, 0.5, 16.0, 0.1) var pixels_per_sample = 1.0 setget set_pixels_per_sample
# Cheap trail test: only depth is read per sample instead of rebuilding the velocity of every sample (big saving, slightly less accurate on thin fast objects).
export(bool) var fast_trail = false setget set_fast_trail
# Jump flood dilation looks at 4 neighbours per level instead of 8 (about 30% cheaper pass, slightly noisier object trails).
export(bool) var dilation_cross_only = false setget set_dilation_cross_only
# Keep the blur length constant below target_constant_framerate.
export(bool) var framerate_independent = true setget set_framerate_independent
# Allow the framerate independent blur to grow longer than one frame of motion (over-blurs; use with care).
export(bool) var uncapped_independence = false setget set_uncapped_independence
export(float, 10.0, 240.0, 1.0) var target_constant_framerate = 30.0 setget set_target_constant_framerate

# --- jump flood dilation (same meaning as the Godot 4 addon) ---
# Portion of a velocity that may bleed sideways while dilating (higher = moving meshes blur more reliably but wash out what is behind them).
export(float, 0.0, 2.0, 0.01) var perpen_error_threshold = 0.5 setget set_perpen_error_threshold
# Pixel size of one tile / the first jump. Maximum dilation radius (px) = pow(2 + step_exponent_modifier, jfa_pass_count - 1) * sample_step_multiplier.
export(int, 2, 64) var sample_step_multiplier = 16 setget set_sample_step_multiplier
export(float, 0.0, 6.0, 0.01) var step_exponent_modifier = 1.0 setget set_step_exponent_modifier
# Number of jump levels (each level looks further away; 8 depth/velocity taps per level).
export(int, 1, 5) var jfa_pass_count = 3 setget set_jfa_pass_count
# Relative distance (fraction of the depth of the pixel) over which foreground/background weighting fades.
export(float, 0.001, 1.0, 0.001) var depth_softness = 0.05 setget set_depth_softness

# --- velocity components (BlurVelocityComponentResource: multiplier, lower_threshold, upper_threshold) ---
export(float, 0.0, 4.0, 0.01) var camera_rotation_multiplier = 1.0 setget set_camera_rotation_multiplier
export(float, 0.0, 1.0, 0.0001) var camera_rotation_lower_threshold = 0.0 setget set_camera_rotation_lower_threshold
export(float, 0.0, 1.0, 0.0001) var camera_rotation_upper_threshold = 0.0 setget set_camera_rotation_upper_threshold
export(float, 0.0, 4.0, 0.01) var camera_movement_multiplier = 1.0 setget set_camera_movement_multiplier
export(float, 0.0, 1.0, 0.0001) var camera_movement_lower_threshold = 0.0 setget set_camera_movement_lower_threshold
export(float, 0.0, 1.0, 0.0001) var camera_movement_upper_threshold = 0.0 setget set_camera_movement_upper_threshold

export(int, "Off", "Velocity", "Dilated velocity", "Object velocity") var debug_view = 0 setget set_debug_view

# --- moving object blur ---
# Blur meshes that move on their own (not only camera motion). Every MeshInstance whose transform changed since last frame is drawn
# into a helper viewport with its full per-pixel velocity (see shaders/rtgi_velocity.shader). Group `motion_blur_ignore` opts a node out.
export(bool) var object_motion = true setget set_object_motion
export(float, 0.0, 4.0, 0.01) var object_multiplier = 1.0 setget set_object_multiplier

var _mi = null
var _mat = null
var _has_prev = false
var _prev_xform = Transform()
var _prev_scale = Vector2(1, 1)
var _prev_cam_id = 0
var _last_usec = 0
var _temp_intensity = 0.5
var _vp = null          # helper viewport (own world) holding velocity proxies
var _vcam = null
var _tracked = {}       # instance id -> {node, prev (Transform), proxy, mat}
var _scan_countdown = 0
var _applying = false

func set_enabled(v):
	enabled = v
	_has_prev = false
	if is_instance_valid(_mi):
		_mi.visible = enabled and not Engine.editor_hint
func set_intensity(v):
	intensity = v
func set_samples(v):
	_to_custom()
	samples = v
	_push()
func set_framerate_independent(v):
	framerate_independent = v
func set_uncapped_independence(v):
	uncapped_independence = v
func set_target_constant_framerate(v):
	target_constant_framerate = max(v, 1.0)
func set_pixels_per_sample(v):
	_to_custom()
	pixels_per_sample = max(v, 0.5)
	_push()
func set_fast_trail(v):
	_to_custom()
	fast_trail = v
	_push()
func set_dilation_cross_only(v):
	_to_custom()
	dilation_cross_only = v
	_push()
func set_quality(v):
	quality = clamp(int(v), 0, 3)
	# while the scene loads (not in the tree yet) the saved values win; afterwards a preset fills them in
	if quality < 3 and is_inside_tree():
		apply_preset(quality)
func apply_preset(q):
	if q < 0 or q >= PRESETS.size():
		return
	var p = PRESETS[q]
	_applying = true
	samples = p["samples"]
	jfa_pass_count = p["jfa_pass_count"]
	sample_step_multiplier = p["sample_step_multiplier"]
	pixels_per_sample = p["pixels_per_sample"]
	fast_trail = p["fast_trail"]
	dilation_cross_only = p["dilation_cross_only"]
	quality = q
	_applying = false
	_push()
	if Engine.editor_hint:
		property_list_changed_notify()
func _to_custom():
	if _applying or quality == 3 or not is_inside_tree():
		return
	quality = 3
	if Engine.editor_hint:
		property_list_changed_notify()
func set_perpen_error_threshold(v):
	perpen_error_threshold = v
	_push()
func set_sample_step_multiplier(v):
	_to_custom()
	sample_step_multiplier = v
	_push()
func set_step_exponent_modifier(v):
	step_exponent_modifier = v
	_push()
func set_jfa_pass_count(v):
	_to_custom()
	jfa_pass_count = clamp(int(v), 1, MAX_PASSES)
	_push()
func set_depth_softness(v):
	depth_softness = v
	_push()
func set_camera_rotation_multiplier(v):
	camera_rotation_multiplier = v
	_push()
func set_camera_rotation_lower_threshold(v):
	camera_rotation_lower_threshold = v
	_push()
func set_camera_rotation_upper_threshold(v):
	camera_rotation_upper_threshold = v
	_push()
func set_camera_movement_multiplier(v):
	camera_movement_multiplier = v
	_push()
func set_camera_movement_lower_threshold(v):
	camera_movement_lower_threshold = v
	_push()
func set_camera_movement_upper_threshold(v):
	camera_movement_upper_threshold = v
	_push()
func set_object_motion(v):
	object_motion = v
func set_object_multiplier(v):
	object_multiplier = v
	_push()
func set_debug_view(v):
	debug_view = v
	_push()

func _enter_tree():
	if _mi == null:
		_build()
	# run after every other script, so the camera has already moved when we read its transform
	if has_method("set_process_priority"):
		call("set_process_priority", 2147483000)
	set_process(true)
	_has_prev = false
	_last_usec = OS.get_ticks_usec()
	_scan_countdown = 0
	if not get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().connect("node_added", self, "_on_node_added")

func _exit_tree():
	if get_tree() != null and get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().disconnect("node_added", self, "_on_node_added")
	if is_instance_valid(_mi):
		_mi.queue_free()
	if is_instance_valid(_vp):
		_vp.queue_free()
	_vp = null
	_vcam = null
	_tracked = {}
	_mi = null
	_mat = null

# Forget last frame's camera (call after teleporting the camera / cutting to another one to avoid one smeared frame).
func reset():
	_has_prev = false

func _build():
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	# transparent pass, right BEFORE the SSAO quad (-126): SCREEN_TEXTURE is copied before the transparent pass, so a blur drawn after the AO would erase it
	_mat.render_priority = -127 # before the SSAO quad (-126): AO is multiplied onto the blurred frame
	var q = QuadMesh.new()
	q.size = Vector2(2, 2)
	_mi = MeshInstance.new()
	_mi.add_to_group("rtgi_ignore")
	_mi.name = "MotionBlurQuad"
	_mi.mesh = q
	_mi.material_override = _mat
	_mi.extra_cull_margin = 16384.0 # the quad ignores its transform; never cull it
	_mi.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
	_mi.visible = false
	add_child(_mi) # no owner -> not saved with the scene, rebuilt on load
	_build_velocity_viewport()
	_push()

func _build_velocity_viewport():
	_vp = Viewport.new()
	_vp.name = "ObjectVelocityViewport"
	_vp.own_world = true
	_vp.world = World.new()
	_vp.hdr = true
	_vp.keep_3d_linear = true
	_vp.transparent_bg = false
	_vp.msaa = Viewport.MSAA_DISABLED
	_vp.render_target_v_flip = false
	_vp.render_target_update_mode = Viewport.UPDATE_DISABLED # only rendered on frames where a mesh moved
	_vp.size = Vector2(64, 64)
	_vp.add_to_group("rtgi_ignore")
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_color = Color(0, 0, 0)
	_vcam = Camera.new()
	_vcam.environment = env
	_vp.add_child(_vcam)
	_vcam.current = true
	add_child(_vp)
	var tex = _vp.get_texture()
	tex.flags = 0 # nearest, no mipmaps: velocities must not be interpolated across object edges
	_mat.set_shader_param("obj_vel", tex)

# Collect every MeshInstance in the scene (cheap: only a transform per mesh is remembered).
func _scan(n):
	if n == _vp or n == _mi or n.is_in_group("motion_blur_ignore") or n.is_in_group("rtgi_ignore"):
		return
	if n is MeshInstance and n.mesh != null and not (n.mesh is QuadMesh and n.material_override is ShaderMaterial):
		var id = n.get_instance_id()
		if not _tracked.has(id):
			_tracked[id] = _make_entry(n)
	for c in n.get_children():
		_scan(c)

func _on_node_added(n):
	if Engine.editor_hint or not object_motion:
		return
	if n is MeshInstance and not n.is_in_group("motion_blur_ignore") and not n.is_in_group("rtgi_ignore") and n != _mi:
		call_deferred("_track_late", n)

func _track_late(n):
	if is_instance_valid(n) and n.is_inside_tree() and n.mesh != null:
		var id = n.get_instance_id()
		if not _tracked.has(id):
			_tracked[id] = _make_entry(n)

func _make_entry(n):
	return {"node": n, "prev": n.global_transform, "proxy": null, "mat": null, "idle": 0}

# Returns how many objects moved this frame.
func _update_objects(cam, prev_view, ratio):
	if _vp == null:
		return 0
	var use = object_motion and enabled
	if not use:
		_mat.set_shader_param("use_obj", 0.0)
		_vp.render_target_update_mode = Viewport.UPDATE_DISABLED
		return 0
	var moved_count = 0
	var vs = get_viewport().size
	if _vp.size != vs:
		_vp.size = vs
	_vcam.global_transform = cam.global_transform
	_vcam.projection = cam.projection
	_vcam.fov = cam.fov
	_vcam.size = cam.size
	_vcam.near = cam.near
	_vcam.far = cam.far
	_vcam.keep_aspect = cam.keep_aspect
	_mat.set_shader_param("obj_far", cam.far)
	_scan_countdown -= 1
	if _scan_countdown <= 0:
		_scan_countdown = RESCAN_FRAMES # safety net only, new meshes are picked up through node_added
		var root = get_tree().current_scene if get_tree().current_scene else get_tree().root
		_scan(root)
	var dead = []
	var fr = Engine.get_frames_drawn()
	for id in _tracked:
		var e = _tracked[id]
		var idle = e["idle"]
		# dormant mesh: only look at it every IDLE_PERIOD frames
		if idle >= IDLE_AFTER and (fr + id) % IDLE_PERIOD != 0:
			continue
		var n = e["node"]
		if not is_instance_valid(n) or not n.is_inside_tree():
			if e["proxy"] != null:
				e["proxy"].queue_free()
			dead.append(id)
			continue
		var cur = n.global_transform
		var same = cur == e["prev"]
		if same or not n.is_visible_in_tree():
			e["idle"] = min(idle + 1, 1000)
			if e["proxy"] != null and e["proxy"].visible:
				e["proxy"].visible = false
			e["prev"] = cur
			continue
		if idle >= IDLE_AFTER:
			# woke up from dormancy: the stored previous transform is old, start fresh (no blur for this one frame)
			e["idle"] = 0
			e["prev"] = cur
			continue
		e["idle"] = 0
		moved_count += 1
		if e["proxy"] == null:
			var pm = MeshInstance.new()
			pm.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
			pm.add_to_group("rtgi_ignore")
			var m = ShaderMaterial.new()
			m.shader = load(VEL_SHADER_PATH)
			pm.material_override = m
			_vp.add_child(pm)
			e["proxy"] = pm
			e["mat"] = m
		if e["proxy"].mesh != n.mesh:
			e["proxy"].mesh = n.mesh
		e["proxy"].global_transform = cur
		e["proxy"].visible = true
		e["mat"].set_shader_param("prev_model", e["prev"])
		e["mat"].set_shader_param("prev_view", prev_view)
		e["mat"].set_shader_param("prev_proj_ratio", ratio)
		e["mat"].set_shader_param("far_plane", cam.far)
		e["prev"] = cur
	for id in dead:
		_tracked.erase(id)
	# nothing moved: no per-pixel object lookups in the shader and no helper viewport render
	_mat.set_shader_param("use_obj", 1.0 if moved_count > 0 else 0.0)
	_vp.render_target_update_mode = Viewport.UPDATE_ALWAYS if moved_count > 0 else Viewport.UPDATE_DISABLED
	return moved_count

# Projection scale (x, y) a Camera would produce; only used as a previous/current ratio, so small differences cancel out.
func _proj_scale(cam):
	var vs = get_viewport().size
	var aspect = max(vs.x, 1.0) / max(vs.y, 1.0)
	var sx = 1.0
	var sy = 1.0
	if cam.projection == Camera.PROJECTION_PERSPECTIVE:
		var t = max(tan(deg2rad(cam.fov) * 0.5), 0.0001)
		if cam.keep_aspect == Camera.KEEP_WIDTH:
			sx = 1.0 / t
			sy = sx * aspect
		else:
			sy = 1.0 / t
			sx = sy / aspect
	elif cam.projection == Camera.PROJECTION_ORTHOGONAL:
		var h = max(cam.size * 0.5, 0.0001)
		if cam.keep_aspect == Camera.KEEP_WIDTH:
			sx = 1.0 / h
			sy = sx * aspect
		else:
			sy = 1.0 / h
			sx = sy / aspect
	return Vector2(sx, sy)

func _process(_delta):
	if _mat == null or not is_instance_valid(_mi):
		return
	var cam = get_viewport().get_camera()
	if Engine.editor_hint or cam == null or not enabled:
		_mi.visible = false
		_has_prev = false
		return

	# frame time
	var now = OS.get_ticks_usec()
	var dt = max(float(now - _last_usec) / 1000000.0, 0.0001)
	_last_usec = now

	var cur = cam.global_transform
	var ps = _proj_scale(cam)
	var cam_id = cam.get_instance_id()
	if not _has_prev or cam_id != _prev_cam_id:
		_prev_xform = cur
		_prev_scale = ps
		_prev_cam_id = cam_id
		_has_prev = true

	# framerate independent intensity (same formula as the Godot 4 addon)
	_temp_intensity = intensity
	if framerate_independent:
		var capped = 1.0 / target_constant_framerate
		if not uncapped_independence:
			capped = min(capped, dt)
		_temp_intensity = intensity * capped / dt

	var ratio = Vector2(_prev_scale.x / ps.x, _prev_scale.y / ps.y)
	var moved = _update_objects(cam, _prev_xform.affine_inverse(), ratio)
	# camera standing still and nothing moving: skip the whole full-screen pass (also saves the screen/depth copies)
	var cam_still = cur.origin.distance_squared_to(_prev_xform.origin) < 1e-10 \
		and (cur.basis.x - _prev_xform.basis.x).length_squared() < 1e-12 \
		and (cur.basis.y - _prev_xform.basis.y).length_squared() < 1e-12 \
		and (cur.basis.z - _prev_xform.basis.z).length_squared() < 1e-12 \
		and (ratio - Vector2(1, 1)).length_squared() < 1e-12
	_mi.visible = not (cam_still and moved == 0 and debug_view == 0)
	# the dilation search only matters when depth dependent velocity exists: camera translation or a moving object
	var cam_moves = cur.origin.distance_squared_to(_prev_xform.origin) > 1e-6
	_mat.set_shader_param("dilate", 1 if (cam_moves or moved > 0 or debug_view == 2) else 0)
	_mat.set_shader_param("rel_cam", _prev_xform.affine_inverse() * cur)
	_mat.set_shader_param("prev_proj_ratio", ratio)
	_mat.set_shader_param("intensity", _temp_intensity)
	_mat.set_shader_param("frame", float(Engine.get_frames_drawn() % 8))

	_prev_xform = cur
	_prev_scale = ps

func _push():
	if _mat == null:
		return
	var passes = clamp(jfa_pass_count, 1, MAX_PASSES)
	var mult = max(sample_step_multiplier, 1)
	_mat.set_shader_param("samples", max(samples, 1))
	_mat.set_shader_param("px_per_sample", max(pixels_per_sample, 0.5))
	_mat.set_shader_param("fast_trail", 1 if fast_trail else 0)
	_mat.set_shader_param("cross_only", 1 if dilation_cross_only else 0)
	_mat.set_shader_param("perpen_error_thresh", perpen_error_threshold)
	_mat.set_shader_param("step_multiplier", mult)
	_mat.set_shader_param("step_exponent_modifier", step_exponent_modifier)
	_mat.set_shader_param("jfa_pass_count", passes)
	_mat.set_shader_param("max_dilation_radius", pow(2.0 + step_exponent_modifier, passes - 1) * mult)
	_mat.set_shader_param("depth_softness", depth_softness)
	_mat.set_shader_param("debug_view", debug_view)
	_mat.set_shader_param("obj_multiplier", object_multiplier)
	_mat.set_shader_param("comp_multiplier", Vector2(camera_rotation_multiplier, camera_movement_multiplier))
	_mat.set_shader_param("comp_lower", Vector2(camera_rotation_lower_threshold, camera_movement_lower_threshold))
	_mat.set_shader_param("comp_upper", Vector2(camera_rotation_upper_threshold, camera_movement_upper_threshold))
