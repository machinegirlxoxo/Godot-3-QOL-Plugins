tool
extends ShaderMaterial
# A SpatialMaterial-like material with two extra options taken from Godot 4:
#   Use Z Clip Scale: squashes the object's depth towards the camera so it doesn't clip into walls.
#   Use FOV Override: renders the object with its own field of view (degrees, vertical).
# Limitation: in shadow passes the light's projection is used, so shadows cast by this
# material can look off while these options are on.

enum CullMode { BACK, FRONT, DISABLED }
enum TextureChannel { RED, GREEN, BLUE, ALPHA, GRAYSCALE }

export(Color) var albedo_color : Color = Color(1, 1, 1, 1) setget set_albedo_color
export(Texture) var albedo_texture : Texture setget set_albedo_texture
export(bool) var vertex_color_use_as_albedo : bool = false setget set_vertex_color_use_as_albedo
export(float, 0, 1) var metallic : float = 0.0 setget set_metallic
export(Texture) var metallic_texture : Texture setget set_metallic_texture
export(TextureChannel) var metallic_texture_channel : int = TextureChannel.RED setget set_metallic_texture_channel
export(float, 0, 1) var roughness : float = 1.0 setget set_roughness
export(Texture) var roughness_texture : Texture setget set_roughness_texture
export(TextureChannel) var roughness_texture_channel : int = TextureChannel.RED setget set_roughness_texture_channel
export(float, 0, 1) var specular : float = 0.5 setget set_specular
export(bool) var emission_enabled : bool = false setget set_emission_enabled
export(Color) var emission : Color = Color(0, 0, 0, 1) setget set_emission
export(float, 0, 16) var emission_energy : float = 1.0 setget set_emission_energy
export(bool) var normal_enabled : bool = false setget set_normal_enabled
export(Texture) var normal_texture : Texture setget set_normal_texture
export(float, -16, 16) var normal_scale : float = 1.0 setget set_normal_scale
export(Vector3) var uv1_scale : Vector3 = Vector3(1, 1, 1) setget set_uv1_scale
export(Vector3) var uv1_offset : Vector3 = Vector3(0, 0, 0) setget set_uv1_offset
export(bool) var transparent : bool = false setget set_transparent
export(bool) var unshaded : bool = false setget set_unshaded
export(CullMode) var cull_mode : int = CullMode.BACK setget set_cull_mode

export(bool) var use_z_clip_scale : bool = false setget set_use_z_clip_scale
export(float, 0.01, 1.0, 0.01) var z_clip_scale : float = 1.0 setget set_z_clip_scale
export(bool) var use_fov_override : bool = false setget set_use_fov_override
export(float, 1.0, 179.0, 0.1) var fov_override : float = 75.0 setget set_fov_override

var _rebuild_queued : bool = false


func _init() -> void:
	_queue_rebuild()


func copy_from_spatial(p_material : SpatialMaterial) -> void:
	albedo_color = p_material.albedo_color
	albedo_texture = p_material.albedo_texture
	vertex_color_use_as_albedo = p_material.vertex_color_use_as_albedo
	metallic = p_material.metallic
	metallic_texture = p_material.metallic_texture
	metallic_texture_channel = p_material.metallic_texture_channel
	roughness = p_material.roughness
	roughness_texture = p_material.roughness_texture
	roughness_texture_channel = p_material.roughness_texture_channel
	specular = p_material.metallic_specular
	emission_enabled = p_material.emission_enabled
	emission = p_material.emission
	emission_energy = p_material.emission_energy
	normal_enabled = p_material.normal_enabled
	normal_texture = p_material.normal_texture
	normal_scale = p_material.normal_scale
	uv1_scale = p_material.uv1_scale
	uv1_offset = p_material.uv1_offset
	transparent = p_material.flags_transparent
	unshaded = p_material.flags_unshaded
	match p_material.params_cull_mode:
		SpatialMaterial.CULL_FRONT:
			cull_mode = CullMode.FRONT
		SpatialMaterial.CULL_DISABLED:
			cull_mode = CullMode.DISABLED
		_:
			cull_mode = CullMode.BACK
	_queue_rebuild()


func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	call_deferred("_rebuild")


func _rebuild() -> void:
	_rebuild_queued = false
	var new_shader := Shader.new()
	new_shader.code = _build_code()
	set_shader(new_shader)
	_push_params()


