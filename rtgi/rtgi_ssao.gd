tool
extends Spatial
# Godot 4 style SSAO for Godot 3.5 (GLES3). Draws one full-screen quad with shaders/rtgi_ssao.shader that
# multiplies ambient occlusion onto the lit frame (direct light, ambient and RTGI light alike).
# Created next to the WorldEnvironment by the plugin ("Godot 4 SSAO" -> Enabled), or add it by hand
# (Spatial + this script). Property names follow Godot 4's Environment SSAO settings.

const SHADER_PATH = "res://addons/rtgi/shaders/rtgi_ssao.shader"
# slices x steps per quality level
const QUALITY = [[2, 4], [2, 6], [3, 8], [4, 10]]

export(bool) var enabled = true setget set_enabled
export(int, "Low", "Medium", "High", "Ultra") var quality = 3 setget set_quality
export(float, 0.01, 10.0, 0.01) var radius = 3.0 setget set_radius
export(float, 0.0, 8.0, 0.01) var intensity = 3.5 setget set_intensity
export(float, 0.01, 8.0, 0.01) var power = 1.6 setget set_power
export(float, 0.0, 1.0, 0.01) var detail = 0.3 setget set_detail
export(float, 0.0, 0.5, 0.01) var horizon = 0.03 setget set_horizon
export(float, 0.0, 1.0, 0.01) var strength = 1.0 setget set_strength
export(float, 1.0, 5000.0, 1.0) var fade_begin = 80.0 setget set_fade_begin
export(float, 1.0, 5000.0, 1.0) var fade_end = 120.0 setget set_fade_end

var _mi = null
var _mat = null

func set_enabled(v):
	enabled = v
	_push()
func set_quality(v):
	quality = clamp(int(v), 0, QUALITY.size() - 1)
	_push()
func set_radius(v):
	radius = v
	_push()
func set_intensity(v):
	intensity = v
	_push()
func set_power(v):
	power = v
	_push()
func set_detail(v):
	detail = v
	_push()
func set_horizon(v):
	horizon = v
	_push()
func set_strength(v):
	strength = v
	_push()
func set_fade_begin(v):
	fade_begin = v
	_push()
func set_fade_end(v):
	fade_end = v
	_push()

func _enter_tree():
	if _mi == null:
		_build()

func _exit_tree():
	if is_instance_valid(_mi):
		_mi.queue_free()
	_mi = null
	_mat = null

func _build():
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_mat.render_priority = -126 # after the motion blur quad (-127), which copies the screen and would otherwise paint over the AO; glass etc. still draws on top
	var q = QuadMesh.new()
	q.size = Vector2(2, 2)
	_mi = MeshInstance.new()
	_mi.add_to_group("rtgi_ignore")
	_mi.name = "SSAOQuad"
	_mi.mesh = q
	_mi.material_override = _mat
	_mi.extra_cull_margin = 16384.0 # the quad ignores its transform; never cull it
	_mi.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
	add_child(_mi) # no owner -> not saved with the scene, rebuilt on load
	_push()

func _push():
	if _mat == null or not is_instance_valid(_mi):
		return
	_mi.visible = enabled
	var qd = QUALITY[clamp(quality, 0, QUALITY.size() - 1)]
	_mat.set_shader_param("ssao_slices", qd[0])
	_mat.set_shader_param("ssao_steps", qd[1])
	_mat.set_shader_param("radius", radius)
	_mat.set_shader_param("intensity", intensity)
	_mat.set_shader_param("power", power)
	_mat.set_shader_param("detail", detail)
	_mat.set_shader_param("horizon", horizon)
	_mat.set_shader_param("strength", strength)
	_mat.set_shader_param("fade_begin", fade_begin)
	_mat.set_shader_param("fade_end", fade_end)