func _push_params() -> void:
	set_shader_param("albedo", albedo_color)
	set_shader_param("albedo_texture", albedo_texture)
	set_shader_param("metallic", metallic)
	set_shader_param("metallic_texture", metallic_texture)
	set_shader_param("metallic_channel", _channel_mask(metallic_texture_channel))
	set_shader_param("roughness", roughness)
	set_shader_param("roughness_texture", roughness_texture)
	set_shader_param("roughness_channel", _channel_mask(roughness_texture_channel))
	set_shader_param("specular", specular)
	set_shader_param("uv1_scale", uv1_scale)
	set_shader_param("uv1_offset", uv1_offset)
	if emission_enabled:
		set_shader_param("emission", emission)
		set_shader_param("emission_energy", emission_energy)
	if normal_enabled:
		set_shader_param("normal_texture", normal_texture)
		set_shader_param("normal_scale", normal_scale)
	if use_z_clip_scale:
		set_shader_param("z_clip_scale", z_clip_scale)
	if use_fov_override:
		set_shader_param("fov_override", fov_override)


func _channel_mask(p_channel : int) -> Color:
	match p_channel:
		TextureChannel.GREEN:
			return Color(0, 1, 0, 0)
		TextureChannel.BLUE:
			return Color(0, 0, 1, 0)
		TextureChannel.ALPHA:
			return Color(0, 0, 0, 1)
		TextureChannel.GRAYSCALE:
			return Color(0.3333, 0.3333, 0.3333, 0)
		_:
			return Color(1, 0, 0, 0)


func _build_code() -> String:
	var modes : Array = []
	match cull_mode:
		CullMode.FRONT:
			modes.append("cull_front")
		CullMode.DISABLED:
			modes.append("cull_disabled")
		_:
			modes.append("cull_back")
	if unshaded:
		modes.append("unshaded")

	var code : String = "shader_type spatial;\n"
	code += "render_mode %s;\n\n" % PoolStringArray(modes).join(", ")
	code += "uniform vec4 albedo : hint_color = vec4(1.0);\n"
	code += "uniform sampler2D albedo_texture : hint_albedo;\n"
	code += "uniform float metallic : hint_range(0.0, 1.0) = 0.0;\n"
	code += "uniform sampler2D metallic_texture : hint_white;\n"
	code += "uniform vec4 metallic_channel = vec4(1.0, 0.0, 0.0, 0.0);\n"
	code += "uniform float roughness : hint_range(0.0, 1.0) = 1.0;\n"
	code += "uniform sampler2D roughness_texture : hint_white;\n"
	code += "uniform vec4 roughness_channel = vec4(1.0, 0.0, 0.0, 0.0);\n"
	code += "uniform float specular : hint_range(0.0, 1.0) = 0.5;\n"
	code += "uniform vec3 uv1_scale = vec3(1.0);\n"
	code += "uniform vec3 uv1_offset = vec3(0.0);\n"
	if emission_enabled:
		code += "uniform vec4 emission : hint_color = vec4(0.0, 0.0, 0.0, 1.0);\n"
		code += "uniform float emission_energy = 1.0;\n"
	if normal_enabled:
		code += "uniform sampler2D normal_texture : hint_normal;\n"
		code += "uniform float normal_scale = 1.0;\n"
	if use_z_clip_scale:
		code += "uniform float z_clip_scale : hint_range(0.01, 1.0) = 1.0;\n"
	if use_fov_override:
		code += "uniform float fov_override : hint_range(1.0, 179.0) = 75.0;\n"

	code += "\nvoid vertex() {\n"
	code += "\tUV = UV * uv1_scale.xy + uv1_offset.xy;\n"
	if use_z_clip_scale or use_fov_override:
		code += "\tvec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);\n"
		code += "\tmat4 proj = PROJECTION_MATRIX;\n"
		if use_fov_override:
			code += "\tif (proj[3][3] == 0.0) {\n"  # perspective projections only
			code += "\t\tfloat aspect = proj[1][1] / proj[0][0];\n"
			code += "\t\tfloat f = 1.0 / tan(radians(fov_override) * 0.5);\n"
			code += "\t\tproj[0][0] = f / aspect;\n"
			code += "\t\tproj[1][1] = f;\n"
			code += "\t}\n"
		code += "\tvec4 clip = proj * view_pos;\n"
		if use_z_clip_scale:
			# Godot 3 (OpenGL) depth runs from -w (near) to +w (far), so squash towards -w.
			# Perspective only, so directional light shadow passes are left untouched.
			code += "\tif (proj[3][3] == 0.0) {\n"
			code += "\t\tclip.z = mix(-clip.w, clip.z, z_clip_scale);\n"
			code += "\t}\n"
		code += "\tPOSITION = clip;\n"
	code += "}\n"

	code += "\nvoid fragment() {\n"
	code += "\tvec4 col = texture(albedo_texture, UV) * albedo;\n"
	if vertex_color_use_as_albedo:
		code += "\tcol *= COLOR;\n"
	code += "\tALBEDO = col.rgb;\n"
	if transparent:
		code += "\tALPHA = col.a;\n"
	code += "\tMETALLIC = metallic * dot(texture(metallic_texture, UV), metallic_channel);\n"
	code += "\tROUGHNESS = roughness * dot(texture(roughness_texture, UV), roughness_channel);\n"
	code += "\tSPECULAR = specular;\n"
	if normal_enabled:
		code += "\tNORMALMAP = texture(normal_texture, UV).rgb;\n"
		code += "\tNORMALMAP_DEPTH = normal_scale;\n"
	if emission_enabled:
		code += "\tEMISSION = emission.rgb * emission_energy;\n"
	code += "}\n"
	return code


func set_albedo_color(v : Color) -> void:
	albedo_color = v
	set_shader_param("albedo", v)

func set_albedo_texture(v : Texture) -> void:
	albedo_texture = v
	set_shader_param("albedo_texture", v)

func set_vertex_color_use_as_albedo(v : bool) -> void:
	vertex_color_use_as_albedo = v
	_queue_rebuild()

func set_metallic(v : float) -> void:
	metallic = v
	set_shader_param("metallic", v)

func set_metallic_texture(v : Texture) -> void:
	metallic_texture = v
	set_shader_param("metallic_texture", v)

func set_metallic_texture_channel(v : int) -> void:
	metallic_texture_channel = v
	set_shader_param("metallic_channel", _channel_mask(v))

func set_roughness_texture(v : Texture) -> void:
	roughness_texture = v
	set_shader_param("roughness_texture", v)

func set_roughness_texture_channel(v : int) -> void:
	roughness_texture_channel = v
	set_shader_param("roughness_channel", _channel_mask(v))

func set_roughness(v : float) -> void:
	roughness = v
	set_shader_param("roughness", v)

func set_specular(v : float) -> void:
	specular = v
	set_shader_param("specular", v)

func set_emission_enabled(v : bool) -> void:
	emission_enabled = v
	_queue_rebuild()

func set_emission(v : Color) -> void:
	emission = v
	if emission_enabled:
		set_shader_param("emission", v)

func set_emission_energy(v : float) -> void:
	emission_energy = v
	if emission_enabled:
		set_shader_param("emission_energy", v)

func set_normal_enabled(v : bool) -> void:
	normal_enabled = v
	_queue_rebuild()

func set_normal_texture(v : Texture) -> void:
	normal_texture = v
	if normal_enabled:
		set_shader_param("normal_texture", v)

func set_normal_scale(v : float) -> void:
	normal_scale = v
	if normal_enabled:
		set_shader_param("normal_scale", v)

func set_uv1_scale(v : Vector3) -> void:
	uv1_scale = v
	set_shader_param("uv1_scale", v)

func set_uv1_offset(v : Vector3) -> void:
	uv1_offset = v
	set_shader_param("uv1_offset", v)

func set_transparent(v : bool) -> void:
	transparent = v
	_queue_rebuild()

func set_unshaded(v : bool) -> void:
	unshaded = v
	_queue_rebuild()

func set_cull_mode(v : int) -> void:
	cull_mode = v
	_queue_rebuild()

func set_use_z_clip_scale(v : bool) -> void:
	use_z_clip_scale = v
	_queue_rebuild()

func set_z_clip_scale(v : float) -> void:
	z_clip_scale = v
	if use_z_clip_scale:
		set_shader_param("z_clip_scale", v)

func set_use_fov_override(v : bool) -> void:
	use_fov_override = v
	_queue_rebuild()

func set_fov_override(v : float) -> void:
	fov_override = v
	if use_fov_override:
		set_shader_param("fov_override", v)
